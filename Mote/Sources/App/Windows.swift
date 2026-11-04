import AppKit
import MoteCore

/// Every window's Browser: the main window's (MoteApp's `Window` scene, kept
/// when it closes, as before) and those opened since, with ⌘N or a link, each
/// a `WindowGroup` scene of its own that goes when it closes. Those are kept
/// in windows.json, their open tabs beside it (Session), so they come back at
/// launch; private ones aren't.
@MainActor
final class Windows {
    static let shared = Windows()

    /// The main window's.
    weak var main: Browser?
    private var extra: [UUID: Browser] = [:]
    /// Opens a window scene for an id: SwiftUI's `openWindow`, handed over by
    /// the first window's view.
    var opener: ((UUID) -> Void)?
    /// Quitting: windows closing now come back at the next launch.
    var quitting = false

    private nonisolated struct Record: Codable, Sendable {
        let id: UUID
        var space: UUID
    }

    private let file = JSONFile<[Record]>("windows.json")
    private var restored = false

    var all: [Browser] { (main.map { [$0] } ?? []) + extra.values }

    /// A new window on `space` (the front window's by default) with that
    /// space's essentials and pinned tabs and its own open tabs (a new tab for
    /// a new window). `prepare` runs before it shows, to put a tab in it.
    @discardableResult
    func open(id: UUID = UUID(), space: UUID? = nil, prepare: (Browser) -> Void = { _ in }) -> Browser {
        let browser = Browser(extra: true, id: id, space: space ?? (Browser.front ?? main)?.spaceID)
        prepare(browser)
        extra[id] = browser
        opener?(id)
        save()
        return browser
    }

    /// The windows open at the last quit, once the main one is up.
    func restore() {
        guard !restored else { return }
        restored = true
        for record in file.load() ?? [] where extra[record.id] == nil { open(id: record.id, space: record.space) }
    }

    func browser(for id: UUID) -> Browser? { extra[id] }

    /// The browser whose window this is, if any (not Settings or a small link window).
    func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// Which space each window shows changed, or a window came or went.
    func save() {
        file.save(extra.map { Record(id: $0.key, space: $0.value.spaceID) })
    }

    /// Before quitting: every window's tabs, now.
    func flush() {
        quitting = true
        for browser in extra.values { browser.writeSession(now: true) }
        file.saveNow(extra.map { Record(id: $0.key, space: $0.value.spaceID) })
    }

    /// A window opened since the main one has closed: its tabs go with it,
    /// and it's forgotten, unless the app is quitting.
    func closed(_ browser: Browser) {
        guard browser.extra, !quitting, let id = extra.first(where: { $0.value === browser })?.key else { return }
        extra[id] = nil
        Session.erase(window: id, spaces: browser.spaces.map(\.id))
        browser.tabs.forEach { $0.close() }
        browser.parkedTabs.forEach { $0.close() }
        if Browser.front === browser { Browser.front = main }
        save()
    }
}
