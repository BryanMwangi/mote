import MoteCore
import SwiftUI

/// The toolbar off the card ("On hover"): it slides out over the page when
/// the pointer reaches the card's top edge, and goes again soon after the
/// pointer leaves it, unless the address is being edited. Pointer moves are
/// followed as `SidebarFold` follows them, and EdgeReveal decides.
struct ToolbarReveal: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var timers = PeekTimers()
    @State private var pointer = PointerWatch()

    /// Some slack before it goes, so a pointer crossing its edge on the way
    /// to a menu doesn't shut it.
    private static let grace = 0.35

    private var watching: Bool { browser.toolbarOnHover }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .background(
                WindowSetup { window in
                    pointer.window = window
                    watch()
                }
            )
            .onAppear(perform: watch)
            .onDisappear {
                pointer.stop()
                timers.cancelShow()
                timers.cancelHide()
            }
            .onChange(of: watching) {
                timers.cancelShow()
                timers.cancelHide()
                browser.toolbarRevealed = false
                watch()
            }
            // Editing ended: where the pointer is now decides, without
            // waiting for it to move.
            .onChange(of: browser.editingInBar) { _, editing in
                if !editing, browser.toolbarRevealed { follow() }
            }
    }

    private func watch() {
        watching ? pointer.start { follow() } : pointer.stop()
    }

    private func follow() {
        guard watching, let window = pointer.window, window.isVisible, browser.active?.immersed != true else {
            return timers.cancelShow()
        }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        let card = browser.layout(in: size).card
        let fromTop = size.height - point.y
        // Above a sidebar's card only the window's thin top margin counts;
        // the strip's tabs above the card don't.
        let slack = prefs.sidebar || browser.folded ? ChromeLayout.gap + 1 : 1
        let over = point.x >= card.minX && point.x <= card.maxX && fromTop >= card.minY - slack
        let distance = over ? max(0, fromTop - card.minY) : .greatestFiniteMagnitude
        let near = browser.toolbarRevealed || (inWindow && distance < EdgeReveal.edge)
        let top = near ? NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) : 0
        let onWindow = top == window.windowNumber
        let state = EdgeReveal.Pointer(
            inWindow: inWindow, onWindow: onWindow, onOwnPanel: near && !onWindow && NSApp.windows.contains { $0.windowNumber == top },
            distance: distance)
        // Its suggestions hang below it; while they show it stays.
        let reach = ChromeLayout.toolbar + (browser.field.offers.isEmpty ? 0 : 400)
        switch EdgeReveal.step(state, peeking: browser.toolbarRevealed, reach: reach, waits: prefs.revealDelay > 0) {
        case .show:
            timers.cancelShow()
            show()
        case .showSoon:
            timers.showAfter(Double(prefs.revealDelay)) { show() }
        case .hideSoon:
            timers.cancelShow()
            hide()
        case .pass:
            timers.cancelShow()
        }
    }

    private func show() {
        timers.cancelHide()
        if watching, !browser.toolbarRevealed { browser.toolbarRevealed = true }
    }

    private func hide() {
        timers.hideAfter(Self.grace) {
            if !browser.editingInBar { browser.toolbarRevealed = false }
        }
    }
}
