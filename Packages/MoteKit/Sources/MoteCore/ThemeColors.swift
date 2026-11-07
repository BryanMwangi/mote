import Foundation

/// The theme picker's field: a dot's angle
/// about the centre is its hue, its distance its lightness, and harmonies
/// set the other dots around the colour wheel from the first.
public enum ThemeColors {
    public enum Harmony: CaseIterable, Sendable {
        case complementary, analogous, triadic

        public var turns: [Double] {
            switch self {
            case .complementary: [180]
            case .analogous: [50, 310]
            case .triadic: [120, 240]
            }
        }
    }

    /// The colour at `point`, x and y from -1 to 1 about the field's centre.
    public static func hex(at point: CGPoint) -> String {
        let distance = min(hypot(point.x, point.y), 1)
        var hue = atan2(point.y, point.x) * 180 / .pi
        if hue < 0 { hue += 360 }
        let rgb = rgb(hue: hue, saturation: 0.85, lightness: 0.25 + distance * 0.5)
        return SpaceTheme.hex(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// Where `hex` sits in the field; the centre for one it can't read.
    public static func point(for hex: String) -> CGPoint {
        guard let rgb = SpaceTheme.rgb(hex) else { return .zero }
        let high = max(rgb.red, rgb.green, rgb.blue), low = min(rgb.red, rgb.green, rgb.blue)
        let lightness = (high + low) / 2
        var hue = 0.0
        if high != low {
            let span = high - low
            hue =
                switch high {
                case rgb.red: (rgb.green - rgb.blue) / span + (rgb.green < rgb.blue ? 6 : 0)
                case rgb.green: (rgb.blue - rgb.red) / span + 2
                default: (rgb.red - rgb.green) / span + 4
                }
            hue *= 60
        }
        let distance = min(max((lightness - 0.25) / 0.5, 0), 1)
        let angle = hue * .pi / 180
        return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }

    /// The other dots for `harmony`, turned about the centre from `first`.
    public static func others(_ harmony: Harmony, from first: CGPoint) -> [CGPoint] {
        harmony.turns.map { turn in
            let angle = turn * .pi / 180
            return CGPoint(x: first.x * cos(angle) - first.y * sin(angle), y: first.x * sin(angle) + first.y * cos(angle))
        }
    }

    /// `hex` with its hue turned by `degrees`, its saturation and lightness kept.
    public static func turned(_ hex: String, by degrees: Double) -> String {
        guard let rgb = SpaceTheme.rgb(hex) else { return hex }
        let high = max(rgb.red, rgb.green, rgb.blue), low = min(rgb.red, rgb.green, rgb.blue)
        let lightness = (high + low) / 2
        guard high != low else { return hex }
        let span = high - low
        let saturation = span / (1 - abs(2 * lightness - 1))
        var hue =
            switch high {
            case rgb.red: (rgb.green - rgb.blue) / span + (rgb.green < rgb.blue ? 6 : 0)
            case rgb.green: (rgb.blue - rgb.red) / span + 2
            default: (rgb.red - rgb.green) / span + 4
            }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let turned = self.rgb(hue: hue, saturation: min(saturation, 1), lightness: lightness)
        return SpaceTheme.hex(red: turned.0, green: turned.1, blue: turned.2)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let part = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) =
            switch hue {
            case ..<60: (chroma, part, 0)
            case ..<120: (part, chroma, 0)
            case ..<180: (0, chroma, part)
            case ..<240: (0, part, chroma)
            case ..<300: (part, 0, chroma)
            default: (chroma, 0, part)
            }
        return (r + base, g + base, b + base)
    }
}
