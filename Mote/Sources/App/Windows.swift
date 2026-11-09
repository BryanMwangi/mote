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
    /// Windows closed by hand, the latest last, their tabs' files kept to reopen them.
    private var closedWindows: [(record: Record, spaces: [UUID])] = []
    var canReopen: Bool { !closedWindows.isEmpty }

    var all: [Browser] { (main.map { [$0] } ?? []) + extra.values }

    /// A new window on `space` (the front window's by default) with that
    /// space's essentials and pinned tabs and its own open tabs (a new tab for
    /// a new window). `prepare` runs before it shows, to put a tab in it.
    @discardableResult
    func open(id: UUID = UUID(), space: UUID? = nil, private isPrivate: Bool = false, prepare: (Browser) -> Void = { _ in }) -> Browser {
        let browser = Browser(extra: true, id: id, space: space ?? (Browser.front ?? main)?.spaceID, isPrivate: isPrivate)
        prepare(browser)
        extra[id] = browser
        opener?(id)
        if #available(macOS 15.4, *) { Extensions.shared.followTabs(of: browser) }
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
        file.save(records)
    }

    /// The windows to bring back: not the private ones.
    private var records: [Record] { extra.filter { !$0.value.isPrivate }.map { Record(id: $0.key, space: $0.value.spaceID) } }

    /// The window closed last, back with its tabs.
    func reopenClosed() {
        guard let last = closedWindows.popLast() else { return }
        open(id: last.record.id, space: last.record.space)
    }

    /// Before quitting: every window's tabs, now.
    func flush() {
        quitting = true
        for closed in closedWindows {
            Session.erase(window: closed.record.id, spaces: closed.spaces)
            WindowPlace.forget(closed.record.id)
        }
        closedWindows = []
        for browser in extra.values { browser.writeSession(now: true) }
        file.saveNow(records)
    }

    /// A window opened since the main one has closed: its tabs go with it.
    /// The last few are kept to reopen (a private one isn't); at quit, all
    /// come back.
    func closed(_ browser: Browser) {
        guard browser.extra, !quitting, let id = extra.first(where: { $0.value === browser })?.key else { return }
        extra[id] = nil
        if #available(macOS 15.4, *) { Extensions.shared.forget(browser) }
        let spaces = browser.spaces.map(\.id)
        if browser.isPrivate {
            Session.erase(window: id, spaces: spaces)
            WindowPlace.forget(id)
        } else {
            for space in spaces {
                browser.writeSession(
                    now: true, space: space, tabs: space == browser.spaceID ? browser.tabs : browser.parked[space]?.tabs ?? [],
                    active: space == browser.spaceID ? browser.activeID : browser.parked[space]?.active)
            }
            closedWindows.append((Record(id: id, space: browser.spaceID), spaces))
            if closedWindows.count > 5 {
                let oldest = closedWindows.removeFirst()
                Session.erase(window: oldest.record.id, spaces: oldest.spaces)
                WindowPlace.forget(oldest.record.id)
            }
        }
        browser.tabs.forEach { $0.close() }
        browser.parkedTabs.forEach { $0.close() }
        if Browser.front === browser { Browser.front = main }
        save()
    }
}
