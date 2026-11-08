import Combine
import SwiftUI

extension View {
    /// A list's scroll bar as Zen's: a thin thumb floating over the rows, no
    /// track or border, there only while the list moves. Before macOS 15,
    /// which can't follow a scroll, the system's own.
    @ViewBuilder func floatingScrollBar() -> some View {
        if #available(macOS 15, *) {
            modifier(FloatingScrollBar())
        } else {
            self
        }
    }
}

/// Where the thumb is and whether it shows. The thumb alone watches it, so
/// the list isn't worked out again on every frame of a scroll.
@MainActor private final class ThumbPlace: ObservableObject {
    /// The part of the list in view, as fractions of its height.
    @Published var span: ClosedRange<CGFloat>?
    @Published var shown = false
    /// The pointer is over the strip it moves in, or it's held.
    @Published var held = false
    private var hiding: Task<Void, Never>?
    /// How far the list scrolls, for a drag; and scrolling it there.
    var room: CGFloat = 0
    var scroll: (CGFloat) -> Void = { _ in }

    func moving(_ moving: Bool) {
        // Rows passing under the pointer meanwhile don't light up (see ScrollHover).
        ScrollHover.moving = moving
        hiding?.cancel()
        if moving {
            shown = true
        } else {
            // A moment after it stops, as the system's overlay bar.
            hiding = Task {
                try? await Task.sleep(for: .seconds(0.6))
                if !Task.isCancelled { shown = false }
            }
        }
    }
}

@available(macOS 15, *)
private struct FloatingScrollBar: ViewModifier {
    /// Held, not observed: the thumb observes it.
    @State private var place = ThumbPlace()
    /// Set only by the thumb, to scroll the list.
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onAppear { place.scroll = { [$position] y in $position.wrappedValue.scrollTo(y: y) } }
            .onScrollPhaseChange { _, phase in place.moving(phase != .idle) }
            .onScrollGeometryChange(for: ClosedRange<CGFloat>?.self) { geometry in
                let whole = geometry.contentSize.height
                let seen = geometry.containerSize.height
                place.room = max(0, whole - seen)
                guard whole > seen, whole > 0 else { return nil }
                let part = seen / whole
                // Held inside the list while it bounces at either end.
                let top = min(max(0, (geometry.contentOffset.y + geometry.contentInsets.top) / whole), 1 - part)
                return top...(top + part)
            } action: { _, span in
                place.span = span
            }
            .overlay { Thumb(place: place) }
    }
}

/// The thumb, in a strip along the list's edge: there while scrolling, or
/// with the pointer over the strip, where it can be dragged, or the strip
/// clicked to jump there, as the system's scroll bar.
private struct Thumb: View {
    @ObservedObject var place: ThumbPlace
    /// Where the thumb was taken from, as the share of the way down.
    @State private var grabbed: (at: CGFloat, travel: CGFloat)?

    var body: some View {
        GeometryReader { box in
            if let span = place.span {
                let part = span.upperBound - span.lowerBound
                let height = max(24, part * box.size.height)
                let room = box.size.height - height
                // The top's share of the room the thumb can travel.
                let travel = part < 1 ? span.lowerBound / (1 - part) : 0
                let wide: CGFloat = place.held ? 7 : 4
                ZStack(alignment: .topTrailing) {
                    // The strip: thin, so the rows' close buttons stay clear of it.
                    Color.clear.frame(width: 9).contentShape(Rectangle())
                    Capsule()
                        .fill(Palette.ink.opacity(place.held ? 0.45 : 0.32))
                        .frame(width: wide, height: height)
                        .offset(x: -1, y: travel * room)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(place.shown || place.held ? 1 : 0)
                .onHover { place.held = $0 || grabbed != nil }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard room > 0 else { return }
                            // On the thumb it's held where taken; off it, it centres there first.
                            let start =
                                grabbed
                                ?? {
                                    let top = travel * room
                                    let on = drag.startLocation.y >= top && drag.startLocation.y <= top + height
                                    return (on ? drag.startLocation.y - top : height / 2, travel)
                                }()
                            grabbed = start
                            place.held = true
                            let share = min(max((drag.location.y - start.at) / room, 0), 1)
                            place.scroll(share * place.room)
                        }
                        .onEnded { _ in
                            grabbed = nil
                            place.held = false
                        })
            }
        }
        .padding(.vertical, 3)
        .animation(.easeOut(duration: place.shown || place.held ? 0.1 : 0.3), value: place.shown || place.held)
    }
}
