import AppKit
import SwiftUI

/// AppKit owns the sidebar's frame and collapse animation; SwiftUI draws
/// the existing sidebar and rounded page card inside the two panes.
struct NativeSidebar: NSViewControllerRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    func makeNSViewController(context: Context) -> Controller { Controller(browser: browser, prefs: prefs) }
    func updateNSViewController(_ controller: Controller, context: Context) { controller.update() }

    /// It fills the window. Said outright, so SwiftUI doesn't ask AppKit for
    /// its fitting size on every change to the browser, which runs Auto
    /// Layout over the split view and both its hosting views: most of the
    /// time a sleeping tab's wake took.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    final class Controller: NSSplitViewController {
        private let browser: Browser
        private let prefs: Preferences
        private let sidebar: NSHostingController<Side>
        private let detail: NSHostingController<ChromeDetail>
        let sidebarItem: NSSplitViewItem
        private var collapsed: Bool
        /// A fold is sliding. ⌃⌥S pressed again meanwhile waits for it: when
        /// it ends, the sidebar slides once more to where the last press left
        /// it. Changing the split view mid-slide stalled the window for a second.
        private var sliding = false
        private var sidebarMode: Bool
        private var immersed: Bool
        /// The sidebar's pane is the split's last, on the right.
        private var right: Bool
        private let detailItem: NSSplitViewItem

        init(browser: Browser, prefs: Preferences) {
            self.browser = browser
            self.prefs = prefs
            sidebar = NSHostingController(rootView: Side(browser: browser, prefs: prefs))
            detail = NSHostingController(rootView: ChromeDetail(browser: browser, prefs: prefs))
            // A plain split item preserves Mote's shared background; the
            // sidebar factory adds a separate system material behind this pane.
            sidebarItem = NSSplitViewItem(viewController: sidebar)
            detailItem = NSSplitViewItem(viewController: detail)
            right = prefs.sideRight
            sidebarMode = prefs.sidebar
            immersed = browser.active?.immersed == true
            collapsed = !prefs.sidebar || browser.folded || immersed
            super.init(nibName: nil, bundle: nil)
            sidebar.sizingOptions = []
            sidebar.safeAreaRegions = []
            detail.sizingOptions = []
            detail.safeAreaRegions = []
            splitView = DividerlessSplitView()
            splitView.isVertical = true
            sidebarItem.canCollapse = true
            sidebarItem.canCollapseFromWindowResize = false
            sidebarItem.isSpringLoaded = false
            sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            sidebarItem.minimumThickness = prefs.sideWidth
            sidebarItem.maximumThickness = prefs.sideWidth
            sidebarItem.isCollapsed = collapsed
            for item in right ? [detailItem, sidebarItem] : [sidebarItem, detailItem] { addSplitViewItem(item) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear() {
            super.viewDidAppear()
            update()
        }

        func update() {
            // ResizeGrip remains the single owner of the saved sidebar width.
            let width = prefs.sideWidth
            if sidebarItem.minimumThickness != width {
                if width > sidebarItem.maximumThickness {
                    sidebarItem.maximumThickness = width
                    sidebarItem.minimumThickness = width
                } else {
                    sidebarItem.minimumThickness = width
                    sidebarItem.maximumThickness = width
                }
            }
            // The sidebar moved to the other side: its pane goes to that end.
            if prefs.sideRight != right {
                right = prefs.sideRight
                splitViewItems.forEach(removeSplitViewItem)
                for item in right ? [detailItem, sidebarItem] : [sidebarItem, detailItem] { addSplitViewItem(item) }
            }
            let fullscreenPage = browser.active?.immersed == true
            let target = !prefs.sidebar || browser.folded || fullscreenPage
            let animate = view.window != nil && sidebarMode == prefs.sidebar && immersed == fullscreenPage
            sidebarMode = prefs.sidebar
            immersed = fullscreenPage
            guard target != collapsed, !(animate && sliding) else { return }
            collapsed = target
            if animate {
                sliding = true
                NSAnimationContext.runAnimationGroup { context in
                    // Zen's quarter second, quick off the mark, as the floating sidebar's.
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                    sidebarItem.animator().isCollapsed = target
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.sliding = false
                        // Pressed again while it slid.
                        self?.update()
                    }
                }
            } else {
                sidebarItem.isCollapsed = target
            }
        }

        override func splitView(
            _ splitView: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt index: Int
        ) -> NSRect {
            _ = super.splitView(splitView, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: index)
            return .zero
        }
    }

    struct Side: View {
        @ObservedObject var browser: Browser
        @ObservedObject var prefs: Preferences

        var body: some View {
            Sidebar(browser: browser, prefs: prefs, showing: !browser.folded)
                // On the edge the page is beside: the right one, or the left on the right.
                .overlay(alignment: prefs.sideRight ? .leading : .trailing) {
                    ResizeGrip(prefs: prefs, edge: .leading, mirrored: prefs.sideRight) { browser.toggleFold() }
                        .frame(width: ResizeGrip.width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .ignoresSafeArea()
                .clipped()
        }
    }

    private final class DividerlessSplitView: NSSplitView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Take the native controls before the first visible frame, including
            // when collapsed panes have not built a TrafficLights host yet.
            if let window { TrafficLights.refresh(in: window) }
        }

        override var dividerThickness: CGFloat { 0 }
        override func drawDivider(in rect: NSRect) {}
    }
}
