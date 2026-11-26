import MoteCore
import SwiftUI

// The window's layout (see ChromeLayout): the tabs sit on the window's frame,
// in a sidebar or a strip, and the page on a rounded card inset from the
// window's edges, with the toolbar across its top.

extension Browser {
    var chromeColor: NSColor? {
        guard let active, !active.isBlank, active.failure == nil else { return nil }
        return active.pageColor
    }

    var chromeGround: Color { chromeColor.map { Color(nsColor: $0) } ?? (active?.isStart == true ? Palette.start : Palette.ground) }

    var chromeScheme: ColorScheme? {
        guard let rgb = chromeColor?.usingColorSpace(.sRGB) else { return nil }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance < 0.179 ? .dark : .light
    }

    /// Address and page chat belong to web pages, not the new-tab composer.
    var pageToolsShown: Bool { active?.isBlank == false }

    /// Whether the bookmarks bar is on the card: as Settings has it, on every
    /// page and new tab alike.
    var bookmarksShown: Bool {
        !bookmarks.isEmpty && active?.immersed != true && prefs.bookmarksBar
    }

    /// Whether the address field is being edited in the toolbar, over a page. A
    /// blank tab edits in its own composer, and ⌘K (or ⌘T as a floating
    /// search) opens the palette instead.
    var editingInBar: Bool {
        editing && !field.switching && !field.launching && !field.relocating && !editingInPill && active?.isStart == false
    }

    /// Whether the address is being edited in the sidebar's pill: the
    /// toolbar is hidden beside a sidebar that's on screen.
    var editingInPill: Bool {
        editing && navInSidebar && (!folded || peeking) && !field.switching && !field.launching && !field.relocating
            && active?.isStart == false
    }

    /// The toolbar sits on the card, above the page.
    var toolbarDocked: Bool { prefs.toolbarMode == .shown }
    /// Back, forward and the address at the top of the sidebar instead of a
    /// toolbar.
    var navInSidebar: Bool { prefs.toolbarMode == .hidden && prefs.sidebar }
    /// The pointer at the page's top edge brings the toolbar out.
    var toolbarOnHover: Bool { !toolbarDocked && !navInSidebar }
    /// With the sidebar on the right and no toolbar on the card, the traffic
    /// lights would sit over the page's corner, in the way of its own menu:
    /// they hide, and the pointer at the top edge brings them out, with the
    /// toolbar or, without one, on a band of their own.
    var lightsHide: Bool { prefs.sidebar && prefs.sideRight && !toolbarDocked }
    /// The toolbar floats over the page's top: brought out by the pointer, or
    /// for editing the address (⌘L).
    var toolbarFloating: Bool {
        !toolbarDocked && active?.immersed != true && ((toolbarRevealed && !navInSidebar) || editingInBar)
    }

    func layout(in window: CGSize, nativeSidebar: Bool = false) -> ChromeLayout {
        ChromeLayout(
            window: window, tabs: prefs.sidebar ? .sidebar : .strip, sideWidth: nativeSidebar ? 0 : prefs.sideWidth, folded: folded,
            immersed: active?.immersed == true, bookmarked: bookmarksShown, panels: active?.immersed == true ? [] : panelSlots,
            bookmarksHeight: ChromeLayout.bookmarks + (active?.isStart == true ? 12 : 0), toolbar: toolbarDocked,
            sideRight: prefs.sideRight)
    }
}

struct Chrome: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        NativeSidebar(browser: browser, prefs: prefs)
            .ignoresSafeArea()
            .background(Palette.frame.opacity(0.35))
            // The space's own colours, under the frame's tint (see SpaceGround).
            .background {
                SpaceGround(spaces: browser.spaces, here: browser.spaceID, swipe: browser.swipeOffset, page: browser.prefs.sideWidth)
                    .ignoresSafeArea()
            }
            .background { WindowMaterial().ignoresSafeArea() }
    }
}

