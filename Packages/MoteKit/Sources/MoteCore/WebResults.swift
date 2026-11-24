import Foundation

/// A result from the web, as Look Up lists it: a page's title, a line from it, and where it is.
public struct WebResult: Equatable, Sendable, Identifiable {
    public let title: String
    public let snippet: String
    public let url: URL

    public var id: URL { url }

    /// The site, without "www.".
    public var site: String {
        let host = url.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A few results from the web for some words, read from DuckDuckGo's plain
/// HTML results page: no key, no script, quick to read.
public enum WebResults {
    /// The page the results are read from.
    public static func address(for words: String) -> URL {
        var parts = URLComponents(string: "https://html.duckduckgo.com/html/")!
        parts.queryItems = [URLQueryItem(name: "q", value: words)]
        return parts.url!
    }

    /// The first `limit` results on a results page, ads left out.
    public static func parse(html: String, limit: Int = 3) -> [WebResult] {
        var found: [WebResult] = []
        for block in html.components(separatedBy: "class=\"result results_links").dropFirst() {
            guard found.count < limit else { break }
            if block.prefix(200).contains("result--ad") { continue }
            guard let link = first(#"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, in: block), link.count == 2,
                let url = address(link[0])
            else { continue }
            let snippet = first(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block)?.first ?? ""
            let title = text(link[1])
            guard !title.isEmpty else { continue }
            found.append(WebResult(title: title, snippet: text(snippet), url: url))
        }
        return found
    }

    /// A result's link: the page's own, or the one inside DuckDuckGo's redirect.
    private static func address(_ href: String) -> URL? {
        let href = text(href)
        let full = href.hasPrefix("//") ? "https:" + href : href
        guard let url = URL(string: full) else { return nil }
        if let inside = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: inside)
        }
        return url.scheme?.hasPrefix("http") == true ? url : nil
    }

    /// The first match's groups.
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// Markup as plain text: tags gone, entities read, spaces squeezed.
    static func text(_ html: String) -> String {
        var out = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        out = out.replacingOccurrences(of: #"&#(x?)([0-9a-fA-F]+);"#, with: "", options: .regularExpression)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
