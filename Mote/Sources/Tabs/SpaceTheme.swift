import AppKit
import Combine
import MoteCore
import SwiftUI

/// The space's colours behind the window's frame, as Zen's space themes: a
/// gradient across it, as strong as the theme says, with an optional grain.
/// A switch of space fades from one to the next.
struct SpaceGround: View {
    let theme: SpaceTheme?
    let space: UUID
    /// A drag in the theme editor shows here alone, frame by frame.
    @ObservedObject private var drafts = ThemeDrafts.shared

    init(theme: SpaceTheme?, space: UUID) {
        self.theme = theme
        self.space = space
    }

    var body: some View {
        let theme = drafts.bySpace[space] ?? theme
        ZStack {
            if let theme, !theme.colors.isEmpty {
                LinearGradient(colors: theme.colors.compactMap(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(theme.opacity)
                    .overlay {
                        if theme.grain > 0 {
                            Image(nsImage: Self.grain).resizable(resizingMode: .tile).opacity(0.2 * theme.grain).blendMode(.overlay)
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

/// Theme…, from a space's menu, as Zen's picker in a frosted panel beside
/// the sidebar: light, dark or Mote's own look; a field where a click adds a
/// colour (up to three) and dots drag, their angle the hue and their reach
/// the lightness; harmonies; swatches; a wave for strength and a dial for
/// grain. Every change shows at once, and is kept when a drag ends.
struct ThemeEditor: View {
    @ObservedObject var browser: Browser
    let space: UUID

    @ObservedObject private var drafts = ThemeDrafts.shared
    @State private var harmony: ThemeColors.Harmony?
    @State private var page = 0

    init(browser: Browser, space: UUID) {
        self.browser = browser
        self.space = space
    }

    private var theme: SpaceTheme? { drafts.bySpace[space] ?? browser.spaces.first { $0.id == space }?.theme }
    private var colors: [String] { theme?.colors ?? [] }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Door(icon: "xmark", help: "Close") { browser.themingSpace = nil }
                Spacer()
                scheme(nil, "sparkles", "Mote's look")
                scheme(.light, "sun.max", "Light")
                scheme(.dark, "moon", "Dark")
                Spacer()
                Door(icon: "dice", help: "Shuffle: a swatch at random") {
                    let swatch = SpaceTheme.swatches.randomElement()!
                    harmony = swatch.dots == 3 ? .analogous : nil
                    set(swatch.colors, saving: true) { $0.colors = $1 }
                }
            }
            .background(DragHandle())
            ThemeField(colors: colors, harmony: harmony) { set($0, saving: $1) { $0.colors = $1 } }
            HStack(spacing: 22) {
                Door(icon: "plus", help: "Add a colour") { addDot() }.disabled(colors.isEmpty || colors.count >= 3)
                Door(icon: "minus", help: "Take a colour away") { set(Array(colors.dropLast()), saving: true) { $0.colors = $1 } }
                    .disabled(colors.isEmpty)
                Door(icon: "circle.hexagongrid", help: "Harmony: the colours around the wheel from the first") { nextHarmony() }
                    .disabled(colors.isEmpty)
            }
            swatches
            HStack(spacing: 16) {
                WaveSlider(value: theme?.opacity ?? 0.45) { value, done in
                    set(colors, saving: done) {
                        $0.opacity = value; _ = $1
                    }
                }
                GrainDial(value: theme?.grain ?? 0) { value, done in
                    set(colors, saving: done) {
                        $0.grain = value; _ = $1
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func scheme(_ scheme: SpaceTheme.Scheme?, _ symbol: String, _ help: String) -> some View {
        Door(icon: symbol, on: theme?.scheme == scheme, help: help) {
            set(colors, saving: true) {
                $0.scheme = scheme; _ = $1
            }
        }
    }

    private var swatches: some View {
        let pages = SpaceTheme.swatches.count / 9
        return HStack(spacing: 4) {
            Door(icon: "chevron.left", help: "") { page = (page + pages - 1) % pages }
            ForEach(SpaceTheme.swatches[page * 9..<page * 9 + 9], id: \.self) { swatch in
                Button {
                    harmony = swatch.dots == 3 ? .analogous : nil
                    set(swatch.colors, saving: true) { $0.colors = $1 }
                } label: {
                    // Three dots show as their gradient.
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: swatch.colors.compactMap(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 21, height: 21)
                        .overlay(Circle().strokeBorder(Palette.edge))
                }
                .buttonStyle(.plain)
            }
            Door(icon: "chevron.right", help: "") { page = (page + 1) % pages }
        }
    }

    /// Another dot, where the harmony (or the opposite side) puts it.
    private func addDot() {
        let first = ThemeColors.point(for: colors[0])
        let turns = ThemeColors.others(harmony ?? (colors.count == 1 ? .complementary : .triadic), from: first)
        set(colors + [ThemeColors.hex(at: turns[min(colors.count - 1, turns.count - 1)])], saving: true) { $0.colors = $1 }
    }

    /// The next harmony, with the other dots set by it from the first.
    private func nextHarmony() {
        let all = ThemeColors.Harmony.allCases
        let next = harmony.flatMap { all.firstIndex(of: $0) }.map { all[($0 + 1) % all.count] } ?? .complementary
        harmony = next
        let first = ThemeColors.point(for: colors[0])
        set([colors[0]] + ThemeColors.others(next, from: first).map(ThemeColors.hex(at:)), saving: true) { $0.colors = $1 }
    }

    /// Changes the theme, from a plain one when there's none; none at all
    /// once its colours and look are gone. Kept on disk only when `saving`.
    private func set(_ colors: [String], saving: Bool, _ change: (inout SpaceTheme, [String]) -> Void) {
        var next = theme ?? SpaceTheme(colors: [])
        change(&next, colors)
        let kept =
            next.colors.isEmpty && next.scheme == nil
            ? nil : SpaceTheme(colors: next.colors, opacity: next.opacity, grain: next.grain, scheme: next.scheme)
        // Mid-drag, only the backdrop and this panel follow; the space itself
        // changes (and every window with it) once the drag ends.
        guard saving else { return drafts.bySpace[space] = kept ?? SpaceTheme(colors: []) }
        browser.setSpaceTheme(space, to: kept)
        drafts.bySpace[space] = nil
    }
}

/// The field: a dot grid in a rounded square, the dots on it; the boost
/// editor's too, with two dots.
struct ThemeField: View {
    let colors: [String]
    let harmony: ThemeColors.Harmony?
    var limit = 3
    var side: CGFloat = 268
    @State private var dragging = false
    /// The new colours, and whether the change is done (a drag let go).
    let change: ([String], Bool) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.25))
            Canvas { context, size in
                for x in stride(from: 8.0, to: size.width, by: 12) {
                    for y in stride(from: 8.0, to: size.height, by: 12) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.14)))
                    }
                }
            }
            Circle().strokeBorder(.white.opacity(0.08)).padding(20)
            if colors.isEmpty {
                Text("Click to add a colour").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: index == 0 ? 38 : 28, height: index == 0 ? 38 : 28)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .position(place(ThemeColors.point(for: hex)))
                    .gesture(
                        DragGesture(coordinateSpace: .named("field"))
                            .onChanged {
                                dragging = true
                                change(moved(index, to: $0.location), false)
                            }
                            .onEnded {
                                change(moved(index, to: $0.location), true)
                                dragging = false
                            })
            }
        }
        // Set by a swatch, shuffle or harmony, the dots spring to their places,
        // as Zen's do; dragged, they keep to the pointer.
        .animation(dragging ? nil : .spring(response: 0.5, dampingFraction: 0.58), value: colors)
        .frame(width: side, height: side)
        .coordinateSpace(name: "field")
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named("field")) { at in
            if colors.count < limit { change(colors + [ThemeColors.hex(at: unit(at))], true) }
        }
    }