/// The page and top tab strip, inside the native split's detail pane.
struct ChromeDetail: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        GeometryReader { geo in
            let layout = browser.layout(in: geo.size, nativeSidebar: true)
            ZStack(alignment: .topLeading) {
                // The chat about the page, the mirror of the sidebar: full window
                // height at its side's edge, outside the card, so the card gives
                // up the width it takes and keeps its rounded corners. Like the
                // sidebar it stays in the tree while a page shows, just slid off
                // the window, so the slide back costs no first frames; it moves on
                // the sidebar's own fold spring.
                if browser.active?.immersed != true, let tab = browser.active, !tab.isBlank || tab.chatOpen {
                    let docked = layout.frame(of: SidePanel.chat.id)
                    let left = prefs.chatSide == .left
                    let away = left ? -prefs.chatWidth - ChromeLayout.gap : geo.size.width + ChromeLayout.gap
                    PageChatPanel(
                        browser: browser, tab: tab, toolbarTop: layout.card.minY,
                        place: layout.place(of: SidePanel.chat.id, side: prefs.chatSide)
                    )
                    .frame(width: prefs.chatWidth, height: geo.size.height)
                    .offset(x: docked?.minX ?? away)
                    .allowsHitTesting(docked != nil)
                    .accessibilityHidden(docked == nil)
                    .transition(.move(edge: left ? .leading : .trailing))
                }

                // The other side panels, beside the card or the chat.
                ForEach(browser.shownPanels.filter { $0.kind != .chat }) { panel in
                    if let frame = layout.frame(of: panel.id) {
                        PanelHost(
                            browser: browser, panel: panel, toolbarTop: layout.card.minY,
                            place: layout.place(of: panel.id, side: browser.side(of: panel))
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                        .transition(.move(edge: browser.side(of: panel) == .left ? .leading : .trailing))
                    }
                }

                // With the sidebar on the right, the traffic lights stay at the
                // window's top left, over the page's side: on the toolbar, or
                // with none, on a strip across the top the pointer brings out
                // (lightsHide).
                if prefs.sidebar, prefs.sideRight, browser.active?.immersed != true {
                    if !browser.lightsHide || browser.toolbarFloating {
                        TrafficLights(showing: true).frame(width: Metrics.lights, height: ChromeLayout.band(for: .sidebar)).zIndex(2)
                    } else if browser.toolbarRevealed {
                        LightsStrip(browser: browser).frame(width: geo.size.width).zIndex(2)
                    }
                }
                // The peeking tabs float over it from another hosting view, so
                // hovers would reach through them.
                PageCard(browser: browser, prefs: prefs, layout: layout)
                    .frame(width: layout.card.width, height: layout.card.height)
                    .offset(x: layout.card.minX, y: layout.card.minY)
                    .allowsHitTesting(!browser.peeking)

                // Over the card, so the active tab covers the card's top edge and the
                // two read as one surface.
                if layout.strip != nil {
                    TabBar(browser: browser, sharedGround: true)
                        .frame(width: geo.size.width, height: ChromeLayout.strip)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // The same handle on each panel's inner edge: dragging the gap
                // between card and panel is what resizes the panel.
                ForEach(layout.panels, id: \.id) { placed in
                    let left = placed.side == .left
                    let chat = placed.id == SidePanel.chat.id
                    ResizeGrip(prefs: prefs, edge: chat ? .trailing : .panel(placed.id), mirrored: chat == left) {
                        browser.closePanel(id: placed.id)
                    }
                    .frame(width: ResizeGrip.width, height: placed.frame.height)
                    .offset(
                        x: (left ? placed.frame.maxX : placed.frame.minX) - (left ? ResizeGrip.width - ResizeGrip.over : ResizeGrip.over))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .backgroundPreferenceValue(TabGroundBounds.self) { anchor in
                if layout.strip != nil {
                    GeometryReader { proxy in
                        let card = RoundedRectangle(cornerRadius: layout.corner, style: .continuous)
                        let split = (browser.shownSplit?.count ?? 0) > 1
                        let surface = TabCardShape(
                            card: layout.card, corner: layout.corner,
                            tab: anchor.anchors["tab"].map { proxy[$0].insetBy(dx: -TabShape.foot, dy: 0) },
                            viewport: anchor.dragging ? nil : anchor.anchors["viewport"].map { proxy[$0] },
                            attachment: anchor.attachment, hole: split ? layout.page : nil)
                        surface.fill(browser.chromeGround.opacity(browser.active?.isStart == true ? 0.92 : 1))
                            .compositingGroup()
                            .shadow(color: .black.opacity(split ? 0 : 0.06), radius: 1.5, y: 0.5)
                            .shadow(color: .black.opacity(split ? 0 : 0.05), radius: 12, y: 4)
                            .overlay(alignment: .topLeading) {
                                card.strokeBorder(split ? .clear : Palette.edge, lineWidth: 1)
                                    .frame(width: layout.card.width, height: layout.card.height)
                                    .offset(x: layout.card.minX, y: layout.card.minY)
                                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                                    .mask(surface.borderMask.fill())
                            }
                            .animation(Motion.settle, value: anchor.attachment)
                            .allowsHitTesting(false)
                    }
                }
            }
            // One native material under the shared tab/card surface.
            .background(layout.corner == 0 ? Color.black : Color.clear)
        }
        .ignoresSafeArea()
        .animation(Motion.glide, value: prefs.sidebar)
        .animation(Motion.fold, value: browser.chatting)
        .animation(Motion.fold, value: browser.sidePanels)
        .animation(.easeOut(duration: 0.12), value: browser.active?.immersed)
        .animation(Motion.quick, value: browser.toolbarRevealed)
    }
}

// MARK: - Card

/// The card's ground: its rounded shape, less the page's place in its
/// bottom-trailing corner when that's left open (filled even-odd).
private nonisolated struct CardGround: Shape {
    let corner: CGFloat
    let hole: CGSize?

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
        if let hole { path.addRect(CGRect(x: rect.maxX - hole.width, y: rect.maxY - hole.height, width: hole.width, height: hole.height)) }
        return path
    }
}

/// One surface throughout the morph from floating tab to attached tab.
private nonisolated struct TabCardShape: Shape {
    let card: CGRect
    let corner: CGFloat
    let tab: CGRect?
    let viewport: CGRect?
    var attachment: CGFloat
    var masksBorder = false
    /// The page's place, left open in a split.
    var hole: CGRect? = nil

    var animatableData: CGFloat {
        get { attachment }
        set { attachment = newValue }
    }

    var borderMask: Self {
        var mask = self
        mask.masksBorder = true
        return mask
    }

    func path(in rect: CGRect) -> Path {
        var outline = tab.map { TabShape(attachment: attachment).path(in: $0) } ?? Path()
        if let viewport, !outline.isEmpty { outline = outline.intersection(Path(viewport)) }
        if masksBorder { return Path(Path(rect).subtracting(outline).cgPath) }
        let surface = Path(RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: card).union(outline).cgPath)
        return hole.map { surface.subtracting(Path($0)) } ?? surface
    }
}

