import MoteCore
import SwiftUI
import WebKit

/// Holds the active tab's web view. Tabs hand theirs over when they come to
/// the front and get it back as it was: not reloaded, scroll and forms kept.
struct WebStage: FillsRoom {
    let page: NSView?
    /// Pages about to be switched to, kept drawing behind it (see StageView.warm).
    var warm: [NSView] = []
    /// Responsive Design Mode: the size the page is laid out at, and whether
    /// it's scaled down to fit.
    var device: CGSize? = nil
    var fits = true

    func makeNSView(context: Context) -> StageView { StageView() }
    func updateNSView(_ view: StageView, context: Context) {
        view.device = device
        view.fits = fits
        view.warm = warm
        view.show(page)
    }
}

final class StageView: NSView {
    /// The view to show; the one thing kept. Every layout brings the subviews
    /// in line with it, so they can't drift apart.
    private weak var wanted: NSView?
    /// Pages a switch is likely to go to next: kept in the window, drawing,
    /// behind the one in front, as Firefox warms a tab. A page that wasn't
    /// showing is drawn afresh when it comes back, which a switch waited on
    /// (about 130 ms); a warm one is already drawn.
    var warm: [NSView] = []
    var device: CGSize?
    var fits = true
    /// Around a device, so its edges and handles show.
    static let margin: CGFloat = 24

    override func layout() {
        super.layout()
        settle()
    }

    func show(_ page: NSView?) {
        wanted = page
        settle()
    }

    private func settle() {
        // A full-screen video's web view lives in WebKit's own window, with a
        // stand-in here; taking it back then leaves a black screen with the sound
        // still playing. WebKit returns it when full screen ends.
        if let web = wanted as? WKWebView, web.fullscreenState != .notInFullscreen { return }

        // Everything else goes, except a docked Web Inspector: WebKit puts it
        // beside the page and narrows the page to fit, so removing it would leave
        // the page narrow beside an empty space.
        let inspecting = inspectorOpen
        let keep = warm.filter { $0 !== wanted }
        for view in subviews where view !== wanted && !keep.contains(where: { $0 === view }) && !(inspecting && Self.isInspector(view)) {
            view.removeFromSuperview()
        }

        guard let wanted, window != nil else { return }
        // Behind the page in front, which takes the clicks.
        for page in keep {
            if page.superview !== self {
                page.removeFromSuperview()
                page.alphaValue = 1
                addSubview(page, positioned: .below, relativeTo: wanted.superview === self ? wanted : nil)
            }
            place(page)
        }
        if wanted.superview !== self {
            // Adding it takes it from wherever it was.
            wanted.removeFromSuperview()
            // Hidden until it has painted, so it doesn't flash white.
            wanted.alphaValue = (wanted as? PageView)?.unpainted == true ? 0 : 1
            addSubview(wanted)
            // A web view back in a window can keep an empty backing store.
            wanted.needsLayout = true
            wanted.needsDisplay = true
            wanted.layer?.setNeedsDisplay()
        }
        // The page in front has the keyboard, as in Safari, unless a field or
        // panel holds it: a key pressed with nobody holding it (after launch,
        // say, while the page loads) made the window beep.
        if let window, window.firstResponder === window || (window.firstResponder is PageView && window.firstResponder !== wanted) {
            window.makeFirstResponder(wanted)
        }
        // In front of the warm pages, as it may have been one of them: by
        // sorting, as adding it again would take it out of the window and
        // back, and it would be drawn afresh.
        if subviews.last(where: { !Self.isInspector($0) }) !== wanted {
            sortSubviews(
                { one, other, front in
                    let front = front.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
                    return one === front ? .orderedDescending : other === front ? .orderedAscending : .orderedSame
                }, context: Unmanaged.passUnretained(wanted).toOpaque())
        }
        // With the inspector docked, WebKit lays both out; a frame here would cover the inspector.
        if !(inspecting && subviews.contains(where: Self.isInspector)) { place(wanted) }
    }

    /// The whole stage; with a device, its size centred, and laid out at that
    /// size even when drawn smaller (WebKit's view scale, as Safari's own
    /// responsive mode uses; a WebKit without it shows the page at its frame).
    private func place(_ page: NSView) {
        guard let device else {
            page.frame = bounds
            return scale(page, 1)
        }
        let placed = Devices.place(device, in: bounds.insetBy(dx: Self.margin, dy: Self.margin), fits: fits)
        // `place` measures from the top; this view, as AppKit's do, from the bottom.
        var frame = placed.frame
        frame.origin.y = bounds.height - frame.maxY
        page.frame = frame
        scale(page, placed.scale)
    }

    private func scale(_ page: NSView, _ scale: CGFloat) {
        guard let web = page as? WKWebView, web.unpublishedNumber("_viewScale") != scale else { return }
        web.unpublished("_setViewScale:", scale)
    }

    /// Whether the page's Web Inspector is open, through private WebKit
    /// calls checked before use (see Inspector.swift).
    private var inspectorOpen: Bool {
        let inspector = NSSelectorFromString("_inspector")
        let visible = NSSelectorFromString("isVisible")
        guard let web = wanted as? WKWebView, web.responds(to: inspector),
            let object = web.perform(inspector)?.takeUnretainedValue() as? NSObject, object.responds(to: visible)
        else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: visible), to: Getter.self)(object, visible)
    }

    private static func isInspector(_ view: NSView) -> Bool {
        String(describing: type(of: view)).hasPrefix("WKInspector")
    }
}
