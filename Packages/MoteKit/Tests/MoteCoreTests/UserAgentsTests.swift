import Testing

@testable import MoteCore

@Suite("User agents")
struct UserAgentsTests {
    @Test("Safari's own entries carry the installed version")
    func safari() {
        let groups = UserAgents.presets(safari: "26.1")
        #expect(groups.first?.first?.title == "Safari 26.1")
        #expect(groups.first?.first?.value.hasSuffix("Version/26.1 Safari/605.1.15") == true)
        #expect(groups[1].first?.title == "Safari — iOS 26 — iPhone")
        #expect(groups[1].first?.value.contains("iPhone OS 18_6") == true)
    }

    @Test("Every entry is distinct and names its browser")
    func distinct() {
        let all = UserAgents.presets(safari: "26.1").flatMap { $0 }
        #expect(Set(all.map(\.value)).count == all.count)
        #expect(all.filter { $0.title.hasPrefix("Microsoft Edge") }.allSatisfy { $0.value.contains("Edg") })
        #expect(all.filter { $0.title.hasPrefix("Firefox") }.allSatisfy { $0.value.contains("Firefox/") })
    }
}