/// One system-managed blur behind the chrome; pages keep their opaque card.
private struct WindowMaterial: FillsRoom {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The space's colours on the window's ground, for chrome out over the page:
/// what the sidebar shows, but opaque.
struct SpaceBand: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Palette.ground
            Palette.frame.opacity(0.35)
            SpaceGround(spaces: browser.spaces, here: browser.spaceID, swipe: browser.swipeOffset, page: browser.prefs.sideWidth)
        }
    }
}

/// The window's top edge when the traffic lights hide beside a sidebar on
/// the right and there's no toolbar (Browser.lightsHide): a thin strip across
/// it on the space's colours, the lights at its start. The sidebar's pane
/// draws its own part, without them.
struct LightsStrip: View {
    @ObservedObject var browser: Browser
    var lights = true
    static let height: CGFloat = 32

    var body: some View {
        SpaceBand(browser: browser)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.edge).frame(height: 1) }
            .overlay(alignment: .topLeading) {
                // The lights' own place less 11 points each way: centred in the strip.
                if lights { TrafficLights(showing: true, inset: 11).frame(width: Metrics.lights, height: Self.height) }
            }
            .frame(height: Self.height)
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            .transition(.opacity)
    }
}

/// The rounded card: the toolbar, the bookmarks bar, and the page.
private struct PageCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let layout: ChromeLayout
    @Environment(\.colorScheme) private var colorScheme

    /// In a split, the page's place is left open: the gaps between the panes
    /// show the window's own colours beneath, as beside the sidebar.
    private var hole: CGSize? { (browser.shownSplit?.count ?? 0) > 1 ? layout.page.size : nil }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: layout.corner, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            if layout.toolbar > 0 {
                Toolbar(browser: browser, prefs: prefs)
                    .environment(\.colorScheme, browser.chromeScheme ?? colorScheme)
                    .frame(height: layout.toolbar)
                    .zIndex(1)
            }
            if layout.bookmarks > 0 {
                BookmarksBar(browser: browser, bookmarks: browser.bookmarks, ruled: browser.active?.isStart == false)
                    .environment(\.colorScheme, browser.chromeScheme ?? colorScheme)
                    .frame(height: layout.bookmarks)
                    .transition(.opacity)
            }
            // The page takes its new size at once, without animating, and keeps to the
            // card's far corner while the card's near edge slides over it or away; a
            // picture of how it was dissolves on top (see `Browser.dissolvingPage`).
            // Only the size: what moves inside (a chat tab's) keeps its own motion.
            stage
                .frame(width: layout.page.width, height: layout.page.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transaction(value: layout.page) { $0.animation = nil }
                .overlay(alignment: .bottomTrailing) {
                    if let veil = browser.pageVeil {
                        Image(nsImage: veil)
                            .frame(width: veil.size.width, height: veil.size.height)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .clipped()
        }
        // Not on the card: over the page's top when called for, clipped to the card.
        .overlay(alignment: .top) {
            if layout.toolbar == 0, browser.toolbarFloating {
                Toolbar(browser: browser, prefs: prefs, floating: true)
                    .frame(height: ChromeLayout.toolbar)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: browser.toolbarFloating)
        .background {
            if layout.strip != nil {
                Color.clear
            } else if layout.corner > 0 {
                // In a split the panes are the cards: no shadow or outline of its own.
                CardGround(corner: layout.corner, hole: hole)
                    .fill(browser.chromeGround.opacity(browser.active?.isStart == true ? 0.92 : 1), style: FillStyle(eoFill: true))
                    .shadow(color: .black.opacity(hole == nil ? 0.06 : 0), radius: 1.5, y: 0.5)
                    .shadow(color: .black.opacity(hole == nil ? 0.05 : 0), radius: 12, y: 4)
            } else {
                CardGround(corner: 0, hole: hole).fill(browser.chromeGround, style: FillStyle(eoFill: true))
            }
        }
        .clipShape(shape)
        .background {
            // Outside the clip, so the shadow can fall onto the sidebar.
            if layout.sidebar != nil, layout.corner > 0, hole == nil {
                shape.fill(browser.chromeGround)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 7, x: -1, y: 2)
            }
        }
        .overlay {
            if layout.corner > 0, layout.strip == nil, hole == nil {
                shape.strokeBorder(Palette.edge, lineWidth: 1).allowsHitTesting(false)
            }
        }
        // Over the page, under the address field; outside the clip so a long list isn't cut.
        .overlayPreferenceValue(AddressBar.Bounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor, browser.editingInBar, !browser.field.offers.isEmpty {
                    BarSuggestions(browser: browser, bar: proxy[anchor])
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
                }
            }
        }
        .animation(Motion.quick, value: browser.editingInBar && !browser.field.offers.isEmpty)
        .animation(Motion.settle, value: browser.reviewing)
    }

    @ViewBuilder
    private var stage: some View {
        if let tab = browser.active {
            ZStack(alignment: .topLeading) {
                SplitStage(browser: browser, layout: browser.shownSplit ?? SplitLayout(tab.id)) { pane in
                    if pane.id == tab.id { content(tab) } else { Page(tab: pane) }
                }
                PeekLayer(browser: browser)
                if browser.reviewing {
                    // Not dimmed, so the page stays visible while reviewing hidden elements.
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { browser.reviewing = false }
                        HiddenElementsPanel(browser: browser, hider: browser.elementHider)
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                            .transition(.scale(scale: 0.97, anchor: .topTrailing).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
        } else {
            Palette.ground
        }
    }

    /// The active tab's own page, chat or new tab page, with what shows over it.
    @ViewBuilder
    private func content(_ tab: Tab) -> some View {
        if let chat = tab.chat, tab.isBlank {
            // One per chat, so a draft and scrolling never carry over to another.
            ChatView(browser: browser, conversation: chat).id(chat.id)
        } else if tab.chats, tab.isBlank {
            ChatsPage(browser: browser)
        } else if tab.isBlank {
            NewTabPage(browser: browser, prefs: prefs)
        } else {
            Page(tab: tab, warm: browser.warmPages)
                .overlay {
                    LinkBubble(status: browser.linkStatus, tab: tab, loadingFrom: tab.loadingFrom, showsLinks: prefs.showsLinks)
                }
                .overlay(alignment: .top) { if prefs.loadingPill { LoadingPill(tab: tab) } }
                .overlay(alignment: .topTrailing) {
                    if browser.finder.showing {
                        FindBar(finder: browser.finder)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let asked = browser.logins.choices, asked.tab == tab.id {
                        AccountList(logins: browser.logins, choices: asked)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) { ContactOfferLayer(browser: browser, tab: tab) }
                .animation(Motion.quick, value: browser.logins.choices)
        }
    }
}

// MARK: - Resize Grip

/// The invisible handle between the sidebar and the card, and the same handle
/// mirrored between the card and the trailing chat panel. Dragging it sets the
/// panel's width, a double-click puts the default back, and letting go well
/// short of the narrowest width folds the sidebar (or closes the chat panel)
/// away, as in Arc.
///
/// AppKit rather than a SwiftUI gesture: the cursor has to win over the web
/// view's cursor rects beside it, and the drag must keep tracking once the
/// pointer leaves the handle.
struct ResizeGrip: FillsRoom {
    /// Which dock the handle belongs to: the sidebar, the chat, or another
    /// side panel by its id (Browser+Panels).
    enum Edge: Equatable {
        case leading, trailing, panel(String)
    }

    /// Width of the handle, and how far of it lies over the card.
    static let width: CGFloat = 10
    static let over: CGFloat = 3
    /// How far past the narrowest width a release folds the sidebar.
    static let foldBeyond: CGFloat = 64

    let prefs: Preferences
    var edge: Edge = .leading
    /// The sidebar on the right: its handle, on its left, grows it leftward.
    var mirrored = false
    let fold: () -> Void

    func makeNSView(context: Context) -> Grip { Grip() }

    func updateNSView(_ grip: Grip, context: Context) {
        grip.prefs = prefs
        grip.edge = edge
        grip.mirrored = mirrored
        grip.fold = fold
    }

    final class Grip: NSView {
        var prefs: Preferences?
        var edge: ResizeGrip.Edge = .leading
        var mirrored = false
        var fold: () -> Void = {}
        private var start: (x: CGFloat, width: CGFloat)?
        private var wanted: CGFloat = 0

        /// The narrowest and widest this dock may be dragged.
        private var least: CGFloat { edge == .leading ? Metrics.sideMin : Metrics.chatMin }
        private var most: CGFloat { edge == .leading ? Metrics.sideMax : Metrics.chatMax }
        /// The width on its double-click default.
        private var usual: CGFloat { edge == .leading ? Metrics.side : Metrics.chat }
        private func width(_ prefs: Preferences) -> CGFloat {
            switch edge {
            case .leading: prefs.sideWidth
            case .trailing: prefs.chatWidth
            case .panel(let id): prefs.panelWidths[id] ?? Metrics.chat
            }
        }
        private func setWidth(_ value: CGFloat, of prefs: Preferences) {
            switch edge {
            case .leading: prefs.sideWidth = value
            case .trailing: prefs.chatWidth = value
            case .panel(let id): prefs.panelWidths[id] = value
            }
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDown(with event: NSEvent) {
            guard let prefs else { return }
            if event.clickCount == 2 {
                start = nil
                withAnimation(Motion.settle) { setWidth(usual, of: prefs) }
                return
            }
            start = (event.locationInWindow.x, width(prefs))
            wanted = width(prefs)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let prefs, let start else { return }
            NSCursor.resizeLeftRight.set()
            // The sidebar's and a panel's handle grow as the pointer moves
            // right, the chat's as it moves left; mirrored, the other way.
            let travel = event.locationInWindow.x - start.x
            wanted = (edge != .trailing) != mirrored ? start.width + travel : start.width - travel
            let held = min(most, max(least, wanted))
            guard held != width(prefs) else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { setWidth(held, of: prefs) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil }
            guard start != nil, wanted < least - ResizeGrip.foldBeyond else { return }
            fold()
        }
    }
}

/// The contact offer under a focused field of `tab`, when there is one.
private struct ContactOfferLayer: View {
    let browser: Browser
    let tab: Tab
    @ObservedObject private var fill = ContactFill.shared

    var body: some View {
        if let offer = fill.offer, offer.tab == tab.id {
            ContactOfferView(fill: fill, offer: offer) { fill.fill($0, in: tab, browser: browser) } manage: {
                fill.drop()
                fill.managing = true
                browser.openSettings(at: .privacy)
            }
            .transition(.opacity)
        }
    }
}
