import Foundation

/// A proxy server, as Network takes one.
public struct ProxyServer: Hashable, Sendable {
    public enum Kind: String, Sendable { case http, https, socks }
    public var kind: Kind
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?

    public init(kind: Kind, host: String, port: UInt16, username: String? = nil, password: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// The server without its sign-in: what a sign-in is kept under.
    public var key: String { "\(kind.rawValue)://\(host.lowercased()):\(port)" }
}

/// Where an extension sends pages with fixed servers: a proxy, and hosts
/// that go direct.
public struct ProxyChoice: Equatable, Sendable {
    public var server: ProxyServer
    /// Hosts that go direct, as domains (see `ProxyRules.bypasses`).
    public var bypass: [String]

    public init(server: ProxyServer, bypass: [String] = []) {
        self.server = server
        self.bypass = bypass
    }
}

/// What a chrome.proxy.settings value (or a Firefox add-on's) asks for.
public enum ProxySetting: Equatable, Sendable {
    /// Fixed servers.
    case fixed(ProxyChoice)
    /// A PAC script, given whole or by address.
    case pac(data: String?, url: String?)
    /// direct, system, auto_detect, and what can't be used: no proxy.
    case none
}

/// One entry of a PAC script's answer ("PROXY a:8080; DIRECT").
public enum PACEntry: Equatable, Sendable {
    case direct
    case proxy(ProxyServer)
}

public enum ProxyRules {
    // MARK: - Settings

