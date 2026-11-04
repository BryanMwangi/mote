import Combine
import SwiftUI

// The pieces Settings is made of: the bar of pages along the top, and
// sections of rows, each row led by a coloured symbol.

/// The pages, side by side under the traffic lights.
struct SettingsPageBar: View {
    @Binding var page: SettingsPage

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsPage.allCases) { item in
                PageButton(page: item, chosen: page == item) { withAnimation(Motion.quick) { page = item } }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private struct PageButton: View {
        let page: SettingsPage
        let chosen: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                VStack(spacing: 4) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 16, weight: .regular))
                        .symbolVariant(chosen ? .fill : .none)
                        .frame(height: 20)
                    Text(page.title).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                }
                .foregroundStyle(chosen ? page.tint : hovering ? Palette.ink.opacity(0.8) : Palette.muted)
                .frame(width: 84, height: 50)
                .background(
                    chosen ? Palette.wash : hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .accessibilityLabel(page.title)
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }
}

// MARK: - Searching

/// What Settings is searched for, as Zen's: anything in it can be found.
/// Rows hide themselves when they don't match (see `settingsSearch`), and
/// sections and pages with nothing left hide too, so there's no second list
/// of settings to keep in step.
@MainActor
final class SettingsSearch: ObservableObject {
    static let shared = SettingsSearch()
    @Published var query = ""
    /// Asks the field for the keyboard (⌘F).
    @Published var focusAsked = 0
    /// The rows showing for the query, for the bench.
    var found: [String] = []

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Every word of `query` somewhere in `terms`, ignoring case and accents.
    static func matches(_ query: String, _ terms: [String]) -> Bool {
        let haystack = terms.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ")
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    /// `text` with the query's words marked, for a found row's title.
    static func marked(_ text: String, _ query: String) -> AttributedString {
        var marked = AttributedString(text)
        for word in query.split(separator: " ") {
            if let range = marked.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                marked[range].backgroundColor = Color.yellow.opacity(0.35)
            }
        }
        return marked
    }
}

/// The query, handed down to the rows.
private struct SettingsQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var settingsQuery: String {
        get { self[SettingsQueryKey.self] }
        set { self[SettingsQueryKey.self] = newValue }
    }
}

/// The rows found under a view, by title.
struct FoundRows: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// A row that hides itself while Settings is searched for something it
/// doesn't hold. The first term names it.
private struct SettingsSearchable: ViewModifier {
    let terms: [String]
    @Environment(\.settingsQuery) private var query

    func body(content: Content) -> some View {
        if query.isEmpty {
            content
        } else if SettingsSearch.matches(query, terms) {
            content.preference(key: FoundRows.self, value: [terms.first ?? ""])
        }
    }
}

extension View {
    /// Found by these words while Settings is searched, and hidden otherwise.
    func settingsSearch(_ terms: [String]) -> some View { modifier(SettingsSearchable(terms: terms)) }

    /// Kept while searching only when something under it was found; laid out
    /// either way, so its rows can still say what they hold.
    func keptWhenFound(_ found: Binding<Bool>, searching: Bool) -> some View {
        self
            .onPreferenceChange(FoundRows.self) { rows in found.wrappedValue = !rows.isEmpty }
            .padding(.bottom, searching && found.wrappedValue ? 18 : 0)
            .frame(height: searching && !found.wrappedValue ? 0 : nil)
            .opacity(searching && !found.wrappedValue ? 0 : 1)
            .clipped()
    }
}

/// A titled group of rows, with an optional note under it.
struct SettingsSection<Rows: View>: View {
    let title: String?
    var note: String?
    @ViewBuilder let rows: () -> Rows
    @Environment(\.settingsQuery) private var query
    @State private var found = true

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
        self.title = title
        self.note = note
        self.rows = rows
    }

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        sectionBody.keptWhenFound($found, searching: !query.isEmpty)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).padding(.leading, 4)
            }
            VStack(spacing: 0, content: rows)
                .background(Palette.wash.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            if let note, query.isEmpty {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A line between two rows, starting where their text does. Found rows
/// stand on their own, without one.
struct RowRule: View {
    @Environment(\.settingsQuery) private var query

    var body: some View {
        if query.isEmpty { Palette.hairline.frame(height: 1).padding(.leading, 47) }
    }
}

/// A coloured symbol, as rows start with.
struct SymbolTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }
}

/// One setting: its symbol, what it is, what it does, and its control.
struct SettingRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    /// More words it's found by: a picker's choices, say.
    var keywords: [String] = []
    @ViewBuilder let control: () -> Control
    @Environment(\.settingsQuery) private var query

    init(
        _ title: String, _ detail: String? = nil, symbol: String, tint: Color, keywords: [String] = [],
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.keywords = keywords
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            SymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(query.isEmpty ? AttributedString(title) : SettingsSearch.marked(title, query))
                    .font(.system(size: 13)).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .settingsSearch([title, detail ?? ""] + keywords)
    }
}

extension SettingRow where Control == Switch {
    /// A setting that's on or off.
    init(_ title: String, _ detail: String? = nil, symbol: String, tint: Color, keywords: [String] = [], on: Binding<Bool>) {
        self.init(title, detail, symbol: symbol, tint: tint, keywords: keywords) { Switch(on: on) }
    }
}

/// The colours rows use, so a page reads at a glance.
enum Tint {
    static let blue = Color(nsColor: .systemBlue)
    static let indigo = Color(nsColor: .systemIndigo)
    static let purple = Color(nsColor: .systemPurple)
    static let pink = Color(nsColor: .systemPink)
    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let yellow = Color(nsColor: .systemYellow)
    static let green = Color(nsColor: .systemGreen)
    static let teal = Color(nsColor: .systemTeal)
    static let gray = Color(nsColor: .systemGray)
}
