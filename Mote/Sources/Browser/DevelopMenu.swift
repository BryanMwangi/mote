import AppKit
import MoteCore
import SwiftUI
import WebKit

// The Develop menu (Settings › General › Show Develop menu): the page in
// another browser, another user agent, and the Web Inspector's commands,
// which View carries while the menu is off.

/// The inspector's commands, in View or in Develop.
struct InspectorItems: View {
    @ObservedObject var browser: Browser
    let keys: (ShortcutID) -> KeyboardShortcut?

    private var blank: Bool { browser.active?.isBlank ?? true }

    var body: some View {
        Button("Web Inspector", action: browser.toggleInspector).keyboardShortcut(keys(.inspector))
        Button("JavaScript Console", action: browser.showConsole).keyboardShortcut(keys(.console))
        Button("Inspect Element", action: browser.inspectElement).keyboardShortcut(keys(.inspectElement))
        Button("Network") { browser.showInspector(.network) }.keyboardShortcut(keys(.inspectNetwork)).disabled(blank)
        Button("Sources") { browser.showInspector(.sources) }.keyboardShortcut(keys(.inspectSources)).disabled(blank)
        Button("Storage") { browser.showInspector(.storage) }.keyboardShortcut(keys(.inspectStorage)).disabled(blank)
        Button("View Page Source") { if let tab = browser.active { browser.viewSource(of: tab) } }
            .keyboardShortcut(keys(.viewSource)).disabled(blank)
        Button("Switch Text Direction", action: browser.switchTextDirection).keyboardShortcut(keys(.textDirection)).disabled(blank)
        Button("About Processes…") { browser.showingProcesses = true }.keyboardShortcut(keys(.processes))
        Button("Responsive Design Mode", action: browser.toggleResponsive).keyboardShortcut(keys(.responsive))
            .disabled(blank)
    }
}

/// Develop's own items, above the inspector's.
struct DevelopItems: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Menu("Open Page With") {
            ForEach(OtherBrowsers.listed, id: \.url) { app in
                Button(app.title) { browser.openPage(with: app.url) }
            }
        }
        .disabled(browser.active?.address == nil)
        if let tab = browser.active {
            UserAgentMenu(tab: tab)
        }
        Divider()
    }
}

/// Develop › User Agent, for the tab in front.
private struct UserAgentMenu: View {
    @ObservedObject var tab: Tab
    /// Responsive Design Mode's devices, the user's own among them.
    @ObservedObject private var devices = DeviceList.shared
    private static let presets = UserAgents.presets(safari: Web.installedSafari)

    /// The presets, then each listed device whose user agent isn't one of them.
    private var groups: [[UserAgents.Preset]] {
        var seen = Set(Self.presets.joined().map(\.value))
        let listed = devices.menu.filter { !$0.userAgent.isEmpty && seen.insert($0.userAgent).inserted }
        return Self.presets + [listed.map { UserAgents.Preset(title: $0.name, value: $0.userAgent) }].filter { !$0.isEmpty }
    }

    var body: some View {
        Menu("User Agent") {
            pick("Default (Automatically Chosen)", nil)
            let groups = groups
            ForEach(groups.indices, id: \.self) { group in
                Divider()
                ForEach(groups[group], id: \.title) { pick($0.title, $0.value) }
            }
            Divider()
            Toggle("Other…", isOn: Binding(get: { other }, set: { _ in askOther() }))
        }
    }

    private func pick(_ title: String, _ value: String?) -> some View {
        Toggle(title, isOn: Binding(get: { tab.userAgent == value }, set: { _ in tab.userAgent = value }))
    }

    /// A user agent typed in, not one of the list's.
    private var other: Bool {
        guard let mine = tab.userAgent else { return false }
        return !groups.joined().contains { $0.value == mine }
    }

    private func askOther() {
        let alert = NSAlert()
        alert.messageText = "Custom User Agent"
        alert.informativeText = "This tab sends it from its next load. Empty goes back to Mote's own."
        let field = NSTextField(string: tab.userAgent ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        field.placeholderString = "Mozilla/5.0 …"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.userAgent = typed.isEmpty ? nil : typed
    }
}

/// Open Page With's icons.
@MainActor
enum DevelopMenuIcons {
    static let shared = MenuBarAdditions(
        find: { NSApp.mainMenu?.items.first { $0.title == "Develop" }?.submenu?.items.first { $0.title == "Open Page With" }?.submenu },
        after: { menu in
            let icons = Dictionary(OtherBrowsers.listed.map { ($0.title, $0.icon) }) { first, _ in first }
            for item in menu.items { item.image = icons[item.title] }
        })
}

/// The other apps on this Mac that open web pages.
enum OtherBrowsers {
    struct App {
        let url: URL
        let title: String
        let icon: NSImage
    }

    /// Asked once a launch: Launch Services looks through every app.
    @MainActor static let listed: [App] = {
        guard let page = URL(string: "https://example.com") else { return [] }
        let mine = Bundle.main.bundleURL.standardizedFileURL
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: page).filter { $0.standardizedFileURL != mine }
        let named = apps.map { url -> (URL, String) in
            let info = Bundle(url: url)?.infoDictionary
            let name =
                info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            let version = (info?["CFBundleShortVersionString"] as? String).map { " (\($0))" } ?? ""
            return (url, name + version)
        }
        // Copies of one app are told apart by where they are, as Safari does.
        let counts = Dictionary(grouping: named, by: \.1).mapValues(\.count)
        return named.map { url, title in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            let place = counts[title, default: 0] > 1 ? " — \(url.deletingLastPathComponent().path)" : ""
            return App(url: url, title: title + place, icon: icon)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()
}

extension Browser {
    /// Develop › Open Page With: the page in front, in another browser.
    func openPage(with app: URL) {
        guard let page = active?.address else { return }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Develop › Empty Caches: every open tab's store forgets what it cached,
    /// and keeps sign-ins and site data.
    func emptyCaches() {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        let stores = Set(tabs.compactMap { $0.built?.configuration.websiteDataStore })
        let group = DispatchGroup()
        for store in stores {
            group.enter()
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in self?.announce("Caches emptied") }
    }
}
