import AppKit
import QuartzCore
import WebKit

/// Snap: an element turns to dust as it goes
/// Core Animation over the page; the page only loses the element.
@MainActor
enum Dust {
    /// About this many specks, whatever the element's size.
    private static let specks = 1400.0

    /// Snaps `rect` (in the page's view) away, then calls `gone` to hide it
    /// for real underneath.
    static func play(over web: WKWebView, rect: CGRect, gone: @escaping () -> Void) {
        let shown = rect.intersection(web.bounds)
        guard !shown.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return gone() }
        let config = WKSnapshotConfiguration()
        config.rect = shown
        web.takeSnapshot(with: config) { image, _ in
            MainActor.assumeIsolated {
                gone()
                guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                scatter(picture, at: shown, over: web)
            }
        }
    }

    private static func scatter(_ picture: CGImage, at rect: CGRect, over web: WKWebView) {
        let cloud = NSView(
            frame: web.isFlipped ? rect : CGRect(x: rect.minX, y: web.bounds.height - rect.maxY, width: rect.width, height: rect.height))
        cloud.wantsLayer = true
        guard let root = cloud.layer else { return }
        web.addSubview(cloud)
        let side = max(3, (rect.width * rect.height / specks).squareRoot())
        let columns = Int((rect.width / side).rounded(.up)), rows = Int((rect.height / side).rounded(.up))
        let now = CACurrentMediaTime()
        // Up is away from the top on screen, whichever way the layer runs.
        let up: CGFloat = root.isGeometryFlipped || web.isFlipped ? -1 : 1
        for row in 0..<rows {
            for column in 0..<columns {
                let frame = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                let speck = CALayer()
                speck.contents = picture
                speck.frame = frame
                speck.contentsRect = CGRect(
                    x: frame.minX / rect.width, y: frame.minY / rect.height, width: side / rect.width, height: side / rect.height)
                root.addSublayer(speck)
                // A sweep from left to right, each speck a little out of turn.
                let start = now + Double(frame.minX / max(rect.width, 1)) * 0.45 + Double.random(in: 0...0.12)
                let drift = CGPoint(x: CGFloat.random(in: 20...90), y: up * CGFloat.random(in: 10...70))
                let move = CABasicAnimation(keyPath: "position")
                move.toValue = CGPoint(x: speck.position.x + drift.x, y: speck.position.y + drift.y)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.toValue = 0
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.toValue = 0.3
                let group = CAAnimationGroup()
                group.animations = [move, fade, shrink]
                group.beginTime = start
                group.duration = 0.5
                group.timingFunction = CAMediaTimingFunction(name: .easeIn)
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false
                speck.add(group, forKey: "dust")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { cloud.removeFromSuperview() }
    }
}
