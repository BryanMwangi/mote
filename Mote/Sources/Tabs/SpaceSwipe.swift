import Combine
import MoteCore
import SwiftUI

/// Swiping between spaces over the tabs, with a trackpad or a mouse wheel.
/// Scroll events come here before any view; only gestures that start over
/// the tabs and run along the spaces are kept (ScrollGate, SpacePager), and
/// the rest scroll as usual.
@MainActor
final class SpaceSwipe {
    static let shared = SpaceSwipe()
    /// How many times the spaces' pages have been worked out, for the bench.
    static var pagesDrawn = 0

    private weak var browser: Browser?
    private var watch: Any?
    private var pager = SpacePager(count: 0, here: 0, enough: 50)
    private var gate = ScrollGate()

    func start(for browser: Browser) {
        self.browser = browser
        guard watch == nil else { return }
        watch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.keeps(event) } ? nil : event
        }
    }

    /// Where the tabs stand among the spaces (the count is the new-space
    /// card), and how far a swipe must go: 50 pt in the sidebar, most of the
    /// strip's height over it, so scrolling a page just below doesn't switch.
    private func refresh(_ browser: Browser) {
        pager.count = browser.spaces.count
        pager.here = browser.makingSpace ? browser.spaces.count : browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
        pager.enough = browser.prefs.sidebar ? 50 : ChromeLayout.strip * 0.6
    }

    private func overTabs(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let window = event.window, window === browser.window else { return false }
        let at = event.locationInWindow
        return browser.prefs.sidebar ? at.x < browser.prefs.sideWidth : at.y > window.frame.height - ChromeLayout.strip
    }

    private func keeps(_ event: NSEvent) -> Bool {
        // The window under the gesture; not mid-swipe, which stays with its window.
        if !gate.tracking, let owner = Windows.shared.browser(for: event.window) { browser = owner }
        guard let browser, browser.usesSpaces, !browser.folded || browser.peeking else { return false }
        guard event.hasPreciseScrollingDeltas else { return wheel(event, in: browser) }
        switch gate.verdict(Self.phase(of: event), over: overTabs(event, in: browser)) {
        case .pass:
            return false
        case .swallow:
            return true
        case .begin:
            began()
            return gate.ignoring || moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .move:
            return moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .end(let cancelled):
            let claimed = pager.isClaimed
            ended(cancelled: cancelled)
            gate.coast(claimed)
            return claimed
        }
    }

    /// A mouse wheel over the strip: a space a notch.
    private func wheel(_ event: NSEvent, in browser: Browser) -> Bool {
        guard !browser.prefs.sidebar, event.scrollingDeltaY != 0, overTabs(event, in: browser) else { return false }
        refresh(browser)
        if let target = pager.click(down: event.scrollingDeltaY < 0, at: Date()) { slide(browser, to: target, from: pager.here) }
        return true
    }

    private static func phase(of event: NSEvent) -> ScrollGate.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        switch event.phase {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled: return .cancelled
        default: return .other
        }
    }

    // MARK: - The gesture, which the bench drives directly too

    func began() {
        guard let browser else { return }
        refresh(browser)
        gate.begin(allowed: pager.begin(at: Date()))
    }

    /// Whether the gesture is taken as a swipe between spaces.
    @discardableResult
    func moved(dx: CGFloat, dy: CGFloat) -> Bool {
        guard gate.tracking, let browser else { return false }
        let (along, aside) = browser.prefs.sidebar ? (dx, dy) : (dy, dx)
        guard let offset = pager.move(along: along, aside: aside) else { return false }
        browser.spaceSwipe = offset
        return true
    }

    /// Along the spaces, whichever way they run.
    @discardableResult
    func moved(along travel: CGFloat) -> Bool {
        guard let browser else { return false }
        return browser.prefs.sidebar ? moved(dx: travel, dy: 0) : moved(dx: 0, dy: travel)
    }

    func ended(cancelled: Bool = false) {
        defer { gate.stop() }
        guard let browser, pager.isClaimed else { return }
        if let target = pager.end(cancelled: cancelled) {
            slide(browser, to: target, from: pager.here)
        } else {
            browser.swipeOffset.ease()
        }
    }

    /// Slides a whole page over, then switches with animation off so the
    /// swap can't be seen. `spaces.count` is the new-space card.
    func slide(_ browser: Browser, to target: Int, from here: Int) {
        // A page: the sidebar's width, or the strip's height.
        let page = browser.prefs.sidebar ? browser.prefs.sideWidth : ChromeLayout.strip
        let forward = target > here, card = target == browser.spaces.count
        pager.switched(at: Date())
        // The space switches now, as ⌃1–9 does; the sidebar's pages are put
        // back where they were in the same update, then ease the rest of the way.
        // Only what changes is set: each change in a transaction draws the
        // sidebar again first, a quarter of a second with a hundred tabs.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            if browser.makingSpace != card { browser.makingSpace = card }
            // Which way the space's icon slides; a switch sets it itself.
            if card { browser.spaceStep = forward ? 1 : -1 }
            if !card { browser.switchSpace(to: browser.spaces[target].id, gliding: false) }
            browser.spaceSwipe += (forward ? 1 : -1) * page
        }
        browser.swipeOffset.ease()
    }
}

