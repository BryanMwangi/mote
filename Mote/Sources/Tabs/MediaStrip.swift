import SwiftUI

/// At the foot of the sidebar while something plays in a tab you aren't on:
/// its icon (back to it), what's playing, previous, play or pause, next and
/// mute.
struct MediaStrip: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    static let height: CGFloat = 36
    /// Between it and the foot.
    static let gap: CGFloat = 6

    @State private var hovering = false

    var body: some View {
        if let media = tab.media {
            HStack(spacing: 2) {
                Button(action: browser.showPlaying) {
                    HStack(spacing: 8) {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 16, dim: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(media.title.isEmpty ? tab.label : media.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            if !media.artist.isEmpty {
                                Text(media.artist).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to “\(tab.label)”")

                Control(symbol: "backward.fill", help: "Previous") { tab.send(.previous) }
                Control(symbol: media.playing ? "pause.fill" : "play.fill", help: media.playing ? "Pause" : "Play") {
                    tab.send(.toggle)
                }
                if media.hasNext { Control(symbol: "forward.fill", help: "Next") { tab.send(.next) } }
                Control(symbol: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: tab.muted ? "Unmute" : "Mute") {
                    tab.toggleMute()
                }
            }
            .padding(.trailing, 4)
            .frame(height: Self.height)
            .background(hovering ? Palette.hover : Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.quick, value: media.playing)
        }
    }

    private struct Control: View {
        let symbol: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: 24, height: 24)
                    .background(hovering ? Palette.veil : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}
