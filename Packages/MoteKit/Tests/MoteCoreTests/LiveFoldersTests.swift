import Foundation
import Testing

@testable import MoteCore

@Suite("LiveFolders")
struct LiveFoldersTests {
    @Test("RSS: each item's title and link")
    func rss() {
        let feed = Data(
            """
            <?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title>
            <item><title>First post</title><link>https://example.com/1</link><guid>post-1</guid></item>
            <item><title><![CDATA[Second & last]]></title><link>https://example.com/2</link></item>
            </channel></rss>
            """.utf8)
        let items = LiveItem.items(in: feed, from: .feed(URL(string: "https://example.com/feed")!))
        #expect(items.map(\.title) == ["First post", "Second & last"])
        #expect(items.map(\.id) == ["post-1", "https://example.com/2"])
    }

    @Test("Atom: the alternate link, from its attribute")
    func atom() {
        let feed = Data(
            """
            <feed xmlns="http://www.w3.org/2005/Atom"><title>News</title>
            <entry><title>Hello</title><id>tag:a,1</id><link rel="self" href="https://a/self"/><link rel="alternate" href="https://a/hello"/></entry>
            </feed>
            """.utf8)
        let items = LiveItem.items(in: feed, from: .feed(URL(string: "https://a/atom")!))
        #expect(items == [LiveItem(id: "tag:a,1", title: "Hello", url: URL(string: "https://a/hello")!)])
    }

    @Test("GitHub: pull requests, issues without the pull requests among them, and search")
    func github() {
        let list = Data(
            """
            [{"number": 1, "title": "Bug", "html_url": "https://github.com/a/b/issues/1"},
             {"number": 2, "title": "Fix", "html_url": "https://github.com/a/b/pull/2", "pull_request": {}}]
            """.utf8)
        #expect(LiveItem.items(in: list, from: .issues(repo: "a/b")).map(\.title) == ["#1 Bug"])
        #expect(LiveItem.items(in: list, from: .pulls(repo: "a/b")).count == 2)
        let search = Data(#"{"items": [{"number": 7, "title": "Found", "html_url": "https://github.com/a/b/issues/7"}]}"#.utf8)
        #expect(LiveItem.items(in: search, from: .search("is:open")).map(\.title) == ["#7 Found"])
    }

    @Test("A repository from its page or its name; addresses to ask")
    func repos() {
        #expect(LiveSource.repo(in: "https://github.com/zen-browser/desktop/pulls") == "zen-browser/desktop")
        #expect(LiveSource.repo(in: "zen-browser/desktop") == "zen-browser/desktop")
        #expect(LiveSource.repo(in: "not a repo") == nil)
        #expect(LiveSource.pulls(repo: "a/b").address?.absoluteString == "https://api.github.com/repos/a/b/pulls?state=open&per_page=30")
        #expect(LiveSource.search("is:open author:me").address?.absoluteString.contains("is:open%20author:me") == true)
    }
}
