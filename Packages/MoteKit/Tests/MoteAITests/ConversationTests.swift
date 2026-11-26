import Foundation
import Testing

@testable import MoteAI

/// Replies with scripted events, then fails or ends; can hold the reply open
/// until let go, and remembers every request.
final class ScriptedService: ChatService, @unchecked Sendable {
    var events: [ChatEvent] = []
    var failure: Error?
    /// Fails the next reply only, before any of its events.
    var failOnce: Error?
    /// Holds the reply open after its events until the stream is ended.
    var hold = false
    private(set) var requests: [ChatRequest] = []
    private(set) var stopped = false
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func reply(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        if let failOnce {
            self.failOnce = nil
            continuation.finish(throwing: failOnce)
            return stream
        }
        let (events, failure, hold) = (events, failure, hold)
        for event in events { continuation.yield(event) }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.stopped = true }
        }
        if hold {
            self.continuation = continuation
        } else {
            continuation.finish(throwing: failure)
        }
        return stream
    }
}

@MainActor
@Suite("Conversation")
struct ConversationTests {
    private func route(_ service: ChatService, provider: String = "claude-code", model: String = "sonnet") -> Conversation.Route {
        Conversation.Route(provider: provider, model: model, author: "Claude Code · \(model)", service: service, instructions: "Be brief")
    }

    /// What a request said with its question: Mote's notes, then the person's words.
    private func said(_ request: ChatRequest?) -> String { request?.messages.last { $0.role == .user }?.text ?? "" }

    /// Waits for the reply to settle.
    private func settle(_ conversation: Conversation) async {
        for _ in 0..<200 where conversation.busy { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func waitForRequest(_ service: ScriptedService, count: Int) async {
        for _ in 0..<200 where service.requests.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Sending adds the question and a reply that fills in as it streams")
    func send() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .reasoning("Adding"), .text("It's "), .text("4."), .usage(Usage(input: 5, output: 3))]
        let conversation = Conversation()
        conversation.send("What's 2+2?", via: route(service))
        #expect(conversation.busy)
        #expect(conversation.phase == .waiting)
        await settle(conversation)
        #expect(conversation.messages.map(\.role) == [.user, .assistant])
        #expect(conversation.messages[1].text == "It's 4.")
        #expect(conversation.messages[1].reasoning == "Adding")
        #expect(conversation.messages[1].author == "Claude Code · sonnet")
        #expect(conversation.phase == .idle)
        #expect(conversation.usage == Usage(input: 5, output: 3))
        let request = service.requests[0]
        #expect(request.model == "sonnet")
        #expect(request.instructions == "Be brief")
        #expect(request.resume == nil)
        #expect(request.messages.map(\.text) == ["What's 2+2?"])
    }

    @Test("Compacting sends the model's summary in place of the messages before, which stay on screen")
    func compact() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Paris.")]
        let conversation = Conversation()
        conversation.send("Capital of France?", via: route(service))
        await settle(conversation)
        service.events = [.text("They asked for France's capital: Paris.")]
        conversation.compact(routing: { self.route(service) })
        await settle(conversation)
        #expect(conversation.summary == "They asked for France's capital: Paris.")
        #expect(conversation.summarised == 2)
        #expect(conversation.messages.count == 2)
        service.events = [.text("Berlin.")]
        conversation.send("And Germany?", via: route(service))
        await settle(conversation)
        let last = service.requests.last!
        #expect(last.messages.map(\.text) == ["And Germany?"])
        #expect(last.instructions?.contains("France's capital: Paris") == true)
        // Every session starts afresh after a summary.
        #expect(last.resume == nil)
        // And it's kept with the chat.
        #expect(Conversation(saved: conversation.saved).summarised == 2)
    }

