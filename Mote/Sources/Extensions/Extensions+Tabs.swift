import AppKit
import Combine
import MoteCore
import WebKit

// The browser as extensions see it: every window, each with its tabs. Private
// tabs stay out of sight unless made to carry extensions (Settings ›
// Extensions); a private window's do too.

@available(macOS 15.4, *)
extension Extensions {
    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    func shows(_ tab: Tab) -> Bool { !tab.shy || tab.carriesExtensions }

    /// A browser's window, as extensions see it.
    func window(for browser: Browser) -> ExtensionWindow {
        let key = ObjectIdentifier(browser)
        if let known = windows[key] { return known }
        let made = ExtensionWindow(owner: self, browser: browser)
        windows[key] = made
        return made
    }

    /// The window holding a tab now: tabs move between windows.
    func holder(of tab: Tab) -> Browser? {
        if let holders { return holders[tab.id] }
        var found: [Tab.ID: Browser] = [:]
        for browser in Windows.shared.all {
            for each in browser.tabs { found[each.id] = browser }
            for each in browser.parkedTabs { found[each.id] = browser }
        }
        holders = found
        forgetSoon()
        return found[tab.id]
    }

    /// A window's tabs in every space, in the spaces' order: the showing
    /// space's, and the others' parked. Extensions see them all, as Firefox
    /// shows a workspace's hidden tabs, so switching spaces is just another tab
    /// in front, not every tab closing and opening.
    func visibleTabs(in browser: Browser) -> [Tab] { shown(in: browser).tabs }

    /// A tab's place among them.
    func place(of tab: Tab, in browser: Browser) -> Int? { shown(in: browser).places[tab.id] }

    private func shown(in browser: Browser) -> (tabs: [Tab], places: [Tab.ID: Int]) {
        let key = ObjectIdentifier(browser)
        if let known = shownTabs[key] { return known }
        let tabs =
            browser.usesSpaces
            ? browser.spaces.flatMap { space in space.id == browser.spaceID ? browser.tabs : browser.parked[space.id]?.tabs ?? [] }
                .filter(shows)
            : browser.tabs.filter(shows)
        let made = (tabs: tabs, places: Dictionary(tabs.enumerated().map { ($1.id, $0) }) { first, _ in first })
        shownTabs[key] = made
        forgetSoon()
        return made
    }

    /// Kept until tabs change, and no longer than this turn of the run loop.
    func forgetShown() {
        shownTabs = [:]
        holders = nil
    }

    private func forgetSoon() {
        guard !forgetting else { return }
        forgetting = true
        DispatchQueue.main.async { [weak self] in
            self?.forgetting = false
            self?.forgetShown()
        }
    }

    /// Every window's, the main one first.
    var visibleTabs: [Tab] { Windows.shared.all.flatMap(visibleTabs(in:)) }

    var activeAdapter: ExtensionTab? {
        guard let tab = front?.active, shows(tab) else { return nil }
        return adapter(for: tab)
    }

