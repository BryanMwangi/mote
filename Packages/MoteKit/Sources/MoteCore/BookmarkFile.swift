import Foundation

/// A bookmarks file as every browser exports it (the old Netscape HTML):
/// folders as `<H3>` headings over `<DL>` lists, sites as `<A HREF>` links.
public enum BookmarkFile {
    public static func bookmarks(in html: String) -> [Bookmark] {
        // Each tag that matters, in order: a folder's name, a link, a list's start or end.
        let tags = /<h3[^>]*>(.*?)<\/h3>|<a\s[^>]*?href\s*=\s*"([^"]*)"[^>]*>(.*?)<\/a>|<dl[^>]*>|<\/dl>/
            .ignoresCase().dotMatchesNewlines()
        // The folders open, each with what's in it so far; the outermost is the file's.
        var open: [(title: String, items: [Bookmark])] = [("", [])]
        // A folder named, waiting for its list.
        var named: String?
        for match in html.matches(of: tags) {
            let text = match.output.0.lowercased()
            if let title = match.output.1 {
                named = plain(title)
            } else if let href = match.output.2, let url = URL(string: plain(href)), url.scheme != nil, url.scheme != "place" {
                // Not Firefox's smart folders (place: queries).
                open[open.count - 1].items.append(.site(plain(match.output.3 ?? ""), url))
            } else if text.hasPrefix("<dl") {
                // The file's own list, or a folder's.
                if let title = named {
                    open.append((title, []))
                    named = nil
                } else if open.count > 1 || !open[0].items.isEmpty {
                    open.append(("", []))
                }
            } else if text.hasPrefix("</dl"), open.count > 1 {
                let done = open.removeLast()
                if done.title.isEmpty {
                    open[open.count - 1].items += done.items
                } else {
                    open[open.count - 1].items.append(.folder(done.title, done.items))
                }
            }
        }
        // Lists left open at the end of a cut-off file.
        while open.count > 1 {
            let done = open.removeLast()
            open[open.count - 1].items.append(done.title.isEmpty ? .folder("Bookmarks", done.items) : .folder(done.title, done.items))
        }
        return open[0].items
    }

    /// Text without its tags and entities.
    private static func plain(_ html: some StringProtocol) -> String {
        var text = String(html).replacing(/<[^>]*>/, with: "")
        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
