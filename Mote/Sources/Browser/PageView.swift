import MoteCore
import WebKit

/// Progress of a swipe, for the indicator at the page's edge.
typealias Pull = SwipeTracker.Pull

/// The web view in a tab. On top of WKWebView it adds Mote's own swipe
/// navigation, mouse back and forward buttons, smart zoom, a fade-in instead
/// of a white first frame, and its own items in the context menu.
final class PageView: WKWebView {
    /// The engine's name for "Search with …", and what to do with the words.
    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    /// "Ask about This": what to do with the selected text, as a chat about
    /// the page the selection sits on.
    var onAsk: ((String) -> Void)?
    /// A swipe's progress, or nil when there is none to show.
    var onPull: ((Pull?) -> Void)?
    /// Any click or scroll, so a wake snapshot never gets in the way.
    var onTouch: (() -> Void)?

    /// WebKit does the sampling in its renderer, including fixed/sticky headers.
    /// These optional SPI are guarded so older engines keep the page background.
    // ponytail: native heuristics can reject complex imagery; add custom sampling only if needed.
    var onPageColor: ((NSColor) -> Void)?
    private var colorKeys: [String] = []

    func watchColors() {
        guard colorKeys.isEmpty else { return }
        // A separate toolbar has no obscured inset. Request a top edge sample
        // without changing the page's viewport or its scroll position.
        let overflow = NSSelectorFromString("_setOverflowHeightForTopScrollEdgeEffect:")
        if responds(to: overflow) {
            typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            unsafeBitCast(method(for: overflow), to: Setter.self)(self, overflow, 1)
        }
        // A header in the normal flow is never sampled, so a declared
        // theme-color comes before the body's background.
        colorKeys = ["_sampledTopFixedPositionContentColor", "themeColor", "underPageBackgroundColor"]
            .filter { responds(to: NSSelectorFromString($0)) }
        for key in colorKeys { addObserver(self, forKeyPath: key, options: [], context: nil) }
        reportColor()
    }

