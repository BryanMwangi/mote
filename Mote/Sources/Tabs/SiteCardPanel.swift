import AppKit
import Combine
import SwiftUI

/// The site card's window: a panel hanging under the padlock that never
/// takes the keyboard, so focus stays where it was. It closes on a click
/// elsewhere, on leaving the app, or on going to another tab.
@MainActor
enum SiteCardPanel {
    private static var panel: Panel?
    private static var leaving: NSObjectProtocol?
    private static var clicks: Any?
    private static var tabWatch: AnyCancellable?

    /// The padlocks it may hang from, in the toolbar and the sidebar's
    /// address (see SiteCardAnchor), and the tab row it was asked for from.
    fileprivate static var padlocks: [WeakView] = []
    fileprivate static weak var row: NSView?
    private static weak var owner: Browser?

    /// The padlock on screen in `window`.
    private static func padlock(in window: NSWindow?) -> NSView? {
        padlocks.compactMap(\.view).last { $0.window === window && $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor }
    }

    static var isShown: Bool { panel != nil }

    /// Opens the card, or closes it if it's open.
    static func toggle(for tab: Tab, in browser: Browser) {
        isShown ? hide() : open(for: tab, in: browser)
    }

    /// Opens the card for `tab` once its padlock shows (a few frames after
    /// switching to it); `beside` its row in the sidebar, for the tab's menu.
    static func open(for tab: Tab, in browser: Browser, security: Bool = false, beside: Bool = false) {
        guard !tab.isBlank else { return }
        hide()
        // Where it was asked for, when there's nothing in this window to hang from.
        let pointer = NSEvent.mouseLocation
        let asideRow = beside && browser.prefs.sidebar
        if asideRow { browser.siteCardRow = tab.id }
        owner = browser
        Task {
            for _ in 0..<16 {
                let spot = asideRow ? row : padlock(in: browser.window)
                if let spot, let window = spot.window, window === browser.window, browser.activeID == tab.id {
                    let place = window.convertToScreen(spot.convert(spot.bounds, to: nil))
                    let side = asideRow ? (browser.prefs.sideRight ? -1 : 1) : 0
                    show(for: tab, in: browser, at: place, in: window, security: security, beside: side)
                    tabWatch = browser.$activeID.dropFirst().sink { _ in MainActor.assumeIsolated { hide() } }
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let window = browser.window, browser.activeID == tab.id else { return }
            let spot = NSRect(x: pointer.x + 6, y: pointer.y, width: 0, height: 0)
            show(for: tab, in: browser, at: spot, in: window, security: security, beside: 0)
            tabWatch = browser.$activeID.dropFirst().sink { _ in MainActor.assumeIsolated { hide() } }
        }
    }

    /// `spot`: on screen, what it hangs below; or, `beside` it, to its
    /// right (1) or left (-1), its top level with the spot's.
    private static func show(for tab: Tab, in browser: Browser, at spot: NSRect, in window: NSWindow, security: Bool, beside: Int) {
        // It grows with its content, from the edge nearest what it hangs from.
        var resized: (NSSize) -> Void = { _ in }
        let card = SiteCard(browser: browser, tab: tab, deeper: security) { hide() }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                resized($0)
            }
        let host = Host(rootView: AnyView(card))
        let size = host.fittingSize
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .menu
        material.state = .active
        // The blur behind is shaped by a mask image only: with the window
        // active it ignores the layer's rounded corners and fills them square.
        material.maskImage = Self.roundedMask(radius: MenuMetrics.corner)
        material.wantsLayer = true
        if let layer = material.layer {
            layer.cornerRadius = MenuMetrics.corner
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = 0.5
            layer.borderColor = MenuMetrics.edge.cgColor
        }
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)

        let panel = Panel(contentRect: material.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = material
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        // Under the padlock, the menu's text in line with the address; or
        // beside the tab's row, level with it.
        var origin =
            switch beside {
            case 1: NSPoint(x: spot.maxX + 8, y: spot.maxY - size.height + 4)
            case -1: NSPoint(x: spot.minX - 8 - size.width, y: spot.maxY - size.height + 4)
            default: NSPoint(x: spot.minX - 6, y: spot.minY - 8 - size.height)
            }
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        // It grows downwards with its content: the security view is taller.
        resized = { [weak panel] fitted in
            guard let panel, fitted.height > 0, fitted != panel.frame.size else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - fitted.height
            if beside == -1 { frame.origin.x += frame.width - fitted.width }
            frame.size = fitted
            panel.setFrame(frame, display: true)
            // Or the shadow keeps the card's old shape.
            panel.invalidateShadow()
        }
        self.panel = panel
        leaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            _ in
            MainActor.assumeIsolated { hide() }
        }
        // A click anywhere but the card closes it; one on the padlock is the
        // padlock's, which toggles.
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                let onPadlock = padlocks.contains {
                    guard let view = $0.view else { return false }
                    return view.window === event.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                }
                if event.window !== panel, !onPadlock { hide() }
            }
            return event
        }
    }

    static func hide() {
        if let leaving { NotificationCenter.default.removeObserver(leaving) }
        if let clicks { NSEvent.removeMonitor(clicks) }
        leaving = nil
        clicks = nil
        tabWatch = nil
        if owner?.siteCardRow != nil { owner?.siteCardRow = nil }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// A rounded rectangle that stretches to any size, keeping its corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click without the panel becoming key.
    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Marks what the card hangs from: a padlock, or the row of the tab it was
/// asked for from.
struct SiteCardAnchor: FillsRoom {
    var row = false

    func makeNSView(context: Context) -> NSView {
        let spot = Spot()
        note(spot)
        return spot
    }

    func updateNSView(_ view: NSView, context: Context) { note(view) }

    private func note(_ view: NSView) {
        if row { return SiteCardPanel.row = view }
        guard !SiteCardPanel.padlocks.contains(where: { $0.view === view }) else { return }
        SiteCardPanel.padlocks = SiteCardPanel.padlocks.filter { $0.view != nil } + [WeakView(view)]
    }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
