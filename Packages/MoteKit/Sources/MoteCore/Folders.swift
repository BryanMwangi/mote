import Foundation

/// A folder of pinned tabs, as Zen's: named, collapsible, and possibly inside
/// another. Tabs say which folder they're in; folders only know their parent.
public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var collapsed = false
    public var parent: UUID?
    /// What a live folder follows; nil for a folder of tabs.
    public var live: LiveSource?
    /// An emoji of its own, as Zen's folders can have; nil for the folder symbol.
    public var icon: String?

    public init(id: UUID = UUID(), name: String, parent: UUID? = nil, live: LiveSource? = nil) {
        self.id = id
        self.name = name
        self.parent = parent
        self.live = live
    }

    /// Zen's limit on folders inside folders.
    public static let deepest = 5

    /// One line of the pinned section, top to bottom.
    public enum Line<TabID: Hashable>: Hashable {
        case folder(UUID, depth: Int)
        case tab(TabID, depth: Int)
    }

    /// The pinned section as drawn: each folder, then its folders and its
    /// tabs, a level further in; then the tabs in no folder. A collapsed
    /// folder still shows the tab in front, if it's inside, as Zen does.
    /// `tabs` are in the row's order; one naming a folder that's gone is in none.
    public static func outline<TabID: Hashable>(
        _ folders: [Folder], tabs: [(id: TabID, folder: UUID?)], active: TabID?
    ) -> [Line<TabID>] {
        let known = Set(folders.map(\.id))
        func home(_ tab: (id: TabID, folder: UUID?)) -> UUID? { tab.folder.flatMap { known.contains($0) ? $0 : nil } }
        func holds(_ folder: UUID, _ tab: (id: TabID, folder: UUID?)) -> Bool {
            var at = home(tab)
            while let here = at {
                if here == folder { return true }
                at = folders.first { $0.id == here }?.parent
            }
            return false
        }
        var lines: [Line<TabID>] = []
        func add(_ folder: Folder, depth: Int) {
            lines.append(.folder(folder.id, depth: depth))
            if folder.collapsed {
                if let active, let tab = tabs.first(where: { $0.id == active }), holds(folder.id, tab) {
                    lines.append(.tab(active, depth: depth + 1))
                }
                return
            }
            for child in folders where child.parent == folder.id { add(child, depth: depth + 1) }
            for tab in tabs where home(tab) == folder.id { lines.append(.tab(tab.id, depth: depth + 1)) }
        }
        for folder in folders where folder.parent.map({ !known.contains($0) }) ?? true { add(folder, depth: 0) }
        for tab in tabs where home(tab) == nil { lines.append(.tab(tab.id, depth: 0)) }
        return lines
    }

    /// How deep `id` sits: 0 at the top.
    public static func depth(of id: UUID, in folders: [Folder]) -> Int {
        var depth = 0
        var at = folders.first { $0.id == id }?.parent
        while let here = at, depth < 64 {
            depth += 1
            at = folders.first { $0.id == here }?.parent
        }
        return depth
    }

    /// `id` and every folder inside it, at any depth.
    public static func family(of id: UUID, in folders: [Folder]) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var grew = true
        while grew {
            let next = found.union(folders.filter { $0.parent.map(found.contains) ?? false }.map(\.id))
            grew = next.count > found.count
            found = next
        }
        return found
    }

    /// The folder a dragged tab is over: the one whose row (on screen,
    /// from `frames`) holds `point`, but not the one it's already in.
    public static func dropTarget(at point: CGPoint, in frames: [UUID: CGRect], from current: UUID?) -> UUID? {
        frames.first { $0.key != current && $0.value.contains(point) }?.key
    }

    /// `folders` with `id` moved to just before `target` (or after it),
    /// beside it under the same parent. Nil when it would go inside itself.
    public static func moving(_ id: UUID, before target: UUID, after: Bool = false, in folders: [Folder]) -> [Folder]? {
        guard id != target, !family(of: id, in: folders).contains(target), let from = folders.firstIndex(where: { $0.id == id }),
            let goal = folders.first(where: { $0.id == target })
        else { return nil }
        var list = folders
        var folder = list.remove(at: from)
        folder.parent = goal.parent
        guard let to = list.firstIndex(where: { $0.id == target }) else { return nil }
        list.insert(folder, at: after ? to + 1 : to)
        return list
    }
}
