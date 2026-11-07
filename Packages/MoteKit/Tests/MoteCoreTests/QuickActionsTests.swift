import Testing

@testable import MoteCore

@Suite("QuickActions")
struct QuickActionsTests {
    private let actions: [(id: String, title: String)] = [
        ("compact", "Compact Mode"), ("close", "Close Tab"), ("reopen", "Reopen Closed Tab"), ("window", "New Window"),
        ("private", "New Private Window"), ("settings", "Settings"), ("pin", "Pin Tab"),
    ]

    @Test("A title's start finds it first; an exact title beats a longer one holding it")
    func prefixAndExact() {
        #expect(QuickActions.ranked(actions, for: "comp") == ["compact"])
        #expect(QuickActions.ranked(actions, for: "close tab").first == "close")
        #expect(QuickActions.ranked(actions, for: "Settings") == ["settings"])
    }

    @Test("Letters in order across words find it")
    func fuzzy() {
        #expect(QuickActions.ranked(actions, for: "new win").first == "window")
        #expect(QuickActions.ranked(actions, for: "npw").contains("private") == false)
    }

    @Test("Two characters or fewer, or letters out of order, find nothing; at most three show")
    func limits() {
        #expect(QuickActions.ranked(actions, for: "co").isEmpty)
        #expect(QuickActions.ranked(actions, for: "zzz").isEmpty)
        #expect(QuickActions.ranked(actions, for: "tab").count <= QuickActions.most)
        #expect(QuickActions.score("Pin Tab", "bat") == 0)
    }
}
