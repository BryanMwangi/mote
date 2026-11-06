import MoteCore
import SwiftUI
import WebKit

/// The page button beside the address, as Zen's site panel: what to do with
/// the page, every extension, the site's settings and how safe it is, in
/// one popover. Extensions' popups hang from it.
struct PageButton: View {
    let browser: Browser
    /// Where the panel opens from.
    var edge: Edge = .bottom

    @State private var open = false

    /// The bench opens the panel (test runs).
    static let ask = Notification.Name("MotePagePanel")

    var body: some View {
        Door(icon: "slider.horizontal.below.rectangle", on: open, help: "Page and Extensions") { open.toggle() }
            .background {
                if #available(macOS 15.4, *) { PopupAnchor(id: Extensions.menuAnchor) }
            }
            .menuPanel(isPresented: $open, edge: edge) { PagePanel(browser: browser) { open = false } }
            .onReceive(NotificationCenter.default.publisher(for: Self.ask)) { note in open = note.object as? Bool ?? true }
    }
}

struct PagePanel: View {
    let browser: Browser
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Tile(symbol: "bookmark", help: "Bookmark this page") { closing(browser.bookmarkCurrent) }
                Tile(symbol: "camera", help: "Take a screenshot") { closing(browser.startScreenshot) }
                Tile(symbol: "doc.plaintext", help: "Reader") { closing(browser.toggleReader) }
                Tile(symbol: "square.and.arrow.up", help: "Share") { closing(browser.share) }
            }
            .disabled(browser.active?.isBlank != false)
            if #available(macOS 15.4, *) { ExtensionGrid(extensions: .shared, close: close) }
            if let tab = browser.active, let host = tab.address?.host(), !tab.isBlank {
                SiteSettings(browser: browser, tab: tab, host: host)
            }
            Divider().overlay(Palette.hairline)
            foot
        }
        .padding(12)
        .frame(width: 292)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var foot: some View {
        HStack(spacing: 6) {
            if let tab = browser.active, !tab.isBlank {
                ConnectionPill(tab: tab) { closing { SiteCardPanel.open(for: tab, in: browser, security: true) } }
                Tile(symbol: "paintbrush", help: "Boost this site", wide: false) { closing(browser.boostSite) }
            }
            Spacer()
            Menu {
                Button("Clear Cookies and Site Data…") { closing { browser.clearSiteData() } }
                    .disabled(browser.active?.address?.host() == nil)
                Divider()
                Button("Manage Extensions") { closing { browser.openSettings(at: .extensions) } }
                Button("Add Extensions") { closing { browser.open(browser.extensionStore, foreground: true) } }
                Divider()
                Button("Page Info…") { closing { if let tab = browser.active { PageInfo.show(for: tab, in: browser) } } }
                    .disabled(browser.active?.isBlank != false)
                Button("All Site Settings") { closing { browser.openSettings(at: .privacy) } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(Palette.wash, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The panel goes first: a sheet or popup opened under it would close with it.
    private func closing(_ then: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: then)
    }
}

/// A square button in the panel.
private struct Tile<Label: View>: View {
    let help: String
    var wide = true
    let act: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    /// Its name, after a moment's hover: the panel never has the keyboard,
    /// and AppKit shows tooltips only in the window that does.
    @State private var naming = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: act) {
            label()
                .frame(maxWidth: wide ? .infinity : 36, minHeight: 36)
                .background(hovering && enabled ? Palette.hover : Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            naming = false
            guard hovering, !help.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.6))
            naming = !Task.isCancelled
        }
        .overlay(alignment: .bottom) {
            if naming {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                    .offset(y: 26)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Over the tiles below it.
        .zIndex(naming ? 1 : 0)
        .animation(Motion.quick, value: naming)
        .opacity(enabled ? 1 : 0.4)
    }
}

extension Tile where Label == AnyView {
    init(symbol: String, help: String, wide: Bool = true, act: @escaping () -> Void) {
        self.init(help: help, wide: wide, act: act) {
            AnyView(Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.8)))
        }
    }
}

