import Network
import WebKit

/// The proxy an extension asked for, through chrome.proxy.settings or
/// Firefox's proxy.onRequest (Scripts/src/extension-shims/proxy.ts), put on
/// every website data store Mote's pages and extensions load in. WebKit takes
/// one proxy per store, not one per request, so the whole browser goes through
/// it while it's set. One extension holds it at a time, the last to set it, as
/// in Chrome; it lets go when that extension clears it or is turned off.
@MainActor
enum ExtensionProxy {
    struct Choice: Equatable {
        enum Kind: String { case http, https, socks }
        var kind: Kind
        var host: String
        var port: UInt16
        var username: String?
        var password: String?
        /// Hosts that go direct.
        var bypass: [String] = []
    }

    /// The extension holding it.
    private(set) static var owner: String?
    private(set) static var current: Choice?
    private static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()

    static func set(_ choice: Choice?, by id: String) {
        if choice == nil, owner != id { return }
        owner = choice == nil ? nil : id
        guard current != choice else { return }
        current = choice
        NSLog("Extensions: proxy %@", choice.map { "\($0.kind.rawValue)://\($0.host):\($0.port) from \(id)" } ?? "off")
        for store in stores.allObjects { dress(store) }
        // Connections already open keep going where they went: a page seen
        // before the proxy came on would load direct again. Chrome closes
        // them when the proxy changes; WebKit can only start its network
        // process over, which keeps sign-ins (measured: session cookies too)
        // and drops what's loading and open sockets, which sites open again.
        let restart = NSSelectorFromString("_terminateNetworkProcess")
        if let store = stores.allObjects.first, store.responds(to: restart) { store.perform(restart) }
    }

    /// An extension turned off or removed.
    static func release(_ id: String) { set(nil, by: id) }

    /// A store pages are about to load in: through the proxy, while one is set.
    static func dress(_ store: WKWebsiteDataStore) {
        stores.add(store)
        guard #available(macOS 14, *) else { return }
        let wanted = current.map { [configuration($0)] } ?? []
        // Left alone while there's never been one.
        if wanted.isEmpty && store.proxyConfigurations.isEmpty { return }
        store.proxyConfigurations = wanted
    }

    @available(macOS 14, *)
    private static func configuration(_ choice: Choice) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(choice.host), port: .init(rawValue: choice.port) ?? 443)
        var made =
            switch choice.kind {
            case .https: ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
            case .http: ProxyConfiguration(httpCONNECTProxy: endpoint)
            case .socks: ProxyConfiguration(socksv5Proxy: endpoint)
            }
        if let username = choice.username, let password = choice.password { made.applyCredential(username: username, password: password) }
        made.excludedDomains = choice.bypass
        return made
    }

    // MARK: - The proxy's sign-in

    /// What the proxy asks a sign-in with (its 407's Proxy-Authenticate):
    /// the scheme and the realm, which an extension's onAuthRequired listener
    /// may check before it answers; nil when it lets Mote through, or
    /// doesn't answer. WebKit never brings a proxy's 407 to Mote, so it's
    /// asked once here, a CONNECT without a sign-in.
    nonisolated static func challenge(of choice: Choice) async -> [String: String]? {
        guard choice.kind != .socks, let port = NWEndpoint.Port(rawValue: choice.port) else { return nil }
        let connection = NWConnection(host: .init(choice.host), port: port, using: choice.kind == .https ? .tls : .tcp)
        let queue = DispatchQueue(label: "io.github.mote-browser.proxy-challenge")
        let head: String? = await withCheckedContinuation { done in
            let once = Once(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ask = "CONNECT www.example.com:443 HTTP/1.1\r\nHost: www.example.com:443\r\n\r\n"
                    connection.send(content: Data(ask.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                        once.finish(data.map { String(decoding: $0, as: UTF8.self) })
                    }
                case .failed, .cancelled: once.finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { once.finish(nil) }
        }
        connection.cancel()
        return head.flatMap(Self.challenge(inHead:))
    }

    /// The scheme and realm of a 407's Proxy-Authenticate.
    nonisolated static func challenge(inHead head: String) -> [String: String]? {
        let lines = head.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "407" else { return nil }
        guard let line = lines.first(where: { $0.lowercased().hasPrefix("proxy-authenticate:") }) else {
            return ["scheme": "basic", "realm": ""]
        }
        let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        let scheme = value.prefix { $0 != " " }.lowercased()
        let realm = value.firstMatch(of: /realm="([^"]*)"/.ignoresCase()).map { String($0.output.1) } ?? ""
        return ["scheme": scheme, "realm": realm]
    }

    /// A continuation resumed once, by whichever comes first.
    private nonisolated final class Once: @unchecked Sendable {
        private var done: CheckedContinuation<String?, Never>?
        private let lock = NSLock()
        init(_ done: CheckedContinuation<String?, Never>) { self.done = done }
        func finish(_ value: String?) {
            lock.lock()
            let waiting = done
            done = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }

    // MARK: - What extensions say

    /// proxy.onRequest's answer for a page, as proxy.ts sends it: a proxy,
    /// or nothing for none.
    static func choice(fromAnswer value: Any?) -> Choice? {
        guard let info = value as? [String: Any], let kind = (info["type"] as? String).flatMap(Choice.Kind.init(rawValue:)),
            let host = info["host"] as? String, !host.isEmpty, let port = (info["port"] as? NSNumber)?.intValue, (1...65_535).contains(port)
        else { return nil }
        return Choice(
            kind: kind, host: host, port: UInt16(port), username: info["username"] as? String, password: info["password"] as? String)
    }

    /// A chrome.proxy.settings value: its fixed servers, the one for HTTPS
    /// first; system, direct, a PAC script (which Network can't run) and
    /// the rest are none.
    static func choice(fromSetting value: Any?) -> Choice? {
        guard let setting = value as? [String: Any], setting["mode"] as? String == "fixed_servers",
            let rules = setting["rules"] as? [String: Any]
        else { return nil }
        let server = ["singleProxy", "proxyForHttps", "proxyForHttp", "fallbackProxy"].lazy.compactMap { rules[$0] as? [String: Any] }.first
        guard let server, let host = server["host"] as? String, !host.isEmpty else { return nil }
        let scheme = (server["scheme"] as? String ?? "http").lowercased()
        let kind: Choice.Kind? =
            switch scheme {
            case "http": .http
            case "https": .https
            case "socks5": .socks
            default: nil
            }
        guard let kind else { return nil }
        let port = (server["port"] as? NSNumber)?.intValue ?? (kind == .https ? 443 : kind == .socks ? 1080 : 80)
        guard (1...65_535).contains(port) else { return nil }
        // Chrome's "<local>" means plain host names; those go direct anyway.
        let bypass = (rules["bypassList"] as? [String] ?? []).filter { $0 != "<local>" }.map {
            $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0
        }
        return Choice(kind: kind, host: host, port: UInt16(port), bypass: bypass)
    }
}
