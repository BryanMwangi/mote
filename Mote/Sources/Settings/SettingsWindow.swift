import Combine
import SwiftUI

// Settings in a window of its own, beside the browser rather than over it.
// Follows every browser window's `tuning`: setting it opens the window over
// that browser window (or brings it to the front), clearing it closes the
// window, and closing the window clears it.

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// The browser's settings window, once the browser window has appeared.
    private static var shared: SettingsWindow?

    let window: NSWindow
    /// The browser window it was opened from, whose settings it shows.
    private weak var owner: Browser?
    private var watching: [AnyCancellable] = []
    /// Its keys, before the menus see them: its own, not a browser window's
    /// router's, as a browser window may not be open.
    private var keys: Any?

    /// Starts following a browser window's settings state, once it exists.
    static func watch(_ browser: Browser) {
        let settings = shared ?? SettingsWindow()
        shared = settings
        settings.follow(browser)
    }

    /// The settings window that owns a given window, if any.
    static func owning(_ window: NSWindow?) -> SettingsWindow? {
        guard let window, let shared, shared.window === window else { return nil }
        return shared
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsPanel.width, height: SettingsPanel.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        super.init()
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // By its title bar only: what's inside (reordering extensions) drags.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.NS.ground
        window.delegate = self
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.take(event) ? nil : event
        }
    }

    /// Receives the current value too, so settings asked for before the
    /// browser window appeared still open. On the next turn, since
    /// @Published sends before the value is stored.
    private func follow(_ browser: Browser) {
        let watch = browser.$tuning.receive(on: DispatchQueue.main).sink { [weak self, weak browser] on in
            guard let self, let browser else { return }
            if on {
                // Asked for from another window: it's that window's now.
                if owner !== browser {
                    let earlier = owner
                    owner = browser
                    if earlier?.tuning == true { earlier?.tuning = false }
                    if window.isVisible { window.contentView = panel(for: browser) }
                }
                show()
            } else if owner === browser {
                hide()
            }
        }
        watching.append(watch)
    }

    private func panel(for browser: Browser) -> NSView {
        NSHostingView(rootView: SettingsPanel(browser: browser, prefs: browser.prefs))
    }

    /// Handles the window's key shortcuts before the browser: Escape and ⌘W
    /// close it. Other keys go to the settings controls and the menus.
    func take(_ event: NSEvent) -> Bool {
        // A shortcut being recorded gets every key (Settings › Keyboard).
        if let recording = KeyRecorder.recording { return recording(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // ⌘F searches Settings; Escape clears a search before it closes the window.
        if key == "f", flags == .command {
            SettingsSearch.shared.focusAsked += 1
            return true
        }
        if event.keyCode == 53, flags.isEmpty, !SettingsSearch.shared.query.isEmpty {
            SettingsSearch.shared.query = ""
            return true
        }
        guard event.keyCode == 53 && flags.isEmpty || key == "w" && flags == .command else { return false }
        window.performClose(nil)
        return true
    }

    private func show() {
        if !window.isVisible {
            // A fresh panel each time, so it opens on the page last chosen
            // (Manage Extensions… picks one before opening settings).
            if let owner { window.contentView = panel(for: owner) }
            place()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Centres the window over the browser window, or on screen without one.
    private func place() {
        guard let main = owner?.window ?? AppDelegate.window, main.isVisible,
            let screen = (main.screen ?? NSScreen.main)?.visibleFrame
        else {
            window.center()
            return
        }
        window.setFrameOrigin(SettingsWindow.origin(for: window.frame.size, over: main.frame, within: screen))
    }

    /// Where a window of `size` sits centred over `main`, moved as little as
    /// needed to stay within `screen`.
    static func origin(for size: NSSize, over main: NSRect, within screen: NSRect) -> NSPoint {
        let x = main.midX - size.width / 2
        let y = main.midY - size.height / 2
        return NSPoint(
            x: min(max(x, screen.minX), screen.maxX - size.width),
            y: min(max(y, screen.minY), screen.maxY - size.height)
        )
    }

    /// Closes the window when settings are dismissed from elsewhere (a button
    /// that leads to the browser, the bench), returning focus to the browser.
    private func hide() {
        guard window.isVisible else { return }
        let wasKey = window.isKeyWindow
        window.close()
        if wasKey { (owner?.window ?? AppDelegate.window)?.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        if owner?.tuning == true { owner?.tuning = false }
        // Drops the panel so it stops observing while hidden.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.window.isVisible else { return }
            self.window.contentView = nil
        }
    }
}
