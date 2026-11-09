import AppKit
import SwiftUI

// Option-clicking a link (or shift-clicking, Settings › General › Links)
// shows it over the page instead of leaving it. The
// preview is a tab of its own that isn't in the list yet, so keeping it
// doesn't load it again. It opens as Zen's Glance does: growing out of the
// link along a slight arc, on a spring.

extension Browser {
    func peek(_ url: URL, from tab: Tab) {
        let preview = Tab(shy: tab.shy)
        prepare(preview)
        preview.go(to: url)
        // The click that asked for it, under the pointer still.
        peekOrigin = NSEvent.mouseLocation
        peekLeaving = false
        withAnimation(Motion.settle) { peekTab = preview }
    }

    /// Back into the link it came from, then gone.
    func closePeek() {
        guard let preview = peekTab, !peekLeaving else { return }
        guard let glance = GlanceView.current, glance.window != nil else {
            takePeek()
            return preview.close()
        }
        withAnimation(.easeIn(duration: GlanceView.closing)) { peekLeaving = true }
        glance.close { [weak self] in
            guard let self, self.peekTab === preview else { return }
            self.takePeek()
            preview.close()
        }
    }

    /// The preview becomes a tab after the one it came from, and is picked.
    func keepPeek() {
        let place = placeForNew()
        guard let preview = takePeek() else { return }
        insert(preview, at: place)
        select(preview)
    }

    @discardableResult
    private func takePeek() -> Tab? {
        let preview = peekTab
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            peekTab = nil
            peekLeaving = false
        }
        return preview
    }
}

/// The page dimmed, with the preview over it.
struct PeekLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            // The dimming only fades: grown with the preview, its edges would move.
            if browser.peekTab != nil, !browser.peekLeaving {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: browser.closePeek)
                    .transition(.opacity)
            }
            if let preview = browser.peekTab {
                Glance(origin: browser.peekOrigin) { PeekCard(browser: browser, preview: preview) }
                    .id(preview.id)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: browser.peekTab == nil)
    }
}

private struct PeekCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var preview: Tab

    static let widthShare: CGFloat = 0.82
    static let heightShare: CGFloat = 0.86
    /// Half the buttons' column, which sits beside the page.
    static let shift: CGFloat = 21
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        GeometryReader { room in
            HStack(alignment: .top, spacing: 10) {
                Page(tab: preview)
                    // Not see-through while it loads.
                    .background(Palette.ground)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
                VStack(spacing: 8) {
                    Bubble(icon: "xmark", help: "Close (esc)", act: browser.closePeek)
                    Bubble(icon: "arrow.up.left.and.arrow.down.right", help: "Open as a tab", act: browser.keepPeek)
                }
            }
            .frame(width: room.size.width * Self.widthShare, height: room.size.height * Self.heightShare)
            // Half the buttons' column over, so the page itself sits in the middle.
            .offset(x: Self.shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A round button beside the preview.
private struct Bubble: View {
    let icon: String
    let help: String
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(hovering ? Palette.hover : Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The preview's opening and closing, as Zen's Glance: the card grows out of
/// the link's place to its own along a slight upward arc, on a spring with a
/// little bounce that settles in 350 ms, its page fading in over the first
/// quarter. Core Animation moves it, so the page inside isn't laid out on
/// every frame.
struct Glance<Card: View>: NSViewRepresentable {
    /// On screen; nil grows from the middle.
    let origin: NSPoint?
    @ViewBuilder let card: () -> Card

    func makeNSView(context: Context) -> GlanceView { GlanceView(content: AnyView(card()), origin: origin) }
    func updateNSView(_ view: GlanceView, context: Context) { view.host.rootView = AnyView(card()) }
}

final class GlanceView: NSView {
    @MainActor weak static var current: GlanceView?
    static let opening = 0.4
    static let closing = 0.2
    let host: NSHostingView<AnyView>
    private let origin: NSPoint?
    private var opened = false

    init(content: AnyView, origin: NSPoint?) {
        host = NSHostingView(rootView: content)
        self.origin = origin
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        host.sizingOptions = []
        host.safeAreaRegions = []
        addSubview(host)
        GlanceView.current = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // SwiftUI sets the frame; AppKit doesn't lay a plain view out for it.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        host.frame = bounds
        openOnce()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        openOnce()
    }

    private func openOnce() {
        guard !opened, window != nil, bounds.width > 0 else { return }
        opened = true
        open()
    }

    /// Where the card sits, as PeekCard lays it out.
    private var card: CGRect {
        let width = bounds.width * 0.82, height = bounds.height * 0.86
        return CGRect(x: (bounds.width - width) / 2 + 21, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// The link's place: a link-sized box around the click.
    private var link: CGRect {
        guard let origin, let window else { return CGRect(x: bounds.midX - 80, y: bounds.midY - 16, width: 160, height: 32) }
        let point = convert(window.convertPoint(fromScreen: origin), from: nil)
        return CGRect(x: point.x - 80, y: point.y - 16, width: 160, height: 32)
    }

    /// The card at `progress` of the way from the link (0) to its place (1),
    /// as a transform of the whole view: scaled about its top left, moved.
    private func transform(at progress: CGFloat) -> CATransform3D {
        let from = link, to = card
        let scaleX = from.width / to.width + (1 - from.width / to.width) * progress
        let scaleY = from.height / to.height + (1 - from.height / to.height) * progress
        let distance = hypot(to.midX - from.midX, to.midY - from.midY)
        // Zen's arc: up by at most 30 pt, highest halfway.
        let rise = min(30, distance * 0.4) * (1 - pow(2 * progress - 1, 2))
        let center = CGPoint(x: from.midX + (to.midX - from.midX) * progress, y: from.midY + (to.midY - from.midY) * progress - rise)
        let move = CATransform3DMakeTranslation(center.x - scaleX * to.midX, center.y - scaleY * to.midY, 0)
        return CATransform3DConcat(CATransform3DMakeScale(scaleX, scaleY, 1), move)
    }

    /// A spring with bounce 0.2 that settles in 350 ms, as Zen's.
    private static func spring(_ time: Double) -> CGFloat {
        let damping = 0.8, omega = 2 * Double.pi / 0.35
        let damped = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * time)
        return CGFloat(1 - decay * (cos(damped * time) + damping * omega / damped * sin(damped * time)))
    }

    private func open() {
        guard let layer = host.layer else { return }
        let steps = 60
        let move = CAKeyframeAnimation(keyPath: "transform")
        move.values = (0...steps).map { NSValue(caTransform3D: transform(at: Self.spring(Self.opening * Double($0) / Double(steps)))) }
        move.duration = Self.opening
        move.calculationMode = .linear
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.35 / 4
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(move, forKey: "glance")
        layer.add(fade, forKey: "glanceFade")
    }

    /// Back into the link, then `done`.
    func close(_ done: @escaping () -> Void) {
        guard let layer = host.layer else { return done() }
        let steps = 30
        let move = CAKeyframeAnimation(keyPath: "transform")
        move.values = (0...steps).map { NSValue(caTransform3D: transform(at: 1 - CGFloat($0) / CGFloat(steps))) }
        move.duration = Self.closing
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Self.closing * 0.55
        fade.duration = Self.closing * 0.45
        fade.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        layer.transform = transform(at: 0)
        layer.add(move, forKey: "glance")
        layer.add(fade, forKey: "glanceFade")
        layer.opacity = 0
        CATransaction.commit()
    }
}
