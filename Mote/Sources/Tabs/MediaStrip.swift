import SwiftUI

/// At the foot of the sidebar while something plays in tabs you aren't on: a
/// strip for each, stacked behind the one heard last, that fan out when the
/// pointer comes over them.
struct MediaStack: View {
    @ObservedObject var browser: Browser
    let players: [Tab]

    @State private var open = false
    /// The strips under the pointer; open while there's one, and a moment
    /// longer, so crossing the gap between two doesn't fold them.
    @State private var over: Set<Tab.ID> = []
    @State private var folding: Task<Void, Never>?

    /// How far each strip behind peeks out above the one in front.
    private static let peek: CGFloat = 5
    /// Those behind that show while folded.
    private static let behind = 2

    /// The room it takes in the sidebar, folded: open, it rises over the tabs.
    static func height(_ count: Int) -> CGFloat {
        count == 0 ? 0 : MediaStrip.height + CGFloat(min(count - 1, behind)) * peek
    }

    var body: some View {
        let shown = Array(players.prefix(open ? 6 : Self.behind + 1).enumerated())
        Color.clear
            .frame(height: Self.height(players.count))
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    ForEach(shown.reversed(), id: \.element.id) { index, tab in
                        MediaStrip(browser: browser, tab: tab, open: open)
                            // Folded, those behind sit a little higher, smaller, under the first.
                            .scaleEffect(open ? 1 : 1 - CGFloat(index) * 0.05, anchor: .top)
                            .offset(y: open ? 0 : CGFloat(index) * (MediaStrip.height + 6) - CGFloat(index) * Self.peek)
                            .zIndex(Double(-index))
                            .allowsHitTesting(open || index == 0)
                            .onHover { hover(tab.id, $0) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .animation(Motion.settle, value: open)
            .animation(Motion.settle, value: players.map(\.id))
    }

    private func hover(_ id: Tab.ID, _ on: Bool) {
        folding?.cancel()
        if on {
            over.insert(id)
            open = true
            return
        }
        over.remove(id)
        guard over.isEmpty else { return }
        folding = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled, over.isEmpty { open = false }
        }
    }
}

/// One tab's strip: its icon (back to it), then previous, play or pause, next
/// and mute; open, what's playing and a button to put the strip away, which
/// leaves it playing. How far it has played fills it from the left, as a
/// tab's row fills with how far it's read.
struct MediaStrip: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var open = false

    static let height: CGFloat = 36
    /// Between it and the foot.
    static let gap: CGFloat = 6

    @State private var hovering = false

    var body: some View {
        if let media = tab.media {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                if open {
                    HStack(spacing: 4) {
                        Button {
                            browser.showPlaying(tab)
                        } label: {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Go to “\(tab.label)”")
                        Control(symbol: "xmark", help: "Hide; it keeps playing") { browser.putAway(tab) }
                    }
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .transition(.opacity)
                }
                HStack(spacing: 2) {
                    Button {
                        browser.showPlaying(tab)
                    } label: {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 16, dim: false)
                            .padding(.leading, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            }
            .background { MediaFill(reading: tab.mediaProgress, icon: tab.icon).clipShape(shape) }
            .background { Tinted(shape: shape, fill: hovering ? Palette.hover : Palette.wash) }
            .background { if open { shape.fill(Palette.frame) } }
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.quick, value: media.playing)
        }
    }

    /// How far it has played, in the site's own colours: its icon blurred,
    /// as an essential's ground is, up to there. Scaled, not laid out.
    private struct MediaFill: View {
        @ObservedObject var reading: Reading
        let icon: NSImage?

        var body: some View {
            if let icon {
                GeometryReader { room in
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: room.size.width * 1.4, height: room.size.width * 1.4)
                        .position(x: room.size.width / 2, y: room.size.height / 2)
                        .blur(radius: 24)
                        .opacity(0.2)
                }
                .mask(alignment: .leading) { Rectangle().scaleEffect(x: reading.fraction, anchor: .leading) }
            } else {
                ReadFill(reading: reading)
            }
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
