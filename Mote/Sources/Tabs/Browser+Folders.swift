import AppKit
import Combine
import MoteCore

/// Every space's folders of pinned tabs, kept in one file and shared by every
/// window, so they're the same wherever the space shows (see Folder).
@MainActor
final class FolderStore: ObservableObject {
    static let shared = FolderStore()
    @Published private(set) var bySpace: [UUID: [Folder]]
    private let file = JSONFile<[String: [Folder]]>("folders.json")

    private init() {
        let saved = file.load() ?? [:]
        bySpace = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func folders(in space: UUID) -> [Folder] { bySpace[space] ?? [] }

    func change(_ space: UUID, _ edit: (inout [Folder]) -> Void) {
        var folders = folders(in: space)
        edit(&folders)
        bySpace[space] = folders.isEmpty ? nil : folders
        file.save(Dictionary(uniqueKeysWithValues: bySpace.map { ($0.key.uuidString, $0.value) }))
    }
}

/// Where a tab dragged out of its folder would land: at a place among the
/// pinned tabs in no folder, or among the open tabs.
enum FolderExit: Equatable {
    case kept(Int)
    case loose(Int)
}

/// Folders of pinned tabs made from the plus menu or a tab's
/// menu, collapsed with a click, renamed, unpacked or deleted from their own.
extension Browser {
    var folders: [Folder] { folders(in: spaceID) }

    /// A space's folders, open or closed as in this window.
    func folders(in space: UUID) -> [Folder] {
        FolderStore.shared.folders(in: space).map { folder in
            var folder = folder
            folder.collapsed = closedFolders.contains(folder.id)
            return folder
        }
    }

    /// A new folder (inside `parent`), named at once; `tab` goes in it.
    func newFolder(in parent: UUID? = nil, with tab: Tab? = nil) {
        if let parent, Folder.depth(of: parent, in: folders) + 1 >= Folder.deepest { return announce("Folders go \(Folder.deepest) deep") }
        Prompt.name("New Folder", placeholder: "Folder", initial: "", confirm: "Create") { [weak self] name in
            guard let self else { return }
            let folder = Folder(name: name.isEmpty ? "Folder" : name, parent: parent)
            FolderStore.shared.change(spaceID) { $0.append(folder) }
            if let tab { move(tab, toFolder: folder.id) }
        }
    }

    /// A folder by name, made if there's none, at the top: for the assistant.
    func folder(named name: String) -> UUID {
        if let found = folders.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return found.id }
        let folder = Folder(name: name, parent: nil)
        FolderStore.shared.change(spaceID) { $0.append(folder) }
        return folder.id
    }

    /// Into a folder; a tab that isn't pinned is pinned on the way.
    func move(_ tab: Tab, toFolder folder: UUID?) {
        if folder != nil, !tab.kept { keep(tab) }
        tab.folder = folder
        writeSession(now: true)
    }

    /// Out of its folder, back among the open tabs: at `place` in them (a drop
    /// there), else first.
    func unfile(_ tab: Tab, at place: Int? = nil) {
        unkeep(tab)
        let loose = tabs.filter { !$0.held && $0.id != tab.id }
        move(tab, to: pinnedCount + min(max(place ?? 0, 0), loose.count))
    }

    /// Out of its folder, still pinned: at `place` among the pinned tabs in
    /// no folder (a drop there).
    func unfile(_ tab: Tab, toKeptAt place: Int) {
        tab.folder = nil
        let rest = tabs.filter { $0.id != tab.id }
        let unfiled = rest.filter { $0.section == .pinned && $0.folder == nil }
        let index =
            place < unfiled.count
            ? rest.firstIndex { $0.id == unfiled[max(place, 0)].id }
            : rest.lastIndex { $0.section == .pinned }.map { $0 + 1 }
        move(tab, to: index ?? essentialCount)
        writeSession(now: true)
    }

    /// Where among the open tabs a tab let go at `pointer` (on screen) goes,
    /// if it's over their list in the sidebar.
    func loosePlace(at pointer: NSPoint) -> Int? {
        place(at: pointer, in: looseSpot, reach: Metrics.row)
    }

    /// Where among the pinned tabs in no folder a tab let go at `pointer` goes,
    /// if it's over them (or the line under them, with none).
    func keptPlace(at pointer: NSPoint) -> Int? {
        place(at: pointer, in: keptSpot, reach: Metrics.row / 2)
    }

    /// The row a pointer is on, in a list marked by `spot`; `reach` past its ends still counts.
    private func place(at pointer: NSPoint, in spot: WeakView?, reach: CGFloat) -> Int? {
        guard let view = spot?.view, let window = view.window, window === self.window else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard frame.insetBy(dx: 0, dy: -reach).contains(pointer) else { return nil }
        // Rows go down from the top; the screen's y goes up.
        return max(0, Int((frame.maxY - pointer.y) / (Metrics.row + 2)))
    }

