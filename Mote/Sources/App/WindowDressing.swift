import AppKit
import MoteCore

@MainActor
enum WindowDressing {
    /// Mote's windows can't be moved by macOS (DragStrip moves them), and
    /// macOS greys out Move to a display, Fill, Center and Remove Window from
    /// Set for such windows. While a menu of the menu bar is open, and a
    /// moment after for its action, they can.
    static func movableWhileMenusOpen() {
        let windows = { Windows.shared.all.compactMap(\.window) }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            let menu = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard menu != nil, menu == NSApp.mainMenu.map(ObjectIdentifier.init) else { return }
                windows().forEach { $0.isMovable = true }
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            let menu = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard menu != nil, menu == NSApp.mainMenu.map(ObjectIdentifier.init) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { windows().forEach { $0.isMovable = false } }
            }
        }
    }

    /// `main`: the main window, the one the Dock and links bring back.
    /// `id`: a window opened since, which keeps its own place by it.
    static func dress(_ window: NSWindow, main: Bool = true, id: UUID? = nil) {
        if main { AppDelegate.window = window }
        PageKeySink.end(window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // DragStrip owns window dragging; text selection and tab drags cannot move it.
        window.isMovableByWindowBackground = false
        window.isMovable = false
        let name = Storage.world.map { "mote (\($0))" } ?? "mote"
        window.setFrameAutosaveName(id.map { "\(name) \($0.uuidString)" } ?? name)
        // macOS doesn't say how round it draws windows; AppKit knows.
        if window.responds(to: NSSelectorFromString("_cornerRadius")), let radius = window.value(forKey: "_cornerRadius") as? CGFloat {
            ChromeLayout.corner = ChromeLayout.corner(inside: radius)
        }
        TrafficLights.refresh(in: window)
    }

}

/// The end of a browser window's responder chain. A key nothing took gets
/// here: one the page used without saying so, coming back up from WebKit as
/// a command (`moveLeft:` for ←, which YouTube seeks with), or one pressed
/// while a page is still opening and the keyboard hasn't reached it yet.
/// AppKit would beep; Safari stays quiet, and so does Mote. Keys meant for
/// Mote are taken before the page sees them (KeyRouter, the menus).
final class PageKeySink: NSResponder {
    /// How many it kept quiet, for the bench.
    @MainActor static var caught = 0
    private weak var window: NSWindow?

    /// Puts one at the end of the window's chain, once.
    @MainActor static func end(_ window: NSWindow) {
        var last: NSResponder = window
        while let next = last.nextResponder {
            if next is PageKeySink { return }
            last = next
        }
        let sink = PageKeySink()
        sink.window = window
        last.nextResponder = sink
    }

    /// A key is being handled: what's left over from it is kept quiet. Other
    /// actions are left as AppKit has them.
    @MainActor private var fromPage: Bool { NSApp.currentEvent?.type == .keyDown }

    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        guard MainActor.assumeIsolated({ fromPage }) else { return super.tryToPerform(action, with: object) }
        MainActor.assumeIsolated { Self.caught += 1 }
        return true
    }

    override func doCommand(by selector: Selector) {
        guard MainActor.assumeIsolated({ fromPage }) else { return super.doCommand(by: selector) }
        MainActor.assumeIsolated { Self.caught += 1 }
    }

    override func keyDown(with event: NSEvent) {
        guard MainActor.assumeIsolated({ fromPage }) else { return super.keyDown(with: event) }
        MainActor.assumeIsolated { Self.caught += 1 }
    }

    override func noResponder(for eventSelector: Selector) {
        if !MainActor.assumeIsolated({ fromPage }) { super.noResponder(for: eventSelector) }
    }
}
