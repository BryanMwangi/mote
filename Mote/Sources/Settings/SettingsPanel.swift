import SwiftUI

/// Settings, in its own window (SettingsWindow): the pages in a bar along the
/// top, the chosen one below.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var page = SettingsPage(rawValue: Storage.settings.string(forKey: "settings.page") ?? "") ?? .general
    @ObservedObject private var search = SettingsSearch.shared
    /// Whether anything matched the query, anywhere.
    @State private var anything = true

    static let width: CGFloat = 780
    static let height: CGFloat = 580

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit in the band above the bar.
            SettingsPageBar(page: $page)
                .padding(.top, 34)
                .padding(.bottom, 8)
            SettingsSearchField(search: search).padding(.horizontal, 24).padding(.bottom, 10)
            Palette.hairline.frame(height: 1)
            ScrollView(showsIndicators: false) {
                Group {
                    if search.searching { results } else { VStack(alignment: .leading, spacing: 22) { content(page) } }
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(search.searching ? nil : page)
        }
        // The content runs under the see-through title bar, so the panel
        // takes the window's height rather than its own.
        .frame(width: Self.width)
        .frame(minHeight: Self.height, maxHeight: .infinity)
        .background(Palette.ground)
        .ignoresSafeArea()
        .onChange(of: page) { Storage.settings.set(page.rawValue, forKey: "settings.page") }
    }

    /// Every page's rows that match, under each page's name, which leads to it.
    private var results: some View {
        let query = search.query.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 0) {
            if !anything {
                Text("No settings match “\(query)”").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            ForEach(SettingsPage.allCases) { item in
                PageResults(page: item, query: query) {
                    page = item
                    search.query = ""
                } content: {
                    content(item)
                }
            }
        }
        .environment(\.settingsQuery, query)
        .onPreferenceChange(FoundRows.self) { rows in
            anything = !rows.isEmpty
            SettingsSearch.shared.found = rows
        }
    }

    @ViewBuilder private func content(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettings(browser: browser, prefs: prefs)
        case .ai: AISettings(browser: browser, prefs: prefs)
        case .tabs: TabSettings(browser: browser, prefs: prefs)
        case .keyboard: KeyboardSettings(prefs: prefs)
        case .passwords: PasswordSettings(browser: browser, prefs: prefs)
        case .privacy: PrivacySettings(browser: browser, prefs: prefs)
        case .extensions: ExtensionsPage(browser: browser)
        case .about: AboutSettings(browser: browser, prefs: prefs)
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, ai, tabs, keyboard, passwords, privacy, extensions, about

    var id: String { rawValue }
    var title: String { self == .ai ? "AI" : rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ai: "sparkles"
        case .tabs: "square.on.square"
        case .keyboard: "keyboard"
        case .passwords: "key"
        case .privacy: "hand.raised"
        case .extensions: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: Tint.gray
        case .ai: Tint.pink
        case .tabs: Tint.blue
        case .keyboard: Tint.green
        case .passwords: Tint.yellow
        case .privacy: Tint.indigo
        case .extensions: Tint.purple
        case .about: Tint.teal
        }
    }
}

/// One page's part of the search results: its name, which goes to it, over
/// its rows that match. Hidden when none do.
private struct PageResults<Content: View>: View {
    let page: SettingsPage
    let query: String
    let open: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var found = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: page.symbol).foregroundStyle(page.tint)
                    Text(page.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(page.title)")
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .keptWhenFound($found, searching: true)
    }
}

/// The field under the pages: typing searches every page (⌘F).
private struct SettingsSearchField: View {
    @ObservedObject var search: SettingsSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Search Settings", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: search.focusAsked) { focused = true }
        // Settings opens ready to search, as System Settings does.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
