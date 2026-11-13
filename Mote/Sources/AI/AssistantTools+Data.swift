import AppKit
import MoteAI
import MoteCore
import WebKit

/// The web and the person's own things: reading a page out of sight,
/// history, bookmarks.
extension AssistantTools {
    var dataTools: [Tool] {
        let query = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
        return [
            Tool(
                name: "read_page",
                description: "Loads a web page out of sight and returns its text. A search engine's results address searches the web.",
                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
            Tool(name: "search_history", description: "Pages the person visited, matching the words.", schema: query),
            Tool(name: "search_bookmarks", description: "The person's bookmarks matching the words.", schema: query),
        ]
    }

    func runData(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "read_page":
            guard let url = web(input["url"]?.string) else { return "That isn't a web address." }
            return await ReadAway.text(of: url)
        case "search_history":
            let found = browser.history.suggestions(for: input["query"]?.string ?? "", limit: 15)
            return found.map { "\($0.key)\t\($0.url.absoluteString)" }.joined(separator: "\n").ifEmpty("Nothing found.")
        case "search_bookmarks":
            let words = (input["query"]?.string ?? "").lowercased()
            let found = Self.flat(browser.bookmarks.roots).filter {
                $0.title.lowercased().contains(words) || ($0.url ?? "").lowercased().contains(words)
            }
            return found.prefix(20).map { "\($0.title)\t\($0.url ?? "")" }.joined(separator: "\n").ifEmpty("Nothing found.")
        default:
            return nil
        }
    }

    static func flat(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { $0.isFolder ? flat($0.children ?? []) : [$0] }
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
