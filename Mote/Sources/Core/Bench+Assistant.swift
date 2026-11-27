import AppKit
import MoteAI
import MoteCore

// Bench commands on the assistant: what the chat in front holds, asking in
// it, and choosing who answers.

extension Bench {
    var assistantCommands: [String: Command] {
        ["chat": Self.chat]
    }

    /// `chat show` the chat in front; `chat ask TEXT` asks as the new tab's Ask does in
    /// the address field, and `chat follow TEXT` asks again in the chat in
    /// front (test runs); `chat wait [SECONDS]` until its reply is
    /// done; `chat use PROVIDER [MODEL] [ADDRESS]` who answers (test runs); `chat
    /// providers` how each stands.
    private static func chat(_ call: BenchCall) {
        let browser = call.browser
        let request = call.request
        switch request.string("action") ?? "show" {
        case "show":
            call.answer(describe(browser))
        case "ask":
            guard call.testRun("it would ask in your browser") else { return }
            guard let text = request.string("text"), !text.isEmpty else { return call.fail("chat ask needs some text") }
            if browser.active?.isStart != true { browser.newTab() }
            // As the new tab's own Ask: not the floating search's question about a page.
            browser.field.launching = false
            browser.field.typed = text
            browser.ask()
            call.answer(describe(browser))
        case "follow":
            guard call.testRun("it would ask in your browser") else { return }
            // A chat tab's, or the open chat sidebar's.
            let sidebar = browser.active?.chatOpen == true ? browser.active?.pageChat : nil
            guard let text = request.string("text"), !text.isEmpty, let chat = browser.active?.chat ?? sidebar else {
                return call.fail("chat follow needs a chat in front and some text")
            }
            Assistant.shared.ask(text, in: chat)
            call.answer(describe(browser))
        case "archive":
            // A kept chat archived or taken out, as its row's button does (test runs).
            guard call.testRun("it would change your chats"), let id = request.string("text").flatMap(UUID.init(uuidString:)) else {
                return call.fail("chat archive needs a chat id")
            }
            let on = request.string("mode") != "off"
            Assistant.shared.archive(id, on)
            call.answer(["archived": Assistant.shared.chats.entries.first { $0.id == id }?.archived == true])
        case "attach":
            // Files for the next message of the chat in front, as the paperclip attaches them.
            guard call.testRun("it would attach files in your browser") else { return }
            let side = browser.active?.chatOpen == true ? browser.active?.pageChat : nil
            guard let chat = browser.active?.chat ?? side, let paths = request.string("text") else {
                return call.fail("chat attach needs a chat in front and paths")
            }
            var refusal: String?
            Assistant.shared.attach(paths.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }, to: chat) { refusal = $0 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                call.answer(["attached": chat.attached.map(\.name), "refused": refusal ?? ""])
            }
        case "answer":
            guard call.testRun("it would answer in your browser") else { return }
            // A chat tab's question, or the open chat sidebar's.
            let side = browser.active?.chatOpen == true ? browser.active?.pageChat : nil
            guard let chat = [browser.active?.chat, side].compactMap({ $0 }).first(where: { $0.question != nil }), let text = request.string("text")
            else {
                return call.fail("chat answer needs a chat in front waiting on a question, and the answer")
            }
            chat.answer(text)
            call.answer(describe(browser))
        case "acting":
            guard call.testRun("it would change how your chat acts") else { return }
            guard let chat = browser.active?.chat, let mode = request.string("mode").flatMap(ChatMode.init(rawValue:)) else {
                return call.fail("chat acting needs a chat in front and asks, auto or plan")
            }
            ChatModes.shared.set(chat.id, mode)
            call.answer(["acting": mode.rawValue])
        case "wait":
            let deadline = Date().addingTimeInterval(request.double("seconds") ?? 30)
            @MainActor func poll() {
                // A question waiting is the bench's to answer: no use waiting on it.
                // The tab's own chat, or the page chat open beside it.
                let chat = browser.active?.chat ?? (browser.active?.chatOpen == true ? browser.active?.pageChat : nil)
                let busy = chat.map { $0.busy && $0.question == nil } == true
                guard busy, Date() < deadline else {
                    var out = describe(browser)
                    out["timeout"] = busy
                    return call.answer(out)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
            }
            poll()
        case "use":
            guard call.testRun("it would change your settings") else { return }
            guard let id = request.string("provider"), let provider = Provider.named(id) else {
                return call.fail("chat use needs one of: \(Provider.all.map(\.id).joined(separator: ", "))")
            }
            Assistant.shared.providerID = provider.id
            if let model = request.string("model") { Assistant.shared.change(provider) { $0.model = model.isEmpty ? nil : model } }
            if let address = request.string("address") {
                Assistant.shared.change(provider) { $0.address = address }
                Assistant.shared.forgetModels(of: provider)
            }
            call.answer(["provider": provider.id, "model": Assistant.shared.model(for: provider)])
        case "search":
            guard call.testRun("it would change your settings") else { return }
            Assistant.shared.chosenMode = request.flag("on") ? .search : .chat
            call.answer(["chosen": Assistant.shared.chosenMode.rawValue, "mode": Assistant.shared.mode.rawValue])
        case "mode":
            guard call.testRun("it would change your settings") else { return }
            guard let mode = request.string("mode").flatMap(Assistant.Mode.init(rawValue:)) else {
                return call.fail("chat mode needs chat, search or research")
            }
            Assistant.shared.chosenMode = mode
            call.answer(["chosen": mode.rawValue, "mode": Assistant.shared.mode.rawValue])
        case "lead":
            guard call.testRun("it would change your settings") else { return }
            // search, or ask: what Return does in the new tab's composer.
            guard let named = request.string("mode"), ["search", "ask"].contains(named) else {
                return call.fail("chat lead needs search or ask")
            }
            browser.field.asksAssistant = named == "ask"
            call.answer(["leads": browser.field.asksAssistant, "mode": Assistant.shared.mode.rawValue])
        case "demo":
            guard call.testRun("it would open a chat in your browser") else { return }
            let service = DemoReply(
                sources: request.int("sources") ?? 400, delay: request.double("delay") ?? 0, plain: request.flag("plain"))
            // side: in the page chat of the tab in front, a fresh one; again: one
            // more turn in the chat in front, for a long chat.
            let side = request.flag("side")
            let again = request.flag("again") ? (side ? browser.active?.pageChat : browser.active?.chat) : nil
            if again == nil {
                // A tab of its own: with new tabs opening the floating search, newTab makes none.
                if side { browser.newPageChat() } else if browser.active?.isStart != true { browser.show(Tab(), adopting: true) }
            }
            guard let chat = again ?? (side ? browser.active?.pageChat : Conversation()) else { return call.fail("no tab for its page chat") }
            chat.send(
                "Demo: a long researched reply",
                via: Conversation.Route(provider: "demo", model: "", author: "Mote · demo", service: service, search: true))
            if !side {
                browser.active?.chat = chat
                browser.editing = false
                browser.field.clear()
            }
            call.answer(describe(browser))
        case "open":
            // A kept chat opened as the list of chats does, timed: the work on
            // the main thread, and until the window has drawn after it.
            guard call.testRun("it would open a chat in your browser") else { return }
            guard let id = request.string("text").flatMap(UUID.init(uuidString:)) else { return call.fail("chat open needs a chat's id") }
            let start = CACurrentMediaTime()
            browser.open(chat: id)
            let opened = (CACurrentMediaTime() - start) * 1000
            BenchDrawn.next(in: browser.window) { call.answer(["openMs": opened, "drawnMs": (CACurrentMediaTime() - start) * 1000]) }
        case "providers":
            Task {
                let assistant = Assistant.shared
                let found = await assistant.lookAround()
                call.answer([
                    "chosen": assistant.providerID, "path": found.path ?? "",
                    "providers": Provider.all.map { provider in
                        [
                            "id": provider.id, "status": "\(assistant.status(of: provider))", "model": assistant.model(for: provider),
                            "program": assistant.program(of: provider)?.path ?? "",
                        ]
                    },
                ])
            }
        default:
            call.fail(
                "chat does show, ask TEXT, follow TEXT, answer TEXT, acting asks|auto|plan, wait [SECONDS], use PROVIDER [MODEL] [ADDRESS], mode chat|search|research, search on|off or providers"
            )
        }
    }

