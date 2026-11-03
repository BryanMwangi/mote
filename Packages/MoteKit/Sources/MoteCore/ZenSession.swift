import Foundation

/// What Mote reads from Zen's `zen-sessions.jsonlz4`: its spaces and tabs.
/// Zen changes this file between releases, so every field is optional and a
/// field of an unexpected type reads as missing rather than failing the file.
public struct ZenSession: Decodable, Sendable, Equatable {
    public struct Space: Decodable, Sendable, Equatable {
        public var uuid: String
        public var name: String?
        /// An emoji, usually; older spaces have an icon's chrome:// address.
        public var icon: String?
        public var position: Double?
        /// Its container (Firefox's userContextId); 0 is none.
        public var containerTabId: Int?

        public init(uuid: String, name: String? = nil, icon: String? = nil, position: Double? = nil, containerTabId: Int? = nil) {
            self.uuid = uuid
            self.name = name
            self.icon = icon
            self.position = position
            self.containerTabId = containerTabId
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            uuid = c.lenient(String.self, .uuid) ?? ""
            name = c.lenient(String.self, .name)
            icon = c.lenient(String.self, .icon)
            position = c.lenient(Double.self, .position)
            containerTabId = c.lenient(Int.self, .containerTabId)
        }

        private enum Keys: String, CodingKey { case uuid, name, icon, position, containerTabId }
    }

    public struct Entry: Decodable, Sendable, Equatable {
        public var url: String?
        public var title: String?

        public init(url: String?, title: String? = nil) {
            self.url = url
            self.title = title
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            url = c.lenient(String.self, .url)
            title = c.lenient(String.self, .title)
        }

        private enum Keys: String, CodingKey { case url, title }
    }

    public struct Tab: Decodable, Sendable, Equatable {
        /// The tab's back-forward list; `index` is 1-based into it.
        public var entries: [Entry]
        public var index: Int?
        public var pinned: Bool
        public var essential: Bool
        /// Its space's uuid.
        public var workspace: String?
        /// A name the user gave it.
        public var label: String?
        public var userContextId: Int?
        /// An empty tab, or a Glance preview: not tabs anyone kept.
        public var transient: Bool

        public init(
            entries: [Entry], index: Int? = nil, pinned: Bool = false, essential: Bool = false, workspace: String? = nil,
            label: String? = nil, userContextId: Int? = nil, transient: Bool = false
        ) {
            self.entries = entries
            self.index = index
            self.pinned = pinned
            self.essential = essential
            self.workspace = workspace
            self.label = label
            self.userContextId = userContextId
            self.transient = transient
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            entries = c.lenient([Entry].self, .entries) ?? []
            index = c.lenient(Int.self, .index)
            pinned = c.lenient(Bool.self, .pinned) ?? false
            essential = c.lenient(Bool.self, .zenEssential) ?? false
            workspace = c.lenient(String.self, .zenWorkspace)
            label = c.lenient(String.self, .zenStaticLabel)
            userContextId = c.lenient(Int.self, .userContextId)
            transient = (c.lenient(Bool.self, .zenIsEmpty) ?? false) || (c.lenient(Bool.self, .zenIsGlance) ?? false)
        }

        /// The page it shows: the entry `index` points at, or the last.
        public var current: Entry? {
            guard !entries.isEmpty else { return nil }
            return entries[min(max((index ?? entries.count) - 1, 0), entries.count - 1)]
        }

        private enum Keys: String, CodingKey {
            case entries, index, pinned, zenEssential, zenWorkspace, zenStaticLabel, userContextId, zenIsEmpty, zenIsGlance
        }
    }

    public var spaces: [Space]
    public var tabs: [Tab]

    public init(spaces: [Space], tabs: [Tab]) {
        self.spaces = spaces
        self.tabs = tabs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        spaces = (c.lenient([Space].self, .spaces) ?? []).filter { !$0.uuid.isEmpty }
        tabs = c.lenient([Tab].self, .tabs) ?? []
    }

    /// From the file as Zen writes it.
    public static func read(_ file: Data) throws -> ZenSession {
        try JSONDecoder().decode(ZenSession.self, from: MozLZ4.decode(file))
    }

    private enum Keys: String, CodingKey { case spaces, tabs }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it's missing or of another type.
    fileprivate func lenient<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Zen's spaces and tabs as Mote will have them: a space each, its tabs in
/// Mote's tiers. Worked out apart from the app, so the rules can be tested.
public struct ZenImportPlan: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var url: URL
        public var title: String
        /// The name the user gave it in Zen.
        public var name: String?
        public var tier: TabTier
    }

    public struct Space: Equatable, Sendable {
        /// Zen's uuid, so importing again can tell it's already here.
        public var zenID: String
        public var name: String
        /// An emoji, when Zen's icon is one.
        public var icon: String?
        /// Zen gave it a container, so it gets website data of its own.
        public var ownData: Bool
        /// Essentials, then pinned tabs, then the rest, each in Zen's order.
        public var tabs: [Tab]

        public func count(_ tier: TabTier) -> Int { tabs.lazy.filter { $0.tier == tier }.count }
    }

    public var spaces: [Space]

    public var tabCount: Int { spaces.reduce(0) { $0 + $1.tabs.count } }

    /// - Parameter containers: container names by id, for spaces without a name.
    public init(_ session: ZenSession, containers: [Int: String] = [:]) {
        let ordered = session.spaces.enumerated()
            .sorted { ($0.element.position ?? .infinity, $0.offset) < ($1.element.position ?? .infinity, $1.offset) }
            .map(\.element)
        var spaces = ordered.enumerated().map { number, zen in
            let container = zen.containerTabId ?? 0
            let named = zen.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Space(
                zenID: zen.uuid,
                name: named.flatMap { $0.isEmpty ? nil : $0 } ?? containers[container] ?? "Space \(number + 1)",
                icon: zen.icon.flatMap { MoteCore.Space.isEmoji($0) ? $0 : nil },
                ownData: container != 0, tabs: [])
        }
        guard !spaces.isEmpty else {
            self.spaces = []
            return
        }
        for zen in session.tabs where !zen.transient {
            guard let entry = zen.current, let text = entry.url, let url = URL(string: text),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            let tier: TabTier = zen.essential ? .essential : zen.pinned ? .pinned : .loose
            let label = zen.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tab = Tab(
                url: url, title: entry.title ?? url.absoluteString, name: label.flatMap { $0.isEmpty ? nil : $0 }, tier: tier)
            spaces[Self.home(of: zen, among: ordered)].tabs.append(tab)
        }
        for index in spaces.indices {
            spaces[index].tabs = [.essential, .pinned, .loose].flatMap { tier in spaces[index].tabs.filter { $0.tier == tier } }
        }
        self.spaces = spaces
    }

    /// Its space; an essential without one goes to a space of its
    /// container (Zen keeps essentials per container); otherwise the first.
    private static func home(of tab: ZenSession.Tab, among spaces: [ZenSession.Space]) -> Int {
        if let workspace = tab.workspace, let index = spaces.firstIndex(where: { $0.uuid == workspace }) { return index }
        if let container = tab.userContextId, container != 0,
            let index = spaces.firstIndex(where: { $0.containerTabId == container })
        {
            return index
        }
        return 0
    }
}
