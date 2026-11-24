import AppKit
import SwiftUI

extension View {
    /// Shows `content` as a menu beside this view while `isPresented` is true,
    /// on the given `edge` of the view: a system popover, its arrow on the
    /// control, so its material, edges and text are the system's and stay
    /// clear over any page.
    /// - Parameter keyboard: the menu takes the keyboard when it opens.
    ///   False leaves it where it is, for suggestions under a field: those
    ///   are a rounded card in a panel of its own, as a popover takes the keyboard.
    /// - Parameter stays: open until answered or Escape, not closed by a
    ///   click elsewhere, for a site's question.
    /// - Parameter plain: without the keyboard, the plain card a tab's hover
    ///   picture shows on (no outline, its corners), for what shows on hover.
    func menuPanel<Content: View>(
        isPresented: Binding<Bool>, edge: Edge, keyboard: Bool = true, stays: Bool = false, plain: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(MenuPanelAnchor(isPresented: isPresented, edge: edge, keyboard: keyboard, stays: stays, plain: plain, content: content))
    }
}

/// Marks where the menu opens from and presents it.
private struct MenuPanelAnchor<Content: View>: FillsRoom {
    @Binding var isPresented: Bool
    let edge: Edge
    let keyboard: Bool
    let stays: Bool
    let plain: Bool
    let content: () -> Content

    func makeCoordinator() -> MenuPanel { MenuPanel() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let menu = context.coordinator
        menu.dismissed = { isPresented = false }
        if isPresented {
            if keyboard {
                menu.pop(AnyView(content()), from: anchor, edge: edge, stays: stays)
            } else {
                menu.show(AnyView(content()), from: anchor, edge: edge, keyboard: false, plain: plain)
            }
        } else {
            menu.close()
        }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: MenuPanel) {
        coordinator.close()
    }
}

/// A menu beside the control that opened it: a system popover, or a
/// borderless panel for one that leaves the keyboard where it is. It closes
/// on a click anywhere else, on Escape, when Mote stops being the active app,
/// and when the window it belongs to closes.
@MainActor
final class MenuPanel: NSObject, NSPopoverDelegate {
    /// Space between the control and the menu, in points.
    static let gap: CGFloat = 6
    /// Closest the menu comes to the screen's edges, in points.
    static let margin: CGFloat = 8
    static let cornerRadius: CGFloat = 14

    /// Called when the menu closes by itself, so the caller can clear its state.
    var dismissed: () -> Void = {}

    private var panel: Panel?
    private var host: Host?
    private weak var anchor: NSView?
    private var edge = Edge.top
    private var monitors: [Any] = []
    /// Set while the menu closes. Closing the panel makes SwiftUI update the
    /// view that owns it, which may still ask for the menu; it isn't reopened.
    private var closing = false
    private var observers: [NSObjectProtocol] = []

    var isShown: Bool { panel?.isVisible == true || popover?.isShown == true }

    private var popover: NSPopover?
    private var popoverHost: NSHostingController<AnyView>?
    /// When a popover last closed by itself, and over which control: a click
    /// on that control closes it, then the control's own toggle opens it again.
    private var lastClosed: (at: Date, anchor: ObjectIdentifier)?

    /// How many menus are open, in every window: a folded sidebar stays out
    /// while one it opened is.
    private(set) static var open = 0