    private static func describe(_ browser: Browser) -> [String: Any] {
        // The chat sidebar's, when it's open: the page it holds, and the selection's place on it.
        if let tab = browser.active, tab.chat == nil, tab.chatOpen, let side = tab.pageChat {
            let page = side.page
            return [
                "chat": "sidebar", "draft": tab.pendingAsk ?? "", "page": page?.url.absoluteString ?? "", "selection": page?.selection ?? "",
                "around": page?.around ?? "", "heading": page?.heading ?? "",
                "messages": side.messages.map { ["role": $0.role.rawValue, "text": $0.text] },
                "question": side.question.map { ["text": $0.text, "options": $0.options.map(\.label)] } ?? NSNull(),
                "busy": side.busy, "mode": ChatModes.shared.mode(of: side.id).rawValue,
            ]
        }
        guard let tab = browser.active, let chat = tab.chat else { return ["chat": false] }
        let phase: String =
            switch chat.phase {
            case .idle: "idle"
            case .waiting: "waiting"
            case .answering: "answering"
            case .failed(let reason): "failed: \(reason)"
            }
        return [
            "chat": true, "tab": BenchWire.short(tab.id), "title": chat.title, "label": tab.label, "phase": phase,
            "tasks": chat.tasks.map { "\($0.id) \($0.state.rawValue) \($0.text)" + ($0.note.map { " (\($0))" } ?? "") },
            "activities": chat.activities.map(\.title),
            "question": chat.question.map { ["text": $0.text, "options": $0.options.map(\.label)] } ?? NSNull(),
            "spent": chat.spentSoFar.map { ["in": $0.input, "out": $0.output] } ?? NSNull(),
            // The model's window once a reply said it, and where the chat will be summarised.
            "window": chat.contextWindow ?? NSNull(),
            "summariseAt": Conversation.limit(window: chat.contextWindow, set: chat.summariseAt),
            "messages": chat.messages.map { message in
                [
                    "role": message.role.rawValue, "text": message.text, "author": message.author ?? "",
                    "reasoning": message.reasoning.count, "interrupted": message.interrupted,
                    "sources": message.sources.map { ["url": $0.url.absoluteString, "title": $0.title] },
                    "steps": message.steps.map { ["title": $0.title, "kind": $0.kind.rawValue, "done": $0.done] },
                ]
            },
        ]
    }
}

