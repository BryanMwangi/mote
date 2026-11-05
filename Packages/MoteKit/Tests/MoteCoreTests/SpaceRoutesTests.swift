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

@Suite("SpaceTheme")
struct SpaceThemeTests {
    @Test("Colours read and write as #rrggbb; three at most; opacity kept between 0 and 1")
    func colours() throws {
        let rgb = try #require(SpaceTheme.rgb("#ff8000"))
        #expect(rgb.red == 1 && abs(rgb.green - 128.0 / 255) < 0.001 && rgb.blue == 0)
        #expect(SpaceTheme.rgb("nope") == nil)
        #expect(SpaceTheme.hex(red: 1, green: 128.0 / 255, blue: 0) == "#ff8000")
        let theme = SpaceTheme(colors: ["#000000", "#111111", "#222222", "#333333"], opacity: 3)
        #expect(theme.colors.count == 3 && theme.opacity == 1)
    }

    @Test("A space without a theme still reads, and one with it comes back")
    func saved() throws {
        var space = Space(id: UUID(), name: "Work")
        #expect(try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space)).theme == nil)
        space.theme = SpaceTheme(colors: ["#7c5cff"], grain: true)
        #expect(try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space)) == space)
    }
}
