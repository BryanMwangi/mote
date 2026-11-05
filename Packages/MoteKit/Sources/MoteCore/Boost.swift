import Foundation

/// A site made to look how you want, as Zen's boosts: brighter or darker,
/// more or less contrast and colour, another font, and CSS of your own.
public struct Boost: Codable, Equatable, Sendable {
    /// 1 is as the site made it.
    public var brightness = 1.0
    public var contrast = 1.0
    public var saturation = 1.0
    /// A font family for the page's text; nil for the site's own.
    public var font: String?
    public var css = ""

    public init(brightness: Double = 1, contrast: Double = 1, saturation: Double = 1, font: String? = nil, css: String = "") {
        (self.brightness, self.contrast, self.saturation, self.font, self.css) = (brightness, contrast, saturation, font, css)
    }

    /// Nothing changed from the site's own look.
    public var isEmpty: Bool { self == Boost() }

    /// The stylesheet that does it: a filter on the whole page, the font on
    /// everything but code, then the CSS as written. Empty when there's nothing.
    public var stylesheet: String {
        var rules: [String] = []
        let filters = [("brightness", brightness), ("contrast", contrast), ("saturate", saturation)]
            .filter { abs($0.1 - 1) > 0.001 }
            .map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }
        if !filters.isEmpty { rules.append("html { filter: \(filters.joined(separator: " ")) !important; }") }
        if let font = font?.trimmingCharacters(in: .whitespaces), !font.isEmpty {
            let family = font.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ";", with: "")
            rules.append(
                #"body, body *:not(code):not(pre):not(kbd):not(samp):not(code *):not(pre *) { font-family: "\#(family)" !important; }"#)
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules.append(css) }
        return rules.joined(separator: "\n")
    }
}
