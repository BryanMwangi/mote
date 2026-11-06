import Foundation
import Testing

@testable import MoteCore

@Suite("Folders")
struct FoldersTests {
    private let work = Folder(name: "Work")
    private var docs: Folder { Folder(name: "Docs", parent: work.id) }

    @Test("Folders come first, each with its folders and tabs a level in; then the tabs in none")
    func outline() {
        let docs = docs
        let lines = Folder.outline(
            [work, docs], tabs: [(id: "a", folder: nil), (id: "b", folder: work.id), (id: "c", folder: docs.id)], active: nil)
        #expect(
            lines == [
                .folder(work.id, depth: 0), .folder(docs.id, depth: 1), .tab("c", depth: 2), .tab("b", depth: 1), .tab("a", depth: 0),
            ])
    }

    @Test("A collapsed folder hides its tabs, but not the one in front, as Zen")
    func collapsed() {
        var work = work
        work.collapsed = true
        let docs = Folder(name: "Docs", parent: work.id)
        let tabs: [(id: String, folder: UUID?)] = [(id: "b", folder: work.id), (id: "c", folder: docs.id)]
        #expect(Folder.outline([work, docs], tabs: tabs, active: nil) == [.folder(work.id, depth: 0)])
        #expect(Folder.outline([work, docs], tabs: tabs, active: "c") == [.folder(work.id, depth: 0), .tab("c", depth: 1)])
    }

    @Test("A tab naming a folder that's gone is in none; a folder whose parent is gone is at the top")
    func orphans() {
        let lost = Folder(name: "Lost", parent: UUID())
        let lines = Folder.outline([lost], tabs: [(id: "a", folder: UUID())], active: nil)
        #expect(lines == [.folder(lost.id, depth: 0), .tab("a", depth: 0)])
    }

    @Test("Depth, and a folder's whole family")
    func family() {
        let docs = docs
        let deep = Folder(name: "Deep", parent: docs.id)
        let other = Folder(name: "Other")
        #expect(Folder.depth(of: deep.id, in: [work, docs, deep]) == 2)
        #expect(Folder.family(of: work.id, in: [work, docs, deep, other]) == [work.id, docs.id, deep.id])
    }

    @Test("Saved and read back")
    func codable() throws {
        var folder = Folder(name: "Work")
        folder.collapsed = true
        #expect(try JSONDecoder().decode(Folder.self, from: JSONEncoder().encode(folder)) == folder)
    }

    @Test("A dragged tab drops into the folder under the pointer, not its own")
    func dropTarget() {
        let (work, docs) = (UUID(), UUID())
        let rows = [work: CGRect(x: 0, y: 100, width: 200, height: 30), docs: CGRect(x: 0, y: 140, width: 200, height: 30)]
        #expect(Folder.dropTarget(at: CGPoint(x: 50, y: 150), in: rows, from: nil) == docs)
        #expect(Folder.dropTarget(at: CGPoint(x: 50, y: 150), in: rows, from: docs) == nil)
        #expect(Folder.dropTarget(at: CGPoint(x: 50, y: 135), in: rows, from: nil) == nil)
    }

    @Test("A folder moves before another, beside it; never into itself")
    func moving() throws {
        let a = Folder(name: "A")
        let b = Folder(name: "B")
        let inner = Folder(name: "Inner", parent: b.id)
        let moved = try #require(Folder.moving(inner.id, before: a.id, in: [a, b, inner]))
        #expect(moved.map(\.name) == ["Inner", "A", "B"])
        #expect(moved[0].parent == nil)
        #expect(Folder.moving(b.id, before: inner.id, in: [a, b, inner]) == nil)
        #expect(Folder.moving(a.id, before: a.id, in: [a, b]) == nil)
        // After the last: the only way there.
        #expect(Folder.moving(a.id, before: b.id, after: true, in: [a, b])?.map(\.name) == ["B", "A"])
    }
}
