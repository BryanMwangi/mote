import AppKit
import Combine
import SwiftUI

/// A download starting: its file's icon falls from where the page was
/// clicked, on an arc toward the side with more room, into the downloads
/// button (or the toast's place, with the sidebar away), and the button
/// ripples as it lands. One layer, moved by Core Animation, so it keeps
/// going while the main thread is busy; skipped under Reduce Motion, or with
/// no click in the page a moment before.
@MainActor
enum DownloadDrop {
    /// Where the page was last pressed, on screen, and when.
    static var pressed: (point: NSPoint, at: Date)?
    /// The downloads button, while it shows.
    static weak var target: NSView?
    /// Lands to ripple the button, counted.
    static let landed = Landings()

    final class Landings: ObservableObject {
        @Published var count = 0
    }

    /// `within`: how long after the click it may still fall; longer after a
    /// save panel, which waits on the person.
    static func fly(_ icon: NSImage, in window: NSWindow?, within: TimeInterval = 3) {
        guard let window, let frame = window.contentView?.superview, let layer = frame.layer, !Glow.stillness,
            let pressed, Date().timeIntervalSince(pressed.at) < within
        else { return }
        self.pressed = nil
        let start = frame.convert(window.convertPoint(fromScreen: pressed.point), from: nil)
        let end: NSPoint
        if let target, target.window === window, !target.isHiddenOrHasHiddenAncestor {
            end = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: frame)
        } else {
            end = NSPoint(x: frame.bounds.midX, y: 50)
        }
        let side: CGFloat = 48
        let flying = CALayer()
        flying.contents = icon
        flying.contentsGravity = .resizeAspect
        flying.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        flying.position = end
        flying.transform = CATransform3DMakeScale(0.45, 0.45, 1)
        flying.opacity = 0
        flying.zPosition = 1000
        layer.addSublayer(flying)

        // Up and over toward the side with more room, then down into place.
        let room = start.x > frame.bounds.midX ? -1.0 : 1.0
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2 + room * 80, y: max(start.y, end.y) + 140))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.5, 1.8, 0.45]
        scale.keyTimes = [0, 0.35, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.9, 1]
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]
        group.duration = 1
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            flying.removeFromSuperlayer()
            MainActor.assumeIsolated { landed.count += 1 }
        }
        flying.add(group, forKey: "drop")
        CATransaction.commit()
    }
}

/// Marks the downloads button for a download's drop to land on.
struct DownloadDropTarget: FillsRoom {
    func makeNSView(context: Context) -> NSView { Spot() }
    func updateNSView(_ view: NSView, context: Context) { DownloadDrop.target = view }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A copy of what it's on going out and fading, each time `trigger` goes
/// up: a ring as a download finishes, a file's icon as it opens.
struct Ripple<Copy: View>: ViewModifier {
    let trigger: Int
    let copy: Copy
    @State private var spread = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                copy
                    .scaleEffect(spread ? 1.8 : 1)
                    .opacity(showing && !spread ? 0.8 : 0)
                    .allowsHitTesting(false)
            }
            .onChange(of: trigger) {
                guard !Glow.stillness else { return }
                showing = true
                spread = false
                withAnimation(.easeOut(duration: 0.5)) { spread = true } completion: {
                    showing = false
                    spread = false
                }
            }
    }
}

extension View {
    func ripple(_ trigger: Int, @ViewBuilder copy: () -> some View) -> some View {
        modifier(Ripple(trigger: trigger, copy: copy()))
    }
}
