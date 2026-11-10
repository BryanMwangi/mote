import SwiftUI

/// At the foot of the sidebar while something plays in tabs you aren't on: a
/// strip for each, stacked behind the one heard last, that fan out when the
/// pointer comes over them.
///
/// Open, the tabs above make room rather than lie under them: the tabs are an
/// AppKit view, which would take the pointer before the strips over it.
struct MediaStack: View {
    let browser: Browser
    let players: [Tab]
    @Binding var open: Bool

    /// The room the strips take: folded, or fanned out over the tabs.
    static func height(_ count: Int, open: Bool) -> CGFloat {
        let shown = CGFloat(min(count, tallest))
        let stack =
            open
            ? shown * MediaStrip.openHeight + (shown - 1) * StripStack.gap
            : MediaStrip.height + CGFloat(min(count - 1, StripStack.behind)) * StripStack.peek
        return count == 0 ? 0 : stack + MediaStrip.gap
    }

    /// The strips open at once; more scroll, so they don't take the sidebar.
    static let tallest = 3

    @State private var folding: Task<Void, Never>?

    var body: some View {
        let shown = Array((open ? players : Array(players.prefix(StripStack.behind + 1))).enumerated())
        let stack = StripStack(open: open) {
            ForEach(shown, id: \.element.id) { index, tab in
                MediaStrip(browser: browser, tab: tab, open: open)
                    // Folded, those behind are a little smaller, under the first.
                    .scaleEffect(open ? 1 : 1 - CGFloat(index) * 0.05, anchor: .top)
                    .zIndex(Double(-index))
                    .allowsHitTesting(open || index == 0)
            }
        }
        Group {
            if open, players.count > Self.tallest {
                // The one heard last, at the foot, in view first.
                ScrollView { stack }
                    .scrollIndicators(.never)
                    .defaultScrollAnchor(.bottom)
                    .frame(height: Self.height(players.count, open: true) - MediaStrip.gap)
            } else {
                stack
            }
        }
        // Opens with the pointer on the stack as drawn, gaps included, and
        // folds a moment after it leaves.
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .padding(.horizontal, 10)
        .padding(.bottom, MediaStrip.gap)
        .animation(Motion.settle, value: open)
        .animation(Motion.settle, value: players.map(\.id))
        .onDisappear { open = false }
    }

    private func hover(_ on: Bool) {
        folding?.cancel()
        if on { return show(true) }
        folding = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { show(false) }
        }
    }

    /// Opens or folds them.
    private func show(_ on: Bool) {
        if on != open { open = on }
    }
}

/// The strips from the bottom up, the first lowest: open, one above another;
/// folded, those behind peeking out above it. Placed, not offset, so the
/// pointer finds each strip where it's drawn.
struct StripStack: Layout {
    var open: Bool

    /// How far each strip behind peeks out above the one in front.
    static let peek: CGFloat = 5
    /// Those behind that show while folded.
    static let behind = 2
    static let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        guard let first = heights.first else { return CGSize(width: width, height: 0) }
        let rest = CGFloat(heights.count - 1)
        return CGSize(width: width, height: open ? heights.reduce(0, +) + rest * Self.gap : first + rest * Self.peek)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var bottom = bounds.maxY
        for (index, subview) in subviews.enumerated() {
            let size = ProposedViewSize(
                width: bounds.width, height: subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height)
            let top = open ? bottom - (size.height ?? 0) : bounds.maxY - (size.height ?? 0) - CGFloat(index) * Self.peek
            subview.place(at: CGPoint(x: bounds.minX, y: top), proposal: size)
            bottom = top - Self.gap
        }
    }
}

/// One tab's strip: its icon (back to it), then previous, play or pause, next
/// and mute; open, what's playing and a button to put the strip away, which
/// leaves it playing. How far it has played fills it from the left, as a
/// tab's row fills with how far it's read.
struct MediaStrip: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    var open = false

    static let height: CGFloat = 36
    /// Open, with what's playing above the buttons.
    static let openHeight: CGFloat = 68
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
                    .frame(height: Self.openHeight - Self.height - 6)
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
                    Control(symbol: "forward.fill", help: "Next") { tab.send(.next) }
                    Control(symbol: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: tab.muted ? "Unmute" : "Mute") {
                        tab.toggleMute()
                    }
                }
                .padding(.trailing, 4)
                .frame(height: Self.height)
            }
            // Clipping doesn't stop the icon, drawn wider than the strip,
            // taking the pointer over the strips above.
            .background { MediaFill(reading: tab.mediaProgress, icon: tab.icon).clipShape(shape).allowsHitTesting(false) }
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
