import AppKit

/// Every window's Browser: the main window's (MoteApp's `Window` scene, kept
/// when it closes, as before) and those opened since, with ⌘N or a link, each
/// a `WindowGroup` scene of its own that goes when it closes.
@MainActor
final class Windows {
    static let shared = Windows()

    /// The main window's.
    weak var main: Browser?
    private var extra: [UUID: Browser] = [:]
    /// Opens a window scene for an id: SwiftUI's `openWindow`, handed over by
    /// the first window's view.
    var opener: ((UUID) -> Void)?

    var all: [Browser] { (main.map { [$0] } ?? []) + extra.values }

    /// A new window on `space` (the front window's by default) with that
    /// space's essentials and pinned tabs and a new tab. `prepare` runs before
    /// it shows, to put a tab in it.
    @discardableResult
    func open(space: UUID? = nil, prepare: (Browser) -> Void = { _ in }) -> Browser {
        let id = UUID()
        let browser = Browser(extra: true, space: space ?? (Browser.front ?? main)?.spaceID)
        prepare(browser)
        extra[id] = browser
        opener?(id)
        return browser
    }

    func browser(for id: UUID) -> Browser? { extra[id] }

    /// The browser whose window this is, if any (not Settings or a small link window).
    func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// A window opened since the main one has closed: its tabs go with it.
    func closed(_ browser: Browser) {
        guard browser.extra, let id = extra.first(where: { $0.value === browser })?.key else { return }
        extra[id] = nil
        browser.tabs.forEach { $0.close() }
        browser.parkedTabs.forEach { $0.close() }
        if Browser.front === browser { Browser.front = main }
    }
}
