import Foundation
import Testing

@testable import MoteCore

@Suite("WebResults")
struct WebResultsTests {
    private static func result(_ href: String, _ title: String, _ snippet: String, ad: Bool = false) -> String {
        """
        <div class="result results_links results_links_deep web-result \(ad ? "result--ad" : "")">
          <h2 class="result__title"><a rel="nofollow" class="result__a" href="\(href)">\(title)</a></h2>
          <a class="result__url" href="\(href)">site</a>
          <a class="result__snippet" href="\(href)">\(snippet)</a>
        </div>
        """
    }

    @Test("Reads each result's title, line and address, as plain text, ads left out")
    func parse() {
        let page =
            "<div class=\"results\">"
            + Self.result("https://ads.example/x", "Buy now", "An ad", ad: true)
            + Self.result("https://en.wikipedia.org/wiki/Newark", "Newark - Wikipedia", "<b>Newark</b> is a city &amp; port")
            + Self.result("//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.newark.com%2F&rut=abc", "Newark Electronics", "We&#x27;re a distributor")
        let found = WebResults.parse(html: page)
        #expect(found.count == 2)
        #expect(found[0] == WebResult(title: "Newark - Wikipedia", snippet: "Newark is a city & port", url: URL(string: "https://en.wikipedia.org/wiki/Newark")!))
        #expect(found[1].url.absoluteString == "https://www.newark.com/")
        #expect(found[1].snippet == "We're a distributor")
        #expect(found[1].site == "newark.com")
    }

    @Test("Stops at the limit, and finds nothing on a page without results")
    func limit() {
        let page = (1...5).map { Self.result("https://e\($0).example/", "Result \($0)", "") }.joined()
        #expect(WebResults.parse(html: page, limit: 3).map(\.title) == ["Result 1", "Result 2", "Result 3"])
        #expect(WebResults.parse(html: "<html>No results.</html>").isEmpty)
    }

    @Test("The results page asks for the words")
    func address() {
        #expect(WebResults.address(for: "total cost").absoluteString == "https://html.duckduckgo.com/html/?q=total%20cost")
    }
}
