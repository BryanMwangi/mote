import AppKit
import MoteAI
import MoteCore
import WebKit

/// What the assistant may ask Mote to do while it answers (Settings › AI ›
/// Tools): read the open tabs, any page, history and bookmarks; and, when
/// allowed, open tabs and click and type in pages, each time asked first.
/// Never in private tabs, never into password fields.
@MainActor
final class AssistantTools {
    private let browser: Browser
    private let acts: Bool
    /// Sites this chat may act on without asking again.
    private static var trusted: [UUID: Set<String>] = [:]
    private let chat: UUID?

    /// The tools on now for the window in front, or nil with none on.
    static func current(chat: UUID?) -> AssistantTools? {
        guard let browser = Browser.front ?? Windows.shared.main, browser.prefs.aiReads else { return nil }
        return AssistantTools(browser: browser, acts: browser.prefs.aiActs, chat: chat)
    }

    private init(browser: Browser, acts: Bool, chat: UUID?) {
        self.browser = browser
        self.acts = acts
        self.chat = chat
    }

    var list: [Tool] {
        let tab = #"{"type":"object","properties":{"tab":{"type":"string","description":"The tab's id, from list_tabs"}},"required":["tab"]}"#
        let query = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
        let url = #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#
        var tools = [
            Tool(name: "list_tabs", description: "The browser's open tabs in this window: id, title and address."),
            Tool(
                name: "read_tab",
                description:
                    "An open tab's text, and a numbered list of what can be clicked or typed into on it, for click and fill.",
                schema: tab),
            Tool(
                name: "read_page",
                description: "Loads a web page out of sight and returns its text. A search engine's results address searches the web.",
                schema: url),
            Tool(name: "search_history", description: "Pages the person visited, matching the words.", schema: query),
            Tool(name: "search_bookmarks", description: "The person's bookmarks matching the words.", schema: query),
        ]
        if acts {
            let element = #"{"type":"object","properties":{"tab":{"type":"string"},"element":{"type":"integer","description":"Its number from read_tab"}"#
            tools += [
                Tool(name: "open_tab", description: "Opens an address in a new tab. The person is asked first.", schema: url),
                Tool(
                    name: "click", description: "Clicks an element read_tab listed. The person is asked first.",
                    schema: element + #"},"required":["tab","element"]}"#),
                Tool(
                    name: "fill", description: "Types text into a field read_tab listed. The person is asked first. Never passwords.",
                    schema: element + #","text":{"type":"string"}},"required":["tab","element","text"]}"#),
            ]
        }
        return tools
    }

    /// The step's line in the chat.
    nonisolated static func describe(_ call: ToolCall) -> String {
        let url = call.input["url"]?.string.flatMap(URL.init(string:))
        switch call.name {
        case "list_tabs": return "Looking at your tabs"
        case "read_tab": return "Reading a tab"
        case "read_page": return url.map { "Reading \(Address.siteName(for: $0))" } ?? "Reading a page"
        case "search_history": return "Searching your history"
        case "search_bookmarks": return "Searching your bookmarks"
        case "open_tab": return url.map { "Opening \(Address.siteName(for: $0))" } ?? "Opening a tab"
        case "click": return "Clicking on the page"
        case "fill": return "Typing on the page"
        default: return call.name
        }
    }

    func run(_ call: ToolCall) async -> String {
        let input = call.input
        switch call.name {
        case "list_tabs":
            let tabs = browser.tabs.filter { !$0.shy && !$0.isBlank }
            return tabs.map { "\(Self.id($0))\t\($0.label)\t\($0.address?.absoluteString ?? "")" }.joined(separator: "\n")
        case "read_tab":
            guard let tab = tab(input) else { return "No such tab." }
            guard !tab.shy else { return "That tab is private." }
            _ = tab.wake()
            let text = await tab.capturePageContext()?.text ?? ""
            let outline = await outline(of: tab)
            return "\(tab.label)\n\(tab.address?.absoluteString ?? "")\n\n\(String(text.prefix(Self.most)))\n\nElements:\n\(outline)"
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
        case "open_tab":
            guard acts, let url = web(input["url"]?.string) else { return "That isn't a web address." }
            guard await allowed("Open \(url.absoluteString) in a new tab?", on: url) else { return "The person said no." }
            browser.open(url, foreground: true)
            return "Opened."
        case "click", "fill":
            return await act(call)
        default:
            return "No such tool."
        }
    }

    // MARK: - Acting

    private func act(_ call: ToolCall) async -> String {
        let input = call.input
        guard acts, let tab = tab(input), let number = input["element"]?.int else { return "No such tab or element." }
        guard !tab.shy, let address = tab.address else { return "That tab is private." }
        let filling = call.name == "fill"
        let text = input["text"]?.string ?? ""
        let what = await label(of: number, in: tab) ?? "element \(number)"
        let question = filling ? "Type “\(text.prefix(60))” into “\(what)” on \(Address.siteName(for: address))?" : "Click “\(what)” on \(Address.siteName(for: address))?"
        guard await allowed(question, on: address) else { return "The person said no." }
        // The page mustn't have moved to another site while asked.
        guard Address.siteHost(of: tab.address) == Address.siteHost(of: address) else { return "The page changed; read it again." }
        let script = """
            const el = window.__moteOutline?.[n];
            if (!el || !el.isConnected) return 'gone';
            el.scrollIntoView({ block: 'center' });
            if (!fill) { el.click(); return 'done'; }
            if (el.type === 'password') return 'password';
            el.focus();
            if (el.isContentEditable) { el.textContent = text; }
            else {
              const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              Object.getOwnPropertyDescriptor(proto, 'value')?.set?.call(el, text);
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'done';
            """
        let result = await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: ["n": number, "fill": filling, "text": text]) { done.resume(returning: $0 as? String) }
        }
        switch result {
        case "done": return filling ? "Typed." : "Clicked."
        case "password": return "Mote doesn't type into password fields."
        default: return "That element is gone; read the tab again."
        }
    }