    @Test("A chat that's grown long is summarised before the next turn")
    func compactsByItself() async {
        let service = ScriptedService()
        let conversation = Conversation()
        for question in ["One?", "Two?", "Three?"] {
            service.events = [.text("Yes."), .usage(Usage(input: Conversation.compactAt, output: 10))]
            conversation.send(question, via: route(service))
            await settle(conversation)
        }
        // The third turn was summarised first: the request before its reply.
        #expect(conversation.summarised == 4)
        #expect(service.requests.last?.messages.map(\.text) == ["Three?"])
    }

    @Test("Stopping marks unfinished steps cut short, and the next turn tells the model what was and wasn't done")
    func cutShort() async {
        let service = ScriptedService()
        service.events = [
            .activity(Activity(id: "1", title: "Closing tabs", done: true, outcome: .done, detail: "Closed “GitHub”")),
            .activity(Activity(id: "2", title: "Moving tabs")),
        ]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Tidy my tabs", via: route(service))
        for _ in 0..<200 where conversation.messages.last?.steps.count != 2 { try? await Task.sleep(for: .milliseconds(5)) }
        conversation.stop()
        #expect(conversation.messages[1].steps.map(\.outcome) == [.done, .interrupted])
        service.hold = false
        service.events = [.text("Carrying on.")]
        conversation.send("Go on", via: route(service))
        await settle(conversation)
        let told = said(service.requests.last)
        #expect(told.contains("stopped your last reply"))
        #expect(told.contains("Closing tabs: Closed “GitHub”"))
        #expect(told.contains("Not done or not finished: Moving tabs"))
        // Told once.
        conversation.send("Thanks", via: route(service))
        await settle(conversation)
        #expect(!said(service.requests.last).contains("stopped your last reply"))
    }

