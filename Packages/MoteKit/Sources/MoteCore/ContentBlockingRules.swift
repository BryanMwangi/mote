import Foundation

/// The ad blocker's rules, in WebKit's content blocker format.
public enum ContentBlockingRules {
    /// Ad and tracking domains, blocked only as third-party requests: a site's
    /// own requests to these domains are left alone.
    public static let blockedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// Cosmetic selectors for unambiguous ad slots, kept short so legitimate
    /// content is never hidden.
    public static let adSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
    ]

    /// The URL filter that matches `domain` and its subdomains over http(s).
    public static func urlFilter(for domain: String) -> String {
        "^https?://([^/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.")
    }

    /// The rule list as JSON, ready for `WKContentRuleListStore`.
    public static func json() throws -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            [
                "trigger": ["url-filter": urlFilter(for: domain), "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": adSelectors.joined(separator: ", ")],
        ])
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// uBlock Origin's filter lists, as far as a page's own scripts and styles
/// go: scriptlet rules (`site##+js(name, args…)`) and a site's element hiding
/// (`site##selector`), each with its exceptions (`#@#`), for the sites it
/// names, read as uBlock Origin reads them. Network rules, and hiding meant
/// for every site, are the content rule list's (above).
public struct FilterRules: Sendable {
    public enum Rule: Hashable, Sendable {
        /// A scriptlet's name (`json-prune.js`) and its arguments; no name
        /// at all, as an exception, turns them all off.
        case scriptlet([String])
        case hide(String)
        /// A selector and the declarations it gets (`:style(…)`).
        case style(String, String)
    }

    struct Entry: Sendable {
        let rule: Rule
        let exception: Bool
        /// From a list allowed the scriptlets that need trust.
        let trusted: Bool
    }

    /// By the hostname or entity (`example.*`) it's for; "" for every site.
    private var bySite: [String: [Entry]] = [:]

    public init() {}

    public var count: Int { bySite.values.reduce(0) { $0 + $1.count } }

    /// What the lists' `!#if` lines ask of the browser reading them: one
    /// that runs uBlock Origin's own filtering, in WebKit, on a Mac.
    private static let environment: Set = ["env_safari", "ext_ublock", "cap_user_stylesheet"]

