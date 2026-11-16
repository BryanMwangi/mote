import MoteCore
import Network
import WebKit

/// The proxies extensions ask for, through chrome.proxy.settings or Firefox's
/// proxy.onRequest (Scripts/src/extension-shims/proxy.ts).
///
/// As in Chrome, each extension that sets one claims the setting, and the
/// newest install's claim is the one in effect; the others are told another
/// extension controls it, and when the holder clears its claim or is turned
/// off, the next one's takes over.
///
/// While a claim sends pages through a proxy, every website data store
/// Mote's pages and extensions load in goes through ExtensionRelay, which
/// picks each connection's hop from the claim — a PAC script asked per host,
/// as in Chrome — and signs in with what the extension's onAuthRequired
/// listeners give, asked when the proxy asks.
@available(macOS 15.4, *)
@MainActor
enum ExtensionProxy {
    typealias Server = ProxyServer

    /// What an extension's claim sends pages through.
    enum Plan {
        case fixed(ProxyChoice)
        case pac(ExtensionPAC.Script)

        func same(as other: Plan?) -> Bool {
            switch (self, other) {
            case (.fixed(let a), .fixed(let b)): a == b
            case (.pac(let a), .pac(let b)): a === b
            default: false
            }
        }
    }

    /// What each extension set through proxy.settings: nil for a setting
    /// with no proxy (direct, system), which still takes control.
    private static var settingClaims: [String: Plan?] = [:]
    /// A Firefox add-on's proxy.onRequest answer, while it names a proxy.
    private static var requestClaims: [String: ProxyChoice] = [:]
    /// The extension whose claim is in effect.
    private(set) static var holder: String?
    /// What pages go through now; nil, direct.
    private static var applied: Plan?
    /// Some extension has set one this launch: from then on every store is
    /// told, none or not, as one store object may have been given it while
    /// another for the same store says it has none.
    private static var used = false
    /// The relay's port, once it listens.
    private static var relayPort: UInt16?
    private static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()

    /// The extension carrying pages through its proxy now, shown beside the
    /// address: not one whose PAC script sends pages direct, as a VPN's
    /// does while it's off, keeping only its own site on a proxy.
    static var inUse: String? { applied == nil || !carries ? nil : holder }
    private static var carries = false
    /// Whose claim the relay's tunnels were opened for.
    private static var tunnelsFor: String?

    /// WebKit's question for the relay's sign-in, answered (Dialogs).
    static func relayCredential(host: String, port: Int) -> URLCredential? {
        guard let relayPort, applied != nil, port == Int(relayPort), host == "127.0.0.1" || host == "localhost" else { return nil }
        return URLCredential(user: ExtensionRelay.shared.user, password: ExtensionRelay.shared.password, persistence: .forSession)
    }

    // MARK: - Claims

    /// chrome.proxy.settings set (or cleared, with nil) by `id`; returns
    /// once it's in effect, a PAC script loaded.
    static func setSetting(_ value: Any?, by id: String) async {
        guard let value else {
            settingClaims[id] = nil
            return settle()
        }
        settingClaims[id] = .some(await plan(fromSetting: value))
        settle()
    }

    /// proxy.onRequest's answer for a sample page, as proxy.ts asks it.
    static func setRequestAnswer(_ choice: ProxyChoice?, by id: String) {
        guard requestClaims[id] != choice else { return }
        requestClaims[id] = choice
        settle()
    }

    /// At launch, the settings extensions left, before their workers start:
    /// the claim in effect is known at once, not after each has loaded in turn.
    static func restore(_ ids: [String]) async {
        for id in ids {
            guard let value = Extensions.settings(for: id)["proxy.settings"] else { continue }
            settingClaims[id] = .some(await plan(fromSetting: value))
        }
        settle()
    }

    /// An extension's worker is running: one turned on gets its setting back.
    static func loaded(_ id: String) {
        guard settingClaims[id] == nil, let value = Extensions.settings(for: id)["proxy.settings"] else { return }
        Task { await setSetting(value, by: id) }
    }

    /// The extensions that couldn't start after launch hold nothing.
    static func keepOnly(_ running: Set<String>) {
        for id in Set(settingClaims.keys).subtracting(running) { settingClaims[id] = nil }
        settle()
    }

    /// An extension turned off or removed.
    static func release(_ id: String) {
        settingClaims[id] = nil
        requestClaims[id] = nil
        signIns[id] = nil
        asked[id] = nil
        told[id] = nil
        if let port = ports.removeValue(forKey: id), !port.isDisconnected { port.disconnect() }
        settle()
    }

    private static func plan(of id: String) -> Plan? {
        if let choice = requestClaims[id] { return .fixed(choice) }
        return settingClaims[id] ?? nil
    }

