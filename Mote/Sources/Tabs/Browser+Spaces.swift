import MoteCore
import SwiftUI
import os

/// Switching spaces and tabs, and peeking the folded tabs, for Instruments
/// (Points of Interest).
let switching = OSSignposter(subsystem: "io.github.mote-browser.mote", category: .pointsOfInterest)

// Switching between spaces and changing them.
extension Browser {
    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }
    /// The tabs of every space not showing, for tab sleep.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }
    var freeIcon: String { SpaceList(saved: spaces).freeIcon }

    /// This space's downloads folder, or the one in Settings.
    var downloadsFolder: URL {
        guard prefs.usesSpaces, let path = space.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    func switchSpace(to id: UUID) {
        if usesSpaces { enter(id) }
    }

    func switchSpace(index: Int) {
        if spaces.indices.contains(index) { switchSpace(to: spaces[index].id) }
    }

    /// ⌃⌥Q and ⌃⌥E: the space before or after, round from the ends, as Zen.
    func stepSpace(_ by: Int) {
        guard spaces.count > 1, let here = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        switchSpace(index: (here + by + spaces.count) % spaces.count)
    }

    /// Parks this space's tabs as they are (their media keeps playing) and
    /// shows the other's.
    private func enter(_ id: UUID) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        let interval = switching.beginInterval("Switch space")
        defer { switching.endInterval("Switch space", interval) }
        // Every change in one transaction, so SwiftUI updates once: a change
        // before it would be drawn first, in an update of its own. One row
        // for another, not each row coming and going.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            // Which way the space's icon slides.
            if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
            cancelTabEdit()
            if floater.showing { land() }
            // Saved in the background: nothing about the switch waits for the disk.
            writeSession(now: false, space: spaceID, tabs: tabs, active: activeID)
            parked[spaceID] = Parked(tabs: tabs, active: activeID)

            spaceID = id
            // The app's current space is the front window's; the main window's is the one kept.
            if Browser.front === self || Browser.front == nil { Spaces.current = id }
            if extra { Windows.shared.save() } else { Storage.settings.set(id.uuidString, forKey: "space.current") }
            if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
                showRow(back.tabs, active: back.active)
                if let active, !active.wake() { active.revive() }
            } else {
                showRow([], active: nil)
                restoreSession()
            }
            editing = active?.isStart ?? true
            field.clear()
            // The address only for a tab with no page, as Zen focuses the page otherwise.
            if editing { field.askFocus() }
        }
        // After the new space's first frame.
        let name = space.name
        DispatchQueue.main.async { [weak self] in self?.announce(name) }
    }

    /// Readies a space before it's shown, as Zen warms the tab it's about to
    /// select: its tab in front gets a page, so switching shows it at once.
    func warmSpace(_ id: UUID) {
        guard usesSpaces, id != spaceID, let row = parked[id], let tab = row.active.flatMap({ id in row.tabs.first { $0.id == id } })
        else { return }
        if !tab.wake() { tab.revive() }
    }

    /// Builds the other spaces' rows ahead, so a swipe can show the next one
    /// sliding in.
    func preloadSpaces() {
        for space in spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    /// Returns to the first space when spaces are turned off. The others are
    /// kept, for when they're turned back on.
    func leaveSpaces() {
        enter(Space.firstID)
        parkedTabs.forEach { $0.close() }
        parked = [:]
    }

    /// Changes the list and saves it.
    private func editSpaces(saving: Bool = true, _ change: (inout SpaceList) -> Void) {
        var list = SpaceList(saved: spaces)
        change(&list)
        spaces = list.spaces
        if saving { Spaces.write(spaces) }
        // Every window shows the same spaces: names, icons and colours follow.
        for other in Windows.shared.all where other !== self { other.spaces = spaces }
    }

    /// A new, empty space, gone to at once.
    func addSpace(named name: String, icon: String? = nil, sharesSignIns: Bool = true) {
        makingSpace = false
        let made = Space(id: UUID(), name: name, icon: icon ?? freeIcon, sharesSignIns: sharesSignIns)
        editSpaces { $0.add(made) }
        switchSpace(to: made.id)
    }

    /// The space several merge into: the first space when it's among them,
    /// as it can't go, otherwise the highest in the list. It keeps all its
    /// own website data, which a new space couldn't be given.
    func mergeTarget(of ids: Set<UUID>) -> Space? {
        spaces.first { $0.isFirst && ids.contains($0.id) } ?? spaces.first { ids.contains($0.id) }
    }

    /// Merges the spaces into one (see `mergeTarget`), which takes `name`.
    func mergeSpaces(_ ids: Set<UUID>, named name: String) async -> Merged {
        guard ids.count > 1, let target = mergeTarget(of: ids) else { return Merged() }
        var total = Merged()
        for space in spaces where ids.contains(space.id) && space.id != target.id {
            let merged = await mergeSpace(space.id, into: target.id)
            total.tabs += merged.tabs
            total.cookies += merged.cookies
        }
        renameSpace(target.id, to: name)
        return total
    }

    /// Spaces made elsewhere (an import), after the others.
    func addSpaces(_ made: [Space]) { editSpaces { list in made.forEach { list.add($0) } } }

    func moveSpace(_ id: UUID, to index: Int) { editSpaces { $0.move(id, to: index) } }

    func renameSpace(_ id: UUID, to name: String) {
        if !name.isEmpty { editSpaces { $0.edit(id) { $0.name = name } } }
    }

    func setSpaceIcon(_ id: UUID, to icon: String) { editSpaces { $0.edit(id) { $0.icon = icon } } }
    /// Light or dark as the space in front's theme says; nil follows Mote's look.
    var spaceScheme: ColorScheme? {
        spaces.first { $0.id == spaceID }?.theme?.scheme.map { $0 == .dark ? .dark : .light }
    }

    /// Its colours; a drag shows each step and keeps only the last (`saving`).
    func setSpaceTheme(_ id: UUID, to theme: SpaceTheme?, saving: Bool = true) {
        editSpaces(saving: saving) { $0.edit(id) { $0.theme = theme } }
    }
    func setSpaceDownloads(_ id: UUID, to folder: URL?) { editSpaces { $0.edit(id) { $0.downloads = folder?.path } } }

    /// The new-space card, or a dialog when the tabs are folded away.
    func askForSpace() {
        if !folded || peeking {
            SpaceSwipe.shared.start(for: self)
            SpaceSwipe.shared.slide(self, to: spaces.count, from: spaces.firstIndex { $0.id == spaceID } ?? 0)
        } else {
            Prompt.newSpace { name, shared in self.addSpace(named: name, sharesSignIns: shared) }
        }
    }

    /// Whether a tab here would keep its sign-ins in another space.
    func sharesData(with id: UUID) -> Bool { Spaces.store(for: id) === Spaces.store(for: spaceID) }

    /// Moves a tab to the end of another space's row. Between spaces with the
    /// same website data the page goes as it is; otherwise it opens again in
    /// the other space's data, signed in only as that space is, and its back
    /// history stays behind.
    func move(_ tab: Tab, toSpace id: UUID) {
        guard usesSpaces, id != spaceID, let to = spaces.first(where: { $0.id == id }),
            let url = tab.pending ?? tab.address
        else { return }
        var row = parked[id] ?? loadRow(id)
        tab.pin = nil
        tab.kept = false
        if sharesData(with: id) {
            guard detach(tab) else { return }
            row.tabs.append(tab)
        } else {
            let moved = Tab(configuration: Web.configuration(space: id))
            prepare(moved)
            moved.restore(url: url, title: tab.title, name: tab.name)
            close(tab)
            row.tabs.append(moved)
        }
        if row.active == nil { row.active = row.tabs.last?.id }
        parked[id] = row
        writeSession(now: true, space: id, tabs: row.tabs, active: row.active)
        writeSession(now: true)
        announce("Moved to \(to.name)")
    }

    /// Deletes a space, its tabs and, unless it shared the first space's,
    /// its website data. The first space stays.
    func deleteSpace(_ id: UUID) {
        guard let doomed = SpaceList(saved: spaces).space(id), !doomed.isFirst else { return }
        if spaceID == id { switchSpace(to: Space.firstID) }
        parked.removeValue(forKey: id)?.tabs.forEach { $0.close() }
        editSpaces { $0.remove(id) }
        Session.erase(space: id)
        FolderStore.shared.change(id) { $0.removeAll() }
        if doomed.ownData { Spaces.erase(id) }
    }
}
