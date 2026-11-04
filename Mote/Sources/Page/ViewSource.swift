import Foundation
import MoteCore
import WebKit

// View Page Source (Firefox's ⌘U): the page as its server sent it, not the
// live document, asked for again with the tab's cookies and user agent, and
// shown line by line in a private tab beside it, which is neither saved nor
// kept in history.

extension Browser {
    func viewSource(of tab: Tab) {
        // A sleeping tab has its address but no page: its store still has its cookies.
        guard let url = tab.address ?? tab.pending, url.scheme?.hasPrefix("http") == true else { return }
        let web = tab.built
        let store = tab.store
        Task {
            let cookies = await store.httpCookieStore.allCookies().filter { Self.sends($0, to: url) }
            var request = URLRequest(url: url)
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
            if let agent = try? await web?.evaluateJavaScript("navigator.userAgent") as? String {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            guard let (data, _) = try? await URLSession.shared.data(for: request) else {
                return announce("Couldn't get this page's source")
            }
            let source = Tab(shy: true, configuration: Web.configuration(shy: true))
            prepare(source)
            reorder { $0.insert(source, at: $0.slotForNew(after: tab.id)) }
            select(source)
            source.web.loadHTMLString(Self.page(of: String(decoding: data, as: UTF8.self), from: url), baseURL: nil)
        }
    }

    /// Whether a browser would send the cookie with a request to `url`.
    private nonisolated static func sends(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
        return hostMatches && url.path().hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
    }

    /// The text, escaped, a numbered line at a time, light or dark as the Mac is.
    private nonisolated static func page(of text: String, from url: URL) -> String {
        let escape = { (line: Substring) in
            line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { "<tr><td>\($0.offset + 1)</td><td>\(escape($0.element))</td></tr>" }.joined()
        let title = escape(Substring("Source of \(url.absoluteString)"))
        return """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(title)</title>
            <style>
            body { margin: 0; font: 12px/1.5 ui-monospace, Menlo, monospace; }
            table { border-collapse: collapse; }
            td { vertical-align: top; padding: 0 12px; white-space: pre-wrap; word-break: break-all; }
            td:first-child { text-align: right; color: GrayText; user-select: none; position: sticky; left: 0; background: Canvas; }
            </style>
            <table>\(rows)</table>
            """
    }
}
