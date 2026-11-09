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
        Group {
            if button == .downloads {
                DownloadsButton(downloads: browser.downloads, act: press)
            } else {
                FootIcon(symbol: button.symbol, help: button.title, act: press)
            }
        }
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

/// The downloads button, as Zen's: while one downloads, how far it has got
/// takes the arrow's place (a ring spinning while its size is unknown), and
/// a ripple goes out as one finishes. Only this watches the downloads.
private struct DownloadsButton: View {
    @ObservedObject var downloads: Downloads
    let act: () -> Void
    /// A ripple showing, and how far it has spread.
    @State private var ripple = false
    @State private var spread = false

    var body: some View {
        Group {
            if let newest = downloads.transfers.first {
                Downloading(transfer: newest, act: act)
            } else {
                FootIcon(symbol: FootButton.downloads.symbol, help: FootButton.downloads.title, act: act)
            }
        }
        .overlay {
            Circle()
                .stroke(Palette.ink, lineWidth: 1.5)
                .frame(width: Downloading.size, height: Downloading.size)
                .scaleEffect(spread ? 1.8 : 1)
                .opacity(ripple && !spread ? 0.8 : 0)
                .allowsHitTesting(false)
        }
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

/// The button while a download is the newest: it redraws alone as it moves.
private struct Downloading: View {
    @ObservedObject var transfer: Transfer
    let act: () -> Void

    /// The circle of an 11 pt symbol, as the foot's others are drawn.
    static let size: CGFloat = 11.5

    var body: some View {
        let running = transfer.state == .running
        FootIcon(symbol: FootButton.downloads.symbol, help: FootButton.downloads.title, showsSymbol: !running, act: act)
            .overlay {
                if running {
                    Group {
                        if let done = transfer.fraction {
                            // The size of the other buttons' symbols, and their stroke.
                            ZStack {
                                Circle().stroke(Palette.muted.opacity(0.3), lineWidth: 1.2)
                                Circle()
                                    .trim(from: 0, to: max(0.04, done))
                                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.easeOut(duration: 0.45), value: done)
                            }
                            .frame(width: Self.size, height: Self.size)
                        } else {
                            Ring(size: Self.size)
                        }
                    }
                    .allowsHitTesting(false)
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
                let there = downloads.isThere(record)
                PopoverLine(record.name, symbol: there ? "doc" : "doc.badge.ellipsis") {
                    if there { downloads.open(record) }
                    close()
                }
                .contextMenu { FileMenu(record: record, there: there, downloads: downloads) }
            }
        } showAll: {
            close()
            browser.showingDownloads = true
        }
        .onAppear { downloads.lookAgain() }
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
