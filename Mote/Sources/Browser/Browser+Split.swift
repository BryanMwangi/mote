import MoteCore
import SwiftUI

/// Where a tab dragged over the page would split in: beside `target`, on `side`.
struct SplitHover: Equatable {
    let target: Tab.ID
    let side: SplitSide
}

/// Where a tab dragged from its list is (see Reorderable): near the list,
/// where it reorders; over the page, where it splits in; or out of the window.
enum DragZone {
    case list, page, outside
}

/// Split view, as Zen's: up to four tabs showing at once, each group a
/// layout kept in `splits` by its own id. A group's tabs sit together in
/// the row; selecting any of them shows the group. Essentials and pinned
/// tabs stay out of groups.
extension Browser {
    /// Between a split's pages.
    static let splitGap: CGFloat = 8

    /// The group a tab is in.
    func group(of id: Tab.ID) -> UUID? { splitOf[id] }

    /// Where `tabs[index]` sits in its group's run along the row, for its
    /// box: nil outside a group.
    func splitRun(at index: Int, in tabs: [Tab]) -> (first: Bool, last: Bool)? {
        guard let group = group(of: tabs[index].id) else { return nil }
        let first = index == 0 || self.group(of: tabs[index - 1].id) != group
        let last = index == tabs.count - 1 || self.group(of: tabs[index + 1].id) != group
        return (first, last)
    }

    /// The group the page shows: the active tab's.
    var shownSplit: SplitLayout<Tab.ID>? { activeID.flatMap(group(of:)).flatMap { splits[$0] } }

    func splittable(_ tab: Tab) -> Bool { !tab.held && row.index(of: tab.id) != nil }

    /// Puts `tab` beside `target` on `side`, in `target`'s group or a new one,
    /// and shows it. False when either can't be split or the group is full.
    @discardableResult
    func split(_ tab: Tab, beside target: Tab, side: SplitSide) -> Bool {
        guard tab.id != target.id, splittable(tab), splittable(target) else { return false }
        let id = group(of: target.id) ?? UUID()
        var layout = splits[id] ?? SplitLayout(target.id)
        // Within its own group, it moves.
        layout.remove(tab.id)
        guard layout.insert(tab.id, beside: target.id, side: side) else {
            announce("A split shows up to \(SplitLayout<Tab.ID>.most) tabs")
            return false
        }
        if let old = group(of: tab.id), old != id { unsplit(tab: tab.id) }
        splits[id] = layout
        gather(id)
        select(tab)
        wakeSplit()
        saveSoon()
        return true
    }

    /// Tab menu › Split with Current Tab: on the right of a pair, into the grid after.
    func splitWithActive(_ tab: Tab) {
        guard let active, active.id != tab.id else { return }
        let group = group(of: active.id)
        guard split(tab, beside: active, side: .right), let group, let ids = splits[group]?.ids, ids.count > 2 else { return }
        relayout(group, .grid)
    }

    /// The plus menu's New Split, as Zen's: a new tab beside the one in front.
    func newSplit() {
        guard let active, splittable(active) else { return }
        let tab = Tab()
        insert(tab, at: placeForNew())
        split(tab, beside: active, side: .right)
        field.clear()
        editing = false
        field.askFocus()
    }

    /// Takes a tab out of its group; a group left with one tab is gone.
    func unsplit(tab id: Tab.ID) {
        guard let group = group(of: id), var layout = splits[group] else { return }
        if layout.count <= 2 {
            splits[group] = nil
        } else {
            layout.remove(id)
            splits[group] = layout
        }
        saveSoon()
    }

    func unsplit(group: UUID) {
        splits[group] = nil
        saveSoon()
    }

    /// Grid, Vertical or Horizontal, as Zen's.
    func relayout(_ group: UUID, _ grid: SplitGrid) {
        guard let ids = splits[group]?.ids, let made = SplitLayout.layout(grid, ids) else { return }
        withAnimation(Motion.settle) { splits[group] = made }
        saveSoon()
    }

    /// The keys: split the active tab with the one before it in that layout,
    /// or lay its group out so.
    func splitKey(_ grid: SplitGrid) {
        guard let active else { return }
        if let group = group(of: active.id) { return relayout(group, grid) }
        guard let other = row.neighbour(of: active.id, by: -1).flatMap(tab), split(active, beside: other, side: .right),
            let group = group(of: active.id)
        else { return }
        relayout(group, grid)
    }

    /// A divider dragged to `position`, in the page's own space.
    func resize(_ group: UUID, _ divider: SplitLayout<Tab.ID>.Divider, to position: CGFloat) {
        splits[group]?.move(divider, to: position)
        saveSoon()
    }

