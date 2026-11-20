import MoteCore
import SwiftUI

/// The History panel: where you've been, by day, with a search and the
/// ways to clear history, sign-ins and the cache.
struct HistoryPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var searching: Bool
    /// The days on show, worked out again only when history or the search changes.
    @State private var days: [Days.Group<History.Entry>] = []
    @State private var clearing = false

    private var pages: Int { days.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        Plate("History", width: 600, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                SearchField(text: $browser.historyQuery, prompt: "Search everywhere you have been", focus: $searching)
                if days.isEmpty {
                    Card { EmptyState(browser.historyQuery.isEmpty ? "Nothing yet." : "Nothing matches.") }
                } else {
                    list
                }
            }
        } foot: {
            if clearing {
                ClearOptions(browser: browser) {
                    refresh()
                } done: {
                    withAnimation(Motion.settle) { clearing = false }
                }
            } else {
                HStack {
                    Text(pages == 1 ? "1 page" : "\(pages) pages").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { clearing = true } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear {
            searching = true
            refresh()
        }
        .onChange(of: browser.historyQuery) { refresh() }
    }

    /// Lazy: a long history is too slow to lay out all at once. Each day is
    /// one card behind its rows, as Passwords: rows drawn bare scroll smoothly.
    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.day) { day in
                    Caption(When.day(day.day))
                        .padding(.top, day.day == days.first?.day ? 0 : 14)
                        .padding(.bottom, 6)
                    Card {
                        LazyVStack(spacing: 0) {
                            ForEach(day.items) { entry in
                                if entry.id != day.items.first?.id { Rule() }
                                PlaceRow(entry: entry, open: open, forget: forget)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: 420)
    }

    /// Opens an entry: here, or as a menu item asks.
    private func open(_ entry: History.Entry, _ opening: LinkOpening?) {
        browser.recalling = false
        if let opening { return browser.open(entry.url, as: opening, from: browser.active) }
        if let tab = browser.active { tab.go(to: entry.url) } else { browser.open(entry.url, foreground: true) }
    }

    private func forget(_ entry: History.Entry) {
        browser.history.remove(entry.key)
        refresh()
    }

    private func refresh() {
        days = Days.group(browser.history.entries(matching: browser.historyQuery), by: \.last)
    }
}

/// History, sign-ins and the cache, each cleared on its own.
private struct ClearOptions: View {
    let browser: Browser
    let cleared: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", "Everywhere you have been") {
                    Pill("Clear") {
                        browser.clearHistory()
                        cleared()
                        done()
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
            HStack {
                Spacer()
                Pill("Back", action: done)
            }
        }
        .transition(.opacity)
    }
}

/// A place in the list: a click opens it here; its menu opens it elsewhere.
private struct PlaceRow: View {
    let entry: History.Entry
    /// nil: here.
    let open: (History.Entry, LinkOpening?) -> Void
    let forget: (History.Entry) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Mark(
                icon: Favicons.shared.cached(entry.url.host()?.lowercased() ?? ""),
                letter: entry.key.first.map { String($0).uppercased() } ?? "•", size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.key : entry.title).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(entry.key).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hovering {
                Quick("Remove", tint: .red.opacity(0.75)) { forget(entry) }
            } else {
                Text(When.clock(entry.last)).font(.system(size: 11.5)).foregroundStyle(Palette.muted).monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { open(entry, nil) }
        // Not lit by rows passing under the pointer as the list scrolls.
        .rowHover { hovering = $0 }
        .contextMenu {
            Button("Open") { open(entry, nil) }
            Button("Open in New Tab") { open(entry, .tab(background: false)) }
            Button("Open in Background") { open(entry, .tab(background: true)) }
            Button("Open in New Window") { open(entry, .window(private: false)) }
            Button("Open in Private Window") { open(entry, .window(private: true)) }
            Divider()
            Button("Copy Link") { Downloads.copy(entry.url) }
            Divider()
            Button("Remove") { forget(entry) }
        }
        .help(entry.url.absoluteString)
    }
}