    /// The field's radius, inside its edge.
    private var radius: CGFloat { side / 2 - 24 }

    private func place(_ point: CGPoint) -> CGPoint { CGPoint(x: side / 2 + point.x * radius, y: side / 2 + point.y * radius) }

    private func unit(_ at: CGPoint) -> CGPoint {
        var point = CGPoint(x: (at.x - side / 2) / radius, y: (at.y - side / 2) / radius)
        let length = hypot(point.x, point.y)
        if length > 1 { point = CGPoint(x: point.x / length, y: point.y / length) }
        return point
    }

    /// Dot `index` dragged to `at`; the first takes the others along by the harmony.
    private func moved(_ index: Int, to at: CGPoint) -> [String] {
        var next = colors
        let point = unit(at)
        next[index] = ThemeColors.hex(at: point)
        if index == 0, let harmony {
            for (offset, other) in ThemeColors.others(harmony, from: point).enumerated() where offset + 1 < next.count {
                next[offset + 1] = ThemeColors.hex(at: other)
            }
        }
        return next
    }
}

/// Strength as a wave, as Zen's: the stronger, the higher it swings.
private struct WaveSlider: View {
    let value: Double
    /// The new value, and whether the drag is done.
    let change: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08)).frame(height: 14)
                Wave(amplitude: 4 + value * 12).stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Wave(amplitude: 4 + value * 12).trim(from: 0, to: value)
                    .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { change(min(max($0.location.x / width, 0.1), 1), false) }
                    .onEnded { change(min(max($0.location.x / width, 0.1), 1), true) })
        }
        .frame(height: 44)
        .help("Strength")
    }

    private struct Wave: Shape {
        var amplitude: Double
        var animatableData: Double {
            get { amplitude }
            set { amplitude = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let steps = 120
            for step in 0...steps {
                let x = rect.minX + 6 + (rect.width - 12) * Double(step) / Double(steps)
                let y = rect.midY + sin(Double(step) / Double(steps) * .pi * 12) * amplitude
                step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            return path
        }
    }
}

/// Grain on a dial: a click steps it round, a drag up or right turns it up.
private struct GrainDial: View {
    let value: Double
    /// The new value, and whether the drag is done.
    let change: (Double, Bool) -> Void
    /// Where it was when the drag began.
    @State private var from: Double?

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { tick in
                Circle().fill(.white.opacity(Double(tick) / 11 <= value ? 0.7 : 0.2)).frame(width: 3, height: 3)
                    .offset(y: -30).rotationEffect(.degrees(-135 + Double(tick) * 270 / 11))
            }
            Circle().fill(.black.opacity(0.35)).frame(width: 44, height: 44)
            Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 9).offset(y: -15).rotationEffect(.degrees(-135 + value * 270))
        }
        .frame(width: 68, height: 68)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = from ?? value
                    from = start
                    change(turned(start, by: drag.translation), false)
                }
                .onEnded { drag in
                    let start = from ?? value
                    from = nil
                    // Barely moved: a click, a step round.
                    if abs(drag.translation.width) + abs(drag.translation.height) < 3 {
                        change(start >= 1 ? 0 : min(1, (start * 4).rounded(.down) / 4 + 0.25), true)
                    } else {
                        change(turned(start, by: drag.translation), true)
                    }
                }
        )
        .help("Grain")
    }

    private func turned(_ start: Double, by travel: CGSize) -> Double {
        min(max(start + Double(travel.width - travel.height) / 140, 0), 1)
    }
}

/// The theme being dragged in the editor, by space, before it's kept: only
/// the backdrop and the editor watch it, so a drag redraws nothing else.
@MainActor
final class ThemeDrafts: ObservableObject {
    static let shared = ThemeDrafts()
    @Published var bySpace: [UUID: SpaceTheme] = [:]
}