    /// A grouped tab dragged to `index` takes its group along; dropped among
    /// its own group, nothing moves.
    func moveGroup(_ group: UUID, by tab: Tab, to index: Int) {
        guard let ids = splits[group]?.ids, let start = row.index(of: tab.id), let first = ids.compactMap(row.index(of:)).min()
        else { return }
        let places = row.places(of: .loose)
        guard !(first..<first + ids.count).contains(index) else { return }
        moveGroup(group, to: min(max(first + index - start, places.lowerBound), places.upperBound - ids.count))
    }

    /// Keeps every group's tabs together after a tab moved in among them.
    func gatherAll() {
        for group in splits.keys { gather(group) }
    }

    /// Moves a group's tabs to sit together, in reading order, from the first of them.
    private func gather(_ group: UUID) {
        guard let ids = splits[group]?.ids, let first = ids.compactMap(row.index(of:)).min() else { return }
        reorder { row in
            for (offset, id) in ids.enumerated() { _ = row.move(id, to: first + offset) }
        }
    }

    /// Moves a whole group so its first tab lands at `index`.
    func moveGroup(_ group: UUID, to index: Int) {
        guard let ids = splits[group]?.ids else { return }
        reorder { row in
            let from = ids.compactMap(row.index(of:)).min() ?? index
            // Rightward, the last goes first, so none passes over another.
            let order = index > from ? Array(ids.enumerated().reversed()) : Array(ids.enumerated())
            for (offset, id) in order { _ = row.move(id, to: index + offset) }
        }
        saveSoon()
    }

    /// The shown group's pages load, not only the active one's.
    func wakeSplit() {
        for id in shownSplit?.ids ?? [] where id != activeID { _ = tab(id)?.wake() }
    }

    // MARK: - Dragging a tab

    /// Where `tab`, dragged from its list, is with the pointer at `pointer` on
    /// screen. Over the page, beyond some slop from the list, it says where
    /// the tab would split in (`splitHover`).
    func zone(dragging tab: Tab, at pointer: NSPoint) -> DragZone {
        guard let window, window.frame.contains(pointer) else {
            if splitHover != nil { splitHover = nil }
            return .outside
        }
        guard let stage = stageView, let active, let content = window.contentView else { return .list }
        let inWindow = window.convertPoint(fromScreen: pointer)
        let point = stage.convert(inWindow, from: nil)
        // The list reaches this far from the window's edge, and a little past
        // it still counts as the list: a hidden sidebar or strip that's out
        // floats over the page, so the page's own edge isn't the list's.
        let slop: CGFloat = 24
        let reach =
            prefs.sidebar
            ? (folded ? (peeking ? prefs.sideWidth + ChromeLayout.gap * 2 : 0) : prefs.sideWidth)
            : (folded && !peeking ? 0 : ChromeLayout.strip)
        let along = prefs.sidebar ? inWindow.x : content.bounds.height - inWindow.y
        guard stage.bounds.contains(point), along >= reach + slop else {
            if splitHover != nil { splitHover = nil }
            return .list
        }
        let frames = (shownSplit ?? SplitLayout(active.id)).frames(in: stage.bounds, gap: Browser.splitGap)
        let target = frames.first { $0.value.contains(point) }
        var hover: SplitHover?
        if let target, target.key != tab.id, splittable(tab), let other = self.tab(target.key), splittable(other),
            let side = SplitLayout<Tab.ID>.dropSide(at: point, in: target.value)
        {
            hover = SplitHover(target: target.key, side: side)
        }
        if splitHover != hover { splitHover = hover }
        return .page
    }

    /// Let go over the page: in beside the page under it, if it said where.
    func dropOnPage(_ tab: Tab) {
        defer { if splitHover != nil { splitHover = nil } }
        guard let hover = splitHover, let target = self.tab(hover.target) else { return }
        split(tab, beside: target, side: hover.side)
    }

    // MARK: - Saving

    /// The groups among `kept`, by their places in it.
    func savedSplits(_ kept: [Tab]) -> [SplitLayout<Int>]? {
        let at = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.id, $0) })
        let found = splits.values.compactMap { layout in layout.compactMap { at[$0] } }
        return found.isEmpty ? nil : found
    }

    /// Brings back saved groups over `made`, the tabs at each saved place.
    func restoreSplits(_ saved: [SplitLayout<Int>]?, _ made: [Tab?]) {
        for layout in saved ?? [] {
            if let back = layout.compactMap({ made.indices.contains($0) ? made[$0]?.id : nil }) { splits[UUID()] = back }
        }
    }
}
