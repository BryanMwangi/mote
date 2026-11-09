import AppKit
import MoteCore
import SwiftUI

/// The buttons at the sidebar's foot, the user's own choice and order (see
/// FootButton). Those with something to show open a small popover of this
/// session's activity first, with the whole panel a click further.
struct FootButtons: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The space showing; another's, during a swipe, opens nothing.
    let showing: Bool

    var body: some View {
        let list = prefs.foot
        // The profile's avatar only once there's more than one profile.
        ForEach(list.filter { $0 != .profile || !Profiles.shared.list.isEmpty }, id: \.self) { button in
            FootItem(browser: browser, button: button, showing: showing)
                .contextMenu {
                    if list.first != button { Button("Move Left") { prefs.foot = FootButton.moving(button, by: -1, in: list) } }
                    if list.last != button { Button("Move Right") { prefs.foot = FootButton.moving(button, by: 1, in: list) } }
                    Divider()
                    Button("Remove from Sidebar") { prefs.foot = list.filter { $0 != button } }
                }
        }
    }
}

extension FootButton {
    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .downloads: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .bookmarks: "bookmark"
        case .library: "books.vertical"
        case .passwords: "key"
        case .screenshot: "camera"
        case .newWindow: "macwindow.badge.plus"
        case .settings: "gearshape"
        case .profile: "person.crop.circle"
        }
    }
}

private struct FootItem: View {
    let browser: Browser
    let button: FootButton
    let showing: Bool
    @State private var open = false

    var body: some View {
        if button == .profile {
            Button(action: press) { ProfileAvatar(id: Storage.profile, size: 18) }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("\(Profiles.shared.current) profile")
        } else {
            icon
        }
    }

    private var icon: some View {
        FootIcon(symbol: button.symbol, help: button.title, act: press)
            .overlay { if button == .downloads { DownloadGauge(downloads: browser.downloads) } }
            .menuPanel(isPresented: showing ? $open : .constant(false), edge: button == .chats ? .trailing : .top) { popover }
    }

    private func press() {
        switch button {
        case .chats, .downloads, .history, .bookmarks: open.toggle()
        case .library: browser.toggleLibrary()
        case .passwords: browser.perform(.passwords)
        case .screenshot: browser.startScreenshot()
        case .newWindow: browser.perform(.newWindow)
        case .settings: browser.perform(.settings)
        case .profile: browser.openSettings(at: .general)
        }
    }

    @ViewBuilder private var popover: some View {
        switch button {
        case .chats: ChatsPage(browser: browser, inPanel: true) { open = false }.frame(width: 380, height: 440)
        case .downloads: SessionDownloads(browser: browser, downloads: browser.downloads) { open = false }
        case .bookmarks: BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks) { open = false }
        case .history: SessionHistory(browser: browser) { open = false }
        default: EmptyView()
        }
    }
}

/// Round the downloads button's arrow: how far the newest download has got,
/// spinning while its size is unknown, and a ripple as one finishes, as
/// Zen's button shows. Only this watches the downloads, not the sidebar.
private struct DownloadGauge: View {
    @ObservedObject var downloads: Downloads
    /// A ripple showing, and how far it has spread.
    @State private var ripple = false
    @State private var spread = false

    var body: some View {
        ZStack {
            if let newest = downloads.transfers.first { TransferArc(transfer: newest) }
            Circle()
                .stroke(Palette.ink, lineWidth: 1.5)
                .frame(width: 15, height: 15)
                .scaleEffect(spread ? 1.6 : 1)
                .opacity(ripple && !spread ? 0.8 : 0)
        }
        .frame(width: 26, height: 26)
        .allowsHitTesting(false)
        .onChange(of: downloads.kept.first?.id) { _, done in
            guard done != nil else { return }
            ripple = true
            spread = false
            withAnimation(.easeOut(duration: 0.5)) { spread = true }
            Task {
                try? await Task.sleep(for: .seconds(0.55))
                ripple = false
                spread = false
            }
        }
    }
}

/// One download's arc; it redraws alone as the download moves.
private struct TransferArc: View {
    @ObservedObject var transfer: Transfer

    var body: some View {
        if transfer.state == .running {
            if let done = transfer.fraction {
                ZStack {
                    Circle().stroke(Palette.muted.opacity(0.25), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: max(0.04, done))
                        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.45), value: done)
                }
                .frame(width: 15, height: 15)
            } else {
                Ring(size: 15)
            }
        }
    }
}

/// When this Mote opened: the session the foot's popovers show.
private let launched = NSRunningApplication.current.launchDate ?? .now

/// This session's downloads, then all of them.
private struct SessionDownloads: View {
    let browser: Browser
    @ObservedObject var downloads: Downloads
    let close: () -> Void

    var body: some View {
        let recent = downloads.kept.filter { $0.date >= launched }
        SessionList(
            empty: recent.isEmpty && downloads.transfers.isEmpty ? "No downloads this session." : nil, more: "Show all downloads"
        ) {
            // Those under way first, as Zen's panel has them.
            ForEach(downloads.transfers) { transfer in
                TransferRow(transfer: transfer, browser: browser).padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(recent.prefix(8)) { record in
                PopoverLine(record.name, symbol: record.stillThere ? "doc" : "doc.badge.ellipsis") {
                    if record.stillThere { downloads.open(record) }
                    close()
                }
                .contextMenu { FileMenu(record: record, there: record.stillThere, downloads: downloads) }
            }
        } showAll: {
            close()
            browser.showingDownloads = true
        }
    }
}

/// The pages visited this session, then all of history.
private struct SessionHistory: View {
    let browser: Browser
    let close: () -> Void

    var body: some View {
        let recent = browser.history.recent().filter { $0.last >= launched }
        SessionList(empty: recent.isEmpty ? "Nothing visited yet this session." : nil, more: "Show all history") {
            ForEach(recent) { entry in
                PopoverLine(entry.title.isEmpty ? entry.url.absoluteString : entry.title, symbol: "globe") {
                    close()
                    browser.open(entry.url, foreground: true)
                }
            }
        } showAll: {
            close()
            browser.recalling = true
        }
    }
}

private struct SessionList<Rows: View>: View {
    /// What to say when there's nothing.
    let empty: String?
    let more: String
    @ViewBuilder let rows: () -> Rows
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let empty { Text(empty).font(.system(size: 12.5)).foregroundStyle(Palette.muted).padding(10) } else { rows() }
            Divider().overlay(Palette.hairline).padding(.vertical, 4)
            PopoverLine(more, act: showAll)
        }
        .padding(6)
        .frame(width: 300)
    }
}
