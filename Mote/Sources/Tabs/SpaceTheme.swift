import AppKit
import MoteCore
import SwiftUI

/// The space's colours behind the window's frame, as Zen's space themes: a
/// gradient across it, as strong as the theme says, with an optional grain.
/// A switch of space fades from one to the next.
struct SpaceGround: View {
    let theme: SpaceTheme?
    let space: UUID

    var body: some View {
        ZStack {
            if let theme, !theme.colors.isEmpty {
                LinearGradient(colors: theme.colors.compactMap(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(theme.opacity)
                    .overlay {
                        if theme.grain {
                            Image(nsImage: Self.grain).resizable(resizingMode: .tile).opacity(0.12).blendMode(.overlay)
                        }
                    }
                    .id(space)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: space)
        .allowsHitTesting(false)
    }

    /// A square of grey noise, made once, tiled for the grain.
    private static let grain: NSImage = {
        let side = 96
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8)
        if let data = bitmap?.bitmapData { for i in 0..<side * side { data[i] = UInt8.random(in: 0...255) } }
        let image = NSImage(size: NSSize(width: side, height: side))
        bitmap.map { image.addRepresentation($0) }
        return image
    }()
}

extension Color {
    /// "#rrggbb", or nil.
    init?(hex: String) {
        guard let rgb = SpaceTheme.rgb(hex) else { return nil }
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Theme…, from a space's menu: Zen's picker, leaner. Presets, up to three
/// colours, how strongly they show, and grain; every change shows at once.
struct SpaceThemePanel: View {
    @ObservedObject var browser: Browser
    let space: UUID

    private var theme: SpaceTheme? { browser.spaces.first { $0.id == space }?.theme }
    private var name: String { browser.spaces.first { $0.id == space }?.name ?? "Space" }

    var body: some View {
        Plate("\(name)’s Colours", width: 440, close: { browser.themingSpace = nil }) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ForEach(Array(SpaceTheme.presets.enumerated()), id: \.offset) { _, preset in
                            Button {
                                set { _ in preset }
                            } label: {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: preset.colors.compactMap(Color.init(hex:)), startPoint: .topLeading,
                                            endPoint: .bottomTrailing)
                                    )
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Palette.edge))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(Array((theme?.colors ?? []).enumerated()), id: \.offset) { index, hex in
                            ColorPicker("", selection: colour(at: index, hex: hex), supportsOpacity: false).labelsHidden()
                        }
                        if (theme?.colors.count ?? 0) < 3 {
                            Door(icon: "plus", help: "Add a colour") {
                                set { theme in theme.colors.append(theme.colors.last ?? "#7c5cff") }
                            }
                        }
                        if (theme?.colors.count ?? 0) > 1 {
                            Door(icon: "minus", help: "Take a colour away") { set { theme in theme.colors.removeLast() } }
                        }
                        Spacer()
                    }
                    HStack {
                        Text("Strength").font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        Slider(
                            value: Binding(get: { theme?.opacity ?? 0.45 }, set: { value in set { $0.opacity = value } }), in: 0.1...1)
                    }
                    Toggle("Grain", isOn: Binding(get: { theme?.grain ?? false }, set: { on in set { $0.grain = on } }))
                        .font(.system(size: 12.5))
                }
                .padding(14)
            }
        } foot: {
            HStack {
                Text("Behind the tabs and around the page.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                if theme != nil { Pill("No Colours") { browser.setSpaceTheme(space, to: nil) } }
            }
        }
    }

    /// Changes the theme, starting from a plain one when there's none.
    private func set(_ change: (inout SpaceTheme) -> Void) {
        var next = theme ?? SpaceTheme(colors: ["#7c5cff"])
        change(&next)
        browser.setSpaceTheme(space, to: SpaceTheme(colors: next.colors, opacity: next.opacity, grain: next.grain))
    }

    private func colour(at index: Int, hex: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex) ?? .purple },
            set: { colour in
                guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
                set { theme in
                    if theme.colors.indices.contains(index) {
                        theme.colors[index] = SpaceTheme.hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                    }
                }
            })
    }
}
