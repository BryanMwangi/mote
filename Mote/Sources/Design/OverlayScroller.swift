import AppKit
import SwiftUI

extension View {
    /// Inside a ScrollView's content: its scroll bar floats over the content,
    /// with no track or border, and shows only while scrolling, whatever the
    /// Mac's "Show scroll bars" setting (a mouse plugged in makes it "Always").
    func floatingScroller() -> some View {
        background(FloatingScroller())
    }
}

private struct FloatingScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }

    final class Probe: NSView {
        private var watch: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// SwiftUI sets its scroll view back to the boxed style soon after it
        /// appears, and again when the Mac's setting changes, so the style is
        /// watched and put back each time.
        func apply() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.autohidesScrollers = true
            guard watch == nil else { return }
            watch = scroll.observe(\.scrollerStyle, options: [.new]) { scroll, _ in
                MainActor.assumeIsolated {
                    if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                }
            }
        }
    }
}
