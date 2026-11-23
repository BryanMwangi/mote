import AppKit
import Combine
import MoteCore
import SwiftUI

/// The assistant at work on a tab's page: whether it is, what it's doing,
/// and who's doing it; and, apart from that, where its cursor goes and what
/// it does there, which go straight to the overlay's layers so a glide never
/// redraws SwiftUI. Cleared a few seconds after the last step.
@MainActor
final class AgentActivity: ObservableObject {
    @Published private(set) var working = false
    @Published private(set) var caption = ""
    @Published private(set) var driver = ""
    /// A step is running: the agent's own keys go through to the page.
    @Published private(set) var stepping = false
    /// The person took the page back (Take control): the agent's actions on
    /// it are refused until they hand it back, or for half an hour.
    @Published private(set) var heldSince: Date?
    /// While the turn goes on, the agent keeps the page between its steps.
    private var turnGoesOn: (() -> Bool)?

    enum Effect {
        /// The cursor glides to the middle of `CGRect` (CSS pixels in the page's view).
        case move(CGRect)
        case click(CGRect)
        /// An outline round the field being written into.
        case write(CGRect)
        case scroll(down: Bool)
    }

    let effects = PassthroughSubject<Effect, Never>()
    /// Stops the turn the assistant is taking (the pill's Stop).
    var stop: (() -> Void)?
    private var resting: Task<Void, Never>?

    /// The person has the page: taken back, within the last half hour.
    var held: Bool { heldSince.map { Date().timeIntervalSince($0) < 30 * 60 } ?? false }

    /// The agent has the page: the person's clicks, scrolls and keys don't reach it.
    var owned: Bool { working && !held }

    /// A step begins: shown, with its caption, the page held.
    func begin(_ caption: String, by driver: String, stop: (() -> Void)?, turnGoesOn: (() -> Bool)? = nil) {
        resting?.cancel()
        if let turnGoesOn { self.turnGoesOn = turnGoesOn }
        // Animated where it changes, so the tab's sparkle and the overlay come and go smoothly.
        if !working { withAnimation(Motion.settle) { working = true } }
        if self.caption != caption { self.caption = caption }
        if self.driver != driver { self.driver = driver }
        self.stop = stop
        stepping = true
    }

    /// The step is done. The overlay goes a moment later, unless another
    /// step comes; while the turn goes on (the model thinking between
    /// steps), it stays up to half a minute, so the page isn't up for grabs.
    func end(then finished: (() -> Void)? = nil) {
        stepping = false
        resting?.cancel()
        resting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<26 where self?.turnGoesOn?() == true {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.settle) { self.working = false }
            self.turnGoesOn = nil
            finished?()
        }
    }

    /// The person takes the page: the agent goes on elsewhere, told so if it
    /// tries to act here.
    func takeControl() {
        heldSince = Date()
        stepping = false
    }

    /// The person gives the page back to the agent.
    func handBack() { heldSince = nil }

    /// The person stops it, or takes the page back.
    func leave() {
        resting?.cancel()
        stop?()
        stop = nil
        stepping = false
        withAnimation(Motion.settle) { working = false }
    }
}

/// Over a page the assistant is acting on: a light wash of Mote's clay and
/// the floating search's halo round the page's edge, turning while it acts
/// and resting between steps, its cursor
/// gliding to what it acts on, a ripple where it clicks, an outline round
/// what it writes in, and a pill saying who's doing what, with Stop and
/// Take control (Hand back once taken). All Core Animation, added only while it works.
struct AgentOverlay: View {
    @ObservedObject var activity: AgentActivity
    /// CSS pixels to points.
    let zoom: CGFloat
    /// The corners of the pane the page sits in, which the halo follows.
    @Environment(\.paneCorner) private var corner