/// Every running extension, as Zen's grid: a press opens its popup from the
/// page button; a right-click has the rest.
@available(macOS 15.4, *)
private struct ExtensionGrid: View {
    @ObservedObject var extensions: Extensions
    let close: () -> Void

    var body: some View {
        if !extensions.installed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions").font(TextStyle.caption.font.weight(.semibold)).foregroundStyle(Palette.muted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(extensions.buttons) { button in
                        Tile(help: button.label) {
                            // The panel closes first, so the popup hangs from the page button.
                            close()
                            let id = button.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.press(id) }
                        } label: {
                            ExtensionIcon(button: button, size: 17)
                        }
                        .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
                    }
                    Tile(symbol: "plus", help: "Add extensions") {
                        close()
                        if let browser = extensions.front { browser.open(browser.extensionStore, foreground: true) }
                    }
                }
            }
        }
    }
}

/// What this site may do: ads and trackers, and the camera and microphone
/// when it has asked; its boost, when it has one.
private struct SiteSettings: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let host: String
    @ObservedObject private var boosts = Boosts.shared
    @State private var blocking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings").font(TextStyle.caption.font.weight(.semibold)).foregroundStyle(Palette.muted)
            SettingLine(
                symbol: blocking ? "shield.lefthalf.filled" : "shield.slash", title: "Tracking Protection",
                state: blocking ? "On for this site" : "Off for this site", on: blocking
            ) {
                blocking.toggle()
                AdBlocker.shared.pause(host, !blocking)
                tab.built?.reload()
            }
            ForEach([(WKMediaCaptureType.camera, "camera", "Camera"), (.microphone, "mic", "Microphone")], id: \.1) { type, symbol, title in
                if let allowed = CaptureRequests.remembered(host, type) {
                    SettingLine(
                        symbol: allowed ? symbol : "\(symbol).slash", title: title, state: allowed ? "Allowed" : "Blocked", on: allowed
                    ) {
                        CaptureRequests.remember(host, type, !allowed)
                    }
                }
            }
            if let site = tab.address.map(SiteCard.site), !boosts.boost(for: site).isEmpty {
                SettingLine(symbol: "paintbrush.fill", title: "Boost", state: "Edit how \(site) looks", on: true) { browser.boostSite() }
            }
        }
        .onAppear { blocking = !AdBlocker.shared.isPaused(on: host) }
    }
}

private struct SettingLine: View {
    let symbol: String
    let title: String
    let state: String
    let on: Bool
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? Palette.ground : Palette.ink.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(on ? Palette.ink.opacity(0.85) : Palette.wash, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(state).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(hovering ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// How safe the connection is, in a word; it opens the site card's closer look.
private struct ConnectionPill: View {
    @ObservedObject var tab: Tab
    let act: () -> Void
    @State private var hovering = false

    private var secure: Bool { tab.address?.scheme == "https" && tab.failure?.kind != .certificate }

    var body: some View {
        Button(action: act) {
            Label(secure ? "Secure" : "Not Secure", systemImage: secure ? "lock" : "lock.open")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secure ? Palette.ink.opacity(0.8) : Palette.unsafe)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(hovering ? Palette.hover : Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Browser {
    /// Clear Cookies and Site Data…, for the site in front, after asking.
    func clearSiteData() {
        guard let tab = active, let host = tab.address?.host(), let store = tab.built?.configuration.websiteDataStore else { return }
        let alert = Dialogs.alert(
            "Clear cookies and site data for \(host)?", "You may be signed out of it, and what it keeps on this Mac goes.",
            buttons: ["Clear", "Cancel"])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: mine) {
                MainActor.assumeIsolated {
                    tab.built?.reload()
                    self.announce("Cleared what \(host) kept")
                }
            }
        }
    }
}

/// The page panel, drawn off screen for the bench: a popover can't stay
/// open while the browser is in the background.
@MainActor
func pagePanelPicture(_ browser: Browser) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: PagePanel(browser: browser) {}.background(Palette.ground))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}