    func followTabs(of browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard windowWatches[key] == nil else { return }
        controller.didOpenWindow(window(for: browser))
        windowWatches[key] = [
            // As tabs change, not after: nothing may see the old ones.
            browser.$tabs.map { _ in () }.merge(with: browser.$parked.map { _ in () }, browser.$spaces.map { _ in () }, browser.$spaceID.map { _ in () })
                .sink { [weak self] in self?.forgetShown() },
            // After the change has landed: a space switch moves both at once.
            browser.$tabs.map { _ in () }.merge(with: browser.$parked.map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak browser] in if let browser { self?.tabsChanged(in: browser) } },
            browser.$activeID
                .removeDuplicates()
                .scan((nil, nil)) { ($0.1, $1) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak browser] pair in if let browser { self?.selected(pair.1, after: pair.0, in: browser) } },
        ]
    }

    /// A window closed: its tabs went with it.
    func forget(_ browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard windowWatches.removeValue(forKey: key) != nil, let window = windows.removeValue(forKey: key) else { return }
        for id in orders.removeValue(forKey: key) ?? [] {
            if let adapter = adapters.removeValue(forKey: id) { controller.didCloseTab(adapter, windowIsClosing: true) }
            tabWatches[id] = nil
        }
        controller.didCloseWindow(window)
    }

    /// The window in front changed.
    func focused(_ browser: Browser) {
        if windowWatches[ObjectIdentifier(browser)] != nil { controller.didFocusWindow(window(for: browser)) }
    }

    private func tabsChanged(in browser: Browser) {
        let key = ObjectIdentifier(browser)
        let shown = visibleTabs(in: browser)
        let before = orders[key] ?? []
        let changes = ExtensionRules.tabChanges(from: before, to: shown.map(\.id))
        for id in changes.closed {
            guard let adapter = adapters[id] else { continue }
            // Gone to another window: a move there, not a close.
            if let tab = adapter.tab, let there = holder(of: tab), there !== browser {
                moved.insert(id)
                controller.didMoveTab(adapter, from: before.firstIndex(of: id) ?? 0, in: window(for: browser))
                continue
            }
            controller.didCloseTab(adapter, windowIsClosing: false)
            adapters[id] = nil
            tabWatches[id] = nil
        }
        for tab in shown where changes.opened.contains(tab.id) {
            // Come from another window, which tells extensions it moved.
            if moved.remove(tab.id) != nil || orders.contains(where: { $0.key != key && $0.value.contains(tab.id) }) { continue }
            controller.didOpenTab(adapter(for: tab))
            watch(tab)
        }
        for (id, from) in changes.moved {
            if let adapter = adapters[id] { controller.didMoveTab(adapter, from: from, in: window(for: browser)) }
        }
        orders[key] = shown.map(\.id)
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        let tell = { [weak self] (change: WKWebExtension.TabChangedProperties) in
            guard let self, let adapter = adapters[id] else { return }
            controller.didChangeTabProperties(change, for: adapter)
        }
        tabWatches[id] = [
            tab.$title.dropFirst().removeDuplicates().sink { _ in tell(.title) },
            tab.$address.dropFirst().removeDuplicates().sink { _ in tell(.URL) },
            tab.$loading.dropFirst().removeDuplicates().sink { _ in tell(.loading) },
            tab.$pin.dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in tell(.pinned) },
        ]
    }

    private func selected(_ id: Tab.ID?, after previous: Tab.ID?, in browser: Browser) {
        guard let tab = id.flatMap(browser.tab), shows(tab) else { return }
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous.flatMap(browser.tab).map(adapter(for:)))
        actionsChanged += 1
    }
}

/// A tab, for WebKit's extension APIs.
@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    /// The window the tab is in now.
    private var browser: Browser? { tab.flatMap(owner.holder(of:)) }
    private var page: WKWebView? { tab?.built }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser.map(owner.window(for:)) }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let browser else { return NSNotFound }
        return owner.place(of: tab, in: browser) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { page }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { tab?.loading != true }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab != nil && tab?.id == browser?.activeID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.held == true }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy == true }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(page?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { page?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser, pinned != tab.held else { return }
        if pinned { browser.keep(tab) } else if tab.pin != nil { browser.unpin(tab) } else { browser.unkeep(tab) }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    /// An extension's page only loads in a web view made for that extension,
    /// so going to one from elsewhere replaces the tab (Browser.replace).
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        let url = Extensions.current(url)
        let here = page?.url ?? tab.address
        let elsewhere = here?.scheme != Extensions.scheme || here?.host != url.host
        if url.scheme == Extensions.scheme, elsewhere, let browser {
            browser.replace(tab, going: url)
        } else {
            tab.go(to: url)
        }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        if let tab { browser?.select(tab) }
    }

    func close(for context: WKWebExtensionContext) async throws {
        if let tab { browser?.close(tab) }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let page else { return nil }
        return try await page.takeSnapshot(configuration: configuration)
    }
}

/// A browser window, for WebKit's extension APIs: one per Browser.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    weak var browser: Browser?

    init(owner: Extensions, browser: Browser) {
        self.owner = owner
        self.browser = browser
    }

    private var shown: NSWindow? { browser?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser.map { owner.visibleTabs(in: $0).map(owner.adapter(for:)) } ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = browser?.active, owner.shows(tab) else { return nil }
        return owner.adapter(for: tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { browser?.isPrivate == true }
    func frame(for context: WKWebExtensionContext) -> CGRect { shown?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { shown?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = shown else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate()
        shown?.makeKeyAndOrderFront(nil)
    }
}
