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

/// The downloads button: while any download runs, how far they've all got
/// together takes the arrow's place (a ring spinning while none knows its
/// size), and a ripple goes out as one finishes. Only this watches them.
private struct DownloadsButton: View {
    @ObservedObject var downloads: Downloads
    let act: () -> Void
    /// A ripple showing, and how far it has spread.
    @State private var ripple = false
    @State private var spread = false

    /// The circle of an 11 pt symbol, as the foot's others are drawn.
    private static let size: CGFloat = 11.5

    var body: some View {
        let running = downloads.running
        FootIcon(symbol: FootButton.downloads.symbol, help: FootButton.downloads.title, showsSymbol: running == nil, act: act)
            .overlay {
                Group {
                    if let running, running > 0 {
                        ZStack {
                            Circle().stroke(Palette.muted.opacity(0.3), lineWidth: 1.2)
                            Circle()
                                .trim(from: 0, to: max(0.04, running))
                                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeOut(duration: 0.45), value: running)
                        }
                        .frame(width: Self.size, height: Self.size)
                    } else if running != nil {
                        Ring(size: Self.size)
                    }
                    Circle()
                        .stroke(Palette.ink, lineWidth: 1.5)
                        .frame(width: Self.size, height: Self.size)
                        .scaleEffect(spread ? 1.8 : 1)
                        .opacity(ripple && !spread ? 0.8 : 0)
                }
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
            // Those under way first, then this session's files: as tall as
            // the first three, scrolling past them, without a scroll bar.
            let files = Array(recent.prefix(20))
            let last = min(downloads.transfers.count + files.count, Self.shown) - 1
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(downloads.transfers.enumerated()), id: \.element.id) { index, transfer in
                        TransferRow(transfer: transfer, browser: browser).padding(.horizontal, 10).padding(.vertical, 8)
                            .modifier(Bottom(measured: index == last, height: $height))
                    }
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, record in
                        let there = downloads.isThere(record)
                        PopoverLine(record.name, image: FileKind.icon(of: record, there: there)) {
                            if there { downloads.open(record) }
                            close()
                        }
                        .opacity(there ? 1 : 0.5)
                        .contextMenu { FileMenu(record: record, there: there, downloads: downloads) }
                        .modifier(Bottom(measured: downloads.transfers.count + index == last, height: $height))
                    }
                }
                .coordinateSpace(.named(Bottom.rows))
            }
            .scrollIndicators(.never)
            .frame(height: height)
        } showAll: {
            close()
            browser.showingDownloads = true
        }
        .onAppear { downloads.lookAgain() }
    }

    /// Rows the popover grows to before it scrolls.
    private static let shown = 3
    @State private var height: CGFloat = 0

    /// Where the last row shown in full ends, which the list is as tall as.
    private struct Bottom: ViewModifier {
        static let rows = "rows"
        let measured: Bool
        @Binding var height: CGFloat

        func body(content: Content) -> some View {
            if measured {
                content.onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(Self.rows)).maxY
                } action: {
                    height = $0
                }
            } else {
                content
            }
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
        .frame(width: 340)
    }
}
