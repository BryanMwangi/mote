/// Where a tab sits in the row. Sections keep this order along the row.
public enum TabTier: Int, Comparable, Sendable {
    /// Kept as a small square at the top: an essential.
    case essential
    /// Kept as a full row under the essentials: a pinned tab.
    case pinned
    /// Every other tab.
    case loose

    public static func < (a: TabTier, b: TabTier) -> Bool { a.rawValue < b.rawValue }
}

/// The order of a window's tabs.
///
/// Essentials come first, then pinned tabs, then every other tab. A tab never
/// crosses between sections by dragging; pinning or unpinning moves it to the
/// edge of its new section.
public struct TabRow<Tab: Identifiable> {
    public private(set) var tabs: [Tab]
    private let section: (Tab) -> TabTier

    public init(_ tabs: [Tab], section: @escaping (Tab) -> TabTier) {
        self.tabs = tabs
        self.section = section
    }

    /// Two sections only: pinned tabs as essentials, and the rest.
    public init(_ tabs: [Tab], isPinned: @escaping (Tab) -> Bool) {
        self.init(tabs) { isPinned($0) ? .essential : .loose }
    }

    /// Essentials and pinned tabs together: everything before the loose tabs.
    public var pinnedCount: Int { start(of: .loose) }

    public func count(in kind: TabTier) -> Int { tabs.lazy.filter { section($0) == kind }.count }

    /// Where a section begins in the row.
    public func start(of kind: TabTier) -> Int { tabs.lazy.filter { section($0) < kind }.count }

    /// The places a section's tabs occupy.
    public func places(of kind: TabTier) -> Range<Int> {
        let from = start(of: kind)
        return from..<(from + count(in: kind))
    }

    public func index(of id: Tab.ID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    /// Where a new tab opens: right after `active`, but never among the
    /// essentials or pinned tabs. With no active tab, at the end.
    public func slotForNew(after active: Tab.ID?) -> Int {
        guard let active, let here = index(of: active) else { return tabs.count }
        return max(here + 1, pinnedCount)
    }

    /// The tab `offset` places away from `id`, wrapping around the row.
    public func neighbour(of id: Tab.ID, by offset: Int) -> Tab.ID? {
        guard tabs.count > 1, let here = index(of: id) else { return nil }
        let next = ((here + offset) % tabs.count + tabs.count) % tabs.count
        return tabs[next].id
    }

    /// The tab that takes over after the tab at `index` was removed: the one
    /// that slid into its place, or the new last tab.
    public func successor(ofRemovedAt index: Int) -> Tab.ID? {
        guard !tabs.isEmpty else { return nil }
        return tabs[min(index, tabs.count - 1)].id
    }

    /// Moves a tab to `index` (its final position). Returns false, changing
    /// nothing, when that would take it out of its section.
    @discardableResult
    public mutating func move(_ id: Tab.ID, to index: Int) -> Bool {
        guard let here = self.index(of: id), index != here, tabs.indices.contains(index) else { return false }
        guard places(of: section(tabs[here])).contains(index) else { return false }
        relocate(from: here, to: index)
        return true
    }

    /// After a tab changed section, moves it to the edge of its new one: last
    /// of the essentials or pinned tabs, or first of the others.
    public mutating func settle(_ id: Tab.ID) {
        guard let here = index(of: id) else { return }
        let tab = tabs.remove(at: here)
        let kind = section(tab)
        let home = kind == .loose ? start(of: .loose) : start(of: kind) + count(in: kind)
        tabs.insert(tab, at: home)
    }

    public mutating func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: min(max(0, index), tabs.count))
    }

    public mutating func append(_ tab: Tab) {
        tabs.append(tab)
    }

    /// Removes a tab and returns where it was.
    @discardableResult
    public mutating func remove(_ id: Tab.ID) -> Int? {
        guard let here = index(of: id) else { return nil }
        tabs.remove(at: here)
        return here
    }

    public mutating func replace(_ id: Tab.ID, with tab: Tab) {
        guard let here = index(of: id) else { return }
        tabs[here] = tab
    }

    private mutating func relocate(from here: Int, to there: Int) {
        let tab = tabs.remove(at: here)
        tabs.insert(tab, at: there)
    }
}

/// Recently closed tabs, oldest first, keeping only the last few.
public struct RecentlyClosed<Entry: Identifiable> {
    public let limit: Int
    public private(set) var entries: [Entry] = []

    public init(limit: Int = 12) {
        self.limit = limit
    }

    public var last: Entry? { entries.last }

    public mutating func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }
}
