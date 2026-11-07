import Foundation

/// A page from another browser's history, as Mote's history takes it.
public struct Visit: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var count: Int
    public var last: Date

    public init(url: URL, title: String, count: Int, last: Date) {
        self.url = url
        self.title = title
        self.count = count
        self.last = last
    }

    static func web(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Firefox's `places.sqlite` (Firefox, Zen, LibreWolf…): its bookmarks and
/// history, from rows the caller reads with these queries.
public enum FirefoxPlaces {
    public static let bookmarksSQL = """
        SELECT b.id, b.parent, b.type, COALESCE(b.title, ''), p.url, COALESCE(b.guid, '')
        FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
        """
    public static let historySQL = """
        SELECT url, COALESCE(title, ''), visit_count, last_visit_date FROM moz_places
        WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 3000
        """

    public struct Row: Sendable {
        public var id: Int64
        public var parent: Int64
        /// 1 a bookmark, 2 a folder, 3 a separator.
        public var type: Int64
        public var title: String
        public var url: String?
        public var guid: String

        public init(id: Int64, parent: Int64, type: Int64, title: String, url: String?, guid: String) {
            self.id = id
            self.parent = parent
            self.type = type
            self.title = title
            self.url = url
            self.guid = guid
        }
    }

    /// The toolbar's at the top, as Chromium's bar; the menu, other and
    /// mobile bookmarks as folders after.
    public static func bookmarks(_ rows: [Row]) -> [Bookmark] {
        let inside = Dictionary(grouping: rows, by: \.parent)
        func items(in folder: Int64) -> [Bookmark] {
            (inside[folder] ?? []).compactMap { row in
                switch row.type {
                case 1: return Visit.web(row.url).map { .site(row.title.isEmpty ? $0.absoluteString : row.title, $0) }
                case 2:
                    let children = items(in: row.id)
                    return children.isEmpty ? nil : .folder(row.title, children)
                default: return nil
                }
            }
        }
        func root(_ guid: String) -> Int64? { rows.first { $0.guid == guid }?.id }
        var found = root("toolbar_____").map(items) ?? []
        for (guid, name) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile")] {
            if let id = root(guid) {
                let children = items(in: id)
                if !children.isEmpty { found.append(.folder(name, children)) }
            }
        }
        return found
    }

    /// Firefox keeps times in microseconds since 1970.
    public static func date(_ microseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(microseconds) / 1_000_000) }
}

/// The bookmarks file every browser exports (Netscape's format): Safari's
/// File › Export, Firefox's, Chrome's. A toolbar or favourites folder's
/// bookmarks come to the top, as Chromium's bar.
public enum NetscapeBookmarks {
    public static func read(html: String) -> [Bookmark] {
        let pattern = #"<DL[^>]*>|</DL>|<H3([^>]*)>(.*?)</H3>|<A\s([^>]*)>(.*?)</A>"#
        guard let tokens = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        struct Level {
            var name: String?
            var toolbar = false
            var items: [Bookmark] = []
        }
        var levels = [Level()]
        var pending: (name: String, toolbar: Bool)?
        let text = html as NSString
        for match in tokens.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range).lowercased()
            func group(_ index: Int) -> String {
                match.range(at: index).location == NSNotFound ? "" : text.substring(with: match.range(at: index))
            }
            if token.hasPrefix("<dl") {
                levels.append(Level(name: pending?.name, toolbar: pending?.toolbar ?? false))
                pending = nil
            } else if token == "</dl>" {
                guard levels.count > 1 else { continue }
                let done = levels.removeLast()
                if done.name == nil || done.toolbar {
                    levels[levels.count - 1].items += done.items
                } else if !done.items.isEmpty, let name = done.name {
                    levels[levels.count - 1].items.append(.folder(name, done.items))
                }
            } else if token.hasPrefix("<h3") {
                let attributes = group(1), name = decode(group(2))
                let toolbar =
                    attributes.localizedCaseInsensitiveContains("PERSONAL_TOOLBAR_FOLDER")
                    || attributes.contains("BookmarksBar")
                    || ["favorites", "favourites", "bookmarks bar", "bookmarks toolbar"].contains(name.lowercased())
                pending = (name, toolbar)
            } else if let url = Visit.web(decode(attribute("HREF", in: group(3)))) {
                let title = decode(group(4))
                levels[levels.count - 1].items.append(.site(title.isEmpty ? url.absoluteString : title, url))
            }
        }
        while levels.count > 1 {
            let done = levels.removeLast()
            levels[levels.count - 1].items += done.items
        }
        return levels[0].items
    }

    private static func attribute(_ name: String, in attributes: String) -> String {
        guard let range = attributes.range(of: #"\#(name)\s*=\s*"([^"]*)""#, options: [.regularExpression, .caseInsensitive]) else {
            return ""
        }
        let found = String(attributes[range])
        guard let open = found.firstIndex(of: "\"") else { return "" }
        return String(found[found.index(after: open)...].dropLast())
    }

    static func decode(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What Safari's File › Export Browsing Data writes, besides its
/// bookmarks file and passwords CSV: `History.json`.
public enum SafariExport {
    public static func history(json: Data) -> [Visit] {
        guard let file = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let entries = file["history"] as? [[String: Any]]
        else { return [] }
        var latest: [URL: Visit] = [:]
        for entry in entries {
            guard let url = Visit.web(entry["url"] as? String) else { continue }
            let when = Date(timeIntervalSince1970: ((entry["time_usec"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000)
            let visit = Visit(
                url: url, title: entry["title"] as? String ?? "", count: max(1, (entry["visit_count"] as? NSNumber)?.intValue ?? 1),
                last: when)
            if let kept = latest[url], kept.last >= when { continue }
            latest[url] = visit
        }
        return latest.values.sorted { $0.last > $1.last }
    }
}
