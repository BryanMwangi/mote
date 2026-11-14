// Draws the DMG window's background and the volume icon.
//
//   swift Tools/dmg/art.swift <Mote.app> <out dir>
//
// Writes background.tiff, the 660×400 picture and its @2x in one Retina TIFF,
// JPEG-compressed: its soft gradients took 800 KB as LZW (tiffutil's), a
// tenth of that as JPEG with the words still sharp. And VolumeIcon.iconset
// from the app's icon, up to 256 pt: a volume never shows bigger, and the
// 512 pt sizes were two thirds of the icon's weight.
// Finder draws the real icons and their labels over the background, at the
// positions in settings.py, so the picture leaves those spots empty.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Swift 6.2's script runner passes its own compiler flags first, then the
// script's arguments after a "--".
let arguments =
    CommandLine.arguments.firstIndex(of: "--").map { ["art.swift"] + CommandLine.arguments[($0 + 1)...] }
    ?? CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: swift art.swift <Mote.app> <out dir>\n".data(using: .utf8)!)
    exit(1)
}
let app = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Where Finder puts the two icons (their centres), matching settings.py.
let appSpot = CGPoint(x: 170, y: 180)
let applicationsSpot = CGPoint(x: 490, y: 180)
let size = CGSize(width: 660, height: 400)

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// The warm light of the pebble, pooled under the app icon.
struct Glow: View {
    var body: some View {
        RadialGradient(
            colors: [Color(hex: 0xF6C6A8).opacity(0.55), Color(hex: 0xF4DCC0).opacity(0.25), .clear],
            center: .center, startRadius: 0, endRadius: 150
        )
        .frame(width: 300, height: 300)
        .position(appSpot)
    }
}

/// A light curve from the app to Applications, ending in an open chevron.
struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let start = CGPoint(x: appSpot.x + 92, y: appSpot.y - 6)
        let end = CGPoint(x: applicationsSpot.x - 92, y: applicationsSpot.y - 6)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: start.y - 34))
        // The chevron follows the curve's direction at its end.
        let angle = atan2(end.y - (start.y - 34), end.x - (start.x + end.x) / 2)
        for turn in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + 9 * cos(angle + turn), y: end.y + 9 * sin(angle + turn)))
        }
        return path
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF5F1EE)], startPoint: .top, endPoint: .bottom)
            Glow()
            Arrow()
                .stroke(Color(hex: 0xB9B2AD), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            Text("The web, with nothing in the way.")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color(hex: 0x2B2724))
                .position(x: size.width / 2, y: 62)
            Text("Drag Mote into Applications")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x9C9591))
                .position(x: size.width / 2, y: 350)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Both sizes in one TIFF, JPEG inside, 72 dpi per point so Finder shows
/// the @2x at the same size.
@MainActor
func writeBackground() throws {
    let file = out.appendingPathComponent("background.tiff") as CFURL
    guard let tiff = CGImageDestinationCreateWithURL(file, UTType.tiff.identifier as CFString, 2, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    for scale in [1.0, 2.0] {
        let renderer = ImageRenderer(content: Background().environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
            // 7: JPEG.
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 7],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(tiff, image, properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(tiff) else { throw CocoaError(.fileWriteUnknown) }
}

/// The app's icon as an iconset, for `iconutil` to make VolumeIcon.icns.
@MainActor
func writeIconset() throws {
    let icon = NSWorkspace.shared.icon(forFile: app)
    let set = out.appendingPathComponent("VolumeIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256] {
        for scale in [1, 2] {
            let pixels = points * scale
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
        }
    }
}

try MainActor.assumeIsolated {
    try writeBackground()
    try writeIconset()
}