/// Making a space, in the place past the last one: a row in the strip, or
/// a card in the sidebar.
struct NewSpaceCard: View {
    @ObservedObject var browser: Browser
    /// One row, for the strip.
    var inline = false

    @State private var name = ""
    @State private var icon = "briefcase"
    @State private var choosingIcon = false
    /// Signed in wherever the first space is; new spaces keep their own data.
    @State private var shared = false
    @State private var hovering = false
    @FocusState private var typing: Bool

    private var explanation: String {
        shared ? "Signed in to the same sites as your first space." : "Its own cookies, sign-ins and site data, starting empty."
    }

    private var sharing: some View {
        Segmented(options: [(false, "Separate"), (true, "Shared")], selection: $shared, wide: !inline)
    }

    var body: some View {
        Group {
            if inline {
                HStack(spacing: 8) {
                    iconButton(size: 13, box: CGSize(width: 28, height: 26))
                    nameField.frame(width: 170)
                    sharing.fixedSize().help(explanation)
                    Pill("Cancel", action: cancel)
                    Pill("Create", filled: true, action: create)
                }
                .frame(height: ChromeLayout.strip)
            } else {
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        Text("Create a Space").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("Spaces keep their own tabs, and can keep their own sign-ins.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                    HStack(spacing: 4) {
                        iconButton(size: 13, box: CGSize(width: 28, height: 26))
                        nameField
                    }
                    .padding(.leading, 2)
                    .background(Palette.wash, in: Rounded.row)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Site data").font(.system(size: 12)).foregroundStyle(Palette.ink)
                            Spacer()
                            sharing.fixedSize()
                        }
                        Text(explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                    HStack(spacing: 8) {
                        Pill("Cancel", action: cancel)
                        Pill("Create Space", filled: true, action: create)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            icon = browser.freeIcon
            Task { @MainActor in typing = true }
        }
        .onExitCommand(perform: cancel)
    }

    /// The icon, opening the icon picker.
    private func iconButton(size: CGFloat, box: CGSize) -> some View {
        Button {
            choosingIcon = true
        } label: {
            SpaceGlyph(icon, size: size)
                .foregroundStyle(Palette.ink)
                .frame(width: box.width, height: box.height)
                .background(
                    hovering || choosingIcon ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: inline ? 8 : 10, style: .continuous)
                )
                .contentShape(Rectangle())
                .id(icon)
                .transition(.opacity)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(inline ? "New space: choose its icon" : "Choose an icon")
        .popover(isPresented: $choosingIcon, arrowEdge: .bottom) { iconPicker }
    }

    private var nameField: some View {
        TextField(inline ? "New space" : "Space name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: inline ? 12.5 : 13))
            .padding(.horizontal, inline ? 10 : 4)
            .frame(height: inline ? 26 : 30)
            .background(inline ? Palette.wash : .clear, in: Rounded.row)
            .focused($typing)
            .onSubmit(create)
    }

    /// Symbols or emoji; picking one closes the picker.
    private var iconPicker: some View {
        IconPicker(current: icon) { picked in
            withAnimation(Motion.quick) { icon = picked }
            choosingIcon = false
            typing = true
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return typing = true }
        browser.addSpace(named: trimmed, icon: icon, sharesSignIns: shared)
    }

    /// Slides back to the space the card was opened from.
    private func cancel() {
        SpaceSwipe.shared.slide(browser, to: browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0, from: browser.spaces.count)
    }
}

/// How far a swipe has moved the spaces' pages (see `Browser.spaceSwipe`).
/// The strip follows `value` in SwiftUI; the sidebar's pages are moved by
/// Core Animation straight from it (SwipeTrack), and redraw only when
/// `shown` changes, at a swipe's start and end.
@MainActor
final class SwipeOffset: ObservableObject {
    @Published var value: CGFloat = 0
    /// Whether the neighbouring spaces' pages show.
    let shown = SwipeShown()
    /// Whether the change of `value` being made eases there, in the sidebar.
    fileprivate private(set) var easing = false

    /// Back to rest, the whole space at once: a
    /// spring without bounce over a quarter second.
    func ease() {
        easing = true
        withAnimation(.spring(duration: 0.25, bounce: 0)) { value = 0 }
        easing = false
    }
}

/// See `SwipeOffset.shown`.
@MainActor
final class SwipeShown: ObservableObject {
    @Published var swiping = false
    /// The space a switch is leaving, shown beside the one coming in however
    /// far apart they are; during a swipe, none: the neighbours show.
    @Published var leaving: UUID?
}

/// The sidebar's spaces' pages, moved by a layer transform during a swipe, as
/// the floating sidebar slides (SlidingPanel): SwiftUI moving them would lay
/// out every page on every scroll event.
struct SwipeTrack: FillsRoom {
    let swipe: SwipeOffset
    let content: AnyView
    /// The page in front, and how many there are: every space's side by side,
    /// and the new-space card's.
    let here: Int
    let count: Int

    func makeNSView(context: Context) -> Holder { Holder(swipe: swipe, content: content) }

    func updateNSView(_ holder: Holder, context: Context) {
        holder.host.rootView = content
        holder.place(here: here, count: count)
    }

    final class Holder: NSView {
        let host: NSHostingView<AnyView>
        private let swipe: SwipeOffset
        private var watch: AnyCancellable?

        init(swipe: SwipeOffset, content: AnyView) {
            self.swipe = swipe
            host = NSHostingView(rootView: content)
            super.init(frame: .zero)
            wantsLayer = true
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.wantsLayer = true
            addSubview(host)
            watch = swipe.$value.sink { [weak self] x in MainActor.assumeIsolated { self?.move(to: x) } }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        private var here = 0
        private var count = 1

        override func layout() {
            super.layout()
            place(here: here, count: count)
        }

        /// The pages laid side by side once, the one in front over this view:
        /// a switch moves only the track, which is a scroll, not a layout.
        func place(here: Int, count: Int) {
            self.here = here
            self.count = count
            let frame = NSRect(x: -CGFloat(here) * bounds.width, y: 0, width: bounds.width * CGFloat(max(count, 1)), height: bounds.height)
            guard host.frame != frame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.frame = frame
            CATransaction.commit()
        }

        private func move(to x: CGFloat) {
            guard let layer = host.layer else { return }
            if x != 0, !swipe.shown.swiping { swipe.shown.swiping = true }
            // From where it shows, mid-ease, or where it was put.
            let was = layer.animation(forKey: "swipe") == nil ? layer.transform : layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "swipe")
            layer.transform = CATransform3DMakeTranslation(x, 0, 0)
            if swipe.easing, window != nil {
                // SwipeOffset.ease's spring: 0.25 s, critically damped.
                let animation = CASpringAnimation(keyPath: "transform")
                animation.stiffness = pow(2 * .pi / 0.25, 2)
                animation.damping = 4 * .pi / 0.25
                animation.duration = animation.settlingDuration
                animation.fromValue = was
                CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.rested() } }
                layer.add(animation, forKey: "swipe")
            } else if x == 0 {
                DispatchQueue.main.async { [weak self] in self?.rested() }
            }
            CATransaction.commit()
        }

        /// Home and still: the neighbours hide again.
        private func rested() {
            guard swipe.value == 0, host.layer?.animation(forKey: "swipe") == nil, swipe.shown.swiping else { return }
            swipe.shown.swiping = false
            swipe.shown.leaving = nil
        }
    }
}
