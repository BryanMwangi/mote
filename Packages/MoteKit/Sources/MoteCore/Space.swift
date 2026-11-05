import Foundation

/// A set of tabs of its own in the window, with its own website data or the
/// first space's. Kept in spaces.json; the field names are that file's format.
public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// No longer used; kept so older files still read.
    public var colour: Int
    /// One of `Space.icons`' symbols, or an emoji.
    public var icon: String?
    /// Signed in wherever the first space is, sharing its website data. nil,
    /// in older spaces, means data of its own.
    public var sharesSignIns: Bool?
    /// Where its downloads go; nil for the folder in Settings.
    public var downloads: String?
    /// Where it came from when imported ("zen:<uuid>"), so importing again
    /// doesn't make it twice.
    public var origin: String?
    /// Its colours behind the window's frame, as Zen's space themes; nil for none.
    public var theme: SpaceTheme?

    public init(
        id: UUID, name: String, icon: String? = nil, sharesSignIns: Bool? = nil, downloads: String? = nil, origin: String? = nil
    ) {
        self.id = id
        self.name = name
        colour = 0
        self.icon = icon
        self.sharesSignIns = sharesSignIns
        self.downloads = downloads
        self.origin = origin
    }

    /// The first space: the default session and data store, so turning spaces
    /// on signs nobody out.
    public static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public var isFirst: Bool { id == Self.firstID }
    public var ownData: Bool { !isFirst && sharesSignIns != true }

    /// Its icon, or a house for the first space and a briefcase for others.
    public var symbol: String {
        icon.flatMap { icon in Self.icons.contains { $0.symbol == icon } ? icon : nil } ?? (isFirst ? "house" : "briefcase")
    }

    /// Its icon when that's an emoji rather than a symbol.
    public var emoji: String? { icon.flatMap { Self.isEmoji($0) ? $0 : nil } }

    /// A single emoji: one character, drawn as a picture. Digits, # and *
    /// count as emoji in Unicode but aren't pictures, so they don't.
    public static func isEmoji(_ text: String) -> Bool {
        text.count == 1
            && text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }

    /// The icons a space can have: SF Symbols and their names.
    public static let icons: [(symbol: String, name: String)] = [
        ("briefcase", "Work"), ("building.2", "Office"), ("desktopcomputer", "Desktop"), ("laptopcomputer", "Laptop"),
        ("chevron.left.forwardslash.chevron.right", "Code"), ("terminal", "Terminal"), ("sparkles", "AI"),
        ("brain.head.profile", "Thinking"), ("lightbulb", "Ideas"), ("gamecontroller", "Games"), ("beach.umbrella", "Leisure"),
        ("cup.and.saucer", "Café"), ("music.note", "Music"), ("film", "Film"), ("paintpalette", "Art"), ("camera", "Photos"),
        ("house", "Home"), ("book", "Reading"), ("graduationcap", "Studies"), ("cart", "Shopping"), ("airplane", "Travel"),
        ("dumbbell", "Sport"), ("leaf", "Nature"), ("heart", "Personal"),
    ]
}

/// The window's spaces, in the order they were put in. The first space
/// (the one holding Mote's main sign-ins) is always among them.
public struct SpaceList: Equatable, Sendable {
    public private(set) var spaces: [Space]

    /// From what was saved; the first space is made, at the front, if it's missing.
    public init(saved: [Space]) {
        spaces = saved.contains(where: \.isFirst) ? saved : [Space(id: Space.firstID, name: "Personal")] + saved
    }

    public func index(of id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }
    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    /// The first icon no space has yet.
    public var freeIcon: String {
        let used = Set(spaces.map(\.symbol))
        return Space.icons.first { !used.contains($0.symbol) }?.symbol ?? "briefcase"
    }

    public mutating func add(_ space: Space) { spaces.append(space) }

    /// Moves a space to `index`; ⌃1–⌃9 and swiping follow the order.
    @discardableResult
    public mutating func move(_ id: UUID, to index: Int) -> Bool {
        guard let from = self.index(of: id), spaces.indices.contains(index), from != index else { return false }
        spaces.insert(spaces.remove(at: from), at: index)
        return true
    }

