import SwiftUI

/// A site's icon, or its first letter in a faint square until the icon comes.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false
    var mote = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.22, style: .continuous) }

    var body: some View {
        Group {
            if mote {
                Logomark().fill(Palette.muted).frame(width: size, height: size)
            } else if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size).clipShape(shape)
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(Palette.ink.opacity(0.06), in: shape)
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}

extension NSImage {
    /// Nearly white and colourless, as some sites' dark-mode icons are: such
    /// an icon vanishes on a light tile. Worked out once per icon.
    @MainActor var isPale: Bool {
        let key = ObjectIdentifier(self)
        if let known = Self.pale[key] { return known }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        let side = 12
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            for x in 0..<side {
                for y in 0..<side {
                    guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.3 else { continue }
                    red += colour.redComponent
                    green += colour.greenComponent
                    blue += colour.blueComponent
                    weight += 1
                }
            }
        }
        let found =
            weight > 0
            && {
                let (r, g, b) = (red / weight, green / weight, blue / weight)
                return min(r, g, b) > 0.8 && max(r, g, b) - min(r, g, b) < 0.12
            }()
        Self.pale[key] = found
        return found
    }

    @MainActor private static var pale: [ObjectIdentifier: Bool] = [:]
}
