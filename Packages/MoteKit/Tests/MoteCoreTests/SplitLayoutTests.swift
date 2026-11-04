import CoreGraphics
import Foundation
import Testing

@testable import MoteCore

@Suite("SplitLayout")
struct SplitLayoutTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func near(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    @Test("A tab dropped on a side takes that half")
    func insertEachSide() {
        for (side, expected) in [
            (SplitSide.left, CGRect(x: 0, y: 0, width: 500, height: 600)),
            (.right, CGRect(x: 500, y: 0, width: 500, height: 600)),
            (.top, CGRect(x: 0, y: 0, width: 1000, height: 300)),
            (.bottom, CGRect(x: 0, y: 300, width: 1000, height: 300)),
        ] {
            var layout = SplitLayout("a")
            let done1 = layout.insert("b", beside: "a", side: side)
            #expect(done1)
            #expect(near(layout.frames(in: area, gap: 0)["b"], expected))
        }
    }

    @Test("Beside a tab along the same axis it's a sibling; a fifth tab is refused")
    func siblingsAndLimit() {
        var layout = SplitLayout("a")
        layout.insert("b", beside: "a", side: .right)
        layout.insert("c", beside: "b", side: .right)
        #expect(layout.ids == ["a", "b", "c"])
        if case .split(.across, let children) = layout.root { #expect(children.count == 3) } else { Issue.record("not a row") }
        layout.insert("d", beside: "a", side: .bottom)
        #expect(layout.count == 4)
        let done2 = layout.insert("e", beside: "a", side: .left)
        #expect(!done2)
        let done3 = layout.insert("a", beside: "b", side: .left)
        #expect(!done3)
    }

    @Test("Removing gives the room back and collapses a split of one")
    func remove() {
        var layout = SplitLayout("a")
        layout.insert("b", beside: "a", side: .right)
        layout.insert("c", beside: "b", side: .bottom)
        let done4 = layout.remove("c")
        #expect(done4)
        #expect(layout.root == SplitLayout.Node.split(.across, [.init(node: .leaf("a"), share: 0.5), .init(node: .leaf("b"), share: 0.5)]))
        let done5 = layout.remove("b")
        #expect(done5)
        #expect(layout.root == .leaf("a"))
        let done6 = layout.remove("a")
        #expect(!done6)
    }

    @Test("Frames fill the area with the gaps between; dividers sit in the gaps and move within bounds")
    func framesAndDividers() throws {
        var layout = try #require(SplitLayout.layout(.across, ["a", "b"]))
        let frames = layout.frames(in: area, gap: 8)
        #expect(near(frames["a"], CGRect(x: 0, y: 0, width: 496, height: 600)))
        #expect(near(frames["b"], CGRect(x: 504, y: 0, width: 496, height: 600)))
        let divider = try #require(layout.dividers(in: area, gap: 8).first)
        #expect(near(divider.rect, CGRect(x: 496, y: 0, width: 8, height: 600)))
        layout.move(divider, to: 750)
        #expect(abs((layout.frames(in: area, gap: 0)["a"]?.width ?? 0) - 750) < 1)
        layout.move(divider, to: 10)
        #expect(abs((layout.frames(in: area, gap: 0)["a"]?.width ?? 0) - 1000 * SplitLayout<String>.least) < 1)
    }

    @Test("Zen's layouts: a grid puts two to a column")
    func grids() throws {
        let three = try #require(SplitLayout.layout(.grid, ["a", "b", "c"]))
        let frames = three.frames(in: area, gap: 0)
        #expect(near(frames["a"], CGRect(x: 0, y: 0, width: 500, height: 300)))
        #expect(near(frames["b"], CGRect(x: 0, y: 300, width: 500, height: 300)))
        #expect(near(frames["c"], CGRect(x: 500, y: 0, width: 500, height: 600)))
        let down = try #require(SplitLayout.layout(.down, ["a", "b"]))
        #expect(near(down.frames(in: area, gap: 0)["b"], CGRect(x: 0, y: 300, width: 1000, height: 300)))
        #expect(SplitLayout.layout(.grid, ["a", "b", "c", "d", "e"]) == nil)
    }

    @Test("Drop sides are the edges' quarters, nothing in the middle")
    func dropSides() {
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 50, y: 300), in: area) == .left)
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 950, y: 300), in: area) == .right)
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 500, y: 40), in: area) == .top)
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 500, y: 590), in: area) == .bottom)
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 500, y: 300), in: area) == nil)
        #expect(SplitLayout<String>.dropSide(at: CGPoint(x: 1200, y: 300), in: area) == nil)
    }

    @Test("Mapped to other ids, a dropped tab leaves; fewer than two is no split")
    func mapping() {
        var layout = SplitLayout("a")
        layout.insert("b", beside: "a", side: .right)
        layout.insert("c", beside: "b", side: .bottom)
        let positions = ["a": 0, "b": 1, "c": 2]
        #expect(layout.compactMap { positions[$0] }?.ids == [0, 1, 2])
        #expect(layout.compactMap { $0 == "c" ? nil : positions[$0] }?.ids == [0, 1])
        #expect(layout.compactMap { $0 == "a" ? positions[$0] : nil } == nil)
    }

    @Test("It survives being saved")
    func codable() throws {
        var layout = SplitLayout("a")
        layout.insert("b", beside: "a", side: .bottom)
        let back = try JSONDecoder().decode(SplitLayout<String>.self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
    }
}