    var body: some View {
        if activity.working {
            ZStack(alignment: .bottom) {
                // Taken by the person: gone, not hidden, so nothing goes on drawing.
                if !activity.held {
                    AgentLayers(activity: activity, corner: corner, zoom: zoom, holds: activity.owned, turning: activity.stepping)
                        .id(corner)
                }
                pill.padding(.bottom, 22)
            }
            .transition(.opacity)
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
            Text(activity.driver).font(.system(size: 12, weight: .semibold))
            Rectangle().fill(Palette.hairline).frame(width: 1, height: 14)
            Text(activity.held ? "Paused here: the page is yours" : activity.caption).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 320, alignment: .leading)
            Pill("Stop") { activity.leave() }
            if activity.held {
                Pill("Hand back", filled: true) { activity.handBack() }.help("Let the assistant act on this page again")
            } else {
                Pill("Take control", filled: true) { activity.takeControl() }
                    .help("Use the page yourself; the assistant is told, and leaves it until you hand it back")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }
}

/// The overlay's layers, moved by Core Animation.
private struct AgentLayers: NSViewRepresentable {
    let activity: AgentActivity
    let corner: CGFloat
    let zoom: CGFloat
    let holds: Bool
    /// A step is running: the halo turns; between steps it rests.
    let turning: Bool

    func makeNSView(context: Context) -> Layers { Layers(activity: activity, corner: corner) }

    func updateNSView(_ view: Layers, context: Context) {
        view.zoom = zoom
        view.holds = holds
        view.turning = turning
    }

    final class Layers: NSView {
        var zoom: CGFloat = 1
        /// Holding the page's clicks and scrolls while the agent has it.
        var holds = false
        /// The halo turns while a step runs and rests, still and dimmer, between them.
        var turning = false {
            didSet { if turning != oldValue { halo.rest(!turning) } }
        }
        private let wash = CALayer()
        /// The floating search's own halo, just inside the page's edge.
        private let halo: AskHalo.HaloView
        private let cursor = CAShapeLayer()
        /// The element the assistant has picked, outlined; it slides to the next one.
        private let picked = CAShapeLayer()
        private var watching: AnyCancellable?

        init(activity: AgentActivity, corner: CGFloat) {
            halo = AskHalo.HaloView(radius: corner, inset: 1)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(wash)
            wash.backgroundColor = Glow.clay.withAlphaComponent(0.04).cgColor
            halo.autoresizingMask = [.width, .height]
            addSubview(halo)
            halo.show(true)
            cursor.path = Self.arrow
            cursor.fillColor = NSColor.white.cgColor
            cursor.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
            cursor.lineWidth = 1
            cursor.shadowOpacity = 0.3
            cursor.shadowRadius = 3
            cursor.shadowOffset = CGSize(width: 0, height: -1)
            cursor.opacity = 0
            picked.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
            picked.lineWidth = 2
            picked.opacity = 0
            picked.strokeColor = Glow.clay.cgColor
            picked.shadowColor = Glow.clay.cgColor
            picked.shadowOpacity = 0.6
            picked.shadowRadius = 6
            picked.shadowOffset = .zero
            layer?.addSublayer(picked)
            layer?.addSublayer(cursor)
            watching = activity.effects.sink { [weak self] effect in self?.play(effect) }
            halo.rest(true)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        /// While the agent has the page it stands in the way: Take control on
        /// the pill hands it to the person.
        override func hitTest(_ point: NSPoint) -> NSView? { holds ? super.hitTest(point) : nil }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func magnify(with event: NSEvent) {}

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.frame = bounds
            halo.frame = bounds
            CATransaction.commit()
        }

        private func play(_ effect: AgentActivity.Effect) {
            switch effect {
            case .move(let box): glide(to: box)
            case .click(let box):
                glide(to: box)
                ripple(at: middle(box))
            case .write(let box):
                glide(to: box)
                outline(box)
            case .scroll(let down): hint(down: down)
            }
        }

        private func points(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * zoom, y: box.minY * zoom, width: box.width * zoom, height: box.height * zoom)
        }

