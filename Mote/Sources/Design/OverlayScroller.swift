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
        private var watching = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The Mac's setting can change while Mote runs; AppKit puts the
            // old style back when it does. Selector observers go by themselves.
            guard !watching, window != nil else { return }
            watching = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(styleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }

        @objc private func styleChanged() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.autohidesScrollers = true
        }
    }
}