    /// A chrome.proxy.settings value, or a Firefox add-on's proxy.settings
    /// value (`proxyType`).
    public static func setting(_ value: Any?) -> ProxySetting {
        guard let setting = value as? [String: Any] else { return .none }
        if setting["proxyType"] != nil { return firefoxSetting(setting) }
        switch setting["mode"] as? String {
        case "fixed_servers":
            guard let rules = setting["rules"] as? [String: Any] else { return .none }
            return fixedServers(rules).map { .fixed($0) } ?? .none
        case "pac_script":
            guard let pac = setting["pacScript"] as? [String: Any] else { return .none }
            let data = (pac["data"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (pac["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return data == nil && url == nil ? .none : .pac(data: data, url: url)
        default:
            return .none
        }
    }

    /// Chrome's fixed_servers rules as pages over HTTPS see them, as most
    /// are: `singleProxy` for all; else `proxyForHttps`, then `fallbackProxy`.
    /// Only `proxyForHttp` leaves HTTPS direct in Chrome, and Network can't
    /// tell the two apart, so it's taken for all pages: a VPN means it.
    static func fixedServers(_ rules: [String: Any]) -> ProxyChoice? {
        let found = ["singleProxy", "proxyForHttps", "fallbackProxy", "proxyForHttp"].lazy.compactMap { rules[$0] as? [String: Any] }.first
        guard let found, let server = server(fromChrome: found) else { return nil }
        let bypass = (rules["bypassList"] as? [String] ?? []).compactMap(domain(bypassing:))
        return ProxyChoice(server: server, bypass: bypass)
    }

    /// One of Chrome's ProxyServer objects: scheme (http by default), host, port.
    static func server(fromChrome info: [String: Any]) -> ProxyServer? {
        guard let host = (info["host"] as? String)?.trimmingCharacters(in: .whitespaces), !host.isEmpty, !host.contains(" ") else {
            return nil
        }
        let kind: ProxyServer.Kind? =
            switch (info["scheme"] as? String ?? "http").lowercased() {
            case "http": .http
            case "https": .https
            // Network speaks SOCKS 5 only.
            case "socks5": .socks
            default: nil
            }
        guard let kind else { return nil }
        let port = (info["port"] as? NSNumber)?.intValue ?? defaultPort(kind)
        guard (1...65_535).contains(port) else { return nil }
        return ProxyServer(kind: kind, host: host, port: UInt16(port))
    }

    static func defaultPort(_ kind: ProxyServer.Kind) -> Int {
        switch kind {
        case .http: 80
        case .https: 443
        case .socks: 1080
        }
    }

    /// A Firefox add-on's proxy.settings value: `manual` with its servers as
    /// "host:port" (the HTTPS one first, or HTTP's for all), and
    /// `passthrough` going direct; `autoConfig` a PAC script by address;
    /// the other types are none.
    static func firefoxSetting(_ setting: [String: Any]) -> ProxySetting {
        switch setting["proxyType"] as? String {
        case "manual": break
        case "autoConfig":
            guard let url = setting["autoConfigUrl"] as? String, !url.isEmpty else { return .none }
            return .pac(data: nil, url: url)
        default: return .none
        }
        let all = setting["httpProxyAll"] as? Bool == true
        let servers: [(String?, ProxyServer.Kind, UInt16)] = [
            (all ? setting["http"] as? String : setting["ssl"] as? String, .http, 443),
            (setting["http"] as? String, .http, 80),
            ((setting["socksVersion"] as? NSNumber)?.intValue == 4 ? nil : setting["socks"] as? String, .socks, 1080),
        ]
        guard let (address, kind, fallback) = servers.first(where: { !($0.0 ?? "").isEmpty }), let address else { return .none }
        // A full address, or host and port.
        let parts = URL(string: address.contains("://") ? address : "http://\(address)")
        guard let host = parts?.host(), !host.isEmpty else { return .none }
        let bypass = (setting["passthrough"] as? String ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).compactMap {
            domain(bypassing: String($0))
        }
        let server = ProxyServer(kind: kind, host: host, port: parts?.port.flatMap { UInt16(exactly: $0) } ?? fallback)
        return .fixed(ProxyChoice(server: server, bypass: bypass))
    }

    /// A bypass list's entry as the domain Network takes: Chrome's and
    /// Firefox's may carry a scheme, a port or a leading `*.` or `.`;
    /// "<local>" (plain host names, which go direct anyway), address
    /// ranges and a browser's own pages are none.
    public static func domain(bypassing entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "<local>", !text.contains("/") || text.contains("://") else { return nil }
        if let range = text.range(of: "://") {
            // A browser's own pages (chrome://newtab) never reach a proxy.
            guard ["http", "https", "ws", "wss"].contains(text[..<range.lowerBound].lowercased()) else { return nil }
            text = String(text[range.upperBound...])
        }
        // about:blank, new-tab-page and the like: no dot, no proxy.
        guard !text.lowercased().hasPrefix("about:") else { return nil }
        text = String(text.prefix { $0 != "/" })
        if !text.hasPrefix("["), let colon = text.lastIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasPrefix("*") || text.hasPrefix(".") { text.removeFirst() }
        // A pattern Network has no word for (`*name*`).
        return text.isEmpty || text.contains("*") ? nil : text.lowercased()
    }

    // MARK: - PAC answers

    /// A PAC script's answer as Chromium's ProxyList::SetFromPacString reads
    /// it: entries split by ";", each a scheme and host:port, those it can't
    /// read skipped. SOCKS is read as Firefox reads it, SOCKS 5; SOCKS4 and
    /// QUIC, which Network can't speak, are skipped. Nothing readable is DIRECT.
    public static func pacEntries(_ answer: String) -> [PACEntry] {
        let entries = answer.split(separator: ";").compactMap { pacEntry(String($0)) }
        return entries.isEmpty ? [.direct] : entries
    }

    /// The entry pages take: the first.
    public static func pacAnswer(_ answer: String) -> PACEntry { pacEntries(answer)[0] }

    static func pacEntry(_ text: String) -> PACEntry? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let scheme = words.first?.uppercased() else { return nil }
        if scheme == "DIRECT" { return words.count == 1 ? .direct : nil }
        let kind: ProxyServer.Kind? =
            switch scheme {
            case "PROXY", "HTTP": .http
            case "HTTPS": .https
            case "SOCKS", "SOCKS5": .socks
            default: nil
            }
        guard let kind, words.count == 2 else { return nil }
        let address = String(words[1])
        guard let parts = URL(string: "http://\(address)"), let host = parts.host(), !host.isEmpty, parts.path.isEmpty,
            parts.user == nil
        else { return nil }
        let port = parts.port ?? defaultPort(kind)
        guard (1...65_535).contains(port) else { return nil }
        return .proxy(ProxyServer(kind: kind, host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: UInt16(port)))
    }

    // MARK: - Going direct

    /// Whether a connection to `host` skips the proxy: as in Chrome, the
    /// Mac itself (localhost, loopback addresses) always does, and a host
    /// matching a bypass domain, or under one.
    public static func bypasses(_ host: String, _ bypass: [String]) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.") { return true }
        return bypass.contains { domain in
            let domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// A CONNECT's target ("host:port", "[v6]:port") as host and port.
    public static func target(_ authority: String) -> (host: String, port: UInt16)? {
        guard let colon = authority.lastIndex(of: ":"), let port = UInt16(authority[authority.index(after: colon)...]), port > 0 else {
            return nil
        }
        var host = String(authority[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    // MARK: - Which extension's setting is in effect

    /// As in Chrome: of the extensions that set one, the newest install's.
    public static func holder(of claimants: some Collection<String>, installedAt: (String) -> Date) -> String? {
        claimants.max { (installedAt($0), $0) < (installedAt($1), $1) }
    }

    /// chrome.types.ChromeSetting's levelOfControl for `id`: another
    /// extension controls it only when that one outranks `id`.
    public static func levelOfControl(for id: String, holder: String?, installedAt: (String) -> Date) -> String {
        guard let holder else { return "controllable_by_this_extension" }
        if holder == id { return "controlled_by_this_extension" }
        return (installedAt(holder), holder) > (installedAt(id), id) ? "controlled_by_other_extensions" : "controllable_by_this_extension"
    }
}
