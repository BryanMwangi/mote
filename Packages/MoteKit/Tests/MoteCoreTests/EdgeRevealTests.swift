import CoreGraphics
import Testing

@testable import MoteCore

@Suite("EdgeReveal")
struct EdgeRevealTests {
    private func pointer(
        at distance: CGFloat, inWindow: Bool = true, onWindow: Bool = true, onOwnPanel: Bool = false
    ) -> EdgeReveal.Pointer {
        EdgeReveal.Pointer(inWindow: inWindow, onWindow: onWindow, onOwnPanel: onOwnPanel, distance: distance)
    }

    @Test("Touching the edge brings the tabs out at once when folded by hand")
    func showsAtEdge() {
        #expect(EdgeReveal.step(pointer(at: 2), peeking: false, reach: 248, waits: false) == .show)
    }

    @Test("Touching the edge waits a moment when the tabs hide by themselves or sit on top")
    func dwells() {
        #expect(EdgeReveal.step(pointer(at: 2), peeking: false, reach: 248, waits: true) == .showSoon)
    }

    @Test("Away from the edge nothing happens")
    func awayFromEdge() {
        #expect(EdgeReveal.step(pointer(at: EdgeReveal.edge), peeking: false, reach: 248, waits: false) == .pass)
        #expect(EdgeReveal.step(pointer(at: 400), peeking: false, reach: 248, waits: false) == .pass)
    }

    @Test("Another app's window over the edge doesn't pull the tabs out")
    func otherWindowAbove() {
        #expect(EdgeReveal.step(pointer(at: 2, onWindow: false), peeking: false, reach: 248, waits: false) == .pass)
        #expect(EdgeReveal.step(pointer(at: 2, inWindow: false), peeking: false, reach: 248, waits: false) == .pass)
    }

    @Test("While out, the tabs stay as long as the pointer is over them")
    func staysWhileOver() {
        #expect(EdgeReveal.step(pointer(at: 120), peeking: true, reach: 248, waits: false) == .show)
    }

    @Test("Leaving the tabs puts them away after the grace period")
    func hidesAfterLeaving() {
        #expect(EdgeReveal.step(pointer(at: 300), peeking: true, reach: 248, waits: false) == .hideSoon)
        #expect(EdgeReveal.step(pointer(at: 100, inWindow: false), peeking: true, reach: 248, waits: false) == .hideSoon)
        #expect(EdgeReveal.step(pointer(at: 100, onWindow: false), peeking: true, reach: 248, waits: false) == .hideSoon)
    }

    @Test("Straying a little past the edge keeps the tabs out; further, or not level with the window, puts them away")
    func strayPastEdge() {
        let past = EdgeReveal.Pointer(inWindow: false, onWindow: false, onOwnPanel: false, distance: -10, beside: true)
        #expect(EdgeReveal.step(past, peeking: true, reach: 248, waits: false) == .show)
        var far = past
        far.distance = -EdgeReveal.slop - 1
        #expect(EdgeReveal.step(far, peeking: true, reach: 248, waits: false) == .hideSoon)
        var below = past
        below.beside = false
        #expect(EdgeReveal.step(below, peeking: true, reach: 248, waits: false) == .hideSoon)
        // Folded away, straying past the edge doesn't bring them out.
        #expect(EdgeReveal.step(past, peeking: false, reach: 248, waits: false) == .pass)
    }

    @Test("A menu opened from the peeking tabs keeps them out")
    func ownPanelKeepsThem() {
        #expect(
            EdgeReveal.step(pointer(at: 600, onWindow: false, onOwnPanel: true), peeking: true, reach: 248, waits: false) == .show)
    }
}
