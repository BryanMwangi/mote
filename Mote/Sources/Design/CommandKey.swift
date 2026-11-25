import AppKit
import SwiftUI

extension View {
    /// Calls `change` as ⌘ goes down and comes up while the view is on screen,
    /// and with false when it goes.
    func onCommandKey(_ change: @escaping (Bool) -> Void) -> some View {
        modifier(CommandKeyWatch(change: change))
    }
}

private struct CommandKeyWatch: ViewModifier {
    let change: (Bool) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    change(event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command))
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                change(false)
            }
            // ⌘ let go in another app never reaches this one.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in change(false) }
    }
}

extension View {
    /// Calls `act` with which way the person scrolls with a wheel or
    /// trackpad over this view, true toward the top; scrolling done in code
    /// doesn't count.
    func onScrollWheel(_ act: @escaping (_ up: Bool) -> Void) -> some View {
        background(ScrollWheelWatch(act: act))
    }
}

private struct ScrollWheelWatch: FillsRoom {
    let act: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) { view.act = act }

    final class Watcher: NSView {
        var act: (Bool) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.scrollingDeltaY != 0,
                    self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.act(event.scrollingDeltaY > 0)
                return event
            }
        }
    }
}
