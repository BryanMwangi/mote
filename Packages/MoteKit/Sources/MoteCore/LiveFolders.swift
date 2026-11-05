import Foundation

/// What a live folder follows, as Zen's live folders: a feed, or GitHub's
/// open pull requests or issues for a repository, or a search, without
/// signing in.
public enum LiveSource: Codable, Equatable, Sendable {
    case feed(URL)
    case pulls(repo: String)
    case issues(repo: String)
    case search(String)

    /// Where to ask.
    public var address: URL? {
        switch self {
        case .feed(let url): url
        case .pulls(let repo): URL(string: "https://api.github.com/repos/\(repo)/pulls?state=open&per_page=30")
        case .issues(let repo): URL(string: "https://api.github.com/repos/\(repo)/issues?state=open&per_page=30")
        case .search(let query):
            query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap {
                URL(string: "https://api.github.com/search/issues?q=\($0)&per_page=30")
            }
        }
    }

    /// "owner/repo" from what was typed: the repository's page or its name.
    public static func repo(in text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        let parts = text.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { return nil }
        return parts.joined(separator: "/")
    }
}

/// One thing a live folder shows.
public struct LiveItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
        (self.id, self.title, self.url) = (id, title, url)
    }

    /// The items in a reply from `source`: an RSS or Atom feed, or GitHub's
    /// JSON (issues without the pull requests GitHub lists among them).
    public static func items(in data: Data, from source: LiveSource) -> [LiveItem] {
        switch source {
        case .feed: return FeedReader.items(in: data)
        case .pulls, .issues, .search:
            let reply = try? JSONSerialization.jsonObject(with: data)
            let list = (reply as? [[String: Any]]) ?? ((reply as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            return list.compactMap { entry in
                if case .issues = source, entry["pull_request"] != nil { return nil }
                guard let title = entry["title"] as? String, let url = (entry["html_url"] as? String).flatMap(URL.init(string:)) else {
                    return nil
                }
                let number = (entry["number"] as? Int).map { "#\($0) " } ?? ""
                return LiveItem(id: url.absoluteString, title: number + title, url: url)
            }
        }
    }
}

/// RSS 2.0 and Atom, as little of each as a list needs: each item's title
/// and link.
final class FeedReader: NSObject, XMLParserDelegate {
    private var items: [LiveItem] = []
    private var inItem = false
    private var text = ""
    private var title = ""
    private var link = ""
    private var guid = ""

    static func items(in data: Data) -> [LiveItem] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        switch name {
        case "item", "entry":
            inItem = true
            (title, link, guid) = ("", "", "")
        // Atom: the link is an attribute; the alternate one, or the first.
        case "link" where inItem:
            if let href = attributes["href"], link.isEmpty || attributes["rel"] == "alternate" { link = href }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch name {
        case "title": title = value
        case "link" where !value.isEmpty: link = value
        case "guid", "id": guid = value
        case "item", "entry":
            inItem = false
            if let url = URL(string: link) {
                items.append(LiveItem(id: guid.isEmpty ? link : guid, title: title.isEmpty ? link : title, url: url))
            }
        default: break
        }
    }
}