    /// When an extension was installed: its claim outranks older ones'.
    static func installedAt(_ id: String) -> Date {
        if let seconds = (Storage.settings.dictionary(forKey: installedKey)?[id] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: seconds)
        }
        // Installed before this was kept.
        let folder = Extensions.folder(for: id)
        return (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static let installedKey = "extensions.installedAt"

    /// Notes an install; an update keeps the first.
    static func noteInstall(of id: String) {
        var all = Storage.settings.dictionary(forKey: installedKey) ?? [:]
        guard all[id] == nil else { return }
        all[id] = Date().timeIntervalSince1970
        Storage.settings.set(all, forKey: installedKey)
    }

    static func forgetInstall(of id: String) {
        var all = Storage.settings.dictionary(forKey: installedKey) ?? [:]
        all[id] = nil
        Storage.settings.set(all, forKey: installedKey)
    }

    // MARK: - Settling on one

    private static func settle() {
        // As in Firefox, a proxy.onRequest answer goes before any proxy.settings value.
        let claimants = requestClaims.isEmpty ? Set(settingClaims.keys) : Set(requestClaims.keys)
        let now = ProxyRules.holder(of: claimants, installedAt: installedAt)
        if now != holder {
            holder = now
            NSLog("Extensions: proxy held by %@", now ?? "none")
        }
        tellChanges()
        guard let wanted = now.flatMap(plan(of:)) else { return apply(nil) }
        if wanted.same(as: applied) { return }
        if relayPort != nil { return apply(wanted) }
        Task {
            relayPort = await ExtensionRelay.shared.start()
            guard relayPort != nil else { return NSLog("Extensions: the proxy relay couldn't start") }
            // Still the one wanted, after the wait.
            if let holder, let plan = plan(of: holder), !plan.same(as: applied) { apply(plan) }
        }
    }

    private static func apply(_ plan: Plan?) {
        let wasOn = applied != nil
        let wasInUse = inUse
        if plan == nil, !wasOn { return }
        applied = plan
        NSLog("Extensions: proxy %@", plan.map(describe) ?? "off")
        if case .pac(let script) = plan {
            // Until it's asked, what the same extension's last script said.
            if tunnelsFor != holder { carries = false }
            Task {
                let sends = await script.entries(for: ExtensionPAC.sample).first != .direct
                guard case .pac(let now) = applied, now === script, sends != carries else { return }
                carries = sends
                Extensions.shared.actionsChanged += 1
            }
        } else {
            carries = plan != nil
        }
        if inUse != wasInUse { Extensions.shared.actionsChanged += 1 }
        // Another extension's proxy: tunnels open go its way no more, and
        // are closed, as Chrome closes its sockets when the proxy changes.
        // The same extension setting its proxy again (a VPN refreshes its
        // PAC script every few seconds) closes only those it moves.
        if tunnelsFor != holder || plan == nil {
            ExtensionRelay.shared.closeAll()
        } else {
            Task { await ExtensionRelay.shared.closeMoved { await hops(for: $0) } }
        }
        tunnelsFor = plan == nil ? nil : holder
        guard wasOn != (plan != nil) else { return }
        used = true
        for store in stores.allObjects { dress(store) }
        restartNetwork()
    }

    private static var restart: Task<Void, Never>?
    private static var lastRestart: Date = .distantPast

    /// Connections WebKit opened before go where they went: a page seen
    /// before the proxy came on would load direct again. WebKit can only
    /// start its network process over, which keeps sign-ins (measured:
    /// session cookies too) and drops what's loading and open sockets,
    /// which sites open again. Changes close together are one restart, and
    /// restarts are a few seconds apart: WebKit stops the app over a second
    /// while the first's new process is still coming up (measured: an
    /// extension turned off and on again at once).
    private static func restartNetwork() {
        restart?.cancel()
        restart = Task {
            try? await Task.sleep(for: .seconds(max(0.3, 3 - Date().timeIntervalSince(lastRestart))))
            guard !Task.isCancelled else { return }
            let terminate = NSSelectorFromString("_terminateNetworkProcess")
            // Only one that's running: WebKit stops the app over one that isn't
            // (as at launch, before the first page).
            guard let store = stores.allObjects.first, store.responds(to: terminate),
                store.responds(to: NSSelectorFromString("_networkProcessExists")),
                store.value(forKey: "_networkProcessExists") as? Bool == true
            else { return }
            lastRestart = Date()
            store.perform(terminate)
            // The new process is given each store's proxy as it last had one,
            // not none (measured): so every store is told again.
            for store in stores.allObjects { dress(store) }
        }
    }

    private static func describe(_ plan: Plan) -> String {
        switch plan {
        case .fixed(let choice): "\(choice.server.kind.rawValue)://\(choice.server.host):\(choice.server.port) from \(holder ?? "?")"
        case .pac: "a PAC script from \(holder ?? "?")"
        }
    }

    /// A store pages are about to load in: through the relay, while a proxy is set.
    static func dress(_ store: WKWebsiteDataStore) {
        stores.add(store)
        // Left alone while no extension has set one.
        guard used else { return }
        guard applied != nil, let relayPort, let port = NWEndpoint.Port(rawValue: relayPort) else {
            store.proxyConfigurations = []
            return
        }
        var relay = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        relay.applyCredential(username: ExtensionRelay.shared.user, password: ExtensionRelay.shared.password)
        store.proxyConfigurations = [relay]
    }

    /// Where a connection to `host` goes, the hops tried in turn (ExtensionRelay).
    static func hops(for host: String) async -> [ProxyHop] {
        switch applied {
        case nil: return [.direct]
        case .fixed(let choice): return ProxyRules.bypasses(host, choice.bypass) ? [.direct] : [.proxy(choice.server)]
        case .pac(let script):
            // The Mac itself never goes through a proxy, as in Chrome.
            if ProxyRules.bypasses(host, []) { return [.direct] }
            return await script.entries(for: host).map {
                switch $0 {
                case .direct: .direct
                case .proxy(let server): .proxy(server)
                }
            }
        }
    }

    // MARK: - Sign-ins

    /// Sign-ins the extensions' listeners gave, by extension and server.
    private static var signIns: [String: [String: (user: String, password: String)]] = [:]
    /// What proxies that refused asked a sign-in with, for the extension's listeners, by extension and server.
    private static var asked: [String: [String: [String: String]]] = [:]
    /// Connections held for a sign-in, by server.
    private static var awaiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// The sign-in the relay gives `server`: one given with it, or the holder's.
    static func signIn(for server: Server) -> (user: String, password: String)? {
        if let user = server.username, let password = server.password { return (user, password) }
        return holder.flatMap { signIns[$0]?[server.key] }
    }

    /// The proxy refused `refused` (or wanted one): the holder's listeners
    /// are asked for a sign-in, and the connection waits for it, ten
    /// seconds at most, as Chrome holds a request on its 407. Nil when none
    /// comes, or the same one again.
    static func freshSignIn(
        for server: Server, asked question: [String: String], refused: (user: String, password: String)?
    ) async
        -> (user: String, password: String)?
    {
        guard let holder else { return nil }
        var question = question
        question["host"] = server.host
        question["port"] = String(server.port)
        question["type"] = server.kind.rawValue
        asked[holder, default: [:]][server.key] = question
        askSignIn(holder)
        let key = server.key
        await withCheckedContinuation { done in
            awaiting[key, default: []].append(done)
            Task {
                try? await Task.sleep(for: .seconds(10))
                awaiting[key]?.forEach { $0.resume() }
                awaiting[key] = nil
            }
        }
        guard let fresh = signIn(for: server), fresh.user != refused?.user || fresh.password != refused?.password else {
            NSLog("Extensions: %@ gave no sign-in for its proxy %@", holder, server.host)
            return nil
        }
        return fresh
    }

    /// What `id`'s proxies asked a sign-in with, for its listeners to answer.
    static func asks(for id: String) -> [[String: String]] {
        Array((asked[id] ?? [:]).values)
    }

    /// The sign-ins `id`'s listeners gave, by host and port.
    static func signIn(_ given: [[String: Any]], by id: String) {
        var mine = signIns[id] ?? [:]
        for entry in given {
            guard let user = entry["username"] as? String, let password = entry["password"] as? String, let host = entry["host"] as? String
            else { continue }
            let port = (entry["port"] as? NSNumber)?.intValue ?? Int(entry["port"] as? String ?? "") ?? 0
            for (key, question) in asked[id] ?? [:]
            where question["host"]?.caseInsensitiveCompare(host) == .orderedSame && Int(question["port"] ?? "") == port {
                mine[key] = (user, password)
                asked[id]?[key] = nil
                awaiting[key]?.forEach { $0.resume() }
                awaiting[key] = nil
            }
        }
        signIns[id] = mine
    }

    /// Asks the extension for its sign-in: at once, over the port its
    /// worker holds open; else its worker is started, and asks as it starts.
    private static func askSignIn(_ id: String) {
        if let port = ports[id], !port.isDisconnected { return port.sendMessage(["signIn": true], completionHandler: nil) }
        Extensions.shared.contexts[id]?.loadBackgroundContent { _ in }
    }

    /// The scheme and realm of a 407's Proxy-Authenticate; nil for another answer.
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

    /// Every proxy for a connection was out of reach: the extension is told
    /// (proxy.onProxyError), at most every few seconds, and may switch servers.
    static func unreachable() {
        guard let holder, Date().timeIntervalSince(lastError) > 5 else { return }
        lastError = Date()
        NSLog("Extensions: %@'s proxy is out of reach", holder)
        tellError(to: holder, "net::ERR_PROXY_CONNECTION_FAILED")
    }

    /// The proxy turned the extension's sign-in away, and it had no other:
    /// told, as Chrome and Firefox tell it, and a VPN fetches new
    /// credentials for its server.
    static func signInRefused() {
        guard let holder, Date().timeIntervalSince(lastError) > 5 else { return }
        lastError = Date()
        tellError(to: holder, "net::ERR_TUNNEL_CONNECTION_FAILED")
    }

    private static var lastError: Date = .distantPast

    // MARK: - Telling extensions

    /// The native app name proxy.ts opens a port to, for what Mote tells it:
    /// a sign-in to give, the setting changing, the proxy failing.
    static let portName = ExtensionShims.application + ".proxy"
    private static var ports: [String: WKWebExtension.MessagePort] = [:]
    /// The last proxy.settings.onChange each was told, as text.
    private static var told: [String: String] = [:]

    /// A port from an extension's worker, kept while it's open.
    static func connect(_ port: WKWebExtension.MessagePort, from id: String) {
        port.messageHandler = { message, _ in
            MainActor.assumeIsolated {
                // The shim holds what it posts until the port is known to have arrived.
                if case .probe(let answer) = SocketRelay.command(message) {
                    if answer { port.sendMessage(SocketRelay.here, completionHandler: nil) }
                    return
                }
                guard (message as? [String: Any])?["hello"] != nil else { return }
                port.sendMessage(["ready": true], completionHandler: nil)
                if let old = ports[id], old !== port, !old.isDisconnected { old.disconnect() }
                ports[id] = port
                told[id] = nil
                tellChanges()
                keepAwake()
            }
        }
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated {
                if ports[id] === port { ports[id] = nil }
            }
        }
    }

