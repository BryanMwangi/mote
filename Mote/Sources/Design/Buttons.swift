import SwiftUI

/// A small icon button that lights up when `on`. Its washes are see-through
/// ink, so it reads on the frame, on the card, and on anything else.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize

    @Environment(\.packedButtons) private var packed

    /// Large in roomy places; packed beside the sidebar's address.
    private var side: CGFloat { controlSize == .large ? 32 : packed ? Metrics.packedButton : Metrics.button }

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: controlSize == .large ? 14 : 12, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(on || hovering ? 0.85 : 0.6))
                .frame(width: side, height: side)
                .background(Palette.veil.opacity(on ? 1.8 : hovering && enabled ? 1.2 : 0), in: Rounded.row)
                .contentShape(Rounded.row)
        }
        .buttonStyle(Pressed())
        .onHover { hovering = $0 }
        .help(help)
        // The help text without its shortcut, which follows three spaces.
        .accessibilityLabel(help.isEmpty ? icon : help.components(separatedBy: "   ")[0])
        .animation(Motion.hover, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// A quiet row-wide action with an icon, lit on hover, like "New tab" in the sidebar.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 16)
                Text(title).font(TextStyle.body.font)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.75) : Palette.muted)
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(hovering ? Palette.veil : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// A spinning arc while something loads.
struct Ring: View {
    var size: CGFloat = 10

    var body: some View {
        // Turned by the clock, not a repeating animation: one started as its
        // row was still settling (a chat's rows in their table) took that
        // movement up too, and drifted off its line. No parent's animations,
        // on or off, reach it either.
        TimelineView(.animation) { time in
            Circle()
                .trim(from: 0, to: 0.78)
                .stroke(Palette.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85) / 0.85 * 360))
        }
    }
}

extension EnvironmentValues {
    /// Buttons packed close beside the sidebar's address (Door, extensions' buttons).
    @Entry var packedButtons = false
}
