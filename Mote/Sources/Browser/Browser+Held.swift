import Foundation
import MoteCore

// Essentials and pinned tabs belong to the space, so every window shows them.
// Each window has tabs of its own for them (a web view lives in
// one window); when one window pins, unpins, reorders, renames or changes a
// letter, the others follow. A tab's page is its own window's: where it
// browses doesn't travel.

/// What the windows last agreed each space's held tabs are: their ids,
/// letters, pinning, names and order.
@MainActor
enum HeldSync {
    private struct Shape: Equatable {
        let held: String?, pin: String?, kept: Bool, name: String?, chat: String?, home: String?, folder: String?
        init(_ entry: Session.Entry) {
            (held, pin, kept, name, chat, home, folder) = (
                entry.held, entry.pin, entry.kept == true, entry.name, entry.chat, entry.home, entry.folder
            )
        }
    }

    private static var known: [UUID: [Shape]] = [:]

    /// How a space's held tabs stand when a window first loads them.
    static func seed(_ entries: [Session.Entry], in space: UUID) {
        if known[space] == nil { known[space] = entries.filter(\.isHeld).map(Shape.init) }
    }

    /// A window saved a space: if its held tabs changed, the others follow.
    static func saved(_ entries: [Session.Entry], in space: UUID, by source: Browser) {
        let held = entries.filter(\.isHeld)
        let shape = held.map(Shape.init)
        guard known[space] != shape else { return }
        known[space] = shape
        for browser in Windows.shared.all where browser !== source { browser.followHeld(held, in: space) }
    }
}

extension Session.Entry {
    var isHeld: Bool { pin != nil || kept == true }
}

extension Browser {
    /// A space's held tabs as another window left them: the same tabs kept
    /// where they're the same (by id, or for older files by letter and
    /// address), new ones asleep, gone ones closed, in the new order.
    func followHeld(_ entries: [Session.Entry], in space: UUID) {
        let showing = space == spaceID
        guard let row = showing ? tabs : parked[space]?.tabs else { return }
        var spare = row.filter(\.held)
        var held: [Tab] = []
        for entry in entries {
            let id = entry.held.flatMap(UUID.init(uuidString:))
            let same =
                spare.firstIndex { id != nil && $0.heldID == id }
                ?? spare.firstIndex { $0.heldID == nil && $0.pin == entry.pin && ($0.pending ?? $0.address)?.absoluteString == entry.url }
            if let same {
                let tab = spare.remove(at: same)
                tab.heldID = id
                if tab.pin != entry.pin { tab.pin = entry.pin }
                if tab.kept != (entry.kept == true) { tab.kept = entry.kept == true }
                if tab.name != entry.name { tab.name = entry.name }
                // Home is the saved one, or the saved address when it's still there.
                let home = entry.home.flatMap(URL.init(string:)) ?? (entry.chat == nil ? URL(string: entry.url) : nil)
                if tab.home != home { tab.home = home }
                let folder = entry.folder.flatMap(UUID.init(uuidString:))
                if tab.folder != folder { tab.folder = folder }
                held.append(tab)
            } else {
                let tab = Tab(configuration: Web.configuration(space: space))
                if restore(entry, in: tab) { held.append(tab) }
            }
        }
        spare.forEach { $0.close() }
        let next = held + row.filter { !$0.held }
        if showing {
            showRow(next, active: activeID.flatMap { id in next.contains { $0.id == id } ? id : nil })
        } else {
            parked[space]?.tabs = next
        }
        // The main window keeps the space's held tabs in its file.
        if !extra { saveSoon() }
    }
}