    public mutating func edit(_ id: UUID, _ change: (inout Space) -> Void) {
        if let at = index(of: id) { change(&spaces[at]) }
    }

    /// Removes a space; never the first.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Space? {
        guard id != Space.firstID, let at = index(of: id) else { return nil }
        return spaces.remove(at: at)
    }

    /// The spaces sharing the first space's data.
    public var sharing: Set<UUID> { Set(spaces.filter { $0.sharesSignIns == true }.map(\.id)) }
}

/// A space's colours, as Zen's themes keep them, leaner: one to three
/// colours in a gradient across the window's frame, how strongly they show,
/// a grain over them, and whether the space is light or dark.
public struct SpaceTheme: Codable, Equatable, Sendable {
    /// "#rrggbb", one to three.
    public var colors: [String]
    /// 0 to 1.
    public var opacity: Double
    /// How much grain, 0 to 1.
    public var grain: Double
    /// Light or dark while the space shows; nil follows Mote's look.
    public var scheme: Scheme?

    public enum Scheme: String, Codable, Sendable { case light, dark }

    public init(colors: [String], opacity: Double = 0.45, grain: Double = 0, scheme: Scheme? = nil) {
        self.colors = Array(colors.prefix(3))
        self.opacity = min(max(opacity, 0), 1)
        self.grain = min(max(grain, 0), 1)
        self.scheme = scheme
    }

    private enum CodingKeys: String, CodingKey { case colors, opacity, grain, scheme }

    /// Grain was once on or off.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let grain = (try? values.decode(Double.self, forKey: .grain)) ?? ((try? values.decode(Bool.self, forKey: .grain)) == true ? 1 : 0)
        self.init(
            colors: try values.decode([String].self, forKey: .colors), opacity: try values.decode(Double.self, forKey: .opacity),
            grain: grain,
            scheme: try values.decodeIfPresent(Scheme.self, forKey: .scheme))
    }

    /// Zen's swatches, a page of nine at a time: vivid, pale and deep, each
    /// as one colour and then as three around it (Zen's theme-picker.inc).
    public static let swatches: [Swatch] = {
        let vivid = ["#f2eae4", "#f29bbb", "#a6729d", "#f25e6b", "#ff8558", "#f8d558", "#34e895", "#6cbad9", "#666789"]
        let pale = ["#fefbfa", "#ffe9f3", "#f1d1ec", "#ffcbd1", "#ffe0d3", "#fff9e5", "#defdeb", "#dcf3fc", "#c5c6e5"]
        let deep = ["#4e3a5a", "#693558", "#8f4042", "#b16d40", "#d7b35d", "#cdcca4", "#7aa982", "#226149", "#26456b"]
        return [vivid, pale, deep].flatMap { page in page.map { Swatch(hex: $0, dots: 1) } + page.map { Swatch(hex: $0, dots: 3) } }
    }()

    /// A swatch: a colour, alone or with two more around it.
    public struct Swatch: Hashable, Sendable {
        public let hex: String
        public let dots: Int

        /// The theme's colours for it.
        public var colors: [String] {
            dots == 1 ? [hex] : [hex] + ThemeColors.others(.analogous, from: ThemeColors.point(for: hex)).map(ThemeColors.hex(at:))
        }
    }

    /// A few to start from, as Zen's picker offers.
    public static let presets: [SpaceTheme] = [
        SpaceTheme(colors: ["#7c5cff", "#ff7ab6"]), SpaceTheme(colors: ["#2bb3ff", "#38e0b0"]),
        SpaceTheme(colors: ["#ff8a3d", "#ffd23f"]), SpaceTheme(colors: ["#3a7bd5", "#00d2ff", "#9b5cff"]),
        SpaceTheme(colors: ["#2f9e44"]), SpaceTheme(colors: ["#e03131", "#7048e8"]),
    ]

    /// A colour's red, green and blue from 0 to 1; nil when it isn't "#rrggbb".
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double(value >> 16 & 0xff) / 255, Double(value >> 8 & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// "#rrggbb" for red, green and blue from 0 to 1.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        let byte = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