    /// Where a menu of `size` opens on `edge` of `anchor` (both in screen
    /// coordinates), kept within `screen` and flipped to the other side when
    /// there is no room.
    static func frame(size: NSSize, anchor: NSRect, edge: Edge, within screen: NSRect) -> NSRect {
        let bounds = screen.insetBy(dx: margin, dy: margin)
        var origin: NSPoint
        switch edge {
        case .trailing, .leading:
            let right = anchor.maxX + gap
            let left = anchor.minX - gap - size.width
            let fitsRight = right + size.width <= bounds.maxX
            let fitsLeft = left >= bounds.minX
            let x = edge == .trailing ? (fitsRight || !fitsLeft ? right : left) : (fitsLeft || !fitsRight ? left : right)
            // Rises from the control's bottom, as a menu from a footer button would.
            origin = NSPoint(x: x, y: anchor.minY)
        case .bottom, .top:
            let below = anchor.minY - gap - size.height
            let above = anchor.maxY + gap
            let fitsBelow = below >= bounds.minY
            let fitsAbove = above + size.height <= bounds.maxY
            let y = edge == .bottom ? (fitsBelow || !fitsAbove ? below : above) : (fitsAbove || !fitsBelow ? above : below)
            origin = NSPoint(x: anchor.minX, y: y)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    /// Opens the popover, or gives the open one its new content.
    func pop(_ content: AnyView, from anchor: NSView, edge: Edge, stays: Bool) {
        guard !closing else { return }
        if let popoverHost, popover?.isShown == true {
            popoverHost.rootView = content
            return
        }
        if let last = lastClosed, last.anchor == ObjectIdentifier(anchor), Date().timeIntervalSince(last.at) < 0.3 {
            lastClosed = nil
            // After the update under way, which must not change its own state.
            DispatchQueue.main.async { [weak self] in self?.dismissed() }
            return
        }
        guard anchor.window != nil else { return }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = stays ? .applicationDefined : .transient
        popover.delegate = self
        self.anchor = anchor
        self.popover = popover
        popoverHost = host
        Self.open += 1
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: Self.side(edge, flipped: anchor.isFlipped))
    }

    /// `edge` as AppKit names it in the anchor's own coordinates.
    private static func side(_ edge: Edge, flipped: Bool) -> NSRectEdge {
        switch edge {
        case .top: flipped ? .minY : .maxY
        case .bottom: flipped ? .maxY : .minY
        case .leading: .minX
        case .trailing: .maxX
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let shown = popover, notification.object as? NSPopover === shown else { return }
        popover = nil
        popoverHost = nil
        Self.open -= 1
        if let anchor { lastClosed = (Date(), ObjectIdentifier(anchor)) }
        dismissed()
    }

    func show(_ content: AnyView, from anchor: NSView, edge: Edge, keyboard: Bool = true, plain: Bool = false) {
        // On frosted glass, as the frosted editors and the system's menus; or,
        // plain, as a tab's hover picture is (TabPreview.Card).
        let card =
            plain
            ? AnyView(content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous)))
            : AnyView(
                content
                    .background(Frost(radius: MenuPanel.cornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: MenuPanel.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MenuPanel.cornerRadius, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
            )
        guard !closing else { return }
        if let host, isShown {
            host.rootView = card
            return
        }
        // A panel that is no longer on screen is replaced, never left behind.
        close()
        guard let window = anchor.window else { return }
        self.anchor = anchor
        self.edge = edge

        let host = Host(rootView: card)
        // Content that settles its size after opening is placed again, so it
        // stays beside the control and on the screen.
        host.resized = { [weak self] in self?.place() }
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        // Hidden by AppKit as soon as Mote stops being the active app.
        panel.hidesOnDeactivate = true
        panel.appearance = window.effectiveAppearance
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.keyable = keyboard

        self.panel = panel
        self.host = host
        place()
        if keyboard { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }

        Self.open += 1
        watch(window)
    }

    /// Sizes the panel to its content, beside the control.
    private func place() {
        guard let panel, let host, let anchor, let window = anchor.window, let screen = window.screen ?? NSScreen.main else { return }
        let anchorOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = MenuPanel.frame(size: host.fittingSize, anchor: anchorOnScreen, edge: edge, within: screen.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Closes the menu without telling the caller, which already knows.
    func close() {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Let go of the panel before ordering it out: ordering out updates
        // SwiftUI, and whatever that does must not find this panel still here.
        let closed = panel
        panel = nil
        host = nil
        if closed != nil { Self.open -= 1 }
        closed?.orderOut(nil)
        // Let go of it first, so its closing isn't taken for the user's.
        if let shown = popover {
            popover = nil
            popoverHost = nil
            Self.open -= 1
            shown.close()
        }
    }

    /// Closes the menu because of something the user did outside it.
    private func dismiss() {
        guard isShown else { return }
        // The owner learns first, so any update that closing causes already
        // sees the menu as closed.
        dismissed()
        close()
    }

    private func watch(_ window: NSWindow) {
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mouseDowns,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            })
        {
            monitors.append(local)
        }
        // Clicks in other apps. While Mote isn't the active app, clicks on its
        // own windows are reported here too; the local monitor handles those.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mouseDowns,
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    let point = NSEvent.mouseLocation
                    guard !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
                    self?.dismiss()
                }
            })
        {
            monitors.append(global)
        }
        let center = NotificationCenter.default
        for (name, object) in [
            (NSApplication.didResignActiveNotification, nil as AnyObject?),
            (NSWindow.willCloseNotification, window),
            (NSWindow.didMoveNotification, window),
        ] {
            observers.append(
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
        }
    }

    /// A click outside the menu closes it, except on the control that opened
    /// it: that control toggles the menu itself.
    private func clicked(_ event: NSEvent) {
        guard let panel, event.window !== panel else { return }
        if let anchor, let window = anchor.window, event.window === window {
            let point = anchor.convert(event.locationInWindow, from: nil)
            if anchor.bounds.contains(point) { return }
        }
        dismiss()
    }

    private final class Host: NSHostingView<AnyView> {
        var resized: () -> Void = {}

        /// A panel that doesn't take the keyboard (a folder's list of tabs)
        /// isn't key when clicked: the first click still picks.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            // After the layout under way, which a new frame mustn't interrupt.
            DispatchQueue.main.async { [weak self] in self?.resized() }
        }
    }

    /// A borderless panel that can take key status, so the menu's own controls
    /// and Escape work.
    private final class Panel: NSPanel {
        var onEscape: () -> Void = {}
        /// False for a panel opened without the keyboard, which a click mustn't make key.
        var keyable = true

        override var canBecomeKey: Bool { keyable }

        override func cancelOperation(_ sender: Any?) { onEscape() }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
        }
    }
}
