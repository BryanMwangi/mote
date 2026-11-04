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
