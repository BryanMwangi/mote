import AppKit
import MoteCore

@MainActor
enum WindowDressing {
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
