import Foundation
import Testing

@testable import MoteCore

@Suite("SpaceRoutes")
struct SpaceRoutesTests {
    private let work = UUID(), home = UUID()

    @Test("Contains, equals and patterns, as Zen's; the first rule that matches wins")
    func matching() {
        let routes = [
            SpaceRoute(reference: "GitHub.com", space: work),
            SpaceRoute(reference: "https://www.example.com/", match: .equals, space: home),
            SpaceRoute(reference: #"^https://(mail|calendar)\.google\.com"#, match: .pattern, space: work),
            SpaceRoute(reference: "github.com/me", space: home),
        ]
        #expect(SpaceRoute.space(for: "https://github.com/me/repo", in: routes) == work)
        #expect(SpaceRoute.space(for: "http://example.com", in: routes) == home)
        #expect(SpaceRoute.space(for: "https://example.com/page", in: routes) == nil)
        #expect(SpaceRoute.space(for: "https://MAIL.google.com/u/0", in: routes) == work)
        #expect(SpaceRoute.space(for: "https://news.ycombinator.com", in: routes) == nil)
    }

    @Test("An empty rule or a broken pattern matches nothing")
    func nothing() {
        #expect(!SpaceRoute(reference: "  ", space: work).matches("https://a.com"))
        #expect(!SpaceRoute(reference: "([", match: .pattern, space: work).matches("https://a.com"))
    }
}
