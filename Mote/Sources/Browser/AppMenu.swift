import MoteCore
import SwiftUI

/// The "…" at the end of the toolbar (or the sidebar's top, with the toolbar
/// hidden), as Zen's app menu: windows, the library, the page and zoom in
/// reach, without the menu bar.
struct AppMenuButton: View {
    let browser: Browser
    @State private var open = false

    /// The bench opens the menu (test runs).
    static let ask = Notification.Name("MoteAppMenu")

    var body: some View {
        Door(icon: "ellipsis", on: open, help: "Mote") { open.toggle() }
            .menuPanel(isPresented: $open, edge: .bottom) { AppMenu(browser: browser) { open = false } }
            .onReceive(NotificationCenter.default.publisher(for: Self.ask)) { note in open = note.object as? Bool ?? true }
    }
}

private struct AppMenu: View {
    let browser: Browser
    let close: () -> Void
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var profiles = Profiles.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            update
            if !profiles.list.isEmpty {
                AppLine(symbol: "person.crop.circle", title: "Open Profile", more: true) {
                    popUp(
                        [ActionItem("Default") { profiles.open(nil) }]
                            + profiles.list.map { profile in ActionItem(profile.name) { profiles.open(profile.id) } })
                }
                AppRule()
            }
            line("plus.square", .newTab)
            line("macwindow", .newWindow)
            line("eyeglasses", .newPrivateWindow)
            AppRule()
            line("clock.arrow.circlepath", .history)
            AppLine(symbol: "book", title: "Bookmarks") { closing { browser.bookmarking = true } }
            line("arrow.down.circle", .downloads)
            line("key", .passwords)
            AppLine(symbol: "puzzlepiece.extension", title: "Extensions") { closing { browser.openSettings(at: .extensions) } }
            AppRule()
            Group {
                line("printer", .print)
                line("square.and.arrow.down", .savePage)
                AppLine(symbol: "translate", title: "Translate Page…") {
                    closing { if let tab = browser.active { browser.toggleTranslation(tab) } }
                }
                .disabled(browser.active?.pageLanguage == nil && browser.active?.translated != true)
                line("doc.text.magnifyingglass", .find)
            }
            .disabled(browser.active?.isBlank != false)
            Zoom(browser: browser)
            AppRule()
            line("gearshape", .settings)
            AppLine(symbol: "wrench.and.screwdriver", title: "More Tools", more: true) {
                popUp(
                    [ShortcutID.screenshot, .inspector, .console, .viewSource, .responsive, .processes].map { id in
                        ActionItem(id.title, key: "") { browser.perform(id) }
                    })
            }
            AppLine(symbol: "info.circle", title: "About Mote") { closing { NSApp.orderFrontStandardAboutPanel(nil) } }
        }
        .padding(6)
        .frame(width: 280)
    }

    /// An update waiting to install, or installed for next time.
    @ViewBuilder private var update: some View {
        switch updater.stage {
        case .waiting, .offered:
            AppLine(symbol: "arrow.up.circle.fill", title: "Update available — install now") { closing(updater.install) }
            AppRule()
        case .ready:
            AppLine(symbol: "checkmark.circle.fill", title: "Updated — it opens next launch") {}
            AppRule()
        default: EmptyView()
        }
    }

    private func line(_ symbol: String, _ id: ShortcutID) -> some View {
        AppLine(symbol: symbol, title: id.title, keys: browser.prefs.shortcuts.combos(for: id).first?.text) {
            closing { browser.perform(id) }
        }
    }

    /// A submenu, beside the pointer; the menu closes as it opens.
    private func popUp(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        menu.items = items
        close()
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    private func closing(_ then: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: then)
    }
}

private struct AppLine: View {
    let symbol: String
    let title: String
    var keys: String?
    var more = false
    var act: (() -> Void)?
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(symbol: String, title: String, keys: String? = nil, more: Bool = false, act: (() -> Void)? = nil) {
        (self.symbol, self.title, self.keys, self.more, self.act) = (symbol, title, keys, more, act)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7)).frame(width: 18)
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if let keys { Text(keys).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            if more { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted) }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(hovering && enabled ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .onTapGesture { act?() }
        .onHover { hovering = $0 }
    }
}

private struct AppRule: View {
    var body: some View { Divider().overlay(Palette.hairline).padding(.vertical, 4).padding(.horizontal, 6) }
}

/// − 100% + and full screen, for the page in front.
private struct Zoom: View {
    let browser: Browser

    var body: some View {
        if let tab = browser.active { Steps(browser: browser, tab: tab) }
    }

    private struct Steps: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.7)).frame(width: 18)
                Text("Zoom").font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Door(icon: "minus", help: "Zoom Out") { browser.zoom(by: 1 / 1.1) }
                    Button(action: browser.resetZoom) {
                        Text("\(Int((tab.zoom * 100).rounded()))%").font(.system(size: 12)).monospacedDigit().frame(width: 44)
                    }
                    .buttonStyle(.plain)
                    Door(icon: "plus", help: "Zoom In") { browser.zoom(by: 1.1) }
                    Divider().frame(height: 16)
                    Door(icon: "arrow.up.left.and.arrow.down.right", help: "Full Screen") { browser.window?.toggleFullScreen(nil) }
                }
            }
            .padding(.leading, 10)
            .frame(height: 32)
            .disabled(tab.isBlank)
        }
    }
}