    /// Where a tab dragged out of its folder would go, noted for the list to
    /// show: into another folder (`folderHover`), among the pinned tabs, or
    /// among the open ones.
    func hoverOutOfFolder(at pointer: NSPoint?, dragging tab: Tab) {
        var next: FolderExit?
        if let pointer, tab.folder != nil, folderHover == nil {
            if let place = keptPlace(at: pointer) {
                next = .kept(place)
            } else if let place = loosePlace(at: pointer) {
                next = .loose(place)
            }
        }
        if folderExit != next { folderExit = next }
    }

    /// The folder a tab dragged to `pointer` (on screen) would drop into,
    /// noted for its row to light up. Live folders keep to their feeds.
    @discardableResult
    func hoverFolder(at pointer: NSPoint?, dragging tab: Tab) -> UUID? {
        var frames: [UUID: CGRect] = [:]
        if pointer != nil {
            for folder in folders where folder.live == nil {
                guard let view = folderSpots[folder.id]?.view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor
                else { continue }
                frames[folder.id] = window.convertToScreen(view.convert(view.bounds, to: nil))
            }
        }
        let over = pointer.flatMap { Folder.dropTarget(at: $0, in: frames, from: tab.folder) }
        if folderHover != over { folderHover = over }
        return over
    }

    /// Let go over a folder: in it goes.
    func dropInFolder(_ tab: Tab) {
        guard let folder = folderHover else { return }
        folderHover = nil
        Haptic.tick()
        move(tab, toFolder: folder)
    }

    /// A folder dragged onto another: before it, or after it when let go
    /// on its lower half, under the same parent.
    func moveFolder(_ id: UUID, before target: UUID, after: Bool = false) {
        FolderStore.shared.change(spaceID) { folders in
            if let moved = Folder.moving(id, before: target, after: after, in: folders) { folders = moved }
        }
    }

    func renameFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        Prompt.name("Rename Folder", placeholder: folder.name, initial: folder.name, confirm: "Rename") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            FolderStore.shared.change(spaceID) { folders in
                if let at = folders.firstIndex(where: { $0.id == id }) { folders[at].name = name }
            }
        }
    }

    /// Change Icon…: an emoji of its own, or none for the folder symbol.
    func changeFolderIcon(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        Prompt.name(
            "Folder Icon", placeholder: "📁", initial: folder.icon ?? "", detail: "An emoji, or nothing for the folder.", confirm: "Use"
        ) { [weak self] text in
            guard let self else { return }
            let icon = text.first.map(String.init)
            FolderStore.shared.change(spaceID) { folders in
                if let at = folders.firstIndex(where: { $0.id == id }) { folders[at].icon = icon }
            }
        }
    }

    /// Opens or closes a folder in this window only. The store keeps how
    /// it was left, for windows opened later and the next launch.
    func toggleFolder(_ id: UUID) {
        let closed = !closedFolders.contains(id)
        if closed { closedFolders.insert(id) } else { closedFolders.remove(id) }
        FolderStore.shared.change(spaceID) { folders in
            if let at = folders.firstIndex(where: { $0.id == id }) { folders[at].collapsed = closed }
        }
    }

    /// Collapse All Folders, or Expand All, in this window.
    func collapseFolders(_ collapsed: Bool) {
        let ids = FolderStore.shared.folders(in: spaceID).map(\.id)
        if collapsed { closedFolders.formUnion(ids) } else { closedFolders.subtract(ids) }
        FolderStore.shared.change(spaceID) { folders in
            for at in folders.indices { folders[at].collapsed = collapsed }
        }
    }

    /// The tabs in a folder, at any depth.
    func tabs(inFolder id: UUID) -> [Tab] {
        let family = Folder.family(of: id, in: folders)
        return tabs.filter { $0.folder.map(family.contains) ?? false }
    }

    func unloadFolder(_ id: UUID) {
        for tab in tabs(inFolder: id) where !tab.asleep { unload(tab) }
    }

    /// Unpack Folder: its tabs and folders move up to where it was.
    func unpackFolder(_ id: UUID) {
        let parent = folders.first { $0.id == id }?.parent
        for tab in tabs where tab.folder == id { tab.folder = parent }
        FolderStore.shared.change(spaceID) { folders in
            for at in folders.indices where folders[at].parent == id { folders[at].parent = parent }
            folders.removeAll { $0.id == id }
        }
        writeSession(now: true)
    }

    /// Delete Folder: it, its folders, and their tabs.
    func deleteFolder(_ id: UUID) {
        let family = Folder.family(of: id, in: folders)
        for tab in tabs(inFolder: id) {
            tab.folder = nil
            unkeep(tab)
            close(tab)
        }
        FolderStore.shared.change(spaceID) { $0.removeAll { family.contains($0.id) } }
        family.forEach(LiveFeeds.shared.forget)
        writeSession(now: true)
    }

    /// The folders as Move to Folder › lists them, each with its depth.
    var folderChoices: [(folder: Folder, depth: Int)] {
        // Every folder, closed ones' folders too.
        let folders = FolderStore.shared.folders(in: spaceID).map { folder in
            var folder = folder
            folder.collapsed = false
            return folder
        }
        return Folder.outline(folders, tabs: [(id: UUID, folder: UUID?)](), active: nil).compactMap { line in
            guard case .folder(let id, let depth) = line, let folder = folders.first(where: { $0.id == id }) else { return nil }
            return (folder, depth)
        }
    }
}
