import Combine
import MoteAI
import MoteCore
import SwiftUI
import WebKit
import os

/// One window's browser: its row of tabs and which one is showing, plus the
/// models for everything drawn around and over the page.
///
/// Tab order follows `TabRow`'s rules. The address field, find in page,
/// passwords and camera prompts each have their own model; the extensions
/// in Browser+*.swift add navigation, downloads, element hiding and floating
/// video.
@MainActor
final class Browser: NSObject, ObservableObject {
    // MARK: - State

    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: Tab.ID? {
        didSet {
            guard oldValue != activeID else { return }
            if let old = oldValue {
                linkStatus.dismiss()
                // Tab sleep measures idle time from the moment a tab stops showing.
                tab(old)?.touch()
            }
            // A tab whose own panel is open shows the page it is on: coming to
            // it takes up its new page (see `syncPageChat`). A tab with a
            // closed panel is left alone.
            syncPageChat()
        }
    }

    // Shared by every window (AppState).
    let prefs = AppState.shared.prefs
    let history = AppState.shared.history
    let bookmarks = AppState.shared.bookmarks
    let downloads = AppState.shared.downloads
    let elementHider = AppState.shared.elementHider
    // This window's own.
    let linkStatus = LinkStatus()
    let floater = FloatingVideo()

    let field = AddressEntry()
    let finder = PageFinder()
    let capture = CaptureRequests()
    private(set) lazy var logins = Logins(say: { [weak self] in self?.announce($0) }, tab: { [weak self] in self?.tab($0) })

    /// The address field is up over the page (⌘L). Blank tabs always show it.
    @Published var editing = false

    // Panels and modes shown over the window.
    @Published var tuning = false
    @Published var welcoming = false
    /// The arrival animation is playing over the window (see Arrival.swift).
    @Published var arriving = false
    @Published var bookmarking = false
    @Published var bookmarksOpen = false
    /// Settings › General › Import from Zen.
    @Published var importingZen = false
    @Published var recalling = false
    @Published var showingDownloads = false
    /// About Processes (see ProcessesPanel).
    @Published var showingProcesses = false
    /// The space whose colours are being chosen (see SpaceThemePanel).
    @Published var themingSpace: UUID?
    /// A page waiting for a translation session (see Translate.swift).
    @Published var translating: TranslationJob?
    /// The site whose boost is being edited (see BoostPanel).
    @Published var boosting: String?
    /// The chat about the active page is docked on the window's trailing edge,
    /// the mirror of the sidebar (its width lives in `Preferences.chatWidth`).
    /// Whether it is open belongs to the tab, not the window (`Tab.chatOpen`),
    /// so each tab keeps its own state; see `chatting`. Kept in memory, like
    /// the other panel and mode flags (`showingDownloads`, `bookmarking`,
    /// `recalling`): Mote persists no panel visibility, and the kept page chats
    /// survive the session through their tabs, not a window flag.
    @Published var historyQuery = ""

    /// ⌘S collapses the sidebar; `peeking` slides it out over the page while
    /// collapsed (see SidebarFold.swift).
    var folded: Bool {
        get { prefs.sidebar ? prefs.sidebarFolded : prefs.stripFolded }
        set {
            if prefs.sidebar { prefs.sidebarFolded = newValue } else { prefs.stripFolded = newValue }
        }
    }
    @Published var peeking = false
    /// The toolbar, when it isn't on the card, is out over the page's top
    /// because the pointer reached it (see ToolbarReveal.swift).
    @Published var toolbarRevealed = false
    /// The space icon picker open now, and the view it hangs from.
    @Published var pickingIcon: IconPick?
    /// The tab the media strip shows (see Browser+Media.swift).
    @Published var playing: Tab?
    /// A picture of the page laid over it while the chrome around it changes
    /// size (see `dissolvingPage`).
    @Published var pageVeil: NSImage?

    /// The tab whose page is in the floating video window. Clearing it also
    /// closes the window, so the two can't disagree.
    @Published var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Element picking is on (see Browser+Hiding.swift).
    @Published var pickingElement = false
    /// The list of hidden elements for this site is shown.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    /// The pinned tab whose letter is being edited in place.
    @Published var editingPin: Tab.ID?
    /// The tab whose name is being edited in place, and the draft.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""

    /// A short message at the bottom of the window.
    /// The short message showing (see `Toast`).
    let announcer = Announcer()
    var announcement: Announcement? { announcer.showing }

    /// Recently closed tabs, for ⌘⇧T and the History menu.
    @Published private var closed = RecentlyClosed<Ghost>()
    var ghosts: [Ghost] { closed.entries }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int