    @Test("A stopped reply's session goes on next turn, told it was stopped, not sent the whole chat again")
    func stopKeepsSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Working")]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Do a long thing", via: route(service))
        for _ in 0..<200 where conversation.messages.last?.text.isEmpty != false { try? await Task.sleep(for: .milliseconds(5)) }
        conversation.stop()
        service.hold = false
        service.events = [.text("Carrying on.")]
        conversation.send("Go on", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(service.requests[1].messages.count == 3)
        #expect(said(service.requests[1]).contains("stopped your last reply"))
    }

    @Test("A reply that fails before anything arrives is tried once more, afresh")
    func failedEarlyTriesAgain() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        service.failOnce = AIError.failed("No conversation found with session ID: s-1")
        service.events = [.session("s-2"), .text("Fresh")]
        conversation.send("Again", via: route(service))
        await settle(conversation)
        #expect(service.requests.count == 3)
        #expect(service.requests[1].resume == "s-1")
        #expect(service.requests[2].resume == nil)
        #expect(conversation.phase == .idle)
        #expect(conversation.messages.last?.text == "Fresh")
    }

    @Test("A turn that ends whole says so")
    func finishedHook() async {
        let service = ScriptedService()
        service.events = [.text("Plan: 1. 2.")]
        let conversation = Conversation()
        var told = 0
        conversation.finished = { _ in told += 1 }
        conversation.send("Plan it", via: route(service))
        await settle(conversation)
        #expect(told == 1)
    }

    @Test("A sidebar chat keeps the tab it was about")
    func origin() {
        let conversation = Conversation()
        conversation.sidebar = true
        conversation.origin = URL(string: "https://example.com/a")
        let held = UUID()
        conversation.originHeld = held
        let back = Conversation(saved: conversation.saved)
        #expect(back.sidebar)
        #expect(back.origin?.absoluteString == "https://example.com/a")
        #expect(back.originHeld == held)
        // A chat kept before these were has none.
        let old = Conversation(saved: SavedChat(id: UUID(), messages: [], created: Date(), updated: Date()))
        #expect(!old.sidebar && old.origin == nil)
    }

    @Test("The title is the first question, on one line and not too long")
    func title() {
        let conversation = Conversation()
        #expect(conversation.title == "New chat")
        conversation.send(
            "  How do\nplanes stay up when they are very heavy and full of people and luggage?  ", via: route(ScriptedService()))
        #expect(conversation.title == "How do planes stay up when they are very heavy and full of…")
    }

    @Test("Blank messages aren't sent")
    func blank() {
        let conversation = Conversation()
        conversation.send("   \n", via: route(ScriptedService()))
        #expect(conversation.messages.isEmpty)
    }

    @Test("The next message carries on the provider's session, with the whole history")
    func resumes() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        service.events = [.text("Sure")]
        conversation.send("Again", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(service.requests[1].messages.map(\.text) == ["Hello", "Hi", "Again"])
    }

    @Test("Another provider starts without the first one's session")
    func switching() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        conversation.send("Again", via: route(service, provider: "opencode"))
        await settle(conversation)
        #expect(service.requests[1].resume == nil)
    }

    @Test("A failure is kept for the chat to show, with what came before it")
    func failure() async {
        let service = ScriptedService()
        service.events = [.text("Part")]
        service.failure = AIError.failed("Overloaded")
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        #expect(conversation.phase == .failed("Overloaded"))
        #expect(conversation.messages.last?.text == "Part")
    }

    @Test("Retrying asks again in place of the failed reply, from a fresh session")
    func retry() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        service.events = []
        service.failure = AIError.failed("Session not found")
        conversation.send("Again", via: route(service))
        await settle(conversation)
        service.failure = nil
        service.events = [.text("Back")]
        conversation.retry(via: route(service))
        await settle(conversation)
        #expect(conversation.messages.map(\.text) == ["Hello", "Hi", "Again", "Back"])
        #expect(conversation.phase == .idle)
        // The session that failed isn't tried again.
        #expect(service.requests[2].resume == nil)
        #expect(service.requests[2].messages.map(\.text) == ["Hello", "Hi", "Again"])
    }

    @Test("Stopping keeps what arrived, marks it, and ends the provider's reply")
    func stop() async throws {
        let service = ScriptedService()
        service.events = [.text("Half")]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        for _ in 0..<100 where conversation.messages.last?.text.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        conversation.stop()
        #expect(!conversation.busy)
        #expect(conversation.phase == .idle)
        #expect(conversation.messages.last?.text == "Half")
        #expect(conversation.messages.last?.interrupted == true)
        for _ in 0..<100 where !service.stopped { try await Task.sleep(for: .milliseconds(5)) }
        #expect(service.stopped)
    }

    @Test("Sending while a reply is coming queues it, and it goes once the reply ends")
    func sendWhileBusy() async throws {
        let service = ScriptedService()
        service.events = [.text("One it is")]
        service.hold = true
        let conversation = Conversation()
        conversation.send("One", via: route(service))
        await waitForRequest(service, count: 1)
        conversation.send("Two", via: route(service))
        #expect(conversation.queued.map(\.text) == ["Two"])
        #expect(!service.stopped)
        service.hold = false
        service.events = [.text("Two it is")]
        service.finish()
        await waitForRequest(service, count: 2)
        await settle(conversation)
        #expect(conversation.messages.map(\.text) == ["One", "One it is", "Two", "Two it is"])
        #expect(conversation.queued.isEmpty)
    }

    @Test("Send now stops the reply and sends the queued message")
    func sendNow() async throws {
        let service = ScriptedService()
        service.hold = true
        let conversation = Conversation()
        conversation.send("One", via: route(service))
        await waitForRequest(service, count: 1)
        conversation.send("Two", via: route(service))
        service.hold = false
        service.events = [.text("Two it is")]
        conversation.sendNow(try #require(conversation.queued.first).id)
        await settle(conversation)
        #expect(conversation.messages.map(\.text) == ["One", "", "Two", "Two it is"])
        #expect(conversation.messages[1].interrupted)
    }

    @Test("Steering is taken once by the reply under way; untaken, it's sent after")
    func steering() async throws {
        let service = ScriptedService()
        service.hold = true
        let conversation = Conversation()
        conversation.send("One", via: route(service))
        await waitForRequest(service, count: 1)
        conversation.send("Use the blue one", via: route(service))
        conversation.steer(try #require(conversation.queued.first).id)
        #expect(conversation.takeSteering() == "Use the blue one")
        #expect(conversation.takeSteering() == nil)
        #expect(conversation.messages.last?.steps.last?.detail == "Use the blue one")
        conversation.send("Then close it", via: route(service))
        conversation.steer(try #require(conversation.queued.first).id)
        service.hold = false
        service.finish()
        await waitForRequest(service, count: 2)
        await settle(conversation)
        #expect(conversation.messages.map(\.text).contains("Then close it"))
    }

    @Test("The task list is numbered, marked, kept with the chat, and told only when it changed")
    func tasks() async throws {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("On it.")]
        let conversation = Conversation()
        conversation.setTasks(["Apply to EIDU", "Apply to KTSM"])
        #expect(conversation.addTasks(["Report back"]) == [3])
        #expect(conversation.markTask(1, .done, note: "sent, tab 4a1"))
        #expect(!conversation.markTask(9, .done))
        conversation.send("Go on", via: route(service))
        await settle(conversation)
        let told = said(service.requests.last)
        #expect(told.contains("2 of 3 open"))
        #expect(told.contains("[x] 1. Apply to EIDU (sent, tab 4a1)"))
        #expect(told.contains("[ ] 2. Apply to KTSM"))
        // The session carries on, and the list hasn't changed: not told again.
        conversation.send("And?", via: route(service))
        await settle(conversation)
        #expect(!said(service.requests.last).contains("task list"))
        conversation.markTask(2, .skipped, note: "closed")
        conversation.send("Next", via: route(service))
        await settle(conversation)
        #expect(said(service.requests.last).contains("[-] 2. Apply to KTSM (closed)"))
        // Kept with the chat.
        #expect(Conversation(saved: conversation.saved).tasks == conversation.tasks)
    }

    @Test("Attached files go with their message, told by where their copies are; a step's picture is kept in the chat's folder")
    func attached() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = ScriptedService()
        service.events = [.activity(Activity(id: "t1", title: "Looking")), .picture(step: "t1", Data([1, 2, 3])), .activity(Activity(id: "t1", title: "Looking", done: true))]
        let conversation = Conversation()
        conversation.folder = folder
        conversation.attached = [Attachment(file: "cv 2.pdf", name: "cv.pdf", bytes: 2048)]
        // A message of files alone goes too.
        conversation.send("", via: route(service))
        await settle(conversation)
        #expect(conversation.attached.isEmpty)
        #expect(conversation.messages.first?.files?.map(\.name) == ["cv.pdf"])
        #expect(said(service.requests.last).contains("- cv.pdf (2 KB): \(folder.appendingPathComponent("cv 2.pdf").path)"))
        let picture = try #require(conversation.messages.last?.steps.first?.picture)
        #expect(FileManager.default.contents(atPath: folder.appendingPathComponent(picture).path) == Data([1, 2, 3]))
    }

    @Test("Mote's own messages reach the model, marked as Mote's, never as the person's: not the title, not their files, not an answer")
    func quiet() async throws {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Done.")]
        let conversation = Conversation()
        conversation.send("Book the train", via: route(service))
        await settle(conversation)
        conversation.attached = [Attachment(file: "cv.pdf", name: "cv.pdf", bytes: 1)]
        conversation.send("Your sub-agents finished. Their reports: …", routing: { self.route(service) }, quiet: true)
        await settle(conversation)
        let told = said(service.requests.last)
        #expect(told.contains(Instructions.fromMote + "Your sub-agents finished"))
        #expect(!told.contains(Instructions.question + "Your sub-agents"))
        let last = try #require(conversation.messages.last(where: { $0.role == .user }))
        #expect(last.mote == true && last.files == nil)
        // The person's files wait for their own message; the title stays theirs.
        #expect(conversation.attached.map(\.name) == ["cv.pdf"])
        #expect(conversation.title == "Book the train")
        #expect(Conversation(saved: conversation.saved).messages.last(where: { $0.role == .user })?.mote == true)
    }

    @Test("Escape on a question answers it as closed, and the reply goes on; Escape again stops it")
    func dismissed() async throws {
        let service = ScriptedService()
        service.hold = true
        let conversation = Conversation()
        conversation.send("Fill in the form", via: route(service))
        await waitForRequest(service, count: 1)
        let asked = Task { await conversation.ask(.init(text: "Allow typing on example.com?", options: [.init(label: "Allow")])) }
        for _ in 0..<100 where conversation.question == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(conversation.dismissQuestion())
        #expect(await asked.value == Conversation.dismissed)
        #expect(conversation.busy)
        #expect(!conversation.dismissQuestion())
        conversation.stop()
        #expect(!conversation.busy)
    }

    @Test("A question waits for the answer; sending answers it, and stopping lets it go")
    func question() async throws {
        let service = ScriptedService()
        service.hold = true
        let conversation = Conversation()
        conversation.send("Tidy my tabs", via: route(service))
        await waitForRequest(service, count: 1)
        let asked = Task { await conversation.ask(.init(text: "Which space?", options: [.init(label: "Work")])) }
        for _ in 0..<100 where conversation.question == nil { try await Task.sleep(for: .milliseconds(5)) }
        conversation.send("Work", via: route(service))
        #expect(await asked.value == "Work")
        #expect(conversation.queued.isEmpty)
        let again = Task { await conversation.ask(.init(text: "Sure?", options: [])) }
        for _ in 0..<100 where conversation.question == nil { try await Task.sleep(for: .milliseconds(5)) }
        conversation.stop()
        #expect(await again.value == nil)
        #expect(conversation.question == nil)
    }

    @Test("Activity shows while the reply is coming, and is gone once it's done")
    func activity() async {
        let service = ScriptedService()
        service.events = [.activity(Activity(id: "t", title: "WebSearch")), .activity(Activity(id: "t", title: "WebSearch", done: true))]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        for _ in 0..<100 where conversation.activities.first?.done != true { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(conversation.activities == [Activity(id: "t", title: "WebSearch", done: true)])
        conversation.stop()
        #expect(conversation.activities.isEmpty)
    }

    @Test("A turn whose route can't be found keeps the question and says why, for a retry later")
    func routeFails() async {
        let conversation = Conversation()
        conversation.send("Hello", routing: { throw AIError.needsKey("OpenAI") })
        #expect(conversation.messages.map(\.text) == ["Hello", ""])
        #expect(conversation.phase == .waiting)
        await settle(conversation)
        #expect(conversation.messages.map(\.text) == ["Hello"])
        #expect(conversation.phase == .failed("OpenAI needs an API key — add one in Settings › AI"))
        let service = ScriptedService()
        service.events = [.text("Hi")]
        conversation.retry(via: route(service))
        await settle(conversation)
        #expect(conversation.messages.map(\.text) == ["Hello", "Hi"])
        #expect(conversation.messages.last?.author == "Claude Code · sonnet")
    }

    @Test("A provider coming back after another answered starts afresh, so it hears the turns it missed")
    func comingBack() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("One")]
        let conversation = Conversation()
        conversation.send("First", via: route(service))
        await settle(conversation)
        service.events = [.text("Two")]
        conversation.send("Second", via: route(service, provider: "openai"))
        await settle(conversation)
        conversation.send("Third", via: route(service))
        await settle(conversation)
        #expect(service.requests[2].resume == nil)
        #expect(service.requests[2].messages.map(\.text) == ["First", "One", "Second", "Two", "Third"])
    }

    @Test("A stopped reply's session isn't carried on, since it holds a turn the chat asks again")
    func stoppedSession() async throws {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Half")]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        for _ in 0..<100 where conversation.messages.last?.text.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        conversation.stop()
        service.hold = false
        service.events = [.text("Whole")]
        conversation.retry(via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == nil)
    }

    @Test("A search reply keeps the pages it found and what it did, once each")
    func searchRecords() async {
        let service = ScriptedService()
        let page = Source(url: URL(string: "https://swift.org/blog")!, title: "Blog")
        service.events = [
            .activity(Activity(id: "s1", title: "Searching “swift”", kind: .search)), .source(page),
            .source(Source(url: URL(string: "https://www.swift.org/blog/")!, title: "Again")),
            .activity(Activity(id: "s1", title: "Searching “swift”", done: true, kind: .search)),
            .text("It's 6.4 [swift.org](https://swift.org/blog)"),
        ]
        let conversation = Conversation()
        var route = route(service)
        route.search = true
        conversation.send("Latest Swift?", via: route)
        await settle(conversation)
        let reply = conversation.messages[1]
        #expect(reply.sources == [page])
        #expect(reply.steps == [Activity(id: "s1", title: "Searching “swift”", done: true, kind: .search)])
        #expect(service.requests[0].search)
    }

    @Test("Turning search on or off starts the provider afresh, so it gets the new instructions")
    func searchChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        var searching = route(service)
        searching.search = true
        conversation.send("Look it up", via: searching)
        await settle(conversation)
        #expect(service.requests[1].resume == nil)
        #expect(service.requests[1].search)
    }

    @Test("Text arriving in many small pieces is shown in a few updates, the first at once, and all of it by the end")
    func coalesced() async {
        let service = ScriptedService()
        service.events = (0..<300).map { .text("w\($0) ") }
        let conversation = Conversation()
        let count = ChangeCount(conversation)
        conversation.send("Hi", via: route(service))
        await settle(conversation)
        #expect(conversation.messages.last?.text.hasPrefix("w0 w1 ") == true)
        #expect(conversation.messages.last?.text.hasSuffix("w299 ") == true)
        #expect(count.changes < 30)
    }

    @Test("A shared page is told with the question, leaving the standing instructions as they are")
    func sharedPage() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.attach(PageContext(url: URL(string: "https://example.com/a")!, title: "An article"))
        conversation.send("What is this?", via: route(service))
        await settle(conversation)
        #expect(service.requests[0].instructions == "Be brief")
        let told = said(service.requests[0])
        #expect(told.contains("An article"))
        #expect(told.contains("https://example.com/a"))
        #expect(told.contains("untrusted page evidence"))
        #expect(told.hasSuffix("The person's message:\nWhat is this?"))
        // The chat itself shows what they typed.
        #expect(conversation.messages[0].text == "What is this?")
        #expect(!service.requests[0].search)
    }

    @Test("A chat with no page is asked exactly as before")
    func noPage() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        #expect(service.requests[0].instructions == "Be brief")
    }

    @Test("Detaching the page stops sharing it, and the chat carries on")
    func detachPage() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.attach(PageContext(url: URL(string: "https://example.com/a")!, title: "An article"))
        conversation.detachPage()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        #expect(service.requests[0].instructions == "Be brief")
    }

    @Test("A page attached in place of another replaces what the model is shown")
    func reattach() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.attach(PageContext(url: URL(string: "https://example.com/a")!, title: "First"))
        conversation.detachPage()
        conversation.attach(PageContext(url: URL(string: "https://example.com/b")!, title: "Second"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        let told = said(service.requests[0])
        #expect(told.contains("Second"))
        #expect(!told.contains("First"))
    }

    @Test("Sharing a page with a provider that already heard the chat carries its session on, telling it the page")
    func pageChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        conversation.attach(PageContext(url: URL(string: "https://example.com/a")!, title: "An article"))
        service.events = [.text("About that page")]
        conversation.send("And now?", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("An article"))
    }

    @Test("The same page kept across turns carries the provider's session on")
    func samePageResumes() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(PageContext(url: URL(string: "https://example.com/a")!, title: "An article"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        service.events = [.text("Sure")]
        conversation.send("Again", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        // Heard already: not told again.
        #expect(said(service.requests[1]) == "Again")
    }

    @Test("Replacing a shared page with identical effective context keeps the provider session")
    func identicalPageContextResumes() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(
            PageContext(url: URL(string: "https://example.com/")!, title: "Article", text: "Same body", selection: "Same quote"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.attach(
            PageContext(url: URL(string: "https://example.com/")!, title: "Article", text: "Same body", selection: "Same quote"))
        service.events = [.text("Sure")]
        conversation.send("Again", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
    }

    @Test("A page changed during a reply is not taken as heard, so it is told next turn")
    func pageChangesDuringReply() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        service.hold = true
        let conversation = Conversation()
        conversation.attach(page("example.com", title: "First", text: "First body"))
        conversation.send("Hello", via: route(service))
        await waitForRequest(service, count: 1)
        #expect(service.requests.count == 1)

        conversation.attach(page("example.com", title: "Second", text: "Second body"))
        service.finish()
        await settle(conversation)

        service.hold = false
        service.events = [.text("Fresh context")]
        conversation.send("What changed?", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Second body"))
    }

    @Test("A mention added during a reply is not taken as heard, so it is told next turn")
    func mentionChangesDuringReply() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        service.hold = true
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await waitForRequest(service, count: 1)
        #expect(service.requests.count == 1)

        conversation.mention(page("example.com", title: "Mentioned", text: "Mentioned body"))
        service.finish()
        await settle(conversation)

        service.hold = false
        service.events = [.text("Fresh context")]
        conversation.send("What does it say?", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Mentioned body"))
    }

    @Test("Updating shared page text at the same URL is told to the session carried on")
    func sameURLPageTextChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(page("example.com", title: "Article", text: "First version"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.attach(page("example.com", title: "Article", text: "Updated version"))
        service.events = [.text("Updated")]
        conversation.send("What changed?", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Updated version"))
    }

    @Test("Updating shared page title at the same URL is told to the session carried on")
    func sameURLPageTitleChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(page("example.com", title: "Old title", text: "Article"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.attach(page("example.com", title: "New title", text: "Article"))
        service.events = [.text("Updated")]
        conversation.send("What changed?", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("New title"))
    }

    @Test("Updating shared page selection at the same URL is told to the session carried on")
    func sameURLPageSelectionChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(PageContext(url: URL(string: "https://example.com/")!, title: "Article", selection: "First quote"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.attach(PageContext(url: URL(string: "https://example.com/")!, title: "Article", selection: "New quote"))
        service.events = [.text("Updated")]
        conversation.send("What changed?", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("New quote"))
    }

    @Test("A shared page's delayed text enrichment is told to the session carried on")
    func sharedPageEnrichmentChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.attach(page("example.com", title: "Article"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.attach(page("example.com", title: "Article", text: "Read after attach"))
        service.events = [.text("Updated")]
        conversation.send("What does it say?", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Read after attach"))
    }

    @Test("Updating a mentioned page's same-URL content is told to the session carried on")
    func sameURLMentionChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.mention(page("example.com", title: "Article", text: "First version"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)

        conversation.mention(page("example.com", title: "Article", text: "Updated version"))
        service.events = [.text("Updated")]
        conversation.send("What changed?", via: route(service))
        await settle(conversation)

        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Updated version"))
    }

    // MARK: - Mentioned tabs

    private func page(_ host: String, title: String, text: String? = nil) -> PageContext {
        PageContext(url: URL(string: "https://\(host)/")!, title: title, text: text)
    }

    @Test("Mentioned tabs are held, in the order they were named")
    func mentions() {
        let conversation = Conversation()
        conversation.mention(page("a.com", title: "A"))
        conversation.mention(page("b.com", title: "B"))
        #expect(conversation.mentions.map { $0.url.host() } == ["a.com", "b.com"])
    }

    @Test("Naming the same tab again updates it in place rather than adding it twice")
    func mentionUpdatesInPlace() {
        let conversation = Conversation()
        conversation.mention(PageContext(url: URL(string: "https://a.com/")!, title: "A"))
        conversation.mention(PageContext(url: URL(string: "https://a.com/")!, title: "A", text: "Read now"))
        #expect(conversation.mentions.count == 1)
        #expect(conversation.mentions[0].text == "Read now")
    }

    @Test("A chat is told about at most the limit of tabs at once, and refuses the rest")
    func mentionCap() {
        let conversation = Conversation()
        for n in 0..<Conversation.mentionLimit {
            #expect(conversation.mention(page("s\(n).com", title: "S\(n)")))
        }
        #expect(conversation.mentions.count == Conversation.mentionLimit)
        #expect(!conversation.mention(page("over.com", title: "Over")))
        #expect(conversation.mentions.count == Conversation.mentionLimit)
    }

    @Test("A tab let go stops being told to the model, the others kept")
    func unmention() {
        let conversation = Conversation()
        conversation.mention(page("a.com", title: "A"))
        conversation.mention(page("b.com", title: "B"))
        conversation.unmention(URL(string: "https://a.com/")!)
        #expect(conversation.mentions.map { $0.url.host() } == ["b.com"])
    }

    @Test("A mentioned tab is rendered after the page, and the model is asked about all of them")
    func mentionedInstructions() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.attach(page("main.com", title: "Main"))
        conversation.mention(page("extra.com", title: "Extra", text: "More words"))
        conversation.send("Compare them", via: route(service))
        await settle(conversation)
        #expect(service.requests[0].instructions == "Be brief")
        let told = said(service.requests[0])
        #expect(told.contains("Main"))
        #expect(told.contains("Extra"))
        #expect(told.contains("More words"))
        #expect(told.contains("untrusted page evidence"))
    }

    @Test("A blank tab's chat has no page, but its mentioned tabs carry the context")
    func mentionedWithoutPage() async {
        let service = ScriptedService()
        service.events = [.text("Hi")]
        let conversation = Conversation()
        conversation.mention(page("only.com", title: "Only"))
        conversation.send("What's this?", via: route(service))
        await settle(conversation)
        #expect(service.requests[0].instructions == "Be brief")
        let told = said(service.requests[0])
        #expect(told.contains("Only"))
        #expect(!told.contains("looking at a web page"))
    }

    @Test("Naming or letting go of a tab carries the session on, telling it so")
    func mentionChangesSession() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        conversation.mention(page("a.com", title: "A"))
        service.events = [.text("On it")]
        conversation.send("And this?", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
        #expect(said(service.requests[1]).contains("Mentioned page: A"))
        conversation.unmention(URL(string: "https://a.com/")!)
        service.events = [.text("Back")]
        conversation.send("And now?", via: route(service))
        await settle(conversation)
        #expect(service.requests[2].resume == "s-1")
        #expect(said(service.requests[2]).contains(Instructions.unmentioned))
    }

    @Test("The same mentioned tabs kept across turns carry the provider's session on")
    func sameMentionsResume() async {
        let service = ScriptedService()
        service.events = [.session("s-1"), .text("Hi")]
        let conversation = Conversation()
        conversation.mention(page("a.com", title: "A"))
        conversation.send("Hello", via: route(service))
        await settle(conversation)
        service.events = [.text("Sure")]
        conversation.send("Again", via: route(service))
        await settle(conversation)
        #expect(service.requests[1].resume == "s-1")
    }
}

/// Counts how often a conversation's messages change, as a view watching them would see.
@MainActor
final class ChangeCount {
    private(set) var changes = 0
    private let conversation: Conversation

    init(_ conversation: Conversation) {
        self.conversation = conversation
        watch()
    }

    private func watch() {
        withObservationTracking {
            _ = conversation.messages
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.changes += 1
                self?.watch()
            }
        }
    }
}
