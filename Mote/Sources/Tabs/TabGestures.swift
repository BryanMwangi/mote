import AppKit
import Combine
import MoteCore
import SwiftUI

/// Dragging a tab to a new place along the strip, down the sidebar or
/// across the pin grid (see ReorderDrag). The held tab follows the pointer
/// and the tabs it passes step aside; the order changes on letting go, when
/// the held tab eases from where it was dropped into its new place.
///
/// An open tab can go further (`away`): over the page its row holds still, a
/// card of it follows the pointer and the page shows where it would split
/// in; out of the window, it goes to another window or a new one.
struct Reorderable: ViewModifier {
    let id: Tab.ID
    let index: Int
    /// The places the tab may take: its section of the row.
    let places: Range<Int>
    let lattice: Lattice
    /// The list's coordinate space. Measured in the tab's own space, the
    /// origin would move whenever the tab did.
    let space: String
    /// The list's drag, one for all its tabs.
    @Binding var drag: ReorderDrag<Tab.ID>?
    /// The leading edge reserved for window controls, when dragging along a strip.
    var leadingLimit: CGFloat? = nil
    /// The open tab, which may leave its list for the page or another window
    /// (see DragZone). Essentials and pinned tabs are the space's, and stay.
    var away: (browser: Browser, tab: Tab)? = nil
    let move: (Int) -> Void
    @State private var originX: CGFloat?

    func body(content: Content) -> some View {
        let held = drag?.id == id
        let following = held && drag?.landed == false
        let frozenOrigin = drag == nil ? nil : originX
        content
            .offset(drag?.offset(of: id, at: index, in: lattice) ?? .zero)
            // The held tab follows the pointer without animation, even as the
            // others step aside with one.
            .transaction { if following { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(following ? 0.14 : 0), radius: 12, y: 4)
            .onGeometryChange(for: CGFloat.self) { [space, frozenOrigin] proxy in
                let x = proxy.frame(in: .named(space)).minX
                return frozenOrigin ?? x
            } action: {
                originX = $0
            }
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { changed($0.translation) }
                    .onEnded { _ in ended() }
            )
            .onReceive(ScriptedDrag.shared.$travel) { travel in
                guard ScriptedDrag.shared.tab == id else { return }
                if let travel { changed(travel) } else { ended() }
            }
    }

    /// Where the pointer is, for a tab that may leave its list; a scripted
    /// drag stays in it.
    private var zone: DragZone {
        guard let away, ScriptedDrag.shared.tab == nil else { return .list }
        return away.browser.zone(dragging: away.tab, at: NSEvent.mouseLocation)
    }

    private func changed(_ travel: CGSize) {
        // A tab still easing home is done; one held elsewhere keeps the drag.
        if drag?.landed == true { drag = nil }
        if let drag, drag.id != id { return }
        var next = drag ?? ReorderDrag(id: id, start: index)
        // Away from the list the row can't follow: it holds still, and a card
        // of it does, so where it's going shows.
        if let away, zone != .list {
            TabGhost.show(away.tab.label, at: NSEvent.mouseLocation)
            if drag == nil { drag = next }
            return
        }
        TabGhost.hide()
        let before = next.target
        var bounded = travel
        if let leadingLimit, let originX { bounded.width = max(leadingLimit - originX, bounded.width) }
        next.follow(bounded, in: lattice, within: places)
        if next.target == before {
            drag = next
        } else {
            withAnimation(Motion.settle) { drag = next }
        }
    }

    private func ended() {
        TabGhost.hide()
        guard var landing = drag, landing.id == id, !landing.landed else { return }
        if let away, case let zone = zone, zone != .list {
            withAnimation(Motion.settle) { drag = nil }
            return zone == .page ? away.browser.dropOnPage(away.tab) : away.browser.drop(away.tab)
        }
        landing.land()
        // The new order and the offsets that keep every tab where it is on
        // screen, in one update with nothing animated: the list's own animation
        // of the order would otherwise slide tabs from their old places.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if landing.target != landing.start { move(landing.target) }
            drag = landing
        }
        let settling = $drag
        DispatchQueue.main.async {
            guard settling.wrappedValue == landing else { return }
            var home = landing
            home.settle(in: lattice)
            withAnimation(Motion.settle, completionCriteria: .removed) {
                settling.wrappedValue = home
            } completion: {
                guard settling.wrappedValue == home else { return }
                withAnimation(Motion.settle) { settling.wrappedValue = nil }
            }
        }
    }
}

/// A drag the bench plays on a tab, a frame at a time, through the same
/// steps as the pointer's (Tools/bench tabdrag).
@MainActor
final class ScriptedDrag: ObservableObject {
    static let shared = ScriptedDrag()
    private(set) var tab: Tab.ID?
    /// How far the drag has gone; nil once let go.
    @Published private(set) var travel: CGSize?

    /// Drags `tab` by `distance` over `seconds`, then lets go.
    func play(_ tab: Tab.ID, by distance: CGSize, over seconds: Double, then done: @escaping () -> Void) {
        self.tab = tab
        let steps = max(2, Int(seconds * 120))
        for n in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(n) / Double(steps)) {
                let part = CGFloat(n) / CGFloat(steps)
                self.travel = CGSize(width: distance.width * part, height: distance.height * part)
                guard n == steps else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.travel = nil
                    self.tab = nil
                    done()
                }
            }
        }
    }
}

/// One click, or a double click, never both: with both, SwiftUI holds every
/// single click back for the double-click interval.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture(count: double ? 2 : 1, perform: act)
    }
}

/// A middle click. SwiftUI has no gesture for it, so this AppKit overlay
/// only takes part in hit-testing for middle-button events and lets
/// everything else through (see DragStrip). One covers a whole list, as
/// Firefox listens on the tab strip rather than on each tab: an AppKit view
/// per row makes every move of the rows cost AppKit a walk through them all.
/// It's told where, from the top left.
struct MiddleClick: FillsRoom {
    let act: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView { Catcher() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Catcher)?.act = act }

    private final class Catcher: NSView {
        var act: (CGPoint) -> Void = { _ in }
        private var down = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, [.otherMouseDown, .otherMouseUp].contains(event.type), event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) { down = true }

        /// On release inside, so sliding off first cancels.
        override func otherMouseUp(with event: NSEvent) {
            defer { down = false }
            let point = convert(event.locationInWindow, from: nil)
            if down, bounds.contains(point) { act(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)) }
        }
    }
}

/// A tab dragged outside its window: a card of it under the pointer, over
/// every window, till it's let go.
@MainActor
enum TabGhost {
    private static var panel: NSPanel?

    static func show(_ title: String, at point: NSPoint) {
        let panel = panel ?? made()
        (panel.contentView as? NSHostingView<Card>)?.rootView = Card(title: title)
        let size = panel.contentView?.fittingSize ?? .zero
        panel.setFrame(NSRect(x: point.x - 16, y: point.y - size.height + 8, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    static func hide() { panel?.orderOut(nil) }

    private static func made() -> NSPanel {
        let made = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.level = .floating
        made.ignoresMouseEvents = true
        made.contentView = NSHostingView(rootView: Card(title: ""))
        panel = made
        return made
    }

    struct Card: View {
        let title: String
        var body: some View {
            Text(title)
                .font(TextStyle.body.font)
                .lineLimit(1)
                .frame(maxWidth: 240, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: Metrics.row)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .fixedSize()
        }
    }
}
