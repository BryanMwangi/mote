import MoteCore
import SwiftUI
import WebKit

/// Folded tabs (⌘S): they slide out over the page when the pointer reaches
/// the window's left edge (or top, for the strip) and go again soon after it
/// leaves, the traffic lights with them. The sidebar comes out as a panel of
/// its own floating over the card. When is EdgeReveal's decision.
struct SidebarFold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var timers = PeekTimers()
    @State private var pointer = PointerWatch()
    /// The pointer is over the peeking tabs.
    @State private var inside = false

    /// Folded, with the page not full screen.
    private var folding: Bool { browser.folded && browser.active?.immersed != true }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // With the sidebar the page reaches the window's top, so a thin band
            // there drags the window and double-click zooms it.
            if prefs.sidebar, browser.active?.immersed != true {
                DragStrip().frame(height: ChromeLayout.gap).frame(maxWidth: .infinity)
            }
            if folding, !prefs.sidebar, browser.peeking {
                // The strip has no ground of its own: give it the frame's, so the page
                // doesn't show through and its shadow falls from the strip's edge.
                TabBar(browser: browser)
                    .background { Palette.frame.shadow(color: .black.opacity(0.16), radius: 20, y: 6) }
                    .transition(.move(edge: .top))
            }
            // Kept built while folded, out past the window's edge: a peek only
            // slides it in, rather than building every row each time.
            if folding, prefs.sidebar {
                SlidingPanel(out: browser.peeking, width: prefs.sideWidth + ChromeLayout.gap * 2, right: prefs.sideRight) {
                    floatingSidebar.padding(ChromeLayout.gap)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: prefs.sideRight ? .topTrailing : .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            watch()
        }
        .onDisappear {
            pointer.stop()
            timers.cancelShow()
            timers.cancelHide()
        }
        .background(
            WindowSetup { window in
                pointer.window = window
                watch()
            }
        )
        .onChange(of: folding) {
            timers.cancelShow()
            timers.cancelHide()
            inside = false
            if !folding { browser.peeking = false }
            watch()
        }
        // Each layout owns its persisted fold; a temporary peek never carries over.
        .onChange(of: prefs.sidebar) {
            browser.peeking = false
        }
        .onChange(of: prefs.sideHides) {
            guard prefs.sidebar else { return }
            browser.peeking = false
        }
        // Hiding waits while a tab is being renamed; once that ends, hide if the pointer left.
        .onChange(of: browser.editingTab) { _, editing in
            if editing == nil, !inside, browser.peeking { hide() }
        }
    }

    /// The sidebar as a floating panel: the frame's colour, rounded, outlined,
    /// and lifted off the card by a deep, soft shadow.
    private var floatingSidebar: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeLayout.corner, style: .continuous)
        // The traffic lights only while it's out: on its way away it mustn't
        // take them from the docked sidebar.
        return Sidebar(browser: browser, prefs: prefs, showing: folding && browser.peeking)
            .frame(maxHeight: .infinity)
            // The space's colours, as behind the docked one; the window keeps its look.
            .background {
                Palette.frame.overlay {
                    SpaceGround(theme: browser.spaces.first { $0.id == browser.spaceID }?.theme, space: browser.spaceID, window: nil)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.12)))
            // Straddling the edge; the width it sets is the docked sidebar's too.
            .overlay(alignment: prefs.sideRight ? .leading : .trailing) {
                ResizeGrip(prefs: prefs, mirrored: prefs.sideRight) {}
                    .frame(width: ResizeGrip.width)
                    .offset(x: (prefs.sideRight ? -1 : 1) * ResizeGrip.width / 2)
            }
            .background {
                shape.fill(Palette.frame)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.18), radius: 28, x: 6, y: 10)
            }
    }

    /// The pointer is watched only while folded.
    private func watch() {
        folding ? pointer.start { follow() } : pointer.stop()
    }

    /// Works out peeking from where the pointer is, on every move. Hover
    /// tracking can't be trusted here: a view appearing under a still pointer
    /// never hears it enter, so never hears it leave.
    private func follow() {
        guard folding, let window = pointer.window, window.isVisible else { return timers.cancelShow() }
        // A drag begun on the peeking tabs, such as resizing them, keeps them out.
        if browser.peeking, NSEvent.pressedMouseButtons & 1 != 0 {
            timers.cancelShow()
            return show()
        }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        // From the sidebar's edge, left or right, or from the top for the strip.
        let distance = prefs.sidebar ? (prefs.sideRight ? size.width - point.x : point.x) : size.height - point.y
        // Other apps' windows on top don't count; Mote's own (a menu from the
        // sidebar) do. The hit test is costly, so it runs only while out or at the edge.
        let near = browser.peeking || (inWindow && distance < EdgeReveal.edge)
        let top = near ? NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) : 0
        let onWindow = top == window.windowNumber
        let along = prefs.sidebar ? point.y : point.x
        let span = prefs.sidebar ? size.height : size.width
        let pointer = EdgeReveal.Pointer(
            inWindow: inWindow, onWindow: onWindow, onOwnPanel: near && !onWindow && NSApp.windows.contains { $0.windowNumber == top },
            distance: distance, beside: along > -EdgeReveal.slop && along < span + EdgeReveal.slop)
        // The floating sidebar sits in by the card's gap, its resize grip just
        // past its edge; the strip has neither.
        let reach = prefs.sidebar ? prefs.sideWidth + ChromeLayout.gap + ResizeGrip.width : ChromeLayout.strip
        // The strip always waits, as its edge is crossed on the way to the menu
        // bar; so does a sidebar that hides by itself.
        let waits = !prefs.sidebar || (prefs.sideHides && prefs.revealDelay > 0)
        switch EdgeReveal.step(pointer, peeking: browser.peeking, reach: reach, waits: waits) {
        case .show:
            timers.cancelShow()
            if browser.peeking { inside = true }
            show()
        case .showSoon:
            timers.showAfter(Double(prefs.revealDelay)) { show() }
        case .hideSoon:
            timers.cancelShow()
            inside = false
            hide()
        case .pass:
            timers.cancelShow()
        }
    }

    private func show() {
        timers.cancelHide()
        if folding, !browser.peeking { browser.peek(true) }
    }

    /// After a grace period counted from when the pointer left, not from its
    /// latest move; not while a tab is being renamed, nor while something
    /// opened from it (a popover, an extension's popup, the site card) is
    /// open, when it looks again a moment later.
    private func hide() {
        timers.hideAfter(EdgeReveal.grace) {
            guard folding, browser.editingTab == nil else { return }
            if MenuPanel.open > 0 || pointer.window?.childWindows?.contains(where: \.isVisible) == true { return hide() }
            browser.peek(false)
        }
    }
}