    /// Asks the person, unless this chat may already act on the site.
    private func allowed(_ question: String, on url: URL) async -> Bool {
        let site = Address.siteHost(of: url) ?? ""
        if let chat, Self.trusted[chat]?.contains(site) == true { return true }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The assistant asks to do this for you."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = chat != nil
        alert.suppressionButton?.title = "Allow on \(site) for this chat"
        let answer: NSApplication.ModalResponse
        if let window = browser.window {
            answer = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
        } else {
            answer = alert.runModal()
        }
        guard answer == .alertFirstButtonReturn else { return false }
        if let chat, alert.suppressionButton?.state == .on { Self.trusted[chat, default: []].insert(site) }
        return true
    }

    // MARK: - Reading

    /// What can be clicked or typed into, numbered, remembered in Mote's own
    /// world for click and fill. Password fields are listed, never their values.
    private func outline(of tab: Tab) async -> String {
        let script = """
            const picked = [...document.querySelectorAll('a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[contenteditable=true]')]
              .filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }).slice(0, 200);
            window.__moteOutline = picked;
            return picked.map((e, i) => {
              const kind = e.tagName.toLowerCase() + (e.type ? '(' + e.type + ')' : '');
              const words = (e.innerText || e.getAttribute('aria-label') || e.placeholder || e.title
                || (['submit', 'button'].includes(e.type) ? e.value : '') || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
              return '[' + i + '] ' + kind + ' ' + words + (e.href ? ' -> ' + e.href : '');
            }).join('\\n');
            """
        return await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: [:]) { done.resume(returning: ($0 as? String) ?? "") }
        }
    }

    private func label(of number: Int, in tab: Tab) async -> String? {
        let script = """
            const e = window.__moteOutline?.[n];
            return e ? (e.innerText || e.getAttribute('aria-label') || e.placeholder || e.name || '').trim().slice(0, 60) : null;
            """
        return await withCheckedContinuation { done in
            tab.web.callInAppWorld(script, arguments: ["n": number]) { done.resume(returning: ($0 as? String).flatMap { $0.isEmpty ? nil : $0 }) }
        }
    }

    private func tab(_ input: JSON) -> Tab? {
        guard let id = input["tab"]?.string?.lowercased() else { return nil }
        return browser.tabs.first { Self.id($0) == id }
    }

    private static func id(_ tab: Tab) -> String { String(tab.id.uuidString.prefix(8)).lowercased() }

    private func web(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func flat(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { $0.isFolder ? flat($0.children ?? []) : [$0] }
    }

    /// The most of a page's text given back.
    static let most = 20_000
}

/// A page loaded out of sight, read once and let go.
@MainActor
private final class ReadAway: NSObject, WKNavigationDelegate {
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

extension String {
    fileprivate func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
