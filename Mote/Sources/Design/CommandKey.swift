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