/// A long researched reply made up on the spot, for measuring the chat:
/// research steps, many sources, and a report with headings, lists, a table
/// and code, streamed in small pieces `delay` milliseconds apart.
private struct DemoReply: ChatService {
    let sources: Int
    let delay: Double
    /// Without the research steps: the reply alone.
    var plain = false

    func reply(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let task = Task {
            for part in 1...8 where !plain {
                continuation.yield(.activity(Activity(id: "part-\(part)", title: "Demo part \(part): what matters here", kind: .task)))
                for search in 1...6 {
                    continuation.yield(
                        .activity(Activity.search("part-\(part)-s\(search)", "query \(search) for part \(part)", done: true)))
                }
                continuation.yield(
                    .activity(Activity(id: "part-\(part)", title: "Demo part \(part): what matters here", done: true, kind: .task)))
            }
            for index in 0..<sources {
                continuation.yield(
                    .source(
                        Source(
                            url: URL(string: "https://site\(index % 40).example/page/\(index)")!, title: "Page \(index) about the subject"))
                )
            }
            for piece in Self.report().split(separator: " ", omittingEmptySubsequences: false) {
                if Task.isCancelled { return }
                continuation.yield(.text(piece + " "))
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func report() -> String {
        var text = "# A long demo report\n\nThis summary answers the question directly [site1](https://site1.example/page/1).\n\n"
        for section in 1...12 {
            text += "## Section \(section)\n\n"
            text +=
                "A paragraph with **bold**, `code`, and a claim worth citing [site\(section)](https://site\(section).example/page/\(section)). "
            text += String(repeating: "More words that make the paragraph long enough to wrap over several lines. ", count: 6) + "\n\n"
            text += "- First point [site2](https://site2.example/page/2)\n- Second point\n- Third point with `inline code`\n\n"
            if section % 3 == 0 {
                text += "| Option | Speed | Cost |\n|---|--:|--:|\n| One | 10 | 5 |\n| Two | 20 | 7 |\n| Three | 30 | 9 |\n\n"
            }
            if section % 4 == 0 { text += "```swift\nlet value = compute(section: \(section))\nprint(value)\n```\n\n" }
        }
        return text
    }
}

/// Calls back on the first frame drawn after now: the main thread's work
/// done and the window shown again.
@MainActor
private final class BenchDrawn: NSObject {
    private var link: CADisplayLink?
    private var done: (() -> Void)?

    static func next(in window: NSWindow?, _ done: @escaping () -> Void) {
        guard let view = window?.contentView else { return done() }
        let drawn = BenchDrawn()
        drawn.done = done
        let link = view.displayLink(target: drawn, selector: #selector(fire))
        drawn.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        done?()
        done = nil
    }
}