        var label: String { title.isEmpty ? Address.displayString(for: url) : title }
    }

    /// All spaces, the current one, and the parked rows of the others (see
    /// Spaces.swift).
    @Published var spaces = Spaces.read() {
        didSet { Spaces.sharing = SpaceList(saved: spaces).sharing }
    }
    @Published var spaceID = Space.firstID
    /// The other spaces' tabs. Published so extensions keep up with them.
    @Published var parked: [UUID: Parked] = [:]
    /// The space swipe's offset. Kept apart, as it changes on every frame of
    /// a swipe and only the sliding pages follow it.
    let swipeOffset = SwipeOffset()
    var spaceSwipe: CGFloat {
        get { swipeOffset.value }
        set { swipeOffset.value = newValue }
    }
    /// Whether the new-space card is shown.
    @Published var makingSpace = false
    /// Direction of the last space change: 1 forward, -1 back.
    @Published var spaceStep = 1
    /// A link preview over the page (see LinkPeek.swift).
    @Published var peekTab: Tab?
    /// Split views, every space's, each by its own id (see Browser+Split.swift).
    @Published var splits: [UUID: SplitLayout<Tab.ID>] = [:] {
        didSet { splitOf = splits.reduce(into: [:]) { found, group in for id in group.value.ids { found[id] = group.key } } }
    }
    /// Each grouped tab's group, kept as `splits` changes: the sidebar asks
    /// for every row on every frame it draws.
    private(set) var splitOf: [Tab.ID: UUID] = [:]
    /// Where a tab dragged over the page would split in.
    @Published var splitHover: SplitHover?
    /// The page area, where a dragged tab's place is measured (see SplitStage).
    weak var stageView: NSView?

    /// File names extensions asked for their downloads.
    var namedDownloads: [URL: String] = [:]
    /// Downloads in progress; tabs with one don't sleep.
    var downloading: [WKDownload] = []
    /// Idle tab sleep timer and memory pressure source (see Browser+TabSleep.swift).
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Updates Chrome Web Store pages as extensions come and go (see WebStoreBridge.swift).
    var storeWatch: AnyCancellable?
    /// The video was floated because the app went to the background, so it
    /// comes back by itself (see Browser+Floating.swift).
    var floatedAway = false

    /// The most recently active window. macOS stops reporting a main window
    /// once the app is in the background.
    static weak var front: Browser?
    /// This browser's window, once it has one.
    weak var window: NSWindow? {
        didSet { titleWindow() }
    }
    /// A window opened after the main one (⌘N, a link), with its own open
    /// tabs, saved under its id (see Windows.swift).
    let extra: Bool
    let windowID: UUID?
    /// A private window (⇧⌘N): its tabs share one store that keeps nothing,
    /// and it saves no session and shows no spaces.
    let isPrivate: Bool
    private(set) lazy var privateStore = WKWebsiteDataStore.nonPersistent()
    /// Spaces show here: they're on, and this isn't a private window.
    var usesSpaces: Bool { prefs.usesSpaces && !isPrivate }
    /// Where the next link WebKit opens goes (see Browser+Links.swift).
    var linkOpening: LinkOpening?
    /// The Touch Bar's buttons, on Macs that have one.
    private(set) lazy var touchBarItems = BrowserTouchBar(browser: self)

    var bag = Set<AnyCancellable>()
    private var hush: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    var zoomShown = 100

    // MARK: - Reading

    var active: Tab? { activeID.flatMap(tab) }
    var fieldShowing: Bool { editing || active?.isStart ?? true }
    /// A page the chat can be opened over: a tab showing a page, not a new
    /// tab, a chat, or the list of kept chats.
    var pageChatPossible: Bool { active.map { !$0.isBlank } ?? false }
    /// The chat about the active page is on screen. Derived from the active
    /// tab's own open state, so the panel follows the tab and a switch shows
    /// each tab's state: a tab whose panel is closed shows no panel.
    var chatting: Bool { active?.chatOpen == true }

    /// Opens or closes the chat about the page showing, on the active tab
    /// alone. Opening makes the chat, so it outlives the navigation from its
    /// first ask on, and takes up the page at once, on the fold spring the
    /// sidebar uses.
    func togglePageChat() {
        guard let tab = active, pageChatPossible else { return }
        if tab.chatOpen {
            slidingFold { tab.chatOpen = false }
        } else {
            tab.ensurePageChat()
            slidingFold { tab.chatOpen = true }
            syncPageChat()
        }
    }

    /// Takes up the page the active tab shows for the chat about it, as its
    /// panel opens or the tab with its panel open becomes active, so the chip
    /// never reads as unshared over a page the model can be told about. A tab
    /// whose own panel is closed takes up nothing. The page is taken at once
    /// with its address and title, so it shows on the panel's first frame, and
    /// its text is read after. A page already held — even one let go on
    /// purpose — is left as it is, so looking away and back does not share it
    /// again.
    func syncPageChat() {
        guard let tab = active, tab.chatOpen else { return }
        // The panel always has a chat to show over the visible page, so an
        // unreadable page still gets its calm note.
        tab.ensurePageChat()
        guard let address = tab.address, PageSharing.takesUp(address, chatting: true, holding: tab.pageChat?.page?.url)
        else { return }
        tab.attachPage(PageContext(url: address, title: tab.title))
        Task { [weak self, weak tab] in
            guard let self, let tab, self.active === tab, tab.chatOpen, let page = await tab.capturePageContext() else { return }
            // The person may have let the page go, closed the panel, or the
            // visible tab moved on, while it was read; then the page is left as
            // it is. A page they asked about by selecting its text is left as
            // it is too: the read must not drop that selection.
            guard self.active === tab, tab.chatOpen, tab.pageChat?.page?.isActive == true, PageSharing.isSamePage(page.url, tab.address),
                PageSharing.replaces(page.url, holding: tab.pageChat?.page?.url, selection: tab.pageChat?.page?.selection != nil)
            else { return }
            tab.attachPage(page)
        }
    }

    /// Essentials and pinned tabs together.
    var pinnedCount: Int { row.pinnedCount }
    var essentialCount: Int { row.count(in: .essential) }
    var keptCount: Int { row.count(in: .pinned) }
    /// The places a section's tabs occupy in the row.
    func places(of section: TabTier) -> Range<Int> { row.places(of: section) }
    var recentlyVisited: [History.Entry] { history.recent() }

    func tab(_ id: Tab.ID) -> Tab? { tabs.first { $0.id == id } }
    func tab(for webView: WKWebView) -> Tab? { tabs.first { $0.built === webView } }

    /// The other tabs a chat may @-mention: this window's open, named tabs,
    /// except the one given and any already mentioned. Blank tabs, which have
    /// no page to share, are left out. Read-only: the chat does the mentioning.
    func mentionCandidates(excluding tab: Tab?, mentioned: Set<URL> = []) -> [MentionMenu.Candidate] {
        tabs.compactMap { other in
            guard other.id != tab?.id, !other.isBlank, let url = other.address, !mentioned.contains(url) else { return nil }
            let title = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return MentionMenu.Candidate(
                id: other.id.uuidString,
                title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                host: url.host() ?? "")
        }
    }

    var row: TabRow<Tab> { TabRow(tabs, section: \.section) }

    /// Changes the tab order under `TabRow`'s rules.
    @discardableResult
    func reorder<Result>(_ change: (inout TabRow<Tab>) -> Result) -> Result {
        var next = row
        let result = change(&next)
        if next.tabs.map(\.id) != tabs.map(\.id) { tabs = next.tabs }
        return result
    }

    // MARK: - Starting

    /// The main window's browser restores the session and starts what the app
    /// runs once; an `extra` one starts on `space` with its held tabs and a
    /// new tab.
    init(extra: Bool = false, id: UUID? = nil, space: UUID? = nil, isPrivate: Bool = false) {
        self.extra = extra || isPrivate
        self.isPrivate = isPrivate
        windowID = extra || isPrivate ? id ?? UUID() : nil
        super.init()
        if !extra { startApp() }

        field.suggest = { [weak self] typed, switching in self?.suggestions(for: typed, switching: switching) ?? ([], nil) }
        finder.page = { [weak self] in self?.active?.web }

        // Views read bookmarks and preferences through this object, so pass on
        // their changes. Not history's: it changes on every page loaded and
        // titled, and only the menu bar shows it, which watches it itself.
        for source in [bookmarks.objectWillChange, prefs.objectWillChange] {
            source.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }
        wireFloater()
        $activeID.dropFirst().sink { [weak self] _ in self?.notePlayingSoon() }.store(in: &bag)
        followTitle()

        if extra {
            if let space, spaces.contains(where: { $0.id == space }) { spaceID = space }
            restoreSession()
        } else {
            if prefs.usesSpaces, let last = Storage.settings.string(forKey: "space.current").flatMap(UUID.init),
                spaces.contains(where: { $0.id == last })
            {
                spaceID = last
                Spaces.current = last
            }
            restoreSession()
        }
        if usesSpaces { preloadSpaces() }
        if !extra { LiveFeeds.shared.start() }
        follow()
        watchForSleep()
    }

    /// The window's title is its tab in front's, as in Zen and Safari: what the
    /// Window menu and Mission Control list it by. The title bar is hidden, so
    /// it shows nowhere else.
    private func followTitle() {
        $activeID
            .map { [weak self] id -> AnyPublisher<Void, Never> in
                guard let tab = id.flatMap({ self?.tab($0) }) else { return Just(()).eraseToAnyPublisher() }
                return tab.$title.map { _ in () }.merge(with: tab.$name.map { _ in () }).eraseToAnyPublisher()
            }
            .switchToLatest()
            // Once switching settles: the title isn't on screen, and setting it
            // lays the title bar out again, which a tab switch's frame shouldn't wait on.
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.titleWindow() }
            .store(in: &bag)
    }

    private func titleWindow() {
        guard let window else { return }
        // Another profile's windows say whose they are, in the Window menu too.
        let page = active.map { $0.isBlank ? "Mote" : $0.label } ?? "Mote"
        let title = Storage.profile == nil ? page : "\(page) — \(Profiles.shared.current)"
        guard window.title != title else { return }
        window.title = title
        // AppKit lays its title bar's buttons out afresh for a new title, back
        // at their stock place; put them back where the chrome keeps them.
        TrafficLights.refresh(in: window)
    }

    /// What the app starts once, with its first window.
    private func startApp() {
        AdBlocker.shared.enabled = prefs.shielded
        AdBlocker.shared.compile()
        if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
        if prefs.bench {
            Bench.shared.start(for: self)
        } else if prefs.benchRefused {
            announce("“Let a script drive Mote” was turned on outside Settings, and stays off")
        }
        welcoming = !prefs.welcomed
        Updater.shared.checkIfDue { [weak self] news in self?.tell(news) }
        FormRelay.passkeysOffered = prefs.passkeys
        Favicons.shared.arrived = { host, image in
            for tab in Windows.shared.all.flatMap(\.tabs) where tab.address?.host()?.lowercased() == host { tab.icon = image }
        }
        Spaces.sweep()
        Spaces.sharing = SpaceList(saved: spaces).sharing
    }

    /// A space's essentials and pinned tabs, from its saved session, asleep:
    /// what a new window shows of it.
    func heldTabs(of space: UUID) -> [Tab] {
        let saved = Session.read(space: space).tabs
        HeldSync.seed(saved, in: space)
        return saved.filter(\.isHeld).compactMap { entry -> Tab? in
            let tab = Tab(configuration: Web.configuration(space: space))
            return restore(entry, in: tab) ? tab : nil
        }
    }

    /// Restores the current space's tabs, or opens one blank tab.
    func restoreSession() {
        // A private window: one new private tab.
        if isPrivate { return show(privateTab(), adopting: true) }
        // A window opened since the main one: the space's held tabs and a new tab.
        if extra {
            let parked = loadRow(spaceID)
            showRow(parked.tabs, active: parked.active)
            if !tabs.contains(where: { !$0.held }) {
                let blank = Tab()
                adopt(blank)
                activeID = blank.id
            }
            active?.wake()
            return
        }
        let saved = Session.read(space: spaceID)
        HeldSync.seed(saved.tabs, in: spaceID)
        let made = saved.tabs.map { entry -> Tab? in
            let tab = Tab()
            return restore(entry, in: tab) ? tab : nil
        }
        let restored = made.compactMap(\.self)
        guard !restored.isEmpty else {
            let tab = Tab()
            adopt(tab)
            // Build the blank tab's web view a second after launch, so its web
            // process is ready for the first navigation without slowing the first frame.
            Task { [weak tab] in
                try? await Task.sleep(for: .seconds(1))
                if let tab, tab.isBlank { _ = tab.web }
            }
            return
        }
        tabs = restored
        let here = min(max(0, saved.active), restored.count - 1)
        activeID = restored[here].id
        restoreSplits(saved.splits, made)
        // Only the active tab, or its split, loads; the rest wait until they are opened.
        restored[here].wake()
        wakeSplit()
    }

    /// Side effects of preferences that change while the window is open.
    private func follow() {
        followStore()
        func on<Value>(_ publisher: Published<Value>.Publisher, _ act: @escaping (Browser, Value) -> Void) {
            publisher.dropFirst().sink { [weak self] value in self.map { act($0, value) } }.store(in: &bag)
        }
        on(prefs.$usesSpaces) { browser, on in on ? browser.preloadSpaces() : browser.leaveSpaces() }
        on(prefs.$shielded) { browser, on in
            AdBlocker.shared.enabled = on
            AdBlocker.shared.apply(to: browser.tabs.compactMap { $0.built?.configuration.userContentController })
            browser.announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
        }
        on(prefs.$look) { browser, _ in browser.refreshIconsSoon() }
        on(prefs.$bench) { browser, on in
            guard !browser.extra else { return }
            if on { Bench.shared.start(for: browser) } else { Bench.shared.stop() }
            browser.announce(on ? "Scripts can drive Mote — see ./bench" : "The bench is closed")
        }
        on(prefs.$autoScroll) { browser, on in
            browser.rearmAll(including: browser.parkedTabs) { $0.evaluateInAppWorld(on ? AutoScroll.script : AutoScroll.off) }
        }
        on(prefs.$showsLinks) { browser, on in
            if !on { browser.linkStatus.dismiss() }
            browser.rearmAll(including: browser.parkedTabs) {
                $0.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
            }
        }
        on(prefs.$passkeys) { browser, on in
            FormRelay.passkeysOffered = on
            browser.rearmAll()
            browser.announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
        }
        on(prefs.$autocorrect) { browser, on in browser.setAutocorrect(on) }

        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in if self?.prefs.look == .system { self?.refreshIconsSoon() } }
            .store(in: &bag)
    }

    /// Favicons come in light and dark versions; fetch them again once a new
    /// appearance has taken effect.
    private func refreshIconsSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard let self else { return }
            Favicons.shared.relook(tabs.filter { !$0.asleep })
        }
    }

    /// Re-arms every tab's next document with its site's hidden elements (an
    /// empty stylesheet would unhide them all), then runs `now` on the pages
    /// already built.
    private func rearmAll(including extra: [Tab] = [], now: ((WKWebView) -> Void)? = nil) {
        for tab in tabs + extra {
            tab.arm(hiding: elementHider.hiding(on: Address.siteHost(of: tab.address)))
            if let now, let web = tab.built { now(web) }
        }
    }

    /// WebKit reads the autocorrect default once at launch; at run time only
    /// the Edit menu's toggle action switches it, and it only toggles.
    private func setAutocorrect(_ on: Bool) {
        guard let web = active?.web else { return }
        let toggle = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
        guard web.responds(to: toggle) else { return }
        if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on { web.perform(toggle, with: nil) }
        Preferences.tellWebKit(autocorrect: on)
        announce(on ? "Autocorrect on" : "Autocorrect off")
    }

    // MARK: - Session

    /// Puts a saved tab back: a page, which loads when opened, or a kept chat.
    func restore(_ entry: Session.Entry, in tab: Tab) -> Bool {
        if let id = entry.chat.flatMap(UUID.init(uuidString:)) {
            guard let chat = Assistant.shared.reopen(id) else { return false }
            prepare(tab)
            tab.chat = chat
            tab.name = entry.name
            tab.pin = entry.pin
            tab.kept = entry.kept == true
            tab.heldID = entry.held.flatMap(UUID.init(uuidString:))
            return true
        }
        guard let url = URL(string: entry.url) else { return false }
        tab.home = entry.isHeld ? entry.home.flatMap(URL.init(string:)) ?? url : nil
        tab.folder = entry.kept == true ? entry.folder.flatMap(UUID.init(uuidString:)) : nil
        prepare(tab)
        tab.restore(url: url, title: entry.title, name: entry.name)
        tab.pin = entry.pin
        tab.kept = entry.kept == true
        tab.heldID = entry.held.flatMap(UUID.init(uuidString:))
        return true
    }

    func writeSession(now: Bool = false) {
        writeSession(now: now, space: spaceID, tabs: tabs, active: activeID)
    }

    /// Saves any space's row: this one, or one parked.
    func writeSession(now: Bool, space: UUID, tabs: [Tab], active: Tab.ID?) {
        // A private window keeps nothing.
        guard !isPrivate else { return }
        let entries = tabs.compactMap(entry(for:))
        HeldSync.saved(entries, in: space, by: self)
        // A window opened since the main one keeps only its open tabs.
        if extra, let windowID {
            let loose = tabs.filter { !$0.held }
            let kept = loose.filter { entry(for: $0) != nil }
            Session.write(
                now: now, window: windowID, space: space,
                .init(tabs: kept.compactMap(entry(for:)), active: loose.firstIndex { $0.id == active } ?? 0, splits: savedSplits(kept)))
            return
        }
        let kept = tabs.filter { entry(for: $0) != nil }
        Session.write(
            now: now, space: space,
            .init(tabs: kept.compactMap(entry(for:)), active: tabs.firstIndex { $0.id == active } ?? 0, splits: savedSplits(kept)))
    }

    /// A tab as the session keeps it: a page, or a kept chat. Private, bench
    /// and blank tabs aren't kept.
    func entry(for tab: Tab) -> Session.Entry? {
        // A held tab keeps one id from window to window.
        if tab.held, tab.heldID == nil { tab.heldID = UUID() }
        let held = tab.held ? tab.heldID?.uuidString : nil
        if !tab.shy, !tab.bench, tab.isBlank, let chat = tab.chat, !chat.messages.isEmpty {
            return Session.Entry(
                url: "", title: chat.title, pin: tab.pin, kept: tab.kept ? true : nil, name: tab.name, chat: chat.id.uuidString,
                held: held)
        }
        guard !tab.shy, !tab.bench,
            // A sleeping tab's address is in `pending`, never its released page's.
            let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true
        else { return nil }
        let home = tab.held ? tab.home.map(\.absoluteString).flatMap { $0 == url.absoluteString ? nil : $0 } : nil
        return Session.Entry(
            url: url.absoluteString, title: tab.title, pin: tab.pin, kept: tab.kept ? true : nil, name: tab.name, held: held, home: home,
            folder: tab.kept ? tab.folder?.uuidString : nil)
    }

    // MARK: - Merging spaces

    struct Merged: Equatable {
        var tabs = 0
        var cookies = 0
    }

    /// Settings › Tabs › Spaces › Merge: moves a space's tabs into another,
    /// each in its tier, leaving out pages the other already has; copies its
    /// cookies there when their website data differs, without replacing the
    /// other's; then deletes it. Cookies are what WebKit lets go between
    /// stores, so sites keeping a sign-in elsewhere (local storage) ask again.
    func mergeSpace(_ source: UUID, into target: UUID) async -> Merged {
        guard source != target, let from = spaces.first(where: { $0.id == source }), !from.isFirst,
            spaces.contains(where: { $0.id == target })
        else { return Merged() }
        var merged = Merged()
        if spaceID == source { switchSpace(to: target) }
        let leaving = parked[source] ?? loadRow(source)
        let showing = spaceID == target
        let staying = showing ? tabs : (parked[target] ?? loadRow(target)).tabs
        let present = Set(staying.compactMap { ($0.pending ?? $0.address)?.absoluteString })
        var arriving: [Tab] = []
        for entry in leaving.tabs.compactMap(entry(for:)) where entry.chat != nil || !present.contains(entry.url) {
            let tab = Tab(configuration: Web.configuration(space: target))
            if restore(entry, in: tab) { arriving.append(tab) }
        }
        merged.tabs = arriving.count
        // Essentials, pinned tabs, then the rest, each keeping its order.
        let row = [TabTier.essential, .pinned, .loose].flatMap { tier in (staying + arriving).filter { $0.section == tier } }
        if showing {
            tabs = row
            writeSession(now: true)
        } else {
            let active = parked[target]?.active ?? row.first?.id
            parked[target] = Parked(tabs: row, active: active)
            writeSession(now: true, space: target, tabs: row, active: active)
        }
        let leavingStore = Spaces.store(for: source)
        let stayingStore = Spaces.store(for: target)
        if leavingStore !== stayingStore {
            func key(_ cookie: HTTPCookie) -> String { "\(cookie.name)|\(cookie.domain)|\(cookie.path)" }
            let kept = Set(await stayingStore.httpCookieStore.allCookies().map(key))
            for cookie in await leavingStore.httpCookieStore.allCookies() where !kept.contains(key(cookie)) {
                await stayingStore.httpCookieStore.setCookie(cookie)
                merged.cookies += 1
            }
        }
        // Made just for this, so not parked: deleting the space wouldn't close them.
        if parked[source] == nil { leaving.tabs.forEach { $0.close() } }
        deleteSpace(source)
        return merged
    }

    /// Saves the session a moment after the last of a burst of changes.
    func saveSoon() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.saving = nil
            self?.writeSession()
        }
    }

    /// Writes the session at once, on quit.
    func flushSession() {
        writeSession(now: true)
        Assistant.shared.chats.flush()
    }

    // MARK: - Opening tabs

    func newTab() {
        // A new tab from a private tab is private too, so nothing leaks into history.
        if isPrivate { return show(privateTab(), adopting: true) }
        if active?.shy == true { return newShyTab() }
        // Over a page, the floating search; a blank tab already is one.
        if prefs.newTabSearch, let active, !active.isStart { return launch() }
        if #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            open(page, foreground: true)
            field.switching = false
            saveSoon()
            return
        }
        let tab = Tab()
        show(tab, adopting: true)
        saveSoon()
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// ⌘⇧N: a tab that keeps nothing.
    func newShyTab() {
        if isPrivate { return show(privateTab(), adopting: true) }
        show(Tab(shy: true), adopting: true)
        announce("A tab that keeps nothing")
    }

    /// Puts a fresh blank tab in front with the field ready for typing.
    func show(_ tab: Tab, adopting: Bool) {
        if adopting { adopt(tab) }
        floatActiveVideo()
        activeID = tab.id
        field.clear()
        editing = false
        field.askFocus()
    }

    /// Opens `url` in a new tab next to the current one, or at the end when
    /// `atEnd` is set (batches keep their order that way). Links from a private
    /// tab open in a private tab sharing its store.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil) -> Tab {
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        let tab =
            if isPrivate, page == nil {
                privateTab()
            } else if let source, source.shy, page == nil {
                Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
            } else {
                Tab(configuration: page)
            }
        prepare(tab)
        // Back on it, with nowhere to go, returns here (see `Browser.back`).
        tab.opener = source?.id
        reorder { $0.insert(tab, at: atEnd ? $0.tabs.count : $0.slotForNew(after: activeID)) }
        tab.go(to: url)
        if foreground { bringForward(tab) }
        return tab
    }

    /// Opens a tab for the bench, at the end and in the background.
    @discardableResult
    func benchOpen(_ url: URL) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(bench: true, configuration: Browser.extensionConfiguration(for: url))
        prepare(tab)
        reorder { $0.append(tab) }
        tab.go(to: url)
        return tab
    }

    /// A link from another app: into the current tab if it is blank and
    /// nothing is typed, otherwise a new tab in front.
    func arrive(_ url: URL) {
        if let active, active.isStart, field.typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark: into the current tab, or a new one with ⌘ held or while the
    /// current tab's video floats.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            go(active, to: url)
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// Opens a bookmark and closes the bookmark menu and manager.
    func pickBookmark(_ url: URL) {
        bookmarking = false
        bookmarksOpen = false
        visit(url)
    }

    /// ⌘D.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true, from: active)
    }

    /// ⌘⇧V outside text: the clipboard as an address or a search, in this tab.
    func pasteAndGo() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = destination(for: text), let tab = active ?? tabs.first else { return field.refuse() }
        go(tab, to: url)
    }

    /// Links dropped on the tab row open as new tabs.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let url = text.flatMap(Address.url(from:)) else { return }
                    Task { @MainActor in self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// Adds a tab made outside the row, such as a kept link preview.
    func insert(_ tab: Tab, at index: Int) {
        reorder { $0.insert(tab, at: index) }
        saveSoon()
    }

    /// Where a new tab would go.
    func placeForNew() -> Int { row.slotForNew(after: activeID) }

    /// Adds a tab at the end; the first tab becomes the active one.
    func adopt(_ tab: Tab) {
        prepare(tab)
        reorder { $0.append(tab) }
        if activeID == nil { activeID = tab.id }
    }

    /// Makes a tab that just opened the one showing.
    func bringForward(_ tab: Tab) {
        floatActiveVideo()
        activeID = tab.id
        editing = false
        field.clear()
    }

    /// Loads `url` in `tab` and puts the field away.
    func go(_ tab: Tab, to url: URL) {
        tab.go(to: url)
        editing = false
        field.clear()
    }

    // MARK: - Switching

    func select(_ tab: Tab) {
        if peekTab != nil, tab.id != activeID { closePeek() }
        cancelTabEdit()
        field.switching = false
        logins.dropChoices()
        guard tab.id != activeID else { return }
        let interval = switching.beginInterval("Select tab")
        defer { switching.endInterval("Select tab", interval) }
        if floating == tab.id { land() }
        floatActiveVideo()
        activeID = tab.id
        tab.touch()
        // Load a waiting tab now; only when there was nothing to wake, check
        // whether a background page's process died (doing both races two loads).
        if !tab.wake() { tab.revive() }
        wakeSplit()
        saveSoon()
        editing = false
        field.clear()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// ⌃Tab and ⌃⇧Tab.
    func step(_ direction: Int) {
        let skips = { (tab: Tab) in (self.prefs.stepSkipsEssentials && tab.pin != nil) || (self.prefs.stepSkipsSleeping && tab.asleep) }
        guard let id = activeID, let next = row.neighbour(of: id, by: direction, skipping: skips).flatMap(tab) else { return }
        select(next)
    }

    /// Drag and drop within the row; tabs stay in their section.
    func move(_ tab: Tab, to index: Int) {
        if let group = group(of: tab.id) { return moveGroup(group, by: tab, to: index) }
        guard reorder({ $0.move(tab.id, to: index) }) else { return }
        gatherAll()
        saveSoon()
    }

    /// Shows another space's row in place of this one (see Spaces.swift).
    func showRow(_ row: [Tab], active: Tab.ID?) {
        tabs = row
        activeID = active ?? row.first?.id
    }

    /// Builds a space's row from its saved session without touching the
    /// current one. Its tabs wait and cost little until opened.
    func loadRow(_ space: UUID) -> Parked {
        if extra, let windowID {
            // The space's held tabs, and this window's own open ones.
            let saved = Session.read(window: windowID, space: space)
            let made = saved.tabs.map { entry -> Tab? in
                let tab = Tab(configuration: Web.configuration(space: space))
                return restore(entry, in: tab) ? tab : nil
            }
            let loose = made.compactMap(\.self)
            restoreSplits(saved.splits, made)
            let held = heldTabs(of: space)
            let active = loose.indices.contains(saved.active) ? loose[saved.active].id : loose.first?.id ?? held.first?.id
            return Parked(tabs: held + loose, active: active)
        }
        let saved = Session.read(space: space)
        HeldSync.seed(saved.tabs, in: space)
        let made = saved.tabs.map { entry -> Tab? in
            let tab = Tab(configuration: Web.configuration(space: space))
            return restore(entry, in: tab) ? tab : nil
        }
        let row = made.compactMap(\.self)
        restoreSplits(saved.splits, made)
        return Parked(tabs: row, active: row.indices.contains(saved.active) ? row[saved.active].id : row.first?.id)
    }

    // MARK: - Closing

    /// ⌘W or a tab's close button. The last tab is replaced by a blank one;
    /// closing that blank tab closes the window. An essential or pinned tab
    /// only lets go of its page and stays in the row; Unpin removes it.
    func close(_ tab: Tab) {
        guard let index = row.index(of: tab.id) else { return }
        if floating == tab.id { land() }

        if tab.held {
            tab.rest()
            // Prefer the most recent loose tab, so ⌘W doesn't bounce between pins.
            let awake = tabs.filter { $0.id != tab.id && !$0.asleep }
            let loose = awake.filter { !$0.held }
            if let back = (loose.isEmpty ? awake : loose).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else {
                newTab()
            }
            writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            guard !tab.isStart else {
                NSApp.keyWindow?.performClose(nil)
                return
            }
            remember(tab, at: 0)
            tab.close()
            let fresh = Tab()
            prepare(fresh)
            tabs = [fresh]
            activeID = fresh.id
            field.clear()
            return
        }

        remember(tab, at: index)
        tab.close()
        unsplit(tab: tab.id)
        reorder { $0.remove(tab.id) }
        if activeID == tab.id,
            let next = (prefs.closeGoesBack ? recentlyUsed() : nil) ?? row.successor(ofRemovedAt: index).flatMap(self.tab)
        {
            // Through select(), so a waiting tab wakes.
            select(next)
        }
        saveSoon()
    }

    /// Takes a tab out of the row without closing it, for another space to
    /// have. The last tab is replaced by a blank one.
    @discardableResult
    func detach(_ tab: Tab) -> Bool {
        guard let index = row.index(of: tab.id) else { return false }
        if floating == tab.id { land() }
        if editingPin == tab.id { editingPin = nil }
        unsplit(tab: tab.id)
        if tabs.count == 1 {
            let fresh = Tab()
            prepare(fresh)
            tabs = [fresh]
            activeID = fresh.id
            field.clear()
            return true
        }
        reorder { $0.remove(tab.id) }
        if activeID == tab.id, let next = row.successor(ofRemovedAt: index).flatMap(self.tab) { select(next) }
        saveSoon()
        return true
    }

    /// Closes every other tab; pinned ones are put to rest instead.
    func closeOthers(but keep: Tab) {
        select(keep)
        for tab in tabs where tab.id != keep.id { close(tab) }
        select(keep)
    }

    /// ⌘⇧T.
    func reopen() {
        if let ghost = closed.last { reopen(ghost) }
    }

    /// Reopens a closed tab where it was.
    func reopen(_ ghost: Ghost) {
        closed.remove(ghost.id)
        let tab = Tab()
        prepare(tab)
        reorder { $0.insert(tab, at: ghost.index) }
        bringForward(tab)
        tab.go(to: ghost.url)
    }

    /// The tab used last, as Zen goes to on closing one: awake ones first,
    /// so closing doesn't wake a page that was resting.
    private func recentlyUsed() -> Tab? {
        let awake = tabs.filter { !$0.asleep }
        return (awake.isEmpty ? tabs : awake).max { $0.touched < $1.touched }
    }

    private func remember(_ tab: Tab, at index: Int) {
        guard !tab.shy, let url = tab.address else { return }
        closed.push(Ghost(url: url, title: tab.title, index: index))
    }

    /// Replaces a tab when it crosses between the web and extension pages
    /// (an extension page sending its tab to a website, say). WebKit keeps a
    /// web view made for an extension to that extension's pages, so the load
    /// would otherwise fail silently.
    func replace(_ tab: Tab, going url: URL) {
        let page = Browser.extensionConfiguration(for: url)
        let fresh =
            if tab.shy {
                // A private tab stays private; leaving an extension page, whose
                // store is the extension's, needs a new private store.
                Tab(
                    shy: true, bench: tab.bench,
                    configuration: page ?? Web.configuration(shy: true, store: tab.store.isPersistent ? nil : tab.store))
            } else {
                Tab(bench: tab.bench, configuration: page)
            }
        prepare(fresh)
        // The tab continues, so it keeps its panel's open state; the chat
        // itself is not carried (the replacement tab starts one), which matches
        // the window-wide flag this state replaced.
        fresh.chatOpen = tab.chatOpen
        reorder { $0.replace(tab.id, with: fresh) }
        fresh.go(to: url)
        if activeID == tab.id { activeID = fresh.id }
        tab.close()
        saveSoon()
    }

    /// Replaces a blank tab with one for an extension's new tab page, which
    /// needs a web view made from the extension's configuration.
    func replaceBlank(_ tab: Tab, with url: URL) {
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        reorder { $0.replace(tab.id, with: page) }
        page.go(to: url)
        if activeID == tab.id {
            activeID = page.id
            editing = false
        }
    }

    // MARK: - Pinning and naming

    /// Add to Essentials.
    func pin(_ tab: Tab) {
        if tab.pin == nil {
            unsplit(tab: tab.id)
            if !tab.held { tab.home = tab.pending ?? tab.address }
            tab.pin = tab.monogram
            tab.kept = false
            tab.folder = nil
            reorder { $0.settle(tab.id) }
        }
        writeSession(now: true)
    }

    /// Pin Tab: a row of its own under the essentials.
    func keep(_ tab: Tab) {
        if !tab.kept || tab.pin != nil {
            if editingPin == tab.id { editingPin = nil }
            unsplit(tab: tab.id)
            if !tab.held { tab.home = tab.pending ?? tab.address }
            tab.pin = nil
            tab.kept = true
            reorder { $0.settle(tab.id) }
        }
        writeSession(now: true)
    }

    func unkeep(_ tab: Tab) {
        tab.kept = false
        tab.folder = nil
        tab.home = nil
        reorder { $0.settle(tab.id) }
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        if !tab.held { tab.home = nil }
        reorder { $0.settle(tab.id) }
        writeSession(now: true)
    }

    /// Back to Pinned Page: an essential or pinned tab home again.
    func goHome(_ tab: Tab) {
        guard let home = tab.home else { return }
        if activeID != tab.id { select(tab) }
        go(tab, to: home)
    }

    /// Replace Pinned Page with Current: where the tab is becomes its home,
    /// in every window.
    func moveHome(_ tab: Tab) {
        guard tab.held, let here = tab.pending ?? tab.address else { return }
        tab.home = here
        writeSession(now: true)
    }

    /// Change Letter, or a double-click on a pinned tab.
    func editLetter(_ tab: Tab) {
        if tab.pin != nil { editingPin = tab.id }
    }

    /// The first typed character becomes the letter; nothing typed keeps it.
    func letter(_ typed: String, for tab: Tab) {
        if let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first { tab.pin = String(first).uppercased() }
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
    }

    /// Starts renaming with the current label; an empty name brings back the
    /// page title.
    func beginTabRename(_ tab: Tab) {
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let tab = editingTab.flatMap(tab) else { return }
        let name = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = name.isEmpty ? nil : name
        cancelTabEdit()
        writeSession(now: true)
    }

    func cancelTabEdit() {
        editingTab = nil
        tabDraft = ""
    }

    /// A click elsewhere keeps the name, as Return would.
    func finishTabEdit() {
        if editingTab != nil { commitTabEdit() }
    }

    // MARK: - Extension pages

    /// Moves an extension URL from the old scheme to chrome-extension://;
    /// other URLs come back unchanged.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.unpopped(Extensions.current(url)) }
        return url
    }

    /// The extension a URL belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The web view configuration an extension page needs (extension pages
    /// are only served to web views made from it), or nil for the web.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: - Wiring a tab

    /// Makes this window the tab's owner and delegate.
    func prepare(_ tab: Tab) {
        tab.delegate = self
        tab.owner = self
        tab.$pageColor.dropFirst().sink { [weak self, weak tab] _ in
            if self?.activeID == tab?.id { self?.objectWillChange.send() }
        }.store(in: &bag)
        tab.$failure.dropFirst().sink { [weak self, weak tab] _ in
            if self?.activeID == tab?.id { self?.objectWillChange.send() }
        }.store(in: &bag)
        tab.$address.dropFirst().sink { [weak self] _ in self?.saveSoon() }.store(in: &bag)
        tab.$media.dropFirst().sink { [weak self] _ in self?.notePlayingSoon() }.store(in: &bag)
        tab.$noisy.dropFirst().sink { [weak self] _ in self?.notePlayingSoon() }.store(in: &bag)
        // The panel's open state lives on the tab, but the chrome, the toolbar
        // and the menu read it through this object (`chatting`); pass the tab's
        // changes on so they redraw when the active tab's panel opens or closes.
        tab.$chatOpen.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        tab.$title.dropFirst()
            .sink { [weak self, weak tab] title in
                guard let tab, !tab.shy, let url = tab.address else { return }
                self?.history.retitle(url, title)
            }
            .store(in: &bag)
    }

    // MARK: - Messages

    func announce(_ text: String) { announce(Announcement(text)) }

    /// Shows a message for a moment: longer when it has something to do or
    /// more to say, and for as long as the pointer rests on it.
    func announce(_ message: Announcement) {
        announcer.showing = message
        hushLater()
    }

    /// An update, with the way to Settings › About, where it's handled.
    func tell(_ news: Updater.News) {
        let settings = Announcement.Action(title: "Open Settings") { [weak self] in self?.openSettings(at: .about) }
        switch news {
        case .out(let release):
            announce(
                Announcement(
                    "Mote \(release.version) is here", detail: release.notes ?? "See its status in Settings.", symbol: "sparkles",
                    action: settings))
        case .ready(let release):
            announce(
                Announcement(
                    "Mote \(release.version) is ready", detail: "It takes over the next time you open Mote.", symbol: "checkmark.seal",
                    action: settings))
        case .manual(let release):
            announce(
                Announcement(
                    "Mote \(release.version) is here", detail: "This copy can't update itself; Settings has the download.",
                    symbol: "arrow.down.circle", action: settings))
        }
    }

    /// Settings, on the given page, even if it's open on another.
    func openSettings(at page: SettingsPage) {
        Storage.settings.set(page.rawValue, forKey: "settings.page")
        guard tuning else { return tuning = true }
        tuning = false
        DispatchQueue.main.async { [weak self] in self?.tuning = true }
    }

    /// The pointer on the message holds it; leaving lets it go.
    func holdAnnouncement(_ held: Bool) {
        hush?.cancel()
        if !held { hushLater() }
    }

    func dismissAnnouncement() {
        hush?.cancel()
        announcer.showing = nil
    }

    private func hushLater() {
        guard let showing = announcement else { return }
        hush?.cancel()
        hush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(showing.lasts))
            if !Task.isCancelled, self?.announcement == showing { self?.announcer.showing = nil }
        }
    }

    /// Ends the first-launch setup and hands the keyboard to the address field.
    func finishWelcome() {
        prefs.welcomed = true
        withAnimation(Motion.settle) { welcoming = false }
        field.askFocus()
    }
}

