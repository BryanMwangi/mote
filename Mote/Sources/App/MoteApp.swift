import AppKit
import MoteCore
import SwiftUI

@main
struct MoteApp: App {
    @StateObject private var browser = Browser()
    /// Links from other apps and reopening from the Dock.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var links

    var body: some Scene {
        Window("Mote", id: "browser") {
            ContentView(browser: browser).frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        // No "Mote" item of its own in the Window menu: every window is listed
        // there by its tab in front (Browser.followTitle), and the Dock brings
        // the main one back.
        .commandsRemoved()
        .commands { MenuBar(main: browser, visits: browser.history) }

        // Windows opened since the main one (⌘N, a link), each with its own
        // browser (Windows.swift). They come back at launch through the
        // session, not macOS.
        WindowGroup(id: "window", for: UUID.self) { $id in
            if let id, let browser = Windows.shared.browser(for: id) {
                ContentView(browser: browser).frame(minWidth: 640, minHeight: 420)
            } else {
                // One macOS brought back from a past launch, with no browser behind it.
                WindowSetup { $0.close() }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
    }
}

/// The menu bar, for the window in front, or the main one.
private struct MenuBar: Commands {
    @ObservedObject var main: Browser
    @FocusedObject private var focused: Browser?
    /// For Recently Visited; the browser doesn't pass on its changes.
    @ObservedObject var visits: History

    private var browser: Browser { focused ?? main }

    private var blank: Bool { browser.active?.isBlank ?? true }

    /// A command's key as the user has it (Settings › Keyboard), or none.
    private func keys(_ id: ShortcutID) -> KeyboardShortcut? {
        browser.prefs.shortcuts.combos(for: id).first.map(\.keyboardShortcut)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab", action: browser.newTab).keyboardShortcut(keys(.newTab))
            Button("New Window") { Windows.shared.open(space: browser.spaceID) }.keyboardShortcut(keys(.newWindow))
            Button("New Private Window") { Windows.shared.open(private: true) }.keyboardShortcut(keys(.newPrivateWindow))
            Button("New Private Tab", action: browser.newShyTab).keyboardShortcut(keys(.newPrivateTab))
            Button("Reopen Closed Tab") { browser.reopen() }.keyboardShortcut(keys(.reopenTab)).disabled(
                browser.ghosts.isEmpty)
            Button("Reopen Closed Window") { Windows.shared.reopenClosed() }.disabled(!Windows.shared.canReopen)
            Divider()
            Button("Open Address…", action: browser.edit).keyboardShortcut(keys(.editAddress))
            Button("Open File…", action: browser.openFile).keyboardShortcut(keys(.openFile))
            Divider()
            Button("Close Tab") { if let tab = browser.active { browser.close(tab) } }.keyboardShortcut(keys(.closeTab))
        }
        CommandGroup(replacing: .printItem) {
            Button("Share…", action: browser.share).disabled(blank)
            Button("Save Page As…", action: browser.savePage).keyboardShortcut(keys(.savePage)).disabled(blank)
            Button("Take Screenshot…") { browser.startScreenshot() }.keyboardShortcut(keys(.screenshot))
                .disabled(blank)
            Button("Take Screenshot of Whole Page") { browser.active?.screenshot(.wholePage) }.disabled(blank)
            Button("Copy Screenshot") { browser.active?.screenshot(copy: true) }.disabled(blank)
            Button("Print…", action: browser.printPage).keyboardShortcut(keys(.print)).disabled(blank)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find on Page…", action: browser.openFind).keyboardShortcut(keys(.find)).disabled(blank)
            Button("Find Next") { browser.finder.look(forward: true) }.keyboardShortcut(keys(.findNext)).disabled(!browser.finder.showing)
            Button("Find Previous") { browser.finder.look(forward: false) }.keyboardShortcut(keys(.findPrevious))
                .disabled(!browser.finder.showing)
        }
        CommandGroup(replacing: .toolbar) { view }
        CommandMenu("Tabs") { tabs }
        CommandMenu("Bookmarks") {
            Button("Add This Page", action: browser.bookmarkCurrent).keyboardShortcut(keys(.bookmark)).disabled(blank)
            Button("Show Bookmarks…") { browser.bookmarking = true }
            Toggle(
                "Show Bookmarks Bar",
                isOn: Binding(
                    get: { browser.prefs.bookmarksBar }, set: { on in withAnimation(Motion.glide) { browser.prefs.bookmarksBar = on } }))
            // The bookmarks themselves are added by AppKit (see BookmarkMenu).
        }
        CommandMenu("History") { history }
        CommandGroup(after: .appSettings) {
            Button("Settings…") { browser.tuning = true }.keyboardShortcut(keys(.settings))
            Button("Welcome…") { browser.welcoming = true }
            Button("Passwords…") { browser.logins.managing = true }.keyboardShortcut(keys(.passwords))
            // Another profile, as its own Mote (see Profiles).
            Menu("Open Profile") {
                ForEach([nil] + Profiles.shared.list.map(\.id), id: \.self) { id in
                    Button {
                        Profiles.shared.open(id)
                    } label: {
                        Label { Text(Profiles.shared.name(of: id)) } icon: { Image(nsImage: Profiles.shared.image(of: id, size: 16)) }
                    }
                    .disabled(Storage.profile == id)
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { AppDelegate.writeFeedback() }
        }
    }

    @ViewBuilder
    private var view: some View {
        Toggle("Show Tabs in Sidebar", isOn: Binding(get: { browser.prefs.sidebar }, set: { _ in browser.toggleSidebar() }))
            .keyboardShortcut(keys(.toggleSidebar))
        // Folds the sidebar or strip away (see SidebarFold).
        Button("\(browser.folded ? "Show" : "Hide") \(browser.prefs.sidebar ? "Sidebar" : "Tab Bar")", action: browser.toggleFold)
            .keyboardShortcut(keys(.foldTabs))
        Button("Compact Mode", action: browser.toggleCompact).keyboardShortcut(keys(.compactMode))
        Button(browser.prefs.toolbarMode == .shown ? "Toolbar on Hover" : "Always Show Toolbar", action: browser.toggleToolbar)
            .keyboardShortcut(keys(.toggleToolbar))
        if browser.usesSpaces {
            Button("Previous Space") { browser.stepSpace(-1) }.keyboardShortcut(keys(.previousSpace))
            Button("Next Space") { browser.stepSpace(1) }.keyboardShortcut(keys(.nextSpace))
        }
        Picker("Tabs Wear", selection: Binding(get: { browser.prefs.glyph }, set: { browser.prefs.glyph = $0 })) {
            ForEach(Glyph.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Reload Page", action: browser.reload).keyboardShortcut(keys(.reload))
        Button("Reload Skipping Cache", action: browser.reloadFromOrigin).keyboardShortcut(keys(.reloadFromOrigin))
            .disabled(blank)
        Button("Reading Mode", action: browser.toggleReader).keyboardShortcut(keys(.reader))
        Button("Float Video", action: browser.toggleFloat).keyboardShortcut(keys(.floatVideo))
        Toggle(
            "Chat about This Page",
            isOn: Binding(get: { browser.chatting }, set: { _ in browser.togglePageChat() })
        )
        .keyboardShortcut(keys(.pageChat))
        .disabled(!browser.pageChatPossible)
        Divider()
        Button("Boost This Site…", action: browser.boostSite).disabled(blank)
        Button("Hide Elements…", action: browser.toggleHiding).keyboardShortcut(keys(.hideElements))
        Button("Hidden on This Site…") { browser.reviewing.toggle() }.keyboardShortcut(keys(.hiddenElements))
        Divider()
        Button("Zoom In") { browser.zoom(by: 1.1) }.keyboardShortcut(keys(.zoomIn))
        Button("Zoom Out") { browser.zoom(by: 1 / 1.1) }.keyboardShortcut(keys(.zoomOut))
        Button("Actual Size", action: browser.resetZoom).keyboardShortcut(keys(.actualSize))
        Divider()
        // Chrome's shortcuts (see Inspector.swift).
        Button("Web Inspector", action: browser.toggleInspector).keyboardShortcut(keys(.inspector))
        Button("JavaScript Console", action: browser.showConsole).keyboardShortcut(keys(.console))
        Button("Inspect Element", action: browser.inspectElement).keyboardShortcut(keys(.inspectElement))
        Button("Network") { browser.showInspector(.network) }.keyboardShortcut(keys(.inspectNetwork)).disabled(blank)
        Button("Sources") { browser.showInspector(.sources) }.keyboardShortcut(keys(.inspectSources)).disabled(blank)
        Button("Storage") { browser.showInspector(.storage) }.keyboardShortcut(keys(.inspectStorage)).disabled(blank)
        Button("Switch Text Direction", action: browser.switchTextDirection).keyboardShortcut(keys(.textDirection)).disabled(blank)
        Button("About Processes…") { browser.showingProcesses = true }.keyboardShortcut(keys(.processes))
        Button("View Page Source") { if let tab = browser.active { browser.viewSource(of: tab) } }
            .keyboardShortcut(keys(.viewSource)).disabled(blank)
        Button("Responsive Design Mode", action: browser.toggleResponsive).keyboardShortcut(keys(.responsive))
            .disabled(blank)
    }

    @ViewBuilder
    private var tabs: some View {
        Button("Back", action: browser.back).keyboardShortcut(keys(.back)).disabled(!browser.canGoBack)
        Button("Forward", action: browser.forward).keyboardShortcut(keys(.forward)).disabled(browser.active?.canGoForward != true)
        Divider()
        Button("Next Tab") { browser.step(1) }.keyboardShortcut(keys(.nextTab))
        Button("Previous Tab") { browser.step(-1) }.keyboardShortcut(keys(.previousTab))
        Button("Search Tabs…", action: browser.summon).keyboardShortcut(keys(.switcher))
        Divider()
        if let tab = browser.active { TabHoldItems(browser: browser, tab: tab) }
        Button("Rename Tab") { if let tab = browser.active { browser.beginTabRename(tab) } }.disabled(browser.active == nil)
        Button("Duplicate Tab", action: browser.duplicate).keyboardShortcut(keys(.duplicateTab)).disabled(blank)
        Button("Unload Tab", action: browser.unloadActive).keyboardShortcut(keys(.unloadTab))
            .disabled(blank || browser.active?.asleep == true)
        Button("Copy Address", action: browser.copyAddress).keyboardShortcut(keys(.copyAddress)).disabled(blank)
        Button("Copy as Markdown Link", action: browser.copyMarkdownLink).disabled(blank)
        Button("Paste and Go", action: browser.pasteAndGo).keyboardShortcut(keys(.pasteAndGo))
        Divider()
        Button("Close Other Tabs") { if let tab = browser.active { browser.closeOthers(but: tab) } }.disabled(browser.tabs.count < 2)
        Button("Stop Sound in Tab", action: browser.pauseMedia).keyboardShortcut(keys(.pauseSound))
    }

    @ViewBuilder
    private var history: some View {
        Section("Recently Visited") {
            ForEach(browser.recentlyVisited) { place in
                Button {
                    browser.open(place.url, foreground: true)
                } label: {
                    PageMenuItem(title: place.title.isEmpty ? place.key : place.title, url: place.url)
                }
            }
        }
        if !browser.ghosts.isEmpty {
            Section("Recently Closed") {
                ForEach(browser.ghosts.reversed().prefix(10)) { ghost in
                    Button {
                        browser.reopen(ghost)
                    } label: {
                        PageMenuItem(title: ghost.label, url: ghost.url)
                    }
                }
            }
        }
        Divider()
        Button("Show History…") { browser.recalling = true }.keyboardShortcut(keys(.history))
        Button("Library…", action: browser.toggleLibrary).keyboardShortcut(keys(.library))
        Button("Downloads…") { browser.showingDownloads = true }.keyboardShortcut(keys(.downloads))
        Divider()
        Button("Clear History", action: browser.clearHistory)
    }
}

/// A page in a menu: its cached icon, if there is one, and its title.
private struct PageMenuItem: View {
    let title: String
    let url: URL

    var body: some View {
        if let icon {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: icon)
            }
        } else {
            Text(title)
        }
    }

    /// The site's icon at menu size: they're kept at 64 pt, so a copy is resized.
    private var icon: NSImage? {
        guard let host = url.host()?.lowercased(), let cached = Favicons.shared.cached(host), let small = cached.copy() as? NSImage else {
            return nil
        }
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}
