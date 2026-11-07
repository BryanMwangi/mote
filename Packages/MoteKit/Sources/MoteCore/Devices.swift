import CoreGraphics
import Foundation

/// A screen to show a page at in Responsive Design Mode, as Firefox's
/// devtools describe one: its size in CSS pixels, its pixel
/// density, whether it's touched, and the user agent its browser sends.
public struct Device: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /// "phones", "tablets", "laptops", "televisions", or `Devices.customType`.
    public var type: String
    public var width: CGFloat
    public var height: CGFloat
    /// `devicePixelRatio`.
    public var scale: CGFloat
    /// Dragging scrolls the page, as a finger does.
    public var touch: Bool
    /// Empty: Mote's own.
    public var userAgent: String
    /// In the menu until the list is edited.
    public var featured: Bool

    enum CodingKeys: String, CodingKey {
        case name, type, width, height, scale = "pixelRatio", touch, userAgent, featured
    }

    public init(
        name: String, type: String = Devices.customType, width: CGFloat, height: CGFloat, scale: CGFloat, touch: Bool = false,
        userAgent: String = "", featured: Bool = true
    ) {
        self.name = name
        self.type = type
        self.width = width
        self.height = height
        self.scale = scale
        self.touch = touch
        self.userAgent = userAgent
        self.featured = featured
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// Turned on its side.
    public var rotated: Device {
        var turned = self
        (turned.width, turned.height) = (height, width)
        return turned
    }

    /// The same device at another size, which is no longer the listed one.
    public func sized(width: CGFloat, height: CGFloat) -> Device {
        var resized = self
        resized.width = max(Devices.smallest, width.rounded())
        resized.height = max(Devices.smallest, height.rounded())
        if resized.size != size, resized.size != rotated.size { resized.name = Devices.custom }
        return resized
    }
}

public enum Devices {
    /// What a resized device is called.
    public static let custom = "Custom"
    /// The type of the devices the user adds.
    public static let customType = "custom"
    /// No page is narrower or shorter than this.
    public static let smallest: CGFloat = 120

    /// Firefox's list (Mote/Resources/devices.json), or the user's own.
    public static func decode(_ data: Data) throws -> [Device] {
        try JSONDecoder().decode([Device].self, from: data)
    }

    /// Where the page goes in `area`, centred: at its own size when that fits
    /// or `fits` is off, scaled down to fit otherwise. Never scaled up. At its
    /// own size it sits at the top when it's taller than the area, so the
    /// page's start shows.
    public static func place(_ size: CGSize, in area: CGRect, fits: Bool) -> (frame: CGRect, scale: CGFloat) {
        let scale = fits ? min(1, area.width / size.width, area.height / size.height) : 1
        // Whole points, rounded up: WebKit lays the page out at the frame over
        // the scale, rounded down, so a fraction short would lose a pixel.
        let shown = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        // On whole points, so the page isn't drawn blurred between pixels.
        let y = shown.height > area.height ? area.minY : (area.minY + (area.height - shown.height) / 2).rounded(.down)
        let x = (area.minX + (area.width - shown.width) / 2).rounded(.down)
        return (CGRect(x: x, y: y, width: shown.width, height: shown.height), scale)
    }
}