/// The floating sidebar, slid in and out by Core Animation, as Zen slides its
/// compact sidebar with a transform. SwiftUI animating an offset would lay
/// out the whole window on every frame of the slide.
private struct SlidingPanel: FillsRoom {
    let out: Bool
    /// The panel's own; past it there's room for its shadow.
    let width: CGFloat
    /// From the window's right edge, for a sidebar on the right.
    let right: Bool
    let content: AnyView

    init(out: Bool, width: CGFloat, right: Bool = false, @ViewBuilder content: () -> some View) {
        self.out = out
        self.width = width
        self.right = right
        self.content = AnyView(content())
    }

    func makeNSView(context: Context) -> Holder { Holder(NSHostingView(rootView: content), out: out, width: width) }

    func updateNSView(_ holder: Holder, context: Context) {
        holder.panel.rootView = content
        holder.right = right
        holder.slide(out: out, width: width)
    }

    final class Holder: NSView {
        let panel: NSHostingView<AnyView>
        private var out: Bool
        private var width: CGFloat
        var right = false
        /// Room for the shadow and the resize grip beside the panel.
        private static var margin: CGFloat { 60 }

        init(_ panel: NSHostingView<AnyView>, out: Bool, width: CGFloat) {
            self.panel = panel
            self.out = out
            self.width = width
            super.init(frame: .zero)
            wantsLayer = true
            panel.sizingOptions = []
            panel.safeAreaRegions = []
            panel.isHidden = !out
            addSubview(panel)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        /// Only the panel takes clicks, and only while out; past its edge,
        /// in the room for its shadow, they go through to the page.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let x = convert(point, from: superview).x
            let inPanel = right ? x > bounds.width - width - ResizeGrip.width / 2 : x < width + ResizeGrip.width / 2
            guard out, inPanel else { return nil }
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        override func layout() {
            super.layout()
            panel.frame = place(out)
        }

        private func place(_ out: Bool) -> NSRect {
            let span = width + Self.margin
            if right { return NSRect(x: out ? bounds.width - span : bounds.width, y: 0, width: span, height: bounds.height) }
            return NSRect(x: out ? 0 : -span, y: 0, width: span, height: bounds.height)
        }

        func slide(out now: Bool, width: CGFloat) {
            self.width = width
            guard now != out else { return panel.frame = place(out) }
            out = now
            if now { panel.isHidden = false }
            guard window != nil else {
                panel.frame = place(now)
                panel.isHidden = !now
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.foldResponse
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().frame = place(now)
            } completionHandler: { [weak self] in
                // Gone: nothing of it is drawn or tracked until it comes back.
                if let self, !self.out { self.panel.isHidden = true }
            }
        }
    }
}

/// The pending show and hide of the folded tabs, or of the toolbar.
@MainActor
final class PeekTimers {
    private var showing: Task<Void, Never>?
    private var hiding: Task<Void, Never>?