    /// WebKit lets a worker go two minutes after it last posted on a port;
    /// asked now and then, the shim answers (native-ports.ts), and a VPN's
    /// worker stays to answer its proxy's sign-ins, as Chrome wakes one for each.
    private static var awake: Task<Void, Never>?
    private static func keepAwake() {
        guard awake == nil else { return }
        awake = Task {
            while !ports.isEmpty {
                try? await Task.sleep(for: .seconds(60))
                // Only those holding a claim: the others' workers may go.
                for (id, port) in ports where !port.isDisconnected && (settingClaims[id] != nil || requestClaims[id] != nil) {
                    port.sendMessage(["__moteNative": "alive"], completionHandler: nil)
                }
            }
            awake = nil
        }
    }

    /// proxy.settings.get for `id`: the value in effect, and who controls it.
    static func state(for id: String) -> [String: Any] {
        let value = holder.flatMap { Extensions.settings(for: $0)["proxy.settings"] } ?? ["mode": "system"]
        return ["value": value, "levelOfControl": ProxyRules.levelOfControl(for: id, holder: holder, installedAt: installedAt)]
    }

    /// proxy.settings.onChange, to each extension with a port whose view of it changed.
    private static func tellChanges() {
        for (id, port) in ports where !port.isDisconnected {
            let details = state(for: id)
            guard let data = try? JSONSerialization.data(withJSONObject: details, options: .sortedKeys) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard told[id] != text else { continue }
            told[id] = text
            port.sendMessage(["change": details], completionHandler: nil)
        }
    }

