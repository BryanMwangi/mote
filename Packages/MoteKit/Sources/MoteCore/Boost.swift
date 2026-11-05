import Foundation

/// A site made to look how you want, as Zen's boosts: a colour cast over
/// it, an accent for its links, dark, brighter or darker, more or less
/// contrast and colour, another font, bigger, in capitals, and CSS of your
/// own; switched off without losing any of it.
public struct Boost: Codable, Equatable, Sendable {
    /// 1 is as the site made it.
    public var brightness = 1.0
    public var contrast = 1.0
    public var saturation = 1.0
    /// A font family for the page's text; nil for the site's own.
    public var font: String?
    public var css = ""
    /// "#rrggbb": the two dots the page's colours move toward, dark ones to
    /// `tint` and light ones to `accent` (see Scripts/src/boost-colors.ts).
    public var tint: String?
    public var accent: String?
    /// Light pages turned dark, pictures kept as they are.
    public var dark = false
    /// 1 is the site's own size.
    public var size = 1.0
    /// "uppercase", "lowercase" or "capitalize"; nil as written.
    public var textCase: String?
    /// Off keeps everything for later.
    public var enabled = true

    public init(
        brightness: Double = 1, contrast: Double = 1, saturation: Double = 1, font: String? = nil, css: String = "", tint: String? = nil,
        accent: String? = nil, dark: Bool = false, size: Double = 1, textCase: String? = nil, enabled: Bool = true
    ) {
        (self.brightness, self.contrast, self.saturation, self.font, self.css) = (brightness, contrast, saturation, font, css)
        (self.tint, self.accent, self.dark, self.size, self.textCase, self.enabled) = (tint, accent, dark, size, textCase, enabled)
    }

    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, font, css, tint, accent, dark, size, textCase, enabled
    }

    /// Older boosts have only some of these.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            brightness: try values.decodeIfPresent(Double.self, forKey: .brightness) ?? 1,
            contrast: try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
            saturation: try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1,
            font: try values.decodeIfPresent(String.self, forKey: .font), css: try values.decodeIfPresent(String.self, forKey: .css) ?? "",
            tint: try values.decodeIfPresent(String.self, forKey: .tint), accent: try values.decodeIfPresent(String.self, forKey: .accent),
            dark: try values.decodeIfPresent(Bool.self, forKey: .dark) ?? false,
            size: try values.decodeIfPresent(Double.self, forKey: .size) ?? 1,
            textCase: try values.decodeIfPresent(String.self, forKey: .textCase),
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }

    /// What the colours script is told: the dots, and how far colours move,
    /// as far as the first dot is from the field's centre. Nil for none.
    public var colors: BoostColors? {
        guard enabled, let tint else { return nil }
        let point = ThemeColors.point(for: tint)
        return BoostColors(primary: tint, secondary: accent, strength: 0.25 + min(hypot(point.x, point.y), 1) * 0.6)
    }

    /// Nothing changed from the site's own look.
    public var isEmpty: Bool { self == Boost() }

    /// The stylesheet that does it: the filters on the whole page (pictures
    /// turned back when it's dark), size, the font and case on everything but
    /// code, then the CSS as written; the colours are the script's (`colors`). Empty when there's
    /// nothing, or when it's switched off.
    public var stylesheet: String {
        guard enabled else { return "" }
        var rules: [String] = []
        var filters: [String] = []
        if dark { filters.append("invert(1) hue-rotate(180deg)") }
        filters += [("brightness", brightness), ("contrast", contrast), ("saturate", saturation)]
            .filter { abs($0.1 - 1) > 0.001 }
            .map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }
        if !filters.isEmpty { rules.append("html { filter: \(filters.joined(separator: " ")) !important; }") }
        if dark { rules.append("img, video, picture, canvas, iframe, svg image { filter: invert(1) hue-rotate(180deg) !important; }") }
        if abs(size - 1) > 0.001 { rules.append("html { zoom: \(String(format: "%.2f", size)) !important; }") }
        let text = "body, body *:not(code):not(pre):not(kbd):not(samp):not(code *):not(pre *)"
        if let font = font?.trimmingCharacters(in: .whitespaces), !font.isEmpty {
            let family = font.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ";", with: "")
            rules.append(#"\#(text) { font-family: "\#(family)" !important; }"#)
        }
        if let textCase, ["uppercase", "lowercase", "capitalize"].contains(textCase) {
            rules.append("\(text) { text-transform: \(textCase) !important; }")
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules.append(css) }
        return rules.joined(separator: "\n")
    }
}

/// The boost colours script's configuration.
public struct BoostColors: Codable, Equatable, Sendable {
    public let primary: String
    public let secondary: String?
    public let strength: Double
}
