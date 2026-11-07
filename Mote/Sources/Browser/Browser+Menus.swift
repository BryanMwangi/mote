import AppKit
import MoteCore
import UniformTypeIdentifiers
import WebKit

extension Browser {
    /// Puts a space's pages to sleep: the showing one's all but the tab in
    /// front, another's all of them.
    func unload(space id: UUID) {
        let row = id == spaceID ? tabs.filter { $0.id != activeID } : parked[id]?.tabs ?? []
        for tab in row where !tab.asleep { sleep(tab) }
    }

    /// A tab's page let go, because the user asked. The tab in front can't
    /// sleep, so another comes forward first, as on closing one: the one
    /// used last, or the one beside it (Settings › Tabs).
    func unload(_ tab: Tab) {
        if activeID == tab.id {
            let beside = (row.neighbour(of: tab.id, by: 1) ?? row.neighbour(of: tab.id, by: -1)).flatMap(self.tab)
            guard let other = (prefs.closeGoesBack ? recentlyUsed(besides: tab) : nil) ?? beside else { return }
            select(other)
        }
        sleep(tab, asked: true) { [weak self] said in
            if said != "asleep" { self?.announce("Can't unload it: \(said)") }
        }
    }

    /// Unload Tab, for the tab in front (its key).
    func unloadActive() { active.map(unload) }

    /// Every other space's.
    func unloadOtherSpaces() {
        for space in spaces where space.id != spaceID { unload(space: space.id) }
    }

    /// Other open tabs at the same address; essentials and pinned tabs stay (TabRow).
    func closeDuplicates(of tab: Tab) {
        let ids = row.duplicates(of: tab.id) { ($0.pending ?? $0.address)?.absoluteString }
        for id in ids { if let other = self.tab(id) { close(other) } }
    }

    /// The open tabs after this one (TabRow).
    func closeTabs(below tab: Tab) {
        for id in row.below(tab.id) { if let other = self.tab(id) { close(other) } }
    }

    /// The tab, its page and history as they are, in a window of its own.
    /// Essentials and pinned tabs belong to the space, so they stay.
    func moveToNewWindow(_ tab: Tab) { move(tab, to: nil) }

    /// A tab let go outside its window: onto another Mote window, it goes
    /// there; elsewhere, into a new window where it was let go.
    func drop(_ tab: Tab) {
        let pointer = NSEvent.mouseLocation
        let under = NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
        let target = Windows.shared.browser(for: NSApp.windows.first { $0.windowNumber == under })
        if let target, target !== self {
            move(tab, to: target)
        } else if target == nil {
            move(tab, to: nil, at: pointer)
        }
    }

    /// Hands a tab, page and all, to another window, or a new one (`nil`),
    /// placed with its top left at `point` when given. A private window's
    /// tabs only go to private windows, and the others' only to others.
    func move(_ tab: Tab, to target: Browser?, at point: NSPoint? = nil) {
        guard !tab.held, tabs.count > 1, target !== self, (target?.isPrivate ?? isPrivate) == isPrivate else { return }
        if activeID == tab.id, let next = row.neighbour(of: tab.id, by: 1) ?? row.neighbour(of: tab.id, by: -1) {
            activeID = next
        }
        unsplit(tab: tab.id)
        reorder { $0.remove(tab.id) }
        let window = target ?? Windows.shared.open(space: spaceID, private: isPrivate)
        let blank = target == nil ? window.active : nil
        window.adopt(tab)
        window.activeID = tab.id
        if let blank, blank.isBlank { window.close(blank) }
        if let point {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { window.window?.setFrameTopLeftPoint(point) }
        }
        window.window?.makeKeyAndOrderFront(nil)
        saveSoon()
        window.saveSoon()
    }

    /// The page in front, as a web archive where the user says.
    func savePage() {
        guard let tab = active, !tab.isBlank, let web = tab.built else { return }
        web.createWebArchiveData { [weak self] result in
            MainActor.assumeIsolated {
                guard case .success(let data) = result else { return self?.announce("This page couldn't be saved") ?? () }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.webArchive]
                panel.nameFieldStringValue = tab.label.replacingOccurrences(of: "/", with: "-")
                panel.directoryURL = self?.downloadsFolder
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if (try? data.write(to: url)) == nil { self?.announce("This page couldn't be saved") }
            }
        }
    }
}