    func stopColors() {
        for key in colorKeys { removeObserver(self, forKeyPath: key) }
        colorKeys = []
        onPageColor = nil
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        let own = object as? PageView === self
        let handled = MainActor.assumeIsolated {
            if let keyPath, own, colorKeys.contains(keyPath) {
                reportColor()
                return true
            }
            return false
        }
        if !handled { super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context) }
    }

    private func reportColor() {
        let color = colorKeys.lazy.compactMap { self.value(forKey: $0) as? NSColor }
            .first { $0.alphaComponent == 1 }
        if let color { onPageColor?(color) }
    }

    deinit {
        for key in colorKeys { removeObserver(self, forKeyPath: key) }
    }

    // MARK: - Context menu

    private var selection: String?
    private var webSearch: (target: AnyObject?, action: Selector?)

    /// Reads the selected text: a focused field's selection first, then the
    /// page and its same-origin frames. Cross-origin frames and password
    /// fields read as empty, and WebKit's own search runs instead.
    /// See Scripts/src/selected-text.ts.
    static let selected = InjectedScript.call("selected-text")

    /// The browser's Touch Bar on pages, as Safari shows it, except while
    /// the page has a video to control or is full screen: then WebKit's own
    /// playback bar (play, time, scrubber, full screen), which is Safari's.
    override func makeTouchBar() -> NSTouchBar? {
        let immersed = Browser.front?.tab(for: self)?.immersed == true
        let playback = wantsPlaybackBar(immersed: immersed)
        barIsPlayback = playback
        barImmersed = immersed
        guard let browser = Browser.front else { return super.makeTouchBar() }
        guard playback else { return browser.touchBarItems.make() }
        // WebKit's controls inside Mote's bar, beside reload and full screen.
        guard let controls = super.makeTouchBar() else { return browser.touchBarItems.make() }
        return browser.touchBarItems.makePlayback(around: controls)
    }

    /// Which kind of bar was last made: nil before the first.
    private var barIsPlayback: Bool?
    /// Full screen when it was made, for the full-screen button's look.
    private var barImmersed = false

    private func wantsPlaybackBar(immersed: Bool) -> Bool { immersed || hasVideoControls }

    /// Asks for the bar again only when it should change kind (or, for the
    /// playback bar, full screen came or went), so making it can never lead
    /// to asking again.
    func refreshTouchBar(immersed: Bool) {
        guard let made = barIsPlayback else { return }
        let changed = made != wantsPlaybackBar(immersed: immersed) || (made && immersed != barImmersed)
        if changed { touchBar = nil }
    }

    /// The Touch Bar's full-screen button: the playing video (or the largest)
    /// in full screen, or out of it. Run from the app, which WebKit counts
    /// as the person asking, as full screen needs.
    func toggleVideoFullScreen() {
        evaluateInAppWorld(
            """
            (() => {
              const doc = document;
              if (doc.fullscreenElement || doc.webkitFullscreenElement) {
                (doc.exitFullscreen || doc.webkitExitFullscreen).call(doc);
                return;
              }
              const videos = [...doc.querySelectorAll('video')];
              const video = videos.find((v) => !v.paused)
                ?? videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
              if (!video) return;
              if (video.requestFullscreen) video.requestFullscreen(); else video.webkitEnterFullscreen?.();
            })();
            """)
    }

    /// WebKit's own test for showing playback controls, through its private
    /// `_hasActiveVideoForControlsManager`; without it, Mote's bar stays.
    private var hasVideoControls: Bool {
        let check = NSSelectorFromString("_hasActiveVideoForControlsManager")
        guard responds(to: check) else { return false }
        typealias Read = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: check), to: Read.self)(self, check)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Where it was opened, for what hangs from the link (Share).
        menuSpot = NSRect(origin: convert(event.locationInWindow, from: nil), size: .zero).insetBy(dx: -2, dy: -2)
        // No Services: macOS's list does nothing useful for what's under the pointer.
        menu.allowsContextMenuPlugIns = false
        for item in menu.items where item.submenu != nil && item.submenu === NSApp.servicesMenu { menu.removeItem(item) }
        if let search = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }) {
            // Read the selection once, for both items: the search, and the
            // chat about the page the selection sits on. WebKit offers its own
            // search only when text is selected, so the two live together.
            selection = nil
            callAsyncJavaScript(Self.selected, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            if let name = searchName?() {
                webSearch = (search.target, search.action)
                search.title = "Search with \(name)"
                search.target = self
                search.action = #selector(searchSelection(_:))
            }
            if let index = menu.items.firstIndex(of: search) {
                menu.insertItem(ask(), at: index + 1)
            }
        }
        linkItems(in: menu)
        pageItems(in: menu)
        // Extensions' items go last.
        guard #available(macOS 15.4, *), let tab = Extensions.shared.browser?.tab(for: self) else { return }
        let items = Extensions.shared.menuItems(for: tab)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    /// On the page itself (after WebKit's Reload), as Zen's page menu: keep
    /// it, save it, select it all, take a picture of it, ask about it.
    private func pageItems(in menu: NSMenu) {
        guard let reload = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }),
            let at = menu.items.firstIndex(of: reload), let browser = Windows.shared.all.first(where: { $0.tab(for: self) != nil }),
            let tab = browser.tab(for: self)
        else { return }
        let items: [NSMenuItem] = [
            .separator(),
            ActionItem("Bookmark Page…") { browser.bookmarkCurrent() },
            ActionItem("Save Page As…") { browser.savePage() },
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""),
            .separator(),
            ActionItem("Take Screenshot") { tab.screenshot() },
            ActionItem("Ask about This Page") { if !browser.chatting { browser.togglePageChat() } },
            .separator(),
            ActionItem("View Page Source") { browser.viewSource(of: tab) },
        ]
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: at + 1 + offset) }
        // WebKit's inspector shows an element's accessibility in its Node panel:
        // Inspect Element opens it there; there's no way to open that panel itself.
        if let inspect = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }),
            let action = inspect.action, let spot = menu.items.firstIndex(of: inspect)
        {
            let target = inspect.target
            let accessibility = ActionItem("Inspect Accessibility Properties") { NSApp.sendAction(action, to: target, from: inspect) }
            accessibility.toolTip = "Opens the Web Inspector on this element: accessibility is in its Node panel"
            menu.insertItem(accessibility, at: spot)
        }
    }

    /// On a link: WebKit's "Open Link in New Window" knows the link, so Mote's
    /// items say where it goes, then send it on through WebKit's action (see
    /// Browser+Links.swift), in Zen's order. "Download Linked File" is "Save
    /// Link As…", as Firefox calls it.
    private func linkItems(in menu: NSMenu) {
        guard let open = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }),
            let action = open.action, let browser = Windows.shared.all.first(where: { $0.tab(for: self) != nil }),
            let at = menu.items.firstIndex(of: open)
        else { return }
        let target = open.target
        let send = { (opening: LinkOpening) in
            ActionItem("") {
                browser.linkOpening = opening
                NSApp.sendAction(action, to: target, from: open)
            }
        }
        func item(_ title: String, _ opening: LinkOpening) -> NSMenuItem {
            let made = send(opening)
            made.title = title
            return made
        }
        var items = [item("Open Link in New Tab", .tab(background: true))]
        let others = browser.usesSpaces ? browser.spaces.filter { $0.id != browser.spaceID } : []
        if !others.isEmpty {
            let spaces = NSMenuItem(title: "Open Link in New Tab in Space", action: nil, keyEquivalent: "")
            spaces.submenu = NSMenu()
            for space in others { spaces.submenu?.addItem(item(space.name, .space(space.id))) }
            items.append(spaces)
        }
        items += [
            item("Open Link in New Window", .window(private: false)),
            item("Open Link in New Private Window", .window(private: true)),
            item("Open Link in Preview", .preview),
            .separator(),
            item("Bookmark Link…", .bookmark),
            item("Share Link…", .share(at: menuSpot, in: self)),
        ]
        // WebKit's own Share hangs its picker from the middle of the page.
        for share in menu.items where share.identifier?.rawValue == "WKMenuItemIdentifierShareMenu" { menu.removeItem(share) }
        menu.removeItem(open)
        for (offset, made) in items.enumerated() { menu.insertItem(made, at: at + offset) }
        menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" }?.title = "Save Link As…"
    }

    /// The chat's way in from the page: the words under the pointer are quoted
    /// in the composer, and the page they sit on is shared with it.
    private func ask() -> NSMenuItem {
        let item = NSMenuItem(title: "Ask about This", action: #selector(askAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        return item
    }

    @objc private func askAboutSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        let words = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !words.isEmpty else { return }
        onAsk?(words)
    }

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        let words = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !words.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        onSearch?(words)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onTouch?()
        // A touch device: held until it's known whether it's a tap or a drag.
        if touchScrolls, event.clickCount == 1 {
            pressed = (event, false)
            return
        }
        super.mouseDown(with: event)
    }

    /// Where the page's menu was last opened, in this view.
    private var menuSpot = NSRect.zero

    // MARK: - Touch (Responsive Design Mode)

    /// A touch device's page (see Responsive.swift): dragging scrolls it, as
    /// a finger does, and a press that doesn't move is a click.
    var touchScrolls = false {
        didSet { pressed = nil }
    }
    /// The press held back, and whether it has turned into a drag.
    private var pressed: (event: NSEvent, dragging: Bool)?

    override func mouseDragged(with event: NSEvent) {
        guard touchScrolls, let held = pressed else { return super.mouseDragged(with: event) }
        let start = held.event.locationInWindow, now = event.locationInWindow
        if !held.dragging, hypot(now.x - start.x, now.y - start.y) < 4 { return }
        pressed?.dragging = true
        // The page follows the pointer: a wheel turned the other way.
        guard
            let wheel = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(event.deltaY.rounded()),
                wheel2: Int32(event.deltaX.rounded()), wheel3: 0),
            let scroll = NSEvent(cgEvent: wheel)
        else { return }
        // Past Mote's own swipes: the page alone scrolls.
        super.scrollWheel(with: scroll)
    }

    override func mouseUp(with event: NSEvent) {
        guard touchScrolls, let held = pressed else { return super.mouseUp(with: event) }
        pressed = nil
        guard !held.dragging else { return }
        super.mouseDown(with: held.event)
        super.mouseUp(with: event)
    }

    /// Tracking areas ignore what lies on top: under the peeking tabs the
    /// page would still hover.
    override func mouseMoved(with event: NSEvent) {
        if Browser.front?.peeking == true { return }
        super.mouseMoved(with: event)
    }

    /// Side buttons, numbered as most mouse drivers do: 3 back, 4 forward.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Logi Options+ sends its back and forward buttons as swipes, as Safari
    /// reads them: positive for back.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBack {
            goBack()
        } else if event.deltaX < 0, canGoForward {
            goForward()
        } else {
            super.swipe(with: event)
        }
    }

    // MARK: - Keys the page didn't use

    /// The last key given to the page. WebKit sends a key the page didn't
    /// handle back up the responder chain, where nothing takes it and macOS
    /// beeps; editors that insert text themselves (Draft.js) get reported as
    /// unhandled, so the second delivery is dropped, as Safari does.
    private var handed: NSEvent?
    /// Keys dropped that way, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let handed, Self.same(handed, event) {
            self.handed = nil
            Self.quieted += 1
            return
        }
        handed = event
        super.keyDown(with: event)
    }

    /// Whether two events are one key press. WebKit sends back the original
    /// event, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - First frame

    /// A web view that has never drawn is opaque white, which flashes in a
    /// dark window. New views stay transparent until their first layout with
    /// content, then fade in.
    private(set) var unpainted = false

    /// `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`.
    static let firstFrame: UInt = 1 << 1

    /// Asks WebKit (privately) for the first-paint event; without it the view
    /// just shows at once.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, Self.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    func showFirstFrame() {
        guard unpainted else { return }
        unpainted = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    // MARK: - Smart zoom

    // Pinching is left to WebKit, which scales on the GPU during the gesture
    // and lays out once at the end; only the two-finger double-tap is Mote's.

    /// Returns, as JSON, the scale fitting the block under the pointer to the
    /// width and the scroll that keeps the tapped point in place, or the way
    /// back when already zoomed. See Scripts/src/smart-zoom.ts.
    static let smart = InjectedScript.call("smart-zoom", arguments: ["x", "y", "scale", "width"])

    private struct SmartZoom: Decodable {
        var scale: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// Fits the block under the pointer to the width, like Safari; again to go back.
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification else { return super.smartMagnify(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let tap: [String: Any] = ["x": point.x, "y": point.y, "scale": magnification, "width": bounds.width]
        callAsyncJavaScript(Self.smart, arguments: tap, in: nil, in: .page) { [weak self] result in
            guard let self, let text = (try? result.get()) as? String,
                let zoom = try? JSONDecoder().decode(SmartZoom.self, from: Data(text.utf8))
            else { return }
            setMagnification(zoom.scale, centeredAt: point)
            callAsyncJavaScript("window.scrollTo(x, y)", arguments: ["x": zoom.x, "y": zoom.y], in: nil, in: .page)
        }
    }

    // MARK: - Swipe navigation

    private var swipe = SwipeTracker()
    /// A navigation's indicator is still leaving; counts gestures so a late
    /// hide doesn't touch a newer one.
    private var leaving = false
    private var gestures = 0

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        // The page sees every event; the swipe only watches.
        super.scrollWheel(with: event)
        // Live trackpad gestures only: momentum and mouse wheels have no phases.
        guard event.momentumPhase == [] else { return }
        switch event.phase {
        case .mayBegin, .began:
            swipe.begin()
            gestures += 1
            if leaving {
                leaving = false
                onPull?(nil)
            }
        case .changed:
            apply(
                swipe.move(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, at: Date()) { [unowned self] back in
                    back ? canGoBack : canGoForward
                })
        case .ended:
            apply(swipe.end(at: Date()))
        case .cancelled:
            apply(swipe.cancel())
        default:
            break
        }
    }

    /// The page's answer: whether the swipe would scroll something on it.
    func swipeAnswered(free: Bool) {
        apply(swipe.pageAnswered(free: free, at: Date()))
    }

    private func apply(_ effects: [SwipeTracker.Effect]) {
        for effect in effects {
            switch effect {
            case .show(let pull):
                onPull?(pull)
            case .tick(let armed):
                NSHapticFeedbackManager.defaultPerformer.perform(armed ? .levelChange : .alignment, performanceTime: .now)
            case .navigate(let back):
                if back { goBack() } else { goForward() }
                leaving = true
                gestures += 1
                let mine = gestures
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.32))
                    guard let self, gestures == mine else { return }
                    leaving = false
                    onPull?(nil)
                }
            }
        }
    }
}

extension WKWebView {
    /// Loads a URL. A file needs its folder granted, or WebKit shows nothing.
    func open(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    /// Runs JavaScript in Mote's world (see Web.world); `then` gets the
    /// result, or nil on error or no value.
    func evaluateInAppWorld(_ js: String, then: ((Any?) -> Void)? = nil) {
        evaluateJavaScript(js, in: nil, in: Web.world) { then?(try? $0.get()) }
    }

    /// Runs `body` as an async function in Mote's world with each argument as
    /// a variable. WebKit serializes the values, so no Swift string becomes code.
    func callInAppWorld(_ body: String, arguments: [String: Any], then: ((Any?) -> Void)? = nil) {
        callAsyncJavaScript(body, arguments: arguments, in: nil, in: Web.world) { then?(try? $0.get()) }
    }
}