// MARK: - What tabs report

extension Browser: TabOwner {
    func tab(_ tab: Tab, hovers link: String?) {
        if prefs.showsLinks, tab.id == activeID { linkStatus.show(link, over: tab.built) }
    }

    /// The announcement line doubles as the zoom level.
    func tab(_ tab: Tab, zoomedTo level: CGFloat) {
        let percent = Int((level * 100).rounded())
        guard percent != zoomShown else { return }
        zoomShown = percent
        announce("\(percent)%")
    }

    func tab(_ tab: Tab, hid selector: String, label: String, note: String) { hide(selector, label: label, note: note, in: tab) }
    func tabStoppedPicking(_ tab: Tab) { pickingElement = false }
    func tab(_ tab: Tab, couldNotHide reason: String) { announce("Couldn't hide that — \(reason)") }

    func tab(_ tab: Tab, focusedSignInAt spot: CGRect?) {
        logins.fieldFocused(in: tab, at: spot, listing: prefs.fillsPasswords && tab.id == activeID)
    }

    func tab(_ tab: Tab, signedIn sent: SentSignIn) {
        guard prefs.savesPasswords, !tab.shy else { return }
        // A password manager extension has taken over saving.
        if #available(macOS 15.4, *), Extensions.shared.passwordSavingTakenBy != nil { return }
        logins.signedIn(host: sent.host, user: sent.user, password: sent.password, clear: sent.clear)
    }

    func tab(_ tab: Tab, openedImageMenuFor image: URL) { showImageMenu(for: tab, at: image) }

    /// Searches from a private tab stay private.
    func tab(_ tab: Tab, searches text: String) {
        if let url = searchURL(for: text) { open(url, foreground: true, from: tab) }
    }

    var searchEngineName: String? { prefs.engine.name(custom: prefs.customEngine) }
    func tabAddsFromStore(_ tab: Tab) { addFromStore(tab) }
    func tab(_ tab: Tab, middleClicked link: URL) { open(link, foreground: false, from: tab) }
    func tabPressed(_ tab: Tab) { if tab.id != activeID, shownSplit?.contains(tab.id) == true { select(tab) } }
    func tab(_ tab: Tab, crosses url: URL) { replace(tab, going: url) }
}
