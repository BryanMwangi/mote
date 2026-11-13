import AppKit
import Combine
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
    /// A step is running: the page holds off the person's clicks and keys.
    @Published private(set) var stepping = false

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

    /// A step begins: shown, with its caption, the page held.
    func begin(_ caption: String, by driver: String, stop: (() -> Void)?) {
        resting?.cancel()
        if !working { working = true }
        if self.caption != caption { self.caption = caption }
        if self.driver != driver { self.driver = driver }
        self.stop = stop
        stepping = true
    }

    /// The step is done: the page is the person's again, and the overlay
    /// goes a moment later unless another step comes.
    func end(then finished: (() -> Void)? = nil) {
        stepping = false
        resting?.cancel()
        resting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.working = false
            finished?()
        }
    }

    /// The person stops it, or takes the page back.
    func leave() {
        resting?.cancel()
        stop?()
        stop = nil
        stepping = false
        working = false
    }
}

/// Over a page the assistant is acting on: a light wash of the space's
/// colour and a lit ring round the edge that turns and breathes, its cursor
/// gliding to what it acts on, a ripple where it clicks, an outline round
/// what it writes in, and a pill saying who's doing what, with Stop and
/// Take over. All Core Animation, added only while it works.
struct AgentOverlay: View {
    @ObservedObject var activity: AgentActivity
    /// CSS pixels to points.
    let zoom: CGFloat
    @Environment(\.spaceTint) private var tint

    var body: some View {
        if activity.working {
            ZStack(alignment: .bottom) {
                AgentLayers(activity: activity, tint: NSColor(tint ?? Color(nsColor: Glow.clay)), zoom: zoom, holds: activity.stepping)
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
            Text(activity.caption).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 320, alignment: .leading)
            Pill("Stop") { activity.leave() }
            Pill("Take over", filled: true) { activity.leave() }
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
    let tint: NSColor
    let zoom: CGFloat
    let holds: Bool

    func makeNSView(context: Context) -> Layers { Layers(activity: activity) }

    func updateNSView(_ view: Layers, context: Context) {
        view.zoom = zoom
        view.holds = holds
        view.tint(tint)
    }

    final class Layers: NSView {
        var zoom: CGFloat = 1
        /// Holding the page's clicks and keys while a step runs.
        var holds = false
        private let wash = CALayer()
        /// The ring: a gradient turning inside a still frame that only shows its edge.
        private let edge = CALayer()
        private let ring = CAGradientLayer()
        private let ringShape = CAShapeLayer()
        private let cursor = CAShapeLayer()
        /// The element the assistant has picked, outlined; it slides to the next one.
        private let picked = CAShapeLayer()
        private var watching: AnyCancellable?

        init(activity: AgentActivity) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(wash)
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 1, y: 0.5)
            ringShape.fillColor = nil
            ringShape.strokeColor = NSColor.black.cgColor
            ringShape.lineWidth = 3
            edge.mask = ringShape
            edge.addSublayer(ring)
            layer?.addSublayer(edge)
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
            layer?.addSublayer(picked)
            layer?.addSublayer(cursor)
            watching = activity.effects.sink { [weak self] effect in self?.play(effect) }
            if !Glow.stillness { breathe() }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        /// Only while a step runs does it stand in the page's way.
        override func hitTest(_ point: NSPoint) -> NSView? { holds ? super.hitTest(point) : nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.frame = bounds
            edge.frame = bounds
            ringShape.frame = bounds
            ringShape.path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
            // Wider than the view, so it covers every corner as it turns.
            let side = hypot(bounds.width, bounds.height)
            ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        func tint(_ color: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.backgroundColor = color.withAlphaComponent(0.05).cgColor
            picked.strokeColor = color.cgColor
            picked.shadowColor = color.cgColor
            picked.shadowOpacity = 0.6
            picked.shadowRadius = 6
            picked.shadowOffset = .zero
            ring.colors = [color.cgColor, color.withAlphaComponent(0.15).cgColor, NSColor.white.withAlphaComponent(0.9).cgColor, color.cgColor]
            CATransaction.commit()
        }

        /// The ring turns once in three seconds and breathes, as Phi's does.
        private func breathe() {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = 3
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = 0.55
            glow.toValue = 1
            glow.duration = 1.7
            glow.autoreverses = true
            glow.repeatCount = .infinity
            edge.add(glow, forKey: "breathe")
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
            ring.strokeColor = wash.backgroundColor.map { NSColor(cgColor: $0)?.withAlphaComponent(1).cgColor } ?? NSColor.white.cgColor
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
            line.strokeColor = ring.colors?.first.map { $0 as! CGColor } ?? NSColor.white.cgColor
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