    /// `aliases`: scriptlet names other than their own (`set.js` for `set-constant.js`).
    public mutating func add(_ text: String, trusted: Bool, aliases: [String: String] = [:]) {
        // Whether each `!#if` around the line holds.
        var active: [Bool] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") {
                active.append(Self.holds(line.dropFirst(5)))
            } else if line.hasPrefix("!#else") {
                if let last = active.popLast() { active.append(!last) }
            } else if line.hasPrefix("!#endif") {
                _ = active.popLast()
            } else if active.allSatisfy({ $0 }), !line.hasPrefix("!"), !line.hasPrefix("[") {
                take(line, trusted: trusted, aliases: aliases)
            }
        }
    }

    private static func holds(_ condition: Substring) -> Bool {
        condition.components(separatedBy: "||").contains { all in
            all.components(separatedBy: "&&").allSatisfy { term in
                let term = term.trimmingCharacters(in: .whitespaces.union(["(", ")"]))
                return term.hasPrefix("!") ? !environment.contains(String(term.dropFirst())) : environment.contains(term)
            }
        }
    }

    /// Ways of choosing elements only uBlock Origin's own script follows.
    private static let procedural = [
        ":has-text(", ":upward(", ":xpath(", ":matches-css", ":matches-attr(", ":matches-path(", ":matches-media(",
        ":matches-prop(", ":min-text-length(", ":watch-attr(", ":others(", ":-abp-", ":contains(", ":remove-attr(",
        ":remove-class(", ":shadow(", ":if(", ":if-not(", ":nth-ancestor(", ":spath(",
    ]

    private mutating func take(_ line: String, trusted: Bool, aliases: [String: String]) {
        let marks = [line.range(of: "##"), line.range(of: "#@#")].compactMap { $0 }
        guard let mark = marks.min(by: { $0.lowerBound < $1.lowerBound }) else { return }
        let exception = line[mark] == "#@#"
        let sites = line[..<mark.lowerBound]
        let body = String(line[mark.upperBound...])
        guard !sites.contains("#"), !sites.contains("$") else { return }

        let rule: Rule
        if body.hasPrefix("+js("), body.hasSuffix(")") {
            var args = Self.arguments(String(body.dropFirst(4).dropLast()))
            if let token = args.first {
                let name = (token.hasSuffix(".js") ? String(token.dropLast(3)) : token) + ".js"
                args[0] = aliases[name] ?? name
            }
            rule = .scriptlet(args)
            // Only an exception goes for every site.
            if sites.isEmpty {
                if exception { store("", Entry(rule: rule, exception: true, trusted: trusted)) }
                return
            }
            if args.isEmpty, !exception { return }
        } else {
            guard !sites.isEmpty, !body.hasPrefix("^"), !body.hasPrefix("+"), !body.isEmpty, !body.contains("{") else { return }
            if body.hasSuffix(":remove()") {
                rule = .hide(String(body.dropLast(9)))
            } else if let style = body.range(of: ":style("), body.hasSuffix(")") {
                rule = .style(String(body[..<style.lowerBound]), String(body[style.upperBound...].dropLast()))
            } else {
                rule = .hide(body)
            }
            switch rule {
            case .hide(let selector), .style(let selector, _):
                guard !selector.isEmpty, !Self.procedural.contains(where: selector.contains) else { return }
            case .scriptlet: return
            }
        }
        for site in sites.split(separator: ",") {
            let site = site.trimmingCharacters(in: .whitespaces).lowercased()
            let not = site.hasPrefix("~")
            let name = not ? String(site.dropFirst()) : site
            // Patterns and frames' ancestors aren't followed here.
            guard !name.isEmpty, !name.contains("/"), !name.contains(">"), !(exception && not) else { continue }
            store(name, Entry(rule: rule, exception: exception || not, trusted: trusted))
        }
    }

    private mutating func store(_ site: String, _ entry: Entry) {
        bySite[site, default: []].append(entry)
    }

    /// A scriptlet rule's arguments, its name first, as uBlock Origin splits
    /// them: at commas, each trimmed; one in quotes (' " `) keeps its commas
    /// and spaces; a backslash keeps a comma (or the quote) from ending it.
    static func arguments(_ text: String) -> [String] {
        let s = Array(text)
        let n = s.count
        var out: [String] = []
        var i = 0
        func unescaped(_ char: Character, from start: Int) -> Int {
            var at = start
            while at < n {
                guard let pos = s[at...].firstIndex(of: char) else { return n }
                var slashes = 0
                while pos - slashes - 1 >= 0, s[pos - slashes - 1] == "\\" { slashes += 1 }
                if slashes % 2 == 0 { return pos }
                at = pos + 1
            }
            return n
        }
        func normalized(_ arg: ArraySlice<Character>, _ char: Character) -> String {
            var kept: [Character] = []
            for c in arg {
                if c == char {
                    var slashes = 0
                    while slashes < kept.count, kept[kept.count - 1 - slashes] == "\\" { slashes += 1 }
                    if slashes % 2 == 1 { kept.removeLast() }
                }
                kept.append(c)
            }
            return String(kept)
        }
        while i < n {
            var begin = i
            while begin < n, s[begin].isWhitespace { begin += 1 }
            if begin < n, ["\"", "'", "`"].contains(s[begin]) {
                let quote = s[begin]
                let end = unescaped(quote, from: begin + 1)
                if end != n {
                    var next = end + 1
                    while next < n, s[next].isWhitespace { next += 1 }
                    if next == n || s[next] == "," {
                        out.append(normalized(s[(begin + 1)..<end], quote))
                        i = next == n ? n : next + 1
                        continue
                    }
                }
            }
            let separator = unescaped(",", from: begin)
            var end = separator
            while end > begin, s[end - 1].isWhitespace { end -= 1 }
            out.append(normalized(s[begin..<max(begin, end)], ","))
            i = separator < n ? separator + 1 : n
        }
        return out
    }

    /// The names a page from `host` is known by in the lists, as uBlock
    /// Origin looks them up: the host and each domain above it
    /// (`www.example.co.uk`, `example.co.uk`…), and each of those as an
    /// entity, any ending (`www.example.*`, `example.*`…).
    public static func names(of host: String) -> [String] {
        var hosts = [host]
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            hosts.append(String(rest))
        }
        var entities: [String] = []
        for name in hosts {
            var name = Substring(name)
            while let dot = name.lastIndex(of: ".") {
                name = name[..<dot]
                entities.append(name + ".*")
            }
        }
        return hosts + entities
    }

    public struct Matches: Equatable, Sendable {
        /// Each scriptlet to run: its name, arguments, and whether its list may run those that need trust.
        public var scriptlets: [(args: [String], trusted: Bool)] = []
        public var hidden: [String] = []
        /// Whole CSS rules (`selector { declarations }`).
        public var styles: [String] = []
        /// The names that matched, for a frame to check it's of this site.
        public var names: [String] = []

        public var isEmpty: Bool { scriptlets.isEmpty && hidden.isEmpty && styles.isEmpty }

        public static func == (a: Matches, b: Matches) -> Bool {
            a.hidden == b.hidden && a.styles == b.styles && a.names == b.names
                && a.scriptlets.map(\.args) == b.scriptlets.map(\.args) && a.scriptlets.map(\.trusted) == b.scriptlets.map(\.trusted)
        }
    }

    /// What the lists do on a page from `host`: each rule for one of its
    /// names, but those an exception for one of them takes back.
    public func matches(on host: String) -> Matches {
        var found: [(String, Entry)] = []
        for name in Self.names(of: host) + [""] {
            for entry in bySite[name] ?? [] { found.append((name, entry)) }
        }
        let exceptions = Set(found.filter(\.1.exception).map(\.1.rule))
        let noScriptlets = exceptions.contains(.scriptlet([]))
        var seen = Set<Rule>()
        var names = Set<String>()
        var out = Matches()
        for (name, entry) in found where !entry.exception && !exceptions.contains(entry.rule) && seen.insert(entry.rule).inserted {
            switch entry.rule {
            case .scriptlet(let args):
                if noScriptlets { continue }
                out.scriptlets.append((args, entry.trusted))
            case .hide(let selector): out.hidden.append(selector)
            case .style(let selector, let declarations): out.styles.append("\(selector) { \(declarations) }")
            }
            names.insert(name)
        }
        out.names = names.sorted()
        return out
    }
}
