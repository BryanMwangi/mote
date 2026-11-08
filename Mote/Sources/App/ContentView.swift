import AppKit
import MoteCore
import SwiftUI

/// The window's content: the chrome and page, with the folded tabs, the
/// notices at the bottom, the ⌘K switcher and the panels over them.
struct ContentView: View {
    @ObservedObject var browser: Browser

    @State private var window: NSWindow?
    @State private var keys = KeyRouter()
    @Environment(\.openWindow) private var openWindow

    /// Runs a key through the window's shortcuts, for the bench.
    static var keyHook: ((NSEvent) -> NSEvent?)?

    /// The switcher, or the floating search, over a page; a blank tab
    /// switches in its own composer.
    private var switching: Bool {
        (browser.field.switching || browser.field.launching || browser.field.relocating) && browser.active?.isStart == false
    }

    var body: some View {
        Chrome(browser: browser, prefs: browser.prefs)
            .overlay(alignment: .leading) { SidebarFold(browser: browser, prefs: browser.prefs) }
            .background { ToolbarReveal(browser: browser, prefs: browser.prefs) }
            .overlay(alignment: .bottom) { Notices(browser: browser) }
            .overlay { Toast(announcer: browser.announcer, browser: browser) }
            .overlay {
                if switching { Omnibox(browser: browser) }
            }
            .overlay { panels }
            // In on a spring, out quickly.
            .animation(switching ? Motion.settle : Motion.quick, value: switching)
            .background(
                WindowSetup {
                    window = $0
                    browser.window = $0
                    WindowDressing.dress($0, main: !browser.extra, id: browser.windowID)
                    $0.touchBar = browser.touchBarItems.make()
                    arrive()
                }
            )
            .onChange(of: browser.welcoming) { _, on in if on { arrive() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                // This window's browser only, so other windows' videos stay put.
                browser.appLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                browser.appBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let window, note.object as? NSWindow === window else { return }
                Browser.front = browser
                Spaces.current = browser.spaceID
                if #available(macOS 15.4, *) { Extensions.shared.focused(browser) }
                // The bench's keys go to the window in front.
                Self.keyHook = { [keys] in keys.route($0) }
            }
            .onChange(of: browser.fieldShowing) { _, showing in
                if showing { Task { @MainActor in browser.field.askFocus() } } else { keyboardToPage() }
            }
            .onChange(of: browser.activeID) { old, _ in
                keyboardToPage()
                // The page leaving gets its pointer back; the one coming in is covered as the window is.
                old.flatMap { browser.tab($0) }?.built?.cover(false)
                browser.active?.built?.cover(browser.pageCovered)
            }
            .onChange(of: browser.pageCovered) { _, covered in browser.active?.built?.cover(covered) }
            // The boost editor: a frosted panel at the window's top right, over the page.
            .onChange(of: browser.boosting) { _, site in
                FrostedPanel.close("boost")
                guard let site, let window else { return }
                FrostedPanel.show(
                    "boost", BoostEditor(browser: browser, site: site), over: window,
                    at: NSPoint(x: window.frame.maxX - 296, y: window.frame.maxY - 56)
                ) { if browser.boosting == site { browser.boosting = nil } }
            }
            // Theme…: a frosted panel beside the sidebar.
            .onChange(of: browser.themingSpace) { _, space in
                guard let space, let window else { return FrostedPanel.close("theme") }
                let prefs = browser.prefs
                let x =
                    prefs.sidebar && !prefs.sideRight ? window.frame.minX + prefs.sideWidth + 16 : window.frame.maxX - prefs.sideWidth - 316
                FrostedPanel.show(
                    "theme", ThemeEditor(browser: browser, space: space), over: window, at: NSPoint(x: x, y: window.frame.maxY - 56)
                ) { browser.themingSpace = nil }
            }
            .animation(Motion.settle, value: browser.recalling)
            .animation(Motion.settle, value: browser.showingDownloads)
            .animation(Motion.settle, value: browser.showingProcesses)
            .animation(Motion.settle, value: browser.welcoming)
            .animation(Motion.settle, value: browser.bookmarking)
            .animation(Motion.settle, value: browser.logins.managing)
            .onAppear {
                keys.start(for: browser)
                Self.keyHook = { [keys] in keys.route($0) }
                browser.field.askFocus()
                Windows.shared.opener = { [openWindow] in openWindow(id: "window", value: $0) }
                // The rest belongs to the main window, as before there were others.
                guard !browser.extra else { return }
                Windows.shared.main = browser
                // The windows open at the last quit come back beside it.
                Windows.shared.restore()
                AppDelegate.hand(to: browser)
                SettingsWindow.watch(browser)
                BookmarkMenu.shared.start(for: browser)
            }
            // A window opened since the main one takes its tabs with it.
            .onDisappear { Windows.shared.closed(browser) }
            .focusedSceneObject(browser)
            // The space's own look, through SwiftUI: it owns the window's
            // appearance and puts back anything set on the window directly.
            .preferredColorScheme(browser.spaceScheme)
            .environment(\.spaceTint, browser.spaceTint)
            .background(TranslationHost(browser: browser))
    }

    @ViewBuilder
    private var panels: some View {
        if browser.recalling {
            Sheet(close: { browser.recalling = false }) { LibraryShelf(browser: browser) { HistoryPanel(browser: browser) } }
        }
        if browser.showingDownloads {
            Sheet(close: { browser.showingDownloads = false }) {
                LibraryShelf(browser: browser) { DownloadsPanel(browser: browser, downloads: browser.downloads) }
            }
        }
        if browser.showingProcesses {
            Sheet(close: { browser.showingProcesses = false }) { ProcessesPanel(browser: browser) }
        }
        if browser.bookmarking {
            Sheet(close: { browser.bookmarking = false }) {
                LibraryShelf(browser: browser) { BookmarksPanel(browser: browser, bookmarks: browser.bookmarks) }
            }
        }
        if browser.welcoming, !browser.arriving {
            WelcomeInWindow(browser: browser)
        }
        if browser.importing {
            Sheet(close: { browser.importing = false }) { ImportPanel(browser: browser) }
        }
        if browser.logins.managing {
            Sheet(close: { browser.logins.managing = false }) { PasswordsPanel(logins: browser.logins) }
        }
    }

    /// Gives the keyboard back to the page when the address field goes: keys
    /// would otherwise go nowhere, and passkeys and pages' own key handling
    /// need a focused document.
    private func keyboardToPage() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        Task { @MainActor in
            // A double-click's second click may have begun a rename since.
            guard !browser.fieldShowing, browser.editingTab == nil else { return }
            if let page = browser.active?.web, let window = page.window { window.makeFirstResponder(page) }
        }
    }

    /// The arrival, when the welcome starts (see Arrival.swift).
    private func arrive() {
        guard browser.welcoming, !browser.arriving, let window, #available(macOS 15, *) else { return }
        browser.arriving = Arrival.play(over: window, setup: browser) { browser.arriving = false }
    }
}

/// A panel over a dimmed window; a click on the dimming closes it.
private struct Sheet<Panel: View>: View {
    let close: () -> Void
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        ZStack {
            ArrowCursor().frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
            Color.black.opacity(0.10).ignoresSafeArea().onTapGesture(perform: close)
            panel().transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }
}

/// An arrow pointer over panels. WebKit does `cursor: none` with an AppKit
/// cursor rect over the whole page, and SwiftUI overlays add none of their
/// own, so without this the pointer stays hidden over a panel.
private struct ArrowCursor: FillsRoom {
    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Area: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

        // Asked again as it moves or resizes, so it applies before the pointer moves.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}
