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
    /// A sidebar tab, which may be dropped into a folder.
    var filing: (browser: Browser, tab: Tab)? = nil
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
            // Alongside the row's own press (OneClick), which picks the tab
            // as the button goes down and would otherwise keep the drag out.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { changed($0.translation) }
                    .onEnded { _ in ended() }
            )
            .onReceive(ScriptedDrag.shared.$travel) { travel in
                guard ScriptedDrag.shared.tab == id else { return }
                // A drag starts from nothing: a row that appears mid-drag (the
                // tab just moved lists) is handed the travel so far, not its own.
                if let travel {
                    if drag == nil, travel != .zero { return }
                    changed(travel)
                } else {
                    ended()
                }
            }
    }

    /// Where the pointer is, for a tab that may leave its list; a scripted
    /// drag stays in it.
    private var zone: DragZone {
        guard let away else { return .list }
        // A scripted drag goes off its list only when it says where to.
        if ScriptedDrag.shared.tab != nil {
            guard let pointer = ScriptedDrag.shared.pointer else { return .list }
            return away.browser.zone(dragging: away.tab, at: pointer)
        }
        return away.browser.zone(dragging: away.tab, at: NSEvent.mouseLocation)
    }

    private func changed(_ travel: CGSize) {
        // A tab still easing home is done; one held elsewhere keeps the drag.
        if drag?.landed == true { drag = nil }
        if let drag, drag.id != id { return }
        if drag == nil, let away { away.browser.beginDrag(away.tab) }
        var next = drag ?? ReorderDrag(id: id, start: index)
        // Held at the sidebar's edge, the spaces slide that way under it.
        if let away {
            SpaceDrag.hold(away.tab, in: away.browser)
            // Carried into another space, its row is out of sight: the card follows.
            if SpaceDrag.carrying(away.tab, in: away.browser) {
                TabGhost.show(away.tab, at: NSEvent.mouseLocation, count: away.browser.picked(with: away.tab).count)
                if drag == nil { drag = next }
                return
            }
        }
        // Over a folder's row, it would go in; the list makes room as ever.
        if let filing {
            let pointer = ScriptedDrag.shared.tab == nil ? NSEvent.mouseLocation : ScriptedDrag.shared.pointer
            filing.browser.hoverFolder(at: pointer, dragging: filing.tab)
            filing.browser.hoverOutOfFolder(at: pointer, dragging: filing.tab)
            // A folder's tab over another list: its row stays in the folder,
            // and a card of it follows the pointer there.
            if filing.tab.folder != nil, filing.browser.folderHover != nil || filing.browser.folderExit != nil {
                if let pointer { TabGhost.show(filing.tab, at: pointer) }
                if drag == nil { drag = next }
                return
            }
        }
        // Away from the list the row can't follow: it holds still, and a card
        // of it does, so where it's going shows.
        if let away, zone != .list {
            TabGhost.show(away.tab, at: NSEvent.mouseLocation, count: away.browser.picked(with: away.tab).count)
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
            Haptic.tick()
            withAnimation(Motion.settle) { drag = next }
        }
    }

    private func ended() {
        TabGhost.hide()
        // Let go in another space: the tab moves there, once, where it's dropped.
        if let away, let from = SpaceDrag.carried(away.tab, in: away.browser) {
            withAnimation(Motion.settle) { drag = nil }
            away.browser.endDrag()
            Haptic.tick()
            let place = away.browser.loosePlace(at: NSEvent.mouseLocation)
            return withAnimation(Motion.settle) { away.browser.bring(away.tab, from: from, at: place) }
        }
        SpaceDrag.stop()
        // Let go over a space's icon: the tab goes to that space.
        if let away, drag?.id == id, let space = SpaceDrag.space(under: NSEvent.mouseLocation, in: away.browser) {
            withAnimation(Motion.settle) { drag = nil }
            away.browser.endDrag()
            Haptic.tick()
            away.browser.move(away.tab, toSpace: space)
            return
        }
        let exit = filing?.browser.folderExit
        filing?.browser.folderExit = nil
        guard var landing = drag, landing.id == id, !landing.landed else { return }
        defer { away?.browser.endDrag() }
        if let filing, filing.browser.folderHover != nil {
            withAnimation(Motion.settle) { drag = nil }
            return filing.browser.dropInFolder(filing.tab)
        }
        // A tab of a folder let go over the pinned tabs leaves the folder,
        // still pinned; over the open tabs, it leaves it for there.
        if let filing, filing.tab.folder != nil, let exit {
            withAnimation(Motion.settle) { drag = nil }
            Haptic.tick()
            return withAnimation(Motion.settle) {
                switch exit {
                case .kept(let place): filing.browser.unfile(filing.tab, toKeptAt: place)
                case .loose(let place): filing.browser.unfile(filing.tab, at: place)
                }
            }
        }
        if let away, case let zone = zone, zone != .list {
            withAnimation(Motion.settle) { drag = nil }
            // Once: another list showing the same tab may hear the same drag end.
            guard away.browser.pageDrag?.tab == away.tab.id else { return away.browser.endDrag() }
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
            // The tabs picked with it follow.
            if let away { away.browser.gatherPicks(around: away.tab) }
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
    /// Where the pointer is said to be, on screen, for a drag onto a folder.
    var pointer: NSPoint?
    /// How far the drag has gone; nil once let go.
    @Published private(set) var travel: CGSize?

    /// Drags `tab` by `distance` over `seconds`, then lets go.
    /// `along`: where the pointer is at each part of the way, on screen.
    func play(
        _ tab: Tab.ID, by distance: CGSize, over seconds: Double, along: ((CGFloat) -> NSPoint)? = nil, then done: @escaping () -> Void
    ) {
        self.tab = tab
        let steps = max(2, Int(seconds * 120))
        for n in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(n) / Double(steps)) {
                let part = CGFloat(n) / CGFloat(steps)
                if let along { self.pointer = along(part) }
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

/// Rows passing under a still pointer while their list scrolls don't light
/// up, as in Firefox, which leaves hover alone until the scroll stops: each
/// one lit and let go is a row worked out again, every frame of the scroll.
/// Leaving still counts. Not observed, so the scroll starting and stopping
/// redraws nothing.
@MainActor enum ScrollHover {
    static var moving = false
}

extension View {
    /// `onHover` for a row in a list that scrolls (see ScrollHover).
    func rowHover(_ set: @escaping (Bool) -> Void) -> some View {
        onHover { over in if !over || !ScrollHover.moving { set(over) } }
    }
}

/// A tab's clicks: one picks it; two in quick succession, whether it was
/// the active tab or became it with the first, edit it (rename it, or a
/// pin's letter). Single taps only, timed here: SwiftUI's double-tap would
/// hold every single click back, and miss a double click that starts on a
/// tab not yet active.
///
/// On the press, not the release, as Firefox's tabs: a tap would wait for the
/// button to come up and for the row's drag to give up first, a tenth of a
/// second or two that a switch feels. A drag still goes on from the press.
struct OneClick: ViewModifier {
    let live: Bool
    /// The row's end where a speaker or a preview's mark sits: a press there is theirs.
    var spare: CGFloat = 0
    let pick: () -> Void
    let edit: () -> Void
    /// A click with ⌘ or ⇧ picks tabs together (Browser.pick); true when it did.
    var together: ((NSEvent.ModifierFlags) -> Bool)? = nil
    @State private var last = Date.distantPast
    @State private var pressed = false
    @State private var width: CGFloat = 0

    /// Held down without moving: the tab gives a little, as a button does.
    @State private var giving = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(giving ? 0.98 : 1)
            .animation(Motion.press, value: giving)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { press in
                        // A drag takes the tab away instead.
                        let still = hypot(press.translation.width, press.translation.height) < 5
                        if giving != still { giving = still }
                        guard !pressed else { return }
                        pressed = true
                        // A control-click is the tab's menu.
                        guard press.startLocation.x < width - spare, !NSEvent.modifierFlags.contains(.control) else { return }
                        pressedDown()
                    }
                    .onEnded { _ in
                        pressed = false
                        giving = false
                    })
    }

    private func pressedDown() {
        if let together, together(NSEvent.modifierFlags) { return }
        let now = Date()
        if now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            last = .distantPast
            return edit()
        }
        last = now
        if !live { pick() }
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

    /// The picture of the tab being dragged, fetched once per drag.
    private static var picture: (tab: Tab.ID, image: NSImage?)?

    static func show(_ tab: Tab, at point: NSPoint, count: Int = 1) {
        if picture?.tab != tab.id {
            picture = (tab.id, nil)
            tab.previewPicture { image in MainActor.assumeIsolated { if picture?.tab == tab.id { picture?.image = image } } }
        }
        show(tab.label, at: point, count: count, image: picture?.image)
    }

    static func show(_ title: String, at point: NSPoint, count: Int = 1, image: NSImage? = nil) {
        let panel = panel ?? made()
        (panel.contentView as? NSHostingView<Card>)?.rootView = Card(title: title, count: count, image: image)
        let size = panel.contentView?.fittingSize ?? .zero
        panel.setFrame(NSRect(x: point.x - 16, y: point.y - size.height + 8, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
        picture = nil
    }

    private static func made() -> NSPanel {
        let made = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.level = .floating
        made.ignoresMouseEvents = true
        made.contentView = NSHostingView(rootView: Card(title: "", count: 1, image: nil))
        panel = made
        return made
    }

    struct Card: View {
        let title: String
        /// Tabs picked together: up to three cards stacked, and how many.
        let count: Int
        /// The page's picture, as the preview card shows it (TabPreview).
        let image: NSImage?
        private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 216, height: 124, alignment: .top).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(title)
                    .font(TextStyle.body.font)
                    .lineLimit(1)
                    .frame(maxWidth: 216, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, image == nil ? 0 : 12)
            .frame(minHeight: Metrics.row)
            .background(.regularMaterial, in: shape)
                .background {
                    ForEach(1..<min(count, 3), id: \.self) { n in
                        shape.fill(.regularMaterial).offset(x: CGFloat(n) * 4, y: CGFloat(n) * 4).opacity(0.7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if count > 1 {
                        Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(Color.accentColor, in: Capsule()).offset(x: 6, y: -6)
                    }
                }
                .padding(10)
                .fixedSize()
        }
    }
}

/// A tab dragged in the sidebar to another space: held half a second at the
/// sidebar's edge, the spaces slide that way under it (again, to go further),
/// and it goes along as a card; let go, it moves once, into the space showing,
/// where it's dropped. Or let go over a space's icon at the foot.
@MainActor
enum SpaceDrag {
    private static var waiting: (forward: Bool, task: Task<Void, Never>)?
    /// The tab carried, and the space it came from.
    private static var carry: (tab: Tab, from: UUID)?
    /// The foot's space icons, where they are.
    static var icons: [UUID: WeakView] = [:]

    static func hold(_ tab: Tab, in browser: Browser) {
        guard browser.prefs.sidebar, browser.usesSpaces, browser.spaces.count > 1, let window = browser.window else { return wait(nil) }
        let x = window.convertPoint(fromScreen: NSEvent.mouseLocation).x
        let side = browser.prefs.sideWidth
        let left = browser.prefs.sideRight ? window.frame.width - side : 0
        let edge: Bool? = x < left + 12 ? false : x > left + side - 12 && x <= left + side ? true : nil
        guard let forward = edge else { return wait(nil) }
        if waiting?.forward == forward { return }
        wait(nil)
        waiting = (forward, Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let here = browser.spaces.firstIndex(where: { $0.id == browser.spaceID }) else { return }
            let next = here + (forward ? 1 : -1)
            guard browser.spaces.indices.contains(next) else { return }
            if carry == nil { carry = (tab, browser.spaceID) }
            Haptic.tick()
            browser.switchSpace(to: browser.spaces[next].id)
            // Held on, it goes on to the next.
            waiting = nil
            hold(tab, in: browser)
        })
    }

    private static func wait(_ none: Void?) {
        waiting?.task.cancel()
        waiting = nil
    }

    /// Whether `tab` is being carried, and out of its own space now.
    static func carrying(_ tab: Tab, in browser: Browser) -> Bool {
        guard let carry, carry.tab === tab else { return false }
        return carry.from != browser.spaceID
    }

    /// Let go: the space `tab` came from, when it's being carried into another.
    static func carried(_ tab: Tab, in browser: Browser) -> UUID? {
        defer { stop() }
        guard let carry, carry.tab === tab, carry.from != browser.spaceID else { return nil }
        return carry.from
    }

    static func stop() {
        wait(nil)
        carry = nil
    }

    /// The space whose icon is under `point`, on screen.
    static func space(under point: NSPoint, in browser: Browser) -> UUID? {
        guard browser.usesSpaces else { return nil }
        return icons.first { id, spot in
            guard id != browser.spaceID, let view = spot.view, let window = view.window, window === browser.window else { return false }
            return view.convert(view.bounds, to: nil).contains(window.convertPoint(fromScreen: point))
        }?.key
    }
}

/// Marks a space's icon for a dragged tab to be dropped on.
struct SpaceDropSpot: FillsRoom {
    let space: UUID

    func makeNSView(context: Context) -> NSView { Spot() }
    func updateNSView(_ view: NSView, context: Context) { SpaceDrag.icons[space] = WeakView(view) }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A picture of a tab's page beside its row while the pointer rests on it:
/// after half a second, then at once moving from row to row, gone a moment
/// after leaving. One card, over every window; never while dragging.
@MainActor
enum TabPreview {
    private static var panel: NSPanel?
    private static var hiding: Task<Void, Never>?
    private static var shownAt = Date.distantPast
    private static var showing = false
    /// The tab the pointer is on, for a picture that arrives late.
    private static var wanted: Tab.ID?

    /// How long to rest on a row first: less when a card was just up.
    static var wait: Double { showing || Date().timeIntervalSince(shownAt) < 0.3 ? 0.15 : 0.5 }

    static func show(_ tab: Tab, in browser: Browser) {
        hiding?.cancel()
        guard NSEvent.pressedMouseButtons == 0, let window = browser.window else { return }
        wanted = tab.id
        let pointer = NSEvent.mouseLocation
        tab.previewPicture { image in
            MainActor.assumeIsolated {
                guard wanted == tab.id, NSEvent.pressedMouseButtons == 0 else { return }
                let panel = panel ?? made()
                (panel.contentView as? NSHostingView<Card>)?.rootView = Card(image: image, title: tab.label, site: tab.address?.host() ?? "")
                let size = panel.contentView?.fittingSize ?? .zero
                let side = browser.prefs.sideWidth
                let x =
                    browser.prefs.sideRight
                    ? window.frame.maxX - side - size.width - 8 : window.frame.minX + side + 8
                panel.setFrame(NSRect(x: x, y: pointer.y - size.height / 2, width: size.width, height: size.height), display: true)
                panel.orderFrontRegardless()
                showing = true
            }
        }
    }

    /// The pointer left the row: the card goes a moment later, unless another row takes it.
    static func leave() {
        wanted = nil
        guard showing else { return }
        hiding?.cancel()
        hiding = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            showing = false
            shownAt = Date()
            hiding = nil
        }
    }

    private static func made() -> NSPanel {
        let made = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.level = .floating
        made.ignoresMouseEvents = true
        made.contentView = NSHostingView(rootView: Card(image: nil, title: "", site: ""))
        panel = made
        return made
    }

    struct Card: View {
        let image: NSImage?
        let title: String
        let site: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: 150, alignment: .top).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !site.isEmpty { Text(site).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 240, alignment: .leading)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .fixedSize()
        }
    }
}