    /// Unless one is already waiting.
    func showAfter(_ delay: TimeInterval, _ show: @escaping @MainActor () -> Void) {
        guard showing == nil else { return }
        showing = later(delay) { [weak self] in
            self?.showing = nil
            show()
        }
    }

    /// Unless one is already waiting: the grace runs from when the pointer left.
    func hideAfter(_ delay: TimeInterval, _ hide: @escaping @MainActor () -> Void) {
        guard hiding == nil else { return }
        hiding = later(delay) { [weak self] in
            self?.hiding = nil
            hide()
        }
    }

    func cancelShow() {
        showing?.cancel()
        showing = nil
    }

    func cancelHide() {
        hiding?.cancel()
        hiding = nil
    }

    private func later(_ delay: TimeInterval, _ act: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { act() }
        }
    }
}

/// Pointer moves while folded, from other apps too, so the edge works when
/// another app is in front.
@MainActor
final class PointerWatch {
    weak var window: NSWindow?
    private var monitors: [Any] = []
    /// Watches running, by window: the sidebar's and the toolbar's.
    private static var watching: [ObjectIdentifier: Int] = [:]
    /// Each window's own `acceptsMouseMovedEvents`, put back when the last
    /// watch on it stops.
    private static var accepted: [ObjectIdentifier: Bool] = [:]

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard monitors.isEmpty, let window else { return }
        // Moves over the whole window, while watching.
        let key = ObjectIdentifier(window)
        if Self.watching[key, default: 0] == 0 { Self.accepted[key] = window.acceptsMouseMovedEvents }
        Self.watching[key, default: 0] += 1
        window.acceptsMouseMovedEvents = true
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: kinds) { event in
                MainActor.assumeIsolated { moved() }
                return event
            } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: kinds) { _ in MainActor.assumeIsolated { moved() } } as Any,
        ]
    }

    func stop() {
        guard !monitors.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let window else { return }
        let key = ObjectIdentifier(window)
        Self.watching[key, default: 1] -= 1
        if Self.watching[key] == 0, let accepted = Self.accepted.removeValue(forKey: key) {
            window.acceptsMouseMovedEvents = accepted
        }
    }
}
