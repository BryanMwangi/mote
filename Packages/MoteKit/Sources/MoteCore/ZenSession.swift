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
        /// Its colours, as Mote keeps a space's: nil when it has none.
        public var theme: SpaceTheme?

        public init(
            uuid: String, name: String? = nil, icon: String? = nil, position: Double? = nil, containerTabId: Int? = nil,
            theme: SpaceTheme? = nil
        ) {
            self.theme = theme
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
            theme = c.lenient(Theme.self, .theme)?.mote
        }

        private enum Keys: String, CodingKey { case uuid, name, icon, position, containerTabId, theme }

        /// Zen's gradient: dots of colour (`c`, red, green and blue), the
        /// primary one first in Mote's; its opacity; its texture as grain.
        private struct Theme: Decodable {
            struct Dot: Decodable {
                var c: [Double]?
                var isPrimary: Bool?

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: Keys.self)
                    c = values.lenient([Double].self, .c)
                    isPrimary = values.lenient(Bool.self, .isPrimary)
                }

                private enum Keys: String, CodingKey { case c, isPrimary }
            }
            var gradientColors: [Dot]?
            var opacity: Double?
            var texture: Double?

            var mote: SpaceTheme? {
                let dots = (gradientColors ?? []).sorted { ($0.isPrimary == true ? 0 : 1) < ($1.isPrimary == true ? 0 : 1) }
                let colors = dots.compactMap { dot -> String? in
                    guard let c = dot.c, c.count >= 3 else { return nil }
                    return String(format: "#%02x%02x%02x", Int(c[0].rounded()), Int(c[1].rounded()), Int(c[2].rounded()))
                }
                guard !colors.isEmpty else { return nil }
                return SpaceTheme(colors: colors, opacity: opacity ?? 0.5, grain: texture ?? 0)
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                gradientColors = c.lenient([Dot].self, .gradientColors)
                opacity = c.lenient(Double.self, .opacity)
                texture = c.lenient(Double.self, .texture)
            }

            private enum Keys: String, CodingKey { case gradientColors, opacity, texture }
        }
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
        /// Zen's id for it, which its split views name it by.
        public var syncID: String?
        /// The folder (or split view's group) it's in.
        public var groupID: String?

        public init(
            entries: [Entry], index: Int? = nil, pinned: Bool = false, essential: Bool = false, workspace: String? = nil,
            label: String? = nil, userContextId: Int? = nil, transient: Bool = false, syncID: String? = nil, groupID: String? = nil
        ) {
            self.syncID = syncID
            self.groupID = groupID
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
            syncID = c.lenient(String.self, .zenSyncId)
            groupID = c.lenient(String.self, .groupId)
        }

        /// The page it shows: the entry `index` points at, or the last.
        public var current: Entry? {
            guard !entries.isEmpty else { return nil }
            return entries[min(max((index ?? entries.count) - 1, 0), entries.count - 1)]
        }

        private enum Keys: String, CodingKey {
            case entries, index, pinned, zenEssential, zenWorkspace, zenStaticLabel, userContextId, zenIsEmpty, zenIsGlance,
                zenSyncId, groupId
        }
    }

    /// A folder of pinned tabs, which may be in another. Split views' groups
    /// are kept beside them, marked.
    public struct Folder: Decodable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var collapsed: Bool
        public var parentID: String?
        public var splitView: Bool

        public init(id: String, name: String, collapsed: Bool = false, parentID: String? = nil, splitView: Bool = false) {
            self.id = id
            self.name = name
            self.collapsed = collapsed
            self.parentID = parentID
            self.splitView = splitView
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = c.lenient(String.self, .id) ?? ""
            name = c.lenient(String.self, .name) ?? ""
            collapsed = c.lenient(Bool.self, .collapsed) ?? false
            parentID = c.lenient(String.self, .parentId)
            splitView = c.lenient(Bool.self, .splitViewGroup) ?? false
        }

        private enum Keys: String, CodingKey { case id, name, collapsed, parentId, splitViewGroup }
    }

    /// A split view: its tabs by `syncID`, laid out as Zen's tree has them.
    public struct Split: Decodable, Sendable, Equatable {
        public indirect enum Node: Decodable, Sendable, Equatable {
            /// A tab, and its share of its parent in percent.
            case leaf(String, Double)
            /// Side by side ("row") or one over another ("column").
            case splitter(across: Bool, Double, [Node])

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                let size = c.lenient(Double.self, .sizeInParent) ?? 100
                if c.lenient(String.self, .type) == "leaf" {
                    self = .leaf(c.lenient(String.self, .tabId) ?? "", size)
                } else {
                    self = .splitter(
                        across: c.lenient(String.self, .direction) != "column", size, c.lenient([Node].self, .children) ?? [])
                }
            }

            private enum Keys: String, CodingKey { case type, tabId, sizeInParent, direction, children }
        }

        public var tabs: [String]
        /// The tree, which older files lack; then `grid` says how.
        public var layout: Node?
        public var grid: String?

        public init(tabs: [String], layout: Node? = nil, grid: String? = nil) {
            self.tabs = tabs
            self.layout = layout
            self.grid = grid
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            tabs = c.lenient([String].self, .tabs) ?? []
            layout = c.lenient(Node.self, .layoutTree)
            grid = c.lenient(String.self, .gridType)
        }

        private enum Keys: String, CodingKey { case tabs, layoutTree, gridType }
    }

    public var spaces: [Space]
    public var tabs: [Tab]
    public var splits: [Split]
    public var folders: [Folder]

    public init(spaces: [Space], tabs: [Tab], splits: [Split] = [], folders: [Folder] = []) {
        self.spaces = spaces
        self.tabs = tabs
        self.splits = splits
        self.folders = folders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        spaces = (c.lenient([Space].self, .spaces) ?? []).filter { !$0.uuid.isEmpty }
        tabs = c.lenient([Tab].self, .tabs) ?? []
        splits = c.lenient([Split].self, .splitViewData) ?? []
        folders = (c.lenient([Folder].self, .folders) ?? []).filter { !$0.id.isEmpty && !$0.splitView }
    }

    /// From the file as Zen writes it.
    public static func read(_ file: Data) throws -> ZenSession {
        try JSONDecoder().decode(ZenSession.self, from: MozLZ4.decode(file))
    }

    private enum Keys: String, CodingKey { case spaces, tabs, splitViewData, folders }
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
        /// Zen's id for it, for its split views.
        public var syncID: String? = nil
        /// Zen's id for its folder.
        public var folder: String? = nil
    }

    /// A folder of pinned tabs, by Zen's ids.
    public struct Folder: Equatable, Sendable {
        public var zenID: String
        public var name: String
        public var collapsed: Bool
        public var parent: String?
    }

    public struct Space: Equatable, Sendable {
        /// Zen's uuid, so importing again can tell it's already here.
        public var zenID: String
        public var name: String
        /// An emoji, when Zen's icon is one.
        public var icon: String?
        /// Zen gave it a container, so it gets website data of its own.
        public var ownData: Bool
        public var theme: SpaceTheme? = nil
        /// Essentials, then pinned tabs, then the rest, each in Zen's order.
        public var tabs: [Tab]
        /// Its split views, by their tabs' places in `tabs`, as a session keeps them.
        public var splits: [SplitLayout<Int>] = []
        /// Its folders, parents before what's in them.
        public var folders: [Folder] = []

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
                ownData: container != 0, theme: zen.theme, tabs: [])
        }
        guard !spaces.isEmpty else {
            self.spaces = []
            return
        }
        for zen in session.tabs where !zen.transient {
            guard let entry = zen.current, let text = entry.url, let url = URL(string: text),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            // In a folder it's pinned, as folders are of pinned tabs.
            let folder = zen.essential ? nil : zen.groupID.flatMap { id in session.folders.contains { $0.id == id } ? id : nil }
            let tier: TabTier = zen.essential ? .essential : zen.pinned || folder != nil ? .pinned : .loose
            let label = zen.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tab = Tab(
                url: url, title: entry.title ?? url.absoluteString, name: label.flatMap { $0.isEmpty ? nil : $0 }, tier: tier,
                syncID: zen.syncID, folder: folder)
            spaces[Self.home(of: zen, among: ordered)].tabs.append(tab)
        }
        for index in spaces.indices {
            spaces[index].tabs = [.essential, .pinned, .loose].flatMap { tier in spaces[index].tabs.filter { $0.tier == tier } }
            // A split goes to the space with its tabs, over their places there.
            let places = Dictionary(
                spaces[index].tabs.enumerated().compactMap { place, tab in tab.syncID.map { ($0, place) } }, uniquingKeysWith: { a, _ in a }
            )
            spaces[index].splits = session.splits.compactMap { Self.layout(of: $0)?.compactMap { places[$0] } }
            spaces[index].folders = Self.folders(holding: Set(spaces[index].tabs.compactMap(\.folder)), in: session.folders)
        }
        self.spaces = spaces
    }

    /// A split as Mote lays one out: its tree, or for an older file, its tabs
    /// in Zen's grid ("hsep" side by side, "vsep" one over another).
    static func layout(of split: ZenSession.Split) -> SplitLayout<String>? {
        func node(_ zen: ZenSession.Split.Node) -> SplitLayout<String>.Node {
            switch zen {
            case .leaf(let id, _): .leaf(id)
            case .splitter(let across, _, let children):
                .split(across ? .across : .down, children.map { .init(node: node($0), share: CGFloat(Self.size(of: $0) / 100)) })
            }
        }
        if let tree = split.layout { return SplitLayout(root: node(tree)) }
        let grid: SplitGrid = split.grid == "grid" ? .grid : split.grid == "vsep" ? .down : .across
        return SplitLayout.layout(grid, split.tabs)
    }

    private static func size(of node: ZenSession.Split.Node) -> Double {
        switch node {
        case .leaf(_, let size), .splitter(_, let size, _): size
        }
    }

    /// The folders that hold these, and the folders around them, each
    /// after its parent.
    static func folders(holding held: Set<String>, in all: [ZenSession.Folder]) -> [Folder] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var wanted = Set<String>()
        for id in held {
            var at: String? = id
            while let here = at, byID[here] != nil, wanted.insert(here).inserted { at = byID[here]?.parentID }
        }
        func depth(_ id: String) -> Int {
            var count = 0, at = byID[id]?.parentID
            while let here = at, count < 10 {
                count += 1
                at = byID[here]?.parentID
            }
            return count
        }
        return all.filter { wanted.contains($0.id) }.sorted { depth($0.id) < depth($1.id) }.map {
            Folder(zenID: $0.id, name: $0.name.isEmpty ? "Folder" : $0.name, collapsed: $0.collapsed, parent: $0.parentID)
        }
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
