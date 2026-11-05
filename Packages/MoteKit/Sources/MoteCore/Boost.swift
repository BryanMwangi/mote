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
    /// "#rrggbb": a colour cast over the whole page, and its links' colour.
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

    /// Nothing changed from the site's own look.
    public var isEmpty: Bool { self == Boost() }

    /// The stylesheet that does it: the filters on the whole page (pictures
    /// turned back when it's dark), size, the font and case on everything but
    /// code, the accent on links, then the CSS as written. Empty when there's
    /// nothing, or when it's switched off.
    public var stylesheet: String {
        guard enabled else { return "" }
        var rules: [String] = []
        var filters: [String] = []
        if dark { filters.append("invert(1) hue-rotate(180deg)") }
        // The cast: sepia gives a warm tone at about 38°, turned to the tint's hue.
        if let tint, let hue = Self.hue(tint) { filters.append("sepia(0.45) hue-rotate(\(Int((hue - 38).rounded()))deg) saturate(1.3)") }
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
        if var accent, let rgb = SpaceTheme.rgb(accent) {
            // Dark turns the page over, accent and all; turned first, it comes out as chosen.
            if dark { accent = SpaceTheme.hex(red: 1 - rgb.red, green: 1 - rgb.green, blue: 1 - rgb.blue) }
            rules.append("a, a * { color: \(accent) !important; } html { accent-color: \(accent); }")
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules.append(css) }
        return rules.joined(separator: "\n")
    }

    /// A colour's hue in degrees.
    private static func hue(_ hex: String) -> Double? {
        guard SpaceTheme.rgb(hex) != nil else { return nil }
        let point = ThemeColors.point(for: hex)
        let degrees = atan2(point.y, point.x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
