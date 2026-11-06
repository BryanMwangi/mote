import AppKit
import MoteCore
import SwiftUI

/// The original AppKit group is hosted inside the moving pane.
struct TrafficLights: FillsRoom {
    var showing: Bool
    var strip = false
    var inset: CGFloat = 0
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {
        host.showing = showing
        host.strip = strip
        host.inset = inset
        host.mount()
    }

    @MainActor final class Host: NSView {
        static let groups = NSMapTable<NSWindow, NSView>.weakToStrongObjects()
        static let titlebars = NSMapTable<NSWindow, NSView>.weakToWeakObjects()
        /// Where the group and its buttons sat in the title bar, for full
        /// screen to have them back.
        static let frames = NSMapTable<NSWindow, NSArray>.weakToStrongObjects()
        static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        static let watched = NSHashTable<NSWindow>.weakObjects()
        static let hosts = NSHashTable<Host>.weakObjects()
        var showing = false
        var strip = false
        var inset: CGFloat = 0
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            Self.hosts.add(self)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            mount()
        }
        /// Leaving the window with the buttons would take them along: the
        /// host showing them now takes them, once this one has gone.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard let window, newWindow !== window, Self.groups.object(forKey: window)?.superview === self else { return }
            DispatchQueue.main.async { [weak window] in
                if let window { TrafficLights.refresh(in: window) }
            }
        }
        func mount() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            guard let group = Self.group(in: window), showing else { return }
            if group.superview !== self { addSubview(group) }
            layoutControls()
        }

        static func group(in window: NSWindow) -> NSView? {
            if let saved = Self.groups.object(forKey: window) {
                return saved
            }
            guard let group = window.standardWindowButton(.closeButton)?.superview else { return nil }
            // AppKit can reveal its titlebar again after SwiftUI finishes opening
            // the window. Take the controls out even when no pane is showing;
            // the retained group waits here until a visible host takes it up.
            if let titlebar = group.superview {
                titlebar.isHidden = true
                Self.titlebars.setObject(titlebar, forKey: window)
                let frames = [group.frame] + buttons.map { window.standardWindowButton($0)?.frame ?? .zero }
                Self.frames.setObject(frames.map(NSValue.init(rect:)) as NSArray, forKey: window)
            }
            watchFullScreen(window)
            group.removeFromSuperview()
            group.autoresizesSubviews = false
            group.autoresizingMask = []
            Self.groups.setObject(group, forKey: window)
            return group
        }
        /// Full screen wants the buttons in AppKit's own title bar, which
        /// shows them on hover at the top; they come back on leaving it.
        private static func watchFullScreen(_ window: NSWindow) {
            guard !watched.contains(window) else { return }
            watched.add(window)
            let center = NotificationCenter.default
            _ = center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { lend(window) } }
            }
            _ = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { TrafficLights.refresh(in: window) } }
            }
        }

        /// Puts the group back in its title bar, as AppKit left it.
        private static func lend(_ window: NSWindow) {
            guard let group = groups.object(forKey: window), let titlebar = titlebars.object(forKey: window) else { return }
            groups.removeObject(forKey: window)
            group.removeFromSuperview()
            titlebar.addSubview(group)
            let saved = (frames.object(forKey: window) as? [NSValue])?.map(\.rectValue) ?? []
            if let frame = saved.first { group.frame = frame }
            group.autoresizesSubviews = true
            group.autoresizingMask = [.width, .minYMargin]
            titlebar.isHidden = false
            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                if index + 1 < saved.count { button.frame = saved[index + 1] }
                button.isHidden = false
            }
        }

        override func layout() {
            super.layout()
            layoutControls()
        }
        private func layoutControls() {
            guard let window, let group = Self.groups.object(forKey: window), group.superview === self else { return }
            Self.titlebars.object(forKey: window)?.isHidden = true
            group.frame = bounds
            let center = ChromeLayout.lights(for: strip ? .strip : .sidebar)
            for (index, type) in Self.buttons.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                button.autoresizingMask = []
                let y =
                    group.isFlipped
                    ? center.y - inset - button.frame.height / 2 : bounds.height - center.y + inset - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: center.x - inset + CGFloat(index) * 20 - button.frame.width / 2, y: y))
                button.isHidden = false
                button.updateTrackingAreas()
            }
            group.updateTrackingAreas()
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }
    @MainActor static func refresh(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        _ = Host.group(in: window)
        for host in Host.hosts.allObjects where host.window === window { host.mount() }
    }
    @MainActor static func visible(in window: NSWindow) -> Bool {
        window.standardWindowButton(.closeButton).map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? false
    }
}
