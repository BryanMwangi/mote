import Foundation
import MoteCore
import Network

/// Where a page's connection goes: straight to the site, or through a proxy.
nonisolated enum ProxyHop: Equatable, Sendable {
    case direct
    case proxy(ProxyServer)
}

/// The local proxy WebKit is pointed at while an extension's proxy carries
/// pages (ExtensionProxy). WebKit takes one fixed proxy per store and asks
/// it the way Apple's Network does, which isn't always the way proxies
/// expect: its CONNECT names the host without the port, and some VPNs'
/// proxies turn that away. So each connection comes here first, and goes
/// on as Chrome would send it:
///
/// - to the hop the extension's setting picks for that host — its PAC
///   script asked per host, its servers tried in turn, a bypass going direct;
/// - with a CONNECT that names host and port, and the extension's sign-in;
/// - a 407 held while the extension's onAuthRequired listeners are asked
///   again, as Chrome holds the request; a proxy out of reach reported to
///   the extension (proxy.onProxyError).
///
/// Only Mote may use it: WebKit is given a sign-in made up at launch, and
/// anything else is turned away.
@available(macOS 15.4, *)
nonisolated final class ExtensionRelay: @unchecked Sendable {
    static let shared = ExtensionRelay()

    let user = UUID().uuidString
    let password = UUID().uuidString
    private var expected: String { "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }

    private let queue = DispatchQueue(label: "io.github.mote-browser.proxy-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: [CheckedContinuation<UInt16?, Never>] = []
    /// Connections to both sides of each tunnel open now.
    private var open: [ObjectIdentifier: [NWConnection]] = [:]
    /// Where each tunnel goes: its host, and the hop it took.
    private var routes: [ObjectIdentifier: (host: String, hop: ProxyHop)] = [:]

    /// Starts it now, on a port of its own, waiting a moment for it: at
    /// launch, before the first page connects. Nil when it can't listen.
    func startNow() -> UInt16? {
        lock.lock()
        if let port {
            lock.unlock()
            return port
        }
        lock.unlock()
        for _ in 0..<5 {
            guard let chosen = NWEndpoint.Port(rawValue: UInt16.random(in: 49_152...64_000)) else { continue }
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: chosen)
            guard let listener = try? NWListener(using: parameters) else { continue }
            let ready = DispatchSemaphore(value: 0)
            let listening = Locked(false)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listening.set(true)
                    ready.signal()
                case .failed, .cancelled: ready.signal()
                default: break
                }
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 0.5) == .success, listening.get() else {
                listener.cancel()
                continue
            }
            lock.lock()
            self.listener = listener
            self.port = chosen.rawValue
            lock.unlock()
            return chosen.rawValue
        }
        return nil
    }

    /// The port it listens on, started the first time.
    func start() async -> UInt16? {
        await withCheckedContinuation { done in
            lock.lock()
            if let port {
                lock.unlock()
                return done.resume(returning: port)
            }
            starting.append(done)
            let first = starting.count == 1
            lock.unlock()
            guard first else { return }
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: parameters) else { return finishStarting(nil) }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: self?.finishStarting(listener?.port?.rawValue)
                case .failed, .cancelled: self?.finishStarting(nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func finishStarting(_ port: UInt16?) {
        lock.lock()
        if self.port == nil { self.port = port }
        if port == nil { listener = nil }
        let waiting = starting
        starting = []
        lock.unlock()
        waiting.forEach { $0.resume(returning: port) }
    }

    /// Closes every tunnel open, as Chrome closes its sockets when the
    /// proxy changes: pages connect again, the new way.
    func closeAll() {
        lock.lock()
        let all = open.values.flatMap { $0 }
        open = [:]
        routes = [:]
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    /// Closes the tunnels a new setting sends another way: the same
    /// extension setting its proxy again leaves the rest open, as Chrome
    /// leaves connections in use, and a VPN turned off this way (its PAC
    /// script now sending pages direct) loses its tunnels.
    func closeMoved(_ hops: @escaping @Sendable (String) async -> [ProxyHop]) async {
        let now = lock.withLock { routes }
        for (key, route) in now where await hops(route.host).first != route.hop { untrack(key) }
    }

    private func track(_ key: ObjectIdentifier, _ connections: [NWConnection]) {
        lock.lock()
        open[key, default: []].append(contentsOf: connections)
        lock.unlock()
    }

    private func untrack(_ key: ObjectIdentifier) {
        lock.lock()
        let mine = open.removeValue(forKey: key) ?? []
        routes[key] = nil
        lock.unlock()
        mine.forEach { $0.cancel() }
    }

    // MARK: - One connection

    private func accept(_ inbound: NWConnection) {
        let key = ObjectIdentifier(inbound)
        track(key, [inbound])
        inbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.untrack(key) }
            if case .cancelled = state { self?.untrack(key) }
        }
        inbound.start(queue: queue)
        Task { [weak self] in await self?.serve(inbound, key: key) }
    }

    private func serve(_ inbound: NWConnection, key: ObjectIdentifier) async {
        var buffer = Data()
        // WebKit's first CONNECT comes without the sign-in; it's asked for, and comes again.
        var request: (head: String, rest: Data)?
        for _ in 0..<3 {
            guard let read = await readHead(inbound, buffer: &buffer) else { return untrack(key) }
            if header("Proxy-Authorization", in: read.head) == expected {
                request = read
                break
            }
            await send(
                inbound,
                "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Mote\"\r\nContent-Length: 0\r\n\r\n")
            buffer = read.rest
        }
        guard let request else { return untrack(key) }
        let words = request.head.prefix { $0 != "\r" }.split(separator: " ")
        guard words.count >= 2, words[0] == "CONNECT", let (host, port) = ProxyRules.target(String(words[1])) else {
            await send(inbound, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return untrack(key)
        }
        let hops = await ExtensionProxy.hops(for: host)
        var proxyDown = false
        for hop in hops {
            let outcome = await connect(hop, host: host, port: port)
            guard case .open(let connection, let rest) = outcome else {
                proxyDown = proxyDown || outcome == .proxyDown
                continue
            }
            let upstream = (connection: connection, rest: rest)
            track(key, [upstream.connection])
            lock.withLock { routes[key] = (host, hop) }
            await send(inbound, "HTTP/1.1 200 Connection established\r\n\r\n")
            if !upstream.rest.isEmpty { await send(inbound, upstream.rest) }
            if !request.rest.isEmpty { await send(upstream.connection, request.rest) }
            splice(inbound, to: upstream.connection, key: key)
            splice(upstream.connection, to: inbound, key: key)
            return
        }
        // The proxy itself out of reach, not a site it couldn't reach.
        if proxyDown { await MainActor.run { ExtensionProxy.unreachable() } }
        await send(inbound, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        untrack(key)
    }

    private enum Outcome: Equatable {
        /// The way through, and what came past the proxy's answer.
        case open(NWConnection, Data)
        /// The proxy can't be reached.
        case proxyDown
        /// The site can't be reached, or the proxy wouldn't go there.
        case refused

        static func == (a: Outcome, b: Outcome) -> Bool {
            switch (a, b) {
            case (.proxyDown, .proxyDown), (.refused, .refused): true
            case (.open(let x, _), .open(let y, _)): x === y
            default: false
            }
        }
    }

    /// A way to host:port through `hop`.
    private func connect(_ hop: ProxyHop, host: String, port: UInt16) async -> Outcome {
        switch hop {
        case .direct:
            guard let site = NWEndpoint.Port(rawValue: port) else { return .refused }
            let connection = NWConnection(host: .init(host), port: site, using: .tcp)
            return await ready(connection) ? .open(connection, Data()) : .refused
        case .proxy(let server) where server.kind == .socks:
            return await socks(server, host: host, port: port)
        case .proxy(let server):
            var signIn = await MainActor.run { ExtensionProxy.signIn(for: server) }
            // Each 407 asks the extension again, as Firefox does, until it
            // gives no sign-in (its way of cancelling) or a few have failed.
            for _ in 0..<3 {
                let connection = NWConnection(
                    host: .init(server.host), port: .init(rawValue: server.port) ?? 443, using: server.kind == .https ? .tls : .tcp)
                guard await ready(connection) else { return .proxyDown }
                var ask = "CONNECT \(authority(host, port)) HTTP/1.1\r\nHost: \(authority(host, port))\r\n"
                if let signIn {
                    ask += "Proxy-Authorization: Basic \(Data("\(signIn.user):\(signIn.password)".utf8).base64EncodedString())\r\n"
                }
                ask += "\r\n"
                await send(connection, ask)
                var buffer = Data()
                guard let answer = await readHead(connection, buffer: &buffer) else {
                    connection.cancel()
                    return .proxyDown
                }
                let status = answer.head.prefix { $0 != "\r" }.split(separator: " ").dropFirst().first
                if status == "200" { return .open(connection, answer.rest) }
                connection.cancel()
                guard status == "407", let asked = ExtensionProxy.challenge(inHead: answer.head) else { return .refused }
                guard let fresh = await ExtensionProxy.freshSignIn(for: server, asked: asked) else { break }
                signIn = fresh
            }
            await MainActor.run { ExtensionProxy.signInRefused() }
            return .refused
        }
    }

    private func authority(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Through a SOCKS 5 proxy (RFC 1928), signed in with a name and password (RFC 1929).
    private func socks(_ server: ProxyServer, host: String, port: UInt16) async -> Outcome {
        let connection = NWConnection(host: .init(server.host), port: .init(rawValue: server.port) ?? 1080, using: .tcp)
        guard await ready(connection) else { return .proxyDown }
        let signIn = await MainActor.run { ExtensionProxy.signIn(for: server) }
        func fail() -> Outcome {
            connection.cancel()
            return .refused
        }
        await send(connection, Data(signIn == nil ? [5, 1, 0] : [5, 2, 0, 2]))
        guard let method = await receive(connection, exactly: 2), method[0] == 5 else { return fail() }
        if method[1] == 2 {
            guard let signIn, let user = signIn.user.data(using: .utf8), let password = signIn.password.data(using: .utf8),
                user.count < 256, password.count < 256
            else { return fail() }
            await send(connection, Data([1, UInt8(user.count)]) + user + Data([UInt8(password.count)]) + password)
            guard let status = await receive(connection, exactly: 2), status[1] == 0 else { return fail() }
        } else if method[1] != 0 {
            return fail()
        }
        guard let name = host.data(using: .utf8), name.count < 256 else { return fail() }
        await send(connection, Data([5, 1, 0, 3, UInt8(name.count)]) + name + Data([UInt8(port >> 8), UInt8(port & 0xff)]))
        guard let reply = await receive(connection, exactly: 4), reply[1] == 0 else { return fail() }
        let rest: Int? =
            switch reply[3] {
            case 1: 4 + 2
            case 4: 16 + 2
            case 3: await receive(connection, exactly: 1).map { Int($0[0]) + 2 }
            default: nil
            }
        guard let rest, await receive(connection, exactly: rest) != nil else { return fail() }
        return .open(connection, Data())
    }

    // MARK: - Reading and writing

    private func ready(_ connection: NWConnection) async -> Bool {
        let queue = self.queue
        return await withCheckedContinuation { done in
            let once = OnceBool(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .cancelled: once.finish(false)
                case .waiting: connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                if once.finish(false) { connection.cancel() }
            }
        }
    }

    private func receive(_ connection: NWConnection, atMost: Int = 65_536) async -> Data? {
        await withCheckedContinuation { done in
            connection.receive(minimumIncompleteLength: 1, maximumLength: atMost) { data, _, complete, error in
                done.resume(returning: data?.isEmpty == false ? data : (complete || error != nil ? nil : Data()))
            }
        }
    }

    private func receive(_ connection: NWConnection, exactly count: Int) async -> Data? {
        await withCheckedContinuation { done in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                done.resume(returning: data?.count == count ? data : nil)
            }
        }
    }

    /// An HTTP head, up to its blank line, and what came after it.
    private func readHead(_ connection: NWConnection, buffer: inout Data) async -> (head: String, rest: Data)? {
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            guard buffer.count < 65_536, let more = await receive(connection), !more.isEmpty else { return nil }
            buffer.append(more)
        }
        guard let range = buffer.range(of: end) else { return nil }
        return (String(decoding: buffer[..<range.upperBound], as: UTF8.self), Data(buffer[range.upperBound...]))
    }

    private func header(_ name: String, in head: String) -> String? {
        head.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
    }

    private func send(_ connection: NWConnection, _ text: String) async { await send(connection, Data(text.utf8)) }

    private func send(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in done.resume() })
        }
    }

    /// Passes what arrives on `from` to `to` until either end closes, which closes both.
    private func splice(_ from: NWConnection, to: NWConnection, key: ObjectIdentifier) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if complete || error != nil { untrack(key) } else { splice(from, to: to, key: key) }
                return
            }
            to.send(
                content: data,
                completion: .contentProcessed { [weak self] sent in
                    guard let self else { return }
                    if sent != nil || complete { untrack(key) } else { splice(from, to: to, key: key) }
                })
        }
    }

    /// A continuation resumed once, by whichever comes first.
    private final class OnceBool: @unchecked Sendable {
        private var done: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()
        init(_ done: CheckedContinuation<Bool, Never>) { self.done = done }
        @discardableResult func finish(_ value: Bool) -> Bool {
            lock.lock()
            let waiting = done
            done = nil
            lock.unlock()
            waiting?.resume(returning: value)
            return waiting != nil
        }
    }
}

/// A value read and written across threads.
nonisolated final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