    /// proxy.onProxyError, and a Firefox add-on's proxy.onError.
    private static func tellError(to id: String, _ error: String) {
        guard let port = ports[id], !port.isDisconnected else { return }
        port.sendMessage(["error": ["fatal": true, "error": error, "details": ""]], completionHandler: nil)
    }

    // MARK: - What extensions say

    /// proxy.onRequest's answer for a page, as proxy.ts sends it: a proxy,
    /// or nothing for none.
    static func choice(fromAnswer value: Any?) -> ProxyChoice? {
        guard let info = value as? [String: Any], let kind = (info["type"] as? String).flatMap(Server.Kind.init(rawValue:)),
            let host = info["host"] as? String, !host.isEmpty, let port = (info["port"] as? NSNumber)?.intValue, (1...65_535).contains(port)
        else { return nil }
        return ProxyChoice(
            server: Server(
                kind: kind, host: host, port: UInt16(port), username: info["username"] as? String, password: info["password"] as? String))
    }

    /// A proxy.settings value's plan: fixed servers or a PAC script; direct,
    /// system and the rest are none.
    private static func plan(fromSetting value: Any?) async -> Plan? {
        switch ProxyRules.setting(value) {
        case .fixed(let choice): .fixed(choice)
        case .pac(let data, let url): await ExtensionPAC.script(data: data, url: url).map { .pac($0) }
        case .none: nil
        }
    }
}
