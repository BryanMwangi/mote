import AppKit
import MoteCore
import SwiftUI

/// A space's icon: a symbol from a grid, or an emoji from a grid with a
/// search field, as Zen picks them.
struct IconPicker: View {
    /// The icon now: a symbol's name or an emoji.
    let current: String?
    let choose: (String) -> Void

    private enum Kind: Hashable { case symbols, emoji }

    @State private var kind: Kind
    @State private var query = ""
    @FocusState private var searching: Bool

    init(current: String?, choose: @escaping (String) -> Void) {
        self.current = current
        self.choose = choose
        _kind = State(initialValue: current.map(Space.isEmoji) == true ? .emoji : .symbols)
    }

    var body: some View {
        VStack(spacing: 10) {
            Segmented(options: [(Kind.symbols, "Symbols"), (.emoji, "Emoji")], selection: $kind, wide: true)
            if kind == .symbols { symbols } else { emoji }
        }
        .padding(10)
        .frame(width: 280)
    }

    private var symbols: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 7), spacing: 6) {
            ForEach(Space.icons, id: \.symbol) { symbol, name in
                cell(on: symbol == current) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(symbol == current ? Palette.ink : Palette.muted)
                }
                .onTapGesture { choose(symbol) }
                .help(name)
            }
        }
    }

    private var emoji: some View {
        let found = EmojiCatalog.matching(query)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searching)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 3), count: 8), spacing: 3) {
                    ForEach(found, id: \.emoji) { item in
                        cell(on: item.emoji == current) { Text(item.emoji).font(.system(size: 19)) }
                            .onTapGesture { choose(item.emoji) }
                            .help(item.name.capitalized)
                    }
                }
            }
            .frame(height: 230)
            .overlay {
                if found.isEmpty { Text("No emoji for “\(query)”").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        }
        .onAppear { searching = true }
    }

    private func cell<Content: View>(on: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 30, height: 30)
            .background(on ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Every single-character emoji, named from Unicode, plus a few people at
/// work who take several characters.
enum EmojiCatalog {
    struct Item {
        let emoji: String
        /// Lowercased, from Unicode: "briefcase", "grinning face".
        let name: String
    }

    static let all: [Item] = {
        // Faces and people first, as most pickers start.
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF,
        ]
        var items: [Item] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation, let name = scalar.properties.name
                else { continue }
                items.append(Item(emoji: String(scalar), name: name.lowercased()))
            }
        }
        let working: [(String, String)] = [
            ("🧑‍💻", "technologist"), ("👩‍💻", "woman technologist"), ("👨‍💻", "man technologist"), ("🧑‍💼", "office worker"),
            ("👩‍💼", "woman office worker"), ("👨‍💼", "man office worker"), ("🧑‍🎓", "student"), ("🧑‍🏫", "teacher"),
            ("🧑‍🎨", "artist"), ("🧑‍🔬", "scientist"), ("🧑‍🍳", "cook"), ("🧑‍🚀", "astronaut"),
        ]
        return items + working.map { Item(emoji: $0.0, name: $0.1) }
    }()

    static func matching(_ query: String) -> [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { item in words.allSatisfy { item.name.contains($0) } }
    }
}
