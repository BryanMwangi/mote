import AppKit
import MoteAI
import MoteCore
import PDFKit
import WebKit

/// The web and the person's own things: reading a page out of sight,
/// history, bookmarks, downloads, saving for later, and keeping a page as a
/// PDF or Markdown.
extension AssistantTools {
    var dataTools: [Tool] {
        let query = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        let dryRun = #""dry_run":{"type":"boolean","description":"Say what would happen, without doing it or asking"}"#
        var tools = [
            Tool(
                name: "read_page",
                description: "Loads a web page out of sight and returns its text. A search engine's results address searches the web.",
                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
            Tool(
                name: "search_history",
                description:
                    "Pages the person visited in Mote whose title or address has all the words, in any order (one word at a time finds the most), newest first: title, address, last visit, how many visits. from and to (ISO 8601 dates) narrow it to when; no words lists everything in that time.",
                schema:
                    #"{"type":"object","properties":{"query":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"},"limit":{"type":"integer"}}}"#),
            Tool(name: "search_bookmarks", description: "The person's bookmarks matching the words (empty: all), with their ids and folders.", schema: query),
            Tool(
                name: "downloads", description: "The person's downloads, numbered newest first; or opens one, or shows it in the Finder, by its number.",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","open","reveal"]},"number":{"type":"integer"}}}"#),
        ]
        // Listed even with acting off: asked for, the model hears how to turn it on.
        tools += [
            Tool(
                name: "add_bookmark", description: "Bookmarks a tab or an address, into a folder by name (made if there's none).",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"url\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\"}}}"),
            Tool(
                name: "organise_bookmarks",
                description:
                    "Tidies bookmarks: moves them into folders by name (made if there's none), and removes some. Asks the person once for all of it.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\"moves\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"bookmark\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\"}}}},\"remove\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\(dryRun)}}"),
            Tool(
                name: "delete_history",
                description:
                    "Deletes history: pages at given addresses, or every page last visited between two times (ISO 8601). Asks first, saying how many; it can't be undone.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\"urls\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"},\(dryRun)}}"),
            Tool(
                name: "save_for_later", description: "Keeps a tab or address in the “Saved for later” bookmarks, with a note.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"url\":{\"type\":\"string\"},\"note\":{\"type\":\"string\"}}}"),
            Tool(
                name: "save_page_as_pdf", description: "Saves a tab's whole page as a PDF in the person's Downloads.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
            Tool(
                name: "export_markdown", description: "Saves a tab's text, with its title and address, as a Markdown file in the person's Downloads.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
        ]
        return tools
    }

    func runData(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "read_page":
            guard let url = web(input["url"]?.string) else { return "That isn't a web address." }
            // A PDF: its text page by page, not WebKit's viewer.
            if url.pathExtension.lowercased() == "pdf", let (data, _) = try? await URLSession.shared.data(from: url),
                let document = PDFDocument(data: data)
            {
                return "\(url.absoluteString)\nA PDF of \(document.pageCount) pages.\n\n" + Self.text(of: document)
            }
            return await ReadAway.text(of: url)
        case "search_history":
            return searchHistory(input)
        case "search_bookmarks":
            let words = (input["query"]?.string ?? "").lowercased()
            let found = Self.marks(browser.bookmarks.roots, in: nil).filter {
                words.isEmpty || $0.mark.title.lowercased().contains(words) || ($0.mark.url ?? "").lowercased().contains(words)
            }
            return found.prefix(40).map { "\(Self.short($0.mark.id))\t\($0.mark.title)\t\($0.mark.url ?? "")\t\($0.folder.map { "in “\($0)”" } ?? "")" }
                .joined(separator: "\n").ifEmpty("Nothing found.")
        case "downloads":
            return downloads(input)
        case "add_bookmark", "save_for_later":
            guard await permit(.gentle, "") else { return refused }
            let found = find(input)
            guard let url = found?.tab.address ?? web(input["url"]?.string) else { return "Give a tab or a web address." }
            let note = input["note"]?.string.map { " — \($0)" } ?? ""
            let title = (input["title"]?.string ?? found?.tab.label ?? url.absoluteString) + note
            let folder = call.name == "save_for_later" ? "Saved for later" : input["folder"]?.string
            let mark = Bookmark(title: title, url: url.absoluteString, children: nil)
            let before = browser.bookmarks.roots
            browser.bookmarks.insert(mark, into: folder.map(bookmarkFolder(named:)))
            return "Bookmarked “\(title)” \(url.absoluteString)\(folder.map { " in “\($0)”" } ?? "")."
                + record("Bookmarked “\(title)”") { [weak browser] in
                    browser?.bookmarks.restore(before)
                    return "Took the bookmark out again."
                }
        case "organise_bookmarks":
            return await organise(input)
        case "delete_history":
            return await deleteHistory(input)
        case "save_page_as_pdf", "export_markdown":
            guard await permit(.gentle, "") else { return refused }
            guard let found = find(input) else { return "There's no open tab with that id; list the tabs again." }
            return await keep(found.tab, asPDF: call.name == "save_page_as_pdf")
        default:
            return nil
        }
    }

    // MARK: - Bookmarks

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// Every bookmark that's a page, with the folder it's in.
    private static func marks(_ nodes: [Bookmark], in folder: String?) -> [(mark: Bookmark, folder: String?)] {
        nodes.flatMap { $0.isFolder ? marks($0.children ?? [], in: $0.title) : [($0, folder)] }
    }

    static func flat(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { $0.isFolder ? flat($0.children ?? []) : [$0] }
    }

    private static func folders(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { $0.isFolder ? [$0] + folders($0.children ?? []) : [] }
    }

    /// A bookmark folder by name, made at the top if there's none.
    private func bookmarkFolder(named name: String) -> UUID {
        if let found = Self.folders(browser.bookmarks.roots).first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return found.id
        }
        return browser.bookmarks.insert(Bookmark(title: name, url: nil, children: []), into: nil).id
    }

    private func organise(_ input: JSON) async -> String {
        let every = Self.marks(browser.bookmarks.roots, in: nil).map(\.mark)
        func mark(_ id: String?) -> Bookmark? { id.flatMap { id in every.first { Self.short($0.id) == id.lowercased() } } }
        let moves = (input["moves"]?.array ?? []).compactMap { move -> (Bookmark, String)? in
            guard let found = mark(move["bookmark"]?.string), let folder = move["folder"]?.string else { return nil }
            return (found, folder)
        }
        let removing = (input["remove"]?.array ?? []).compactMap { mark($0.string) }
        guard !moves.isEmpty || !removing.isEmpty else { return "None of those bookmarks was found; search the bookmarks again for their ids." }
        let plan = [
            moves.isEmpty ? nil : "move \(moves.count) into \(Set(moves.map(\.1)).map { "“\($0)”" }.joined(separator: ", "))",
            removing.isEmpty ? nil : "remove \(removing.count): \(removing.prefix(5).map { "“\($0.title)”" }.joined(separator: ", "))",
        ].compactMap { $0 }.joined(separator: " and ")
        if input["dry_run"]?.bool == true { return "Would \(plan)." }
        guard await permit(.destructive, "Tidy your bookmarks: \(plan)?") else { return refused }
        let before = browser.bookmarks.roots
        for (found, folder) in moves { browser.bookmarks.move(found.id, into: bookmarkFolder(named: folder)) }
        for found in removing { browser.bookmarks.remove(found.id) }
        let listed = moves.map { "- moved “\($0.0.title)” into “\($0.1)”" } + removing.map { "- removed “\($0.title)” \($0.url ?? "")" }
        return "Done:\n" + listed.joined(separator: "\n") + record("Tidied the bookmarks: \(plan)") { [weak browser] in
            browser?.bookmarks.restore(before)
            return "The bookmarks are as they were."
        }
    }

    // MARK: - History and downloads

    private func deleteHistory(_ input: JSON) async -> String {
        let dates = ISO8601DateFormatter()
        var keys: [String] = []
        if let urls = input["urls"]?.array {
            keys = urls.compactMap { $0.string.flatMap(URL.init(string:)).map(HistoryIndex.key(for:)) }
        }
        var range: (Date, Date)?
        if let from = input["from"]?.string.flatMap(dates.date(from:)) {
            range = (from, input["to"]?.string.flatMap(dates.date(from:)) ?? Date())
        }
        let inRange = range.map { browser.history.visited(between: $0.0, and: $0.1) } ?? []
        let count = keys.count + inRange.count
        guard count > 0 else { return "No history matches." }
        let what = range.map { "\(inRange.count) page\(inRange.count == 1 ? "" : "s") visited from \($0.0.formatted()) to \($0.1.formatted())" }
        let said = [keys.isEmpty ? nil : "\(keys.count) address\(keys.count == 1 ? "" : "es")", what].compactMap { $0 }.joined(separator: " and ")
        if input["dry_run"]?.bool == true {
            return "Would delete \(said): \(inRange.prefix(8).map { $0.title.isEmpty ? $0.url : $0.title }.joined(separator: ", "))"
        }
        guard await permit(.irreversible, "Delete \(said) from your history? This can't be undone.") else { return refused }
        for key in keys { browser.history.remove(key) }
        if let range { browser.history.remove(visitedBetween: range.0, and: range.1) }
        return "Deleted \(said)."
    }

    /// A long address cut in the middle, for lists.
    static func clipped(_ address: String) -> String {
        address.count > 160 ? String(address.prefix(110)) + "…" + String(address.suffix(40)) : address
    }

    private func searchHistory(_ input: JSON) -> String {
        let date = { (text: String?) -> Date? in
            guard let text else { return nil }
            let full = ISO8601DateFormatter()
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            return full.date(from: text) ?? day.date(from: text)
        }
        let from = date(input["from"]?.string), to = date(input["to"]?.string)
        let words = input["query"]?.string ?? ""
        let found = browser.history.entries(withWords: words, from: from, to: to)
        let limit = min(max(input["limit"]?.int ?? 25, 1), 100)
        guard !found.isEmpty else {
            return "Nothing in Mote's history has all of “\(words)”" + (from != nil || to != nil ? " in that time" : "")
                + ". Try fewer or other words, one at a time."
        }
        let when = DateFormatter()
        when.dateStyle = .medium
        when.timeStyle = .short
        let lines = found.prefix(limit).map { entry in
            "\(entry.title.isEmpty ? entry.key : entry.title)\t\(Self.clipped(entry.url.absoluteString))\tlast \(when.string(from: entry.last))\t\(entry.count) visit\(entry.count == 1 ? "" : "s")"
        }
        return lines.joined(separator: "\n") + (found.count > limit ? "\n…and \(found.count - limit) more; narrow it with more words or dates." : "")
    }

    private func downloads(_ input: JSON) -> String {
        let kept = browser.downloads.kept
        switch input["action"]?.string ?? "list" {
        case "open", "reveal":
            guard acts else { return refused }
            guard let number = input["number"]?.int, kept.indices.contains(number - 1) else {
                return "No download has that number; list them again."
            }
            let record = kept[number - 1]
            guard browser.downloads.isThere(record) else { return "“\(record.name)” has been moved or deleted." }
            input["action"]?.string == "open" ? browser.downloads.open(record) : browser.downloads.reveal(record)
            return input["action"]?.string == "open" ? "Opened “\(record.name)”." : "Showed “\(record.name)” in the Finder."
        default:
            let list = kept.prefix(30).enumerated().map { index, record in
                "\(index + 1)\t\(record.name)\t\(record.from)\t\(record.date.formatted(date: .abbreviated, time: .shortened))\(browser.downloads.isThere(record) ? "" : "\t(gone)")"
            }
            return list.joined(separator: "\n").ifEmpty("No downloads.")
        }
    }

    // MARK: - Keeping a page

    /// The page as a PDF, or its text as Markdown, in the downloads folder.
    private func keep(_ tab: Tab, asPDF: Bool) async -> String {
        guard let web = tab.built, let address = tab.address else { return "“\(tab.label)” has no page to keep; it may be asleep." }
        let folder = browser.downloadsFolder
        let name = Clippings.freeName(tab.label.replacingOccurrences(of: "/", with: "-") + (asPDF ? ".pdf" : ".md")) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let file = folder.appendingPathComponent(name)
        let data: Data?
        if asPDF {
            data = await withCheckedContinuation { done in web.createPDF { done.resume(returning: try? $0.get()) } }
        } else {
            let text = await tab.capturePageContext()?.text ?? ""
            data = Data("# \(tab.label)\n\n<\(address.absoluteString)>\n\n\(text)\n".utf8)
        }
        guard let data, (try? data.write(to: file)) != nil else { return "It couldn't be saved." }
        browser.announce("Saved \(name) to \(folder.lastPathComponent)")
        return "Saved “\(name)” in \(folder.path)."
    }
}

/// A page loaded out of sight, read once and let go.
@MainActor
final class ReadAway: NSObject, WKNavigationDelegate {
    private var done: CheckedContinuation<Void, Never>?

    static func text(of url: URL) async -> String {
        let reader = ReadAway()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: Web.configuration(shy: true))
        page.navigationDelegate = reader
        page.load(URLRequest(url: url))
        await withCheckedContinuation { done in
            reader.done = done
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                reader.finish()
            }
        }
        let text = (try? await page.callAsyncJavaScript(Reader.text, contentWorld: .page) as? String) ?? ""
        page.stopLoading()
        return text.isEmpty ? "The page had no text to read." : String(text.prefix(AssistantTools.most))
    }

    private func finish() {
        done?.resume()
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}