        private func middle(_ box: CGRect) -> CGPoint {
            let box = points(box)
            return CGPoint(x: box.midX, y: box.midY)
        }

        private func glide(to box: CGRect) {
            select(box)
            let to = middle(box)
            let from = cursor.opacity == 0 ? CGPoint(x: bounds.midX, y: bounds.maxY - 80) : cursor.position
            cursor.opacity = 1
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = from
            move.toValue = to
            move.duration = Glow.stillness ? 0 : 0.35
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cursor.position = to
            cursor.add(move, forKey: "glide")
        }

        /// Outlines the element picked, sliding there from the last one.
        private func select(_ box: CGRect) {
            let path = CGPath(roundedRect: points(box).insetBy(dx: -4, dy: -4), cornerWidth: 7, cornerHeight: 7, transform: nil)
            let was = picked.opacity == 0 ? path : picked.presentation()?.path ?? picked.path ?? path
            picked.opacity = 1
            let slide = CABasicAnimation(keyPath: "path")
            slide.fromValue = was
            slide.toValue = path
            slide.duration = Glow.stillness ? 0 : 0.35
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            picked.path = path
            picked.add(slide, forKey: "slide")
        }

        private func ripple(at point: CGPoint) {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = Glow.clay.cgColor
            ring.lineWidth = 2
            ring.position = point
            layer?.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let both = CAAnimationGroup()
            both.animations = [grow, fade]
            both.duration = 0.5
            both.beginTime = CACurrentMediaTime() + 0.3
            both.fillMode = .backwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.opacity = 0
            ring.add(both, forKey: "ripple")
            CATransaction.commit()
        }

        private func outline(_ box: CGRect) {
            let line = CAShapeLayer()
            line.path = CGPath(roundedRect: points(box).insetBy(dx: -3, dy: -3), cornerWidth: 6, cornerHeight: 6, transform: nil)
            line.fillColor = nil
            line.strokeColor = Glow.clay.cgColor
            line.lineWidth = 2
            layer?.addSublayer(line)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.2
            pulse.duration = 0.4
            pulse.autoreverses = true
            pulse.repeatCount = 2
            CATransaction.begin()
            CATransaction.setCompletionBlock { line.removeFromSuperlayer() }
            line.add(pulse, forKey: "pulse")
            CATransaction.commit()
        }

        private func hint(down: Bool) {
            let arrow = CATextLayer()
            arrow.string = down ? "↓" : "↑"
            arrow.fontSize = 28
            arrow.alignmentMode = .center
            arrow.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            arrow.contentsScale = window?.backingScaleFactor ?? 2
            arrow.frame = CGRect(x: bounds.midX - 20, y: down ? bounds.maxY - 120 : 60, width: 40, height: 40)
            layer?.addSublayer(arrow)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.7
            CATransaction.begin()
            CATransaction.setCompletionBlock { arrow.removeFromSuperlayer() }
            arrow.opacity = 0
            arrow.add(fade, forKey: "fade")
            CATransaction.commit()
        }

        /// An arrow pointer, its tip at the layer's origin (y down).
        private static let arrow: CGPath = {
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 17))
            path.addLine(to: CGPoint(x: 4.5, y: 13))
            path.addLine(to: CGPoint(x: 7.5, y: 19.5))
            path.addLine(to: CGPoint(x: 10, y: 18.5))
            path.addLine(to: CGPoint(x: 7, y: 12))
            path.addLine(to: CGPoint(x: 12.5, y: 12))
            path.closeSubpath()
            return path
        }()
    }
}

/// The corners of the pane a page sits in: the window's card on its own,
/// a split pane's in a split.
private struct PaneCorner: EnvironmentKey {
    static var defaultValue: CGFloat { ChromeLayout.corner }
}

extension EnvironmentValues {
    var paneCorner: CGFloat {
        get { self[PaneCorner.self] }
        set { self[PaneCorner.self] = newValue }
    }
}
