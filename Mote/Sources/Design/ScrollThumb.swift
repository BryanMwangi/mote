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
    private var hiding: Task<Void, Never>?

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

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in place.moving(phase != .idle) }
            .onScrollGeometryChange(for: ClosedRange<CGFloat>?.self) { geometry in
                let whole = geometry.contentSize.height
                let seen = geometry.containerSize.height
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

private struct Thumb: View {
    @ObservedObject var place: ThumbPlace

    var body: some View {
        GeometryReader { box in
            if let span = place.span {
                let part = span.upperBound - span.lowerBound
                let height = max(24, part * box.size.height)
                // The top's share of the room the thumb can travel.
                let travel = part < 1 ? span.lowerBound / (1 - part) : 0
                Capsule()
                    .fill(Palette.ink.opacity(0.32))
                    .frame(width: 4, height: height)
                    .offset(x: box.size.width - 4, y: travel * (box.size.height - height))
            }
        }
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .opacity(place.shown ? 1 : 0)
        .animation(.easeOut(duration: place.shown ? 0.1 : 0.3), value: place.shown)
        .allowsHitTesting(false)
    }
}
