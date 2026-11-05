import Testing

@testable import MoteCore

@Suite("TabRow")
struct TabRowTests {
    struct Tab: Identifiable, Equatable {
        let id: String
        var pinned = false
        var section: TabTier = .loose
    }

    /// A row from a spec like "A* B* c d": starred names are pinned.
    private func row(_ spec: String) -> TabRow<Tab> {
        let tabs = spec.split(separator: " ").map { word in
            Tab(id: String(word.filter { $0 != "*" }), pinned: word.hasSuffix("*"))
        }
        return TabRow(tabs, isPinned: \.pinned)
    }

    /// A three-section row: "E!" an essential, "P*" pinned, "l" loose.
    private func tiered(_ spec: String) -> TabRow<Tab> {
        let tabs = spec.split(separator: " ").map { word in
            let section: TabTier = word.hasSuffix("!") ? .essential : word.hasSuffix("*") ? .pinned : .loose
            return Tab(id: String(word.filter { $0 != "*" && $0 != "!" }), section: section)
        }
        return TabRow(tabs, section: \.section)
    }

    private func names(_ row: TabRow<Tab>) -> String {
        row.tabs.map(\.id).joined(separator: " ")
    }

    private func moved(_ tabs: inout TabRow<Tab>, _ id: String, to index: Int) -> Bool {
        tabs.move(id, to: index)
    }

    @Test("Stepping wraps round, and can pass over tabs, as Zen's ⌃⇥ without essentials")
    func steppingSkips() {
        let tabs = tiered("E! F! a b c")
        #expect(tabs.neighbour(of: "c", by: 1) == "E")
        #expect(tabs.neighbour(of: "a", by: -1) == "F")
        let loose = { (tab: Tab) in tab.section == .essential }
        #expect(tabs.neighbour(of: "c", by: 1, skipping: loose) == "a")
        #expect(tabs.neighbour(of: "a", by: -1, skipping: loose) == "c")
        #expect(tabs.neighbour(of: "a", by: 2, skipping: loose) == "c")
        // Nothing else to go to.
        #expect(tiered("E! a").neighbour(of: "a", by: 1, skipping: loose) == nil)
        #expect(row("a").neighbour(of: "a", by: 1) == nil)
    }

    @Test("New tabs open next to the active one")
    func nextToActive() {
        #expect(row("a b c").slotForNew(after: "a") == 1)
        #expect(row("a b c").slotForNew(after: "c") == 3)
    }

    @Test("New tabs never open among the pinned ones")
    func afterPins() {
        #expect(row("A* B* c").slotForNew(after: "A") == 2)
    }

    @Test("With no active tab, new tabs go at the end")
    func noActive() {
        #expect(row("a b").slotForNew(after: nil) == 2)
        #expect(row("a b").slotForNew(after: "gone") == 2)
    }

    @Test("Stepping wraps around both ends")
    func stepping() {
        let tabs = row("a b c")
        #expect(tabs.neighbour(of: "c", by: 1) == "a")
        #expect(tabs.neighbour(of: "a", by: -1) == "c")
        #expect(tabs.neighbour(of: "b", by: 1) == "c")
        #expect(row("a").neighbour(of: "a", by: 1) == nil)
    }

    @Test("Closing a tab hands over to its right neighbour, or the new last tab")
    func successor() {
        var tabs = row("a b c")
        let at = tabs.remove("b")
        #expect(at == 1)
        #expect(tabs.successor(ofRemovedAt: 1) == "c")
        tabs.remove("c")
        #expect(tabs.successor(ofRemovedAt: 1) == "a")
    }

    @Test("Dragging moves a tab to its final position")
    func drag() {
        var tabs = row("a b c d")
        #expect(moved(&tabs, "a", to: 2))
        #expect(names(tabs) == "b c a d")
        #expect(moved(&tabs, "d", to: 0))
        #expect(names(tabs) == "d b c a")
    }

    @Test("Dragging never crosses the pinned boundary")
    func dragBoundary() {
        var tabs = row("A* B* c d")
        #expect(!moved(&tabs, "c", to: 1))
        #expect(!moved(&tabs, "A", to: 3))
        #expect(moved(&tabs, "B", to: 0))
        #expect(names(tabs) == "B A c d")
    }

