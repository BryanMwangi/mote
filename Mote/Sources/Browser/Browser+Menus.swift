import AppKit
import MoteCore
import UniformTypeIdentifiers
import WebKit

// What the tab, space and page menus do beyond what was already there, after
// Zen's menus (see ROADMAP.md, "Context menus and extension popups").

extension Browser {
    /// Puts a space's pages to sleep: the showing one's all but the tab in
    /// front, another's all of them.
    func unload(space id: UUID) {
        let row = id == spaceID ? tabs.filter { $0.id != activeID } : parked[id]?.tabs ?? []
        for tab in row where !tab.asleep { sleep(tab) }
    }

    /// Every other space's.
    func unloadOtherSpaces() {
        for space in spaces where space.id != spaceID { unload(space: space.id) }
    }

    /// Other open tabs at the same address; essentials and pinned tabs stay.
    func closeDuplicates(of tab: Tab) {
        let address = (tab.pending ?? tab.address)?.absoluteString
        guard let address else { return }
        for other in tabs where other !== tab && !other.held && (other.pending ?? other.address)?.absoluteString == address {
            close(other)
        }
    }

    /// The open tabs after this one.
    func closeTabs(below tab: Tab) {
        guard let at = tabs.firstIndex(where: { $0 === tab }) else { return }
        for other in tabs[(at + 1)...] where !other.held { close(other) }
    }

    /// The tab, its page and history as they are, in a window of its own.
    /// Essentials and pinned tabs belong to the space, so they stay.
    func moveToNewWindow(_ tab: Tab) {
        guard !tab.held, tabs.count > 1 else { return }
        if activeID == tab.id, let next = row.neighbour(of: tab.id, by: 1) ?? row.neighbour(of: tab.id, by: -1) {
            activeID = next
        }
        reorder { $0.remove(tab.id) }
        let window = Windows.shared.open(space: spaceID, private: isPrivate)
        let blank = window.active
        window.adopt(tab)
        window.activeID = tab.id
        if let blank, blank.isBlank { window.close(blank) }
        saveSoon()
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
