import Foundation
import MoteAI
import MoteCore
import WebKit

/// Waiting on a site without holding a turn open: the assistant leaves a
/// watch on a tab (text or an element appearing, its address changing, a
/// download finishing) and ends its turn; when it fires, or its time is
/// up, Mote wakes the chat with a new turn saying so.
extension AssistantTools {
    var watchTools: [Tool] {
        [
            Tool(
                name: "watch_page",
                description:
                    "Leaves a watch on a tab and lets you end your turn instead of waiting: when the page shows some text (text) or an element (selector), its address changes (address_change), or a download finishes (download), Mote wakes you with a new turn saying what happened. Also when nothing has happened within `minutes` (default 10, at most 30). Use it for a site that answers slowly (an email to arrive, a payment to clear, a long export).",
                schema:
                    #"{"type":"object","properties":{"tab":{"type":"string"},"text":{"type":"string","description":"Wake when the page's text contains this"},"selector":{"type":"string","description":"Wake when an element matching this CSS selector appears"},"address_change":{"type":"boolean"},"download":{"type":"boolean","description":"Wake when a download finishes"},"minutes":{"type":"number"}},"required":["tab"]}"#)
        ]
    }

    func runWatch(_ call: ToolCall) async -> String? {
        guard call.name == "watch_page" else { return nil }
        guard let chat else { return "There's no chat to wake." }
        guard let found = find(call.input) else { return Self.noTab }
        let input = call.input
        let text = input["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let selector = input["selector"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let address = input["address_change"]?.bool == true, download = input["download"]?.bool == true
        guard text != nil || selector != nil || address || download else {
            return "Say what to watch for: text, selector, address_change or download."
        }
        let minutes = min(30, max(1, input["minutes"]?.double ?? 10))
        let watch = PageWatch(
            chat: chat, tab: found.tab, text: text, selector: selector, address: address, download: download, browser: found.browser,
            until: .now + .seconds(minutes * 60))
        PageWatch.start(watch)
        return "Watching \(Self.line(found.tab)) (watch \(watch.id)) for up to \(Int(minutes)) minutes. End your turn: Mote will wake you when it happens, or when the time is up."
    }
}

/// One watch, polled every two seconds while its tab and chat are there.
@MainActor
final class PageWatch {
    private static var running: [String: PageWatch] = [:]
    private static var next = 1

    let id: String
    let chat: UUID
    weak var tab: Tab?
    weak var browser: Browser?
    let text: String?
    let selector: String?
    let address: URL??
    let downloads: Int?
    let until: ContinuousClock.Instant
    private let label: String

    init(
        chat: UUID, tab: Tab, text: String?, selector: String?, address: Bool, download: Bool, browser: Browser,
        until: ContinuousClock.Instant
    ) {
        id = "w\(Self.next)"
        Self.next += 1
        self.chat = chat
        self.tab = tab
        self.browser = browser
        self.text = text
        self.selector = selector
        self.address = address ? .some(tab.address) : nil
        downloads = download ? browser.downloads.kept.count : nil
        self.until = until
        label = AssistantTools.line(tab)
    }

    static func start(_ watch: PageWatch) {
        running[watch.id] = watch
        Task { @MainActor in
            while running[watch.id] != nil {
                try? await Task.sleep(for: .seconds(2))
                if let what = await watch.happened() { return finish(watch, said: what) }
                guard watch.tab != nil else { return finish(watch, said: nil, gone: true) }
                if ContinuousClock.now >= watch.until { return finish(watch, said: nil) }
            }
        }
    }

    /// What it was waiting for, if it has happened.
    private func happened() async -> String? {
        guard let tab else { return nil }
        // Watched, it's in use: not put to sleep meanwhile.
        tab.touch()
        if let address, tab.address != address { return "the address changed to \(tab.address?.absoluteString ?? "nothing")" }
        if let downloads, let browser, browser.downloads.kept.count > downloads, let last = browser.downloads.kept.first {
            return "the download \(last.name) finished"
        }
        guard text != nil || selector != nil, let web = tab.built else { return nil }
        let script = "return (selector ? !!document.querySelector(selector) : false) || (text ? (document.body?.innerText ?? '').includes(text) : false)"
        let found = try? await web.callAsyncJavaScript(
            script, arguments: ["selector": selector ?? "", "text": text ?? ""], contentWorld: .defaultClient) as? Bool
        guard found == true else { return nil }
        return selector.map { "an element matching \($0) appeared" } ?? "the page now shows “\(text ?? "")”"
    }

    /// Wakes the chat once it's idle, with what happened.
    private static func finish(_ watch: PageWatch, said: String?, gone: Bool = false) {
        running[watch.id] = nil
        let news =
            gone
            ? "Your watch \(watch.id) on \(watch.label) ended: the tab was closed."
            : said.map { "Your watch \(watch.id) on \(watch.label) fired: \($0). Carry on with the task from here." }
                ?? "Your watch \(watch.id) on \(watch.label) ran out of time with nothing happening. Look at the tab, then decide what to do."
        Task { @MainActor in
            // A turn under way finishes first; then the news goes as a turn of its own.
            for _ in 0..<1800 {
                guard let chat = Assistant.shared.conversation(watch.chat) else { return }
                if !chat.busy {
                    Assistant.shared.ask(news, in: chat, carrying: true, quiet: true)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The watches a chat has left, for ending them with it.
    static func open(in chat: UUID) -> [PageWatch] { running.values.filter { $0.chat == chat } }
}
