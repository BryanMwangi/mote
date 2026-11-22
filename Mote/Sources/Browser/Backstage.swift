import AppKit
import WebKit

/// Pages the assistant works on out of sight, kept live: a view with no
/// window is hidden to its page, which then gets no animation frames and
/// slow timers, and some (Gmail's list) never draw. Here it is laid out and
/// painted in a window off every screen, as a page in front would be, until
/// the assistant has left it alone for a while or the tab is shown.
@MainActor
enum Backstage {
    /// How long a page stays live after the assistant last used it.
    static let linger: Duration = .seconds(120)
    private static var until: [ObjectIdentifier: ContinuousClock.Instant] = [:]

    /// Keeps the tab's page live, off screen, unless it's already in a window.
    static func keep(_ tab: Tab) {
        guard let web = tab.built else { return }
        let room = BenchRoom.made
        let bench = tab.bench
        let key = ObjectIdentifier(web)
        // In the browser's window, it's shown.
        guard web.window == nil || web.window === room else { return }
        // Already here, it stays longer.
        if until[key] != nil { return until[key] = .now + linger }
        until[key] = .now + linger
        // WebKit doesn't run a page whose window it thinks is covered; it
        // looks again as the view moves into a window.
        web.unpublished("_setWindowOcclusionDetectionEnabled:", false)
        web.removeFromSuperview()
        web.frame = room.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        web.autoresizingMask = [.width, .height]
        room.contentView?.addSubview(web)
        Task { [weak web] in
            while let web, let end = until[key], ContinuousClock.now < end {
                try? await Task.sleep(until: end)
            }
            until[key] = nil
            guard let web else { return }
            web.unpublished("_setWindowOcclusionDetectionEnabled:", true)
            // Shown meanwhile, the stage has it; a bench page lives here anyway.
            if web.window === room, !bench { web.removeFromSuperview() }
        }
    }
}
