import Foundation
import Testing

@testable import MoteCore

@Suite("ContentBlockingRules")
struct ContentBlockingRulesTests {
    @Test("The filter matches the domain and its subdomains, and nothing that merely ends like it")
    func urlFilter() throws {
        let filter = try Regex(ContentBlockingRules.urlFilter(for: "doubleclick.net"))
        #expect("https://doubleclick.net/ad".contains(filter))
        #expect("https://stats.g.doubleclick.net/x".contains(filter))
        #expect(!"https://notdoubleclick.net/x".contains(filter))
        #expect(!"https://doubleclickxnet.com/x".contains(filter))
    }

    @Test("One third-party block rule per domain, plus the cosmetic rule")
    func json() throws {
        let data = Data(try ContentBlockingRules.json().utf8)
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: [String: Any]]])
        #expect(rules.count == ContentBlockingRules.blockedDomains.count + 1)

        let blocks = rules.filter { $0["action"]?["type"] as? String == "block" }
        #expect(blocks.count == ContentBlockingRules.blockedDomains.count)
        #expect(blocks.allSatisfy { ($0["trigger"]?["load-type"] as? [String]) == ["third-party"] })

        let cosmetic = try #require(rules.last)
        #expect(cosmetic["action"]?["type"] as? String == "css-display-none")
    }

    @Test("Domains are unique")
    func uniqueDomains() {
        #expect(Set(ContentBlockingRules.blockedDomains).count == ContentBlockingRules.blockedDomains.count)
    }
}

@Suite("FilterRules")
struct FilterRulesTests {
    @Test("Scriptlet arguments split as uBlock Origin splits them")
    func arguments() {
        #expect(FilterRules.arguments("json-prune, adPlacements playerAds") == ["json-prune", "adPlacements playerAds"])
        #expect(FilterRules.arguments("set, a.b, '1, 2'") == ["set", "a.b", "1, 2"])
        #expect(FilterRules.arguments(#"x, a\, b, c"#) == ["x", "a, b", "c"])
        #expect(FilterRules.arguments(#"x, 'it\'s', "q""#) == ["x", "it's", "q"])
        #expect(FilterRules.arguments("x, , c") == ["x", "", "c"])
        #expect(FilterRules.arguments("x, a,") == ["x", "a"])
        #expect(FilterRules.arguments("x, /a,b/") == ["x", "/a", "b/"])
        #expect(FilterRules.arguments("") == [])
    }

    @Test("A host is known by its domains and entities")
    func names() {
        #expect(
            FilterRules.names(of: "www.youtube.com") == [
                "www.youtube.com", "youtube.com", "com", "www.youtube.*", "www.*", "youtube.*",
            ])
    }

    private func rules(_ text: String, trusted: Bool = true) -> FilterRules {
        var rules = FilterRules()
        rules.add(text, trusted: trusted, aliases: ["set.js": "set-constant.js"])
        return rules
    }

    @Test("Scriptlets go to the sites named, their subdomains and entities, but those excepted")
    func scriptlets() {
        let rules = rules(
            """
            ! comment
            youtube.com,~music.youtube.com##+js(json-prune, adPlacements)
            example.*##+js(set, a, 1)
            ##+js(generic-is-ignored)
            example.org#@#+js(set-constant.js, a, 1)
            """)
        #expect(rules.matches(on: "www.youtube.com").scriptlets.map(\.args) == [["json-prune.js", "adPlacements"]])
        #expect(rules.matches(on: "music.youtube.com").scriptlets.isEmpty)
        #expect(rules.matches(on: "example.co.uk").scriptlets.map(\.args) == [["set-constant.js", "a", "1"]])
        #expect(rules.matches(on: "example.org").scriptlets.isEmpty)
        #expect(rules.matches(on: "other.com").isEmpty)
    }

    @Test("An empty scriptlet exception turns them all off for a site")
    func allOff() {
        let rules = rules("a.com##+js(x)\na.com##.ad\nb.a.com#@#+js()")
        #expect(rules.matches(on: "b.a.com").scriptlets.isEmpty)
        #expect(rules.matches(on: "b.a.com").hidden == [".ad"])
        #expect(!rules.matches(on: "a.com").scriptlets.isEmpty)
    }

    @Test("A site's element hiding, with :style and :remove; procedural and generic ones left out")
    func hiding() {
        let rules = rules(
            """
            a.com##.banner
            a.com##.box:style(opacity: 0 !important)
            a.com##.gone:remove()
            a.com##.x:has-text(Ad)
            a.com##^script:has-text(ad)
            ##.everywhere
            a.com#@#.banner
            b.com##.banner
            """)
        let a = rules.matches(on: "a.com")
        #expect(a.hidden == [".gone"])
        #expect(a.styles == [".box { opacity: 0 !important }"])
        #expect(rules.matches(on: "b.com").hidden == [".banner"])
    }

    @Test("!#if follows what holds for Mote, with !#else")
    func conditions() {
        let rules = rules(
            """
            !#if env_safari
            a.com##.safari
            !#else
            a.com##.not-safari
            !#endif
            !#if env_chromium
            a.com##.chromium
            !#endif
            !#if !cap_html_filtering
            a.com##.no-html
            !#endif
            """)
        #expect(rules.matches(on: "a.com").hidden == [".safari", ".no-html"])
    }
}