    @Test("A drag to the same place or off the row changes nothing")
    func dragNowhere() {
        var tabs = row("a b")
        #expect(!moved(&tabs, "a", to: 0))
        #expect(!moved(&tabs, "a", to: 5))
        #expect(names(tabs) == "a b")
    }

    @Test("A newly pinned tab goes to the end of the pinned tabs")
    func pinning() {
        var tabs = row("A* b c D*")
        tabs.settle("D")
        #expect(names(tabs) == "A D b c")
    }

    @Test("An unpinned tab goes to the start of the others")
    func unpinning() {
        var tabs = row("a B* C* d")
        tabs.settle("a")
        #expect(names(tabs) == "B C a d")
    }

    @Test("Sections are measured in order: essentials, pinned, loose")
    func sections() {
        let tabs = tiered("A! B! c* d* e f")
        #expect(tabs.count(in: .essential) == 2)
        #expect(tabs.places(of: .pinned) == 2..<4)
        #expect(tabs.start(of: .loose) == 4)
        #expect(tabs.pinnedCount == 4)
    }

    @Test("New tabs open after the pinned tabs too")
    func afterKept() {
        #expect(tiered("A! b* c").slotForNew(after: "A") == 2)
        #expect(tiered("A! b* c").slotForNew(after: "b") == 2)
    }

    @Test("Dragging stays within each of three sections")
    func dragThreeSections() {
        var tabs = tiered("A! B! c* d* e f")
        #expect(!moved(&tabs, "c", to: 1))
        #expect(!moved(&tabs, "d", to: 4))
        #expect(!moved(&tabs, "e", to: 3))
        #expect(moved(&tabs, "d", to: 2))
        #expect(names(tabs) == "A B d c e f")
    }

    @Test("A tab moving between sections lands at the edge of its new one")
    func settleThreeSections() {
        var tabs = tiered("A! b* c d* e")
        tabs.settle("d")
        #expect(names(tabs) == "A b d c e")
        var essential = tiered("A! b* c D! e")
        essential.settle("D")
        #expect(names(essential) == "A D b c e")
        var loose = tiered("A! b c* e")
        loose.settle("b")
        #expect(names(loose) == "A c b e")
    }

    @Test("Closed tabs keep only the most recent")
    func recentlyClosed() {
        struct Entry: Identifiable { let id: Int }
        var closed = RecentlyClosed<Entry>(limit: 3)
        for n in 1...5 { closed.push(Entry(id: n)) }
        #expect(closed.entries.map(\.id) == [3, 4, 5])
        closed.remove(4)
        #expect(closed.entries.map(\.id) == [3, 5])
        #expect(closed.last?.id == 5)
    }
}

@Suite("TabRow menu helpers")
struct TabRowMenuTests {
    struct Tab: Identifiable {
        let id: String
        var section: TabTier = .loose
        var address: String?
    }

    /// "E!" an essential, "P*" pinned, the rest open; "=x" gives the address x.
    private func row(_ spec: String) -> TabRow<Tab> {
        let tabs = spec.split(separator: " ").map { word -> Tab in
            let parts = word.split(separator: "=")
            let name = String(parts[0])
            let section: TabTier = name.hasSuffix("!") ? .essential : name.hasSuffix("*") ? .pinned : .loose
            return Tab(id: name.filter { $0 != "!" && $0 != "*" }, section: section, address: parts.count > 1 ? String(parts[1]) : nil)
        }
        return TabRow(tabs, section: \.section)
    }

    @Test("Close Duplicate Tabs: the other open tabs at the address, not essentials or pinned ones")
    func duplicates() {
        let tabs = row("E!=x P*=x a=x b=y c=x d")
        #expect(tabs.duplicates(of: "a", address: \.address) == ["c"])
        #expect(tabs.duplicates(of: "E", address: \.address) == ["a", "c"])
        #expect(tabs.duplicates(of: "b", address: \.address).isEmpty)
        #expect(tabs.duplicates(of: "d", address: \.address).isEmpty)
    }

    @Test("Close Tabs Below: the open tabs after it")
    func below() {
        let tabs = row("E! P* a b c")
        #expect(tabs.below("a") == ["b", "c"])
        #expect(tabs.below("c").isEmpty)
        #expect(tabs.below("E") == ["a", "b", "c"])
        #expect(tabs.below("nope").isEmpty)
    }
}
