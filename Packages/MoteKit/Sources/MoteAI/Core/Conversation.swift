import Foundation
import Observation

/// A chat: its messages, the reply on its way, and what went wrong.
///
/// It keeps the whole history itself, so any provider can take over at any
/// turn. Providers that keep their own sessions are handed theirs back, and
/// only need the new message.
@MainActor
@Observable
public final class Conversation: Identifiable {
    /// The shared context a provider session has heard. Page URLs alone are
    /// insufficient: a same-URL read, title, or selection update changes the
    /// next request's instructions.
    private struct SharedPage: Equatable {
        var url: String
        var title: String
        var text: String?
        var selection: String?
    }

    private struct SharedContext: Equatable {
        var page: SharedPage?
        var mentions: [SharedPage]
    }

    /// Where a message goes: the provider, its model, and the service that answers.
    public struct Route: Sendable {
        public var provider: String
        public var model: String
        /// Shown over the reply ("Claude Code · sonnet").
        public var author: String
        public var service: any ChatService
        public var instructions: String?
        /// Search the web for the answer.
        public var search: Bool

        public init(
            provider: String, model: String, author: String, service: any ChatService, instructions: String? = nil, search: Bool = false
        ) {
            self.provider = provider
            self.model = model
            self.author = author
            self.service = service
            self.instructions = instructions
            self.search = search
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Asked, and nothing back yet.
        case waiting
        /// The reply is arriving.
        case answering
        /// The last reply failed, for this reason.
        case failed(String)
    }

    public let id: UUID
    public private(set) var messages: [Message] = []
    public let created: Date
    /// When the chat last changed: a question asked, a reply ended.
    public private(set) var updated: Date
    /// Called when the chat reaches a point worth keeping: a question asked,
    /// a reply ended or stopped.
    @ObservationIgnored public var changed: (@MainActor (Conversation) -> Void)?
    public private(set) var phase: Phase = .idle
    /// What the model is doing on the way to its reply.
    public private(set) var activities: [Activity] = []
    /// What the last reply cost.
    public private(set) var usage: Usage?
    /// The page the person has shared with this chat, if any. Kept as the tab
    /// moves: the page is detached on navigation, not thrown away.
    public private(set) var page: PageContext?
    /// The other tabs the person has mentioned with @, shared as further
    /// context after the page. Ordered as they were named, and kept as the
    /// tabs move; letting one go removes it from here.
    public private(set) var mentions: [PageContext] = []

    /// How many tabs a chat may be told about at once.
    public static let mentionLimit = 5

    /// The chat so far in the model's own summary, sent in place of the
    /// first `summarised` messages, which stay on screen.
    public private(set) var summary: String?
    public private(set) var summarised = 0
    /// A turn that heard this many tokens or more summarises the chat before the next.
    public static let compactAt = 100_000

    /// Sessions providers opened, by provider.
    ///
    /// A session is only carried on while it has heard every message: it
    /// holds the chat up to `heard` messages, the reply included. Another
    /// provider answering, or a reply stopped halfway, leaves it behind, and
    /// the provider then starts afresh with the whole conversation.
    /// It was opened searching or not, and its instructions say so; a turn
    /// the other way starts afresh too.
    @ObservationIgnored private var sessions: [String: (id: String, heard: Int, search: Bool, shared: SharedContext?)] = [:]
    /// The session opened or carried on by the reply under way.
    @ObservationIgnored private var opened: String?
    /// Context captured when that request was built, not when its reply ends.
    @ObservationIgnored private var openedShared: SharedContext?
    /// Whether the reply under way searches.
    @ObservationIgnored private var searched = false
    /// Text and thinking that arrived since the reply was last shown; they
    /// go into the message together, at most every `pace`, so a reply that
    /// comes a word at a time doesn't redraw the chat per word. The chat
    /// shows them at a reader's pace of its own, so this can be slow.
    @ObservationIgnored private var held = (text: "", reasoning: "")
    @ObservationIgnored private var flushing: Task<Void, Never>?
    static let pace: Duration = .milliseconds(150)
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts replies, so a stopped one's late events are dropped.
    @ObservationIgnored private var turn = 0

    public init() {
        id = UUID()
        created = Date()
        updated = created
    }

    /// A chat kept earlier, ready to carry on.
    public init(saved: SavedChat) {
        id = saved.id
        created = saved.created
        updated = saved.updated
        messages = saved.messages
        summary = saved.summary
        summarised = min(saved.summarised ?? 0, saved.messages.count)
        title = SavedChat.title(of: saved.messages)
        sessions = saved.sessions.mapValues { ($0.id, $0.heard, $0.search, nil) }
    }

    /// The chat as it is now, for keeping. A reply still coming is kept as
    /// stopped, and its session left out.
    public var saved: SavedChat {
        var kept = messages
        if busy, let last = kept.indices.last, kept[last].role == .assistant {
            kept[last].text += held.text
            kept[last].reasoning += held.reasoning
            kept[last].interrupted = true
        }
        var saved = SavedChat(
            id: id, messages: kept, sessions: sessions.mapValues { SavedChat.Session(id: $0.id, heard: $0.heard, search: $0.search) },
            created: created, updated: updated)
        saved.summary = summary
        saved.summarised = summary == nil ? nil : summarised
        return saved
    }

    private func touch() {
        updated = Date()
        changed?(self)
    }

    public var busy: Bool { phase == .waiting || phase == .answering }

    /// The first question, cut short. Kept apart from `messages`, so what
    /// shows it (a tab's label, the window's title) isn't drawn again with
    /// every piece of a reply.
    public private(set) var title = SavedChat.title(of: [])

    /// Finds the route for a turn. Asked once the question is on screen, so
    /// it can take a moment (finding a program, listing models) or fail.
    public typealias Routing = @MainActor @Sendable () async throws -> Route

    /// Shares `page` with the chat, so the model answers about it from the
    /// next turn on. Replaces any page already shared.
    public func attach(_ page: PageContext) {
        var page = page
        page.attach()
        self.page = page
    }

    /// Stops sharing the page, keeping the chat. The next turn starts
    /// providers that keep their own sessions afresh, since what they were
    /// told has changed.
    public func detachPage() {
        page?.detach()
    }

    /// Shares `page` as an additional tab the chat is told about, for its
    /// questions to range over. A tab already mentioned is brought up to date
    /// in place; a new one once the limit is reached is left out. Returns
    /// whether the chat holds it now.
    @discardableResult
    public func mention(_ page: PageContext) -> Bool {
        var page = page
        page.attach()
        if let index = mentions.firstIndex(where: { $0.url == page.url }) {
            mentions[index] = page
            return true
        }
        guard mentions.count < Self.mentionLimit else { return false }
        mentions.append(page)
        return true
    }

    /// Stops telling the model about a mentioned tab, keeping the chat. A
    /// change starts providers that keep their own sessions afresh, as
    /// sharing or detaching the page does.
    public func unmention(_ url: URL) {
        mentions.removeAll { $0.url == url }
    }

    /// What the model is told the chat is about, for providers that keep
    /// their own sessions: the effective details of the page shared and every
    /// tab mentioned. A change starts the provider afresh, as turning search
    /// on or off does.
    @ObservationIgnored private var shared: SharedContext? {
        func snapshot(_ page: PageContext) -> SharedPage {
            SharedPage(url: page.url.absoluteString, title: page.title, text: page.text, selection: page.selection)
        }

        let page = page.flatMap { $0.isActive ? snapshot($0) : nil }
        let mentions = mentions.filter(\.isActive).map(snapshot)
        guard page != nil || !mentions.isEmpty else { return nil }
        return SharedContext(page: page, mentions: mentions)
    }

    public func send(_ text: String, via route: Route) { send(text, routing: { route }) }

    public func send(_ text: String, routing: @escaping Routing) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        messages.append(Message(role: .user, text: text))
        if messages.count == 1 { title = SavedChat.title(of: messages) }
        ask(routing: routing)
        touch()
    }

    public func retry(via route: Route) { retry(routing: { route }) }

    /// Asks again for the last reply, in place of the one that failed or was stopped.
    public func retry(routing: @escaping Routing) {
        stop()
        guard messages.contains(where: { $0.role == .user }) else { return }
        while messages.last?.role == .assistant { messages.removeLast() }
        ask(routing: routing)
    }

    /// Stops the reply, keeping what arrived.
    public func stop() {
        guard busy else { return }
        flush()
        turn += 1
        task?.cancel()
        task = nil
        if let last = messages.indices.last, messages[last].role == .assistant { messages[last].interrupted = true }
        activities = []
        phase = .idle
        touch()
    }

    /// Whether the chat has grown long enough to summarise before the next turn.
    private var wantsCompacting: Bool {
        (usage?.input ?? 0) >= Self.compactAt && messages.count - summarised > 4
    }

    /// Summarises the chat so far (`/compact`): the model is sent the
    /// summary in place of the messages before, which stay on screen.
    public func compact(routing: @escaping Routing) {
        guard !busy, messages.count - summarised >= 2 else { return }
        turn += 1
        let turn = turn
        phase = .waiting
        task = Task { [weak self] in
            do {
                let route = try await routing()
                guard let self, self.turn == turn else { return }
                try await self.summarise(via: route, through: self.messages.count)
                guard self.turn == turn else { return }
                self.task = nil
                self.phase = .idle
                self.touch()
            } catch {
                guard let self, self.turn == turn else { return }
                self.task = nil
                self.activities = []
                self.phase = .failed("The chat couldn't be summarised: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    /// Asks the model for a summary of the first `through` messages (and any
    /// summary before), and sends that from now on in their place. Every
    /// provider's session starts afresh, since what it heard is replaced.
    private func summarise(via route: Route, through: Int) async throws {
        let step = Activity(id: "compact-\(through)", title: "Summarising the chat so far", kind: .phase)
        activities = [step]
        let earlier = summary.map { "Summary of the chat before this:\n\($0)\n\n" } ?? ""
        let transcript = messages[summarised..<through].map { message in
            (message.role == .user ? "Person: " : "Assistant: ") + message.text + Self.stepsLine(message.steps)
        }.joined(separator: "\n\n")
        let request = ChatRequest(
            model: route.model,
            messages: [Message(role: .user, text: Self.compactAsk + "\n\n" + earlier + transcript)],
            instructions: "You summarise conversations faithfully and compactly, for the same assistant to carry on from.",
            resume: nil, search: false)
        var text = ""
        for try await event in route.service.reply(to: request) {
            if case .text(let more) = event { text += more }
        }
        let made = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !made.isEmpty else { throw CancellationError() }
        summary = made
        summarised = through
        sessions = [:]
        activities = []
    }

    static let compactAsk = """
        Summarise this conversation between a person and their browser's assistant so the assistant can carry on \
        without it. Keep: what the person wants and has decided, facts and figures found, tabs, pages, files and ids \
        named, what the assistant did (and whether it worked), and anything left to do. Leave out pleasantries. \
        Write it as notes, under 400 words.
        """

    /// What a reply did on the way, for the summary: its steps' titles.
    private static func stepsLine(_ steps: [Activity]) -> String {
        steps.isEmpty ? "" : "\n(Steps: " + steps.map(\.title).joined(separator: "; ") + ")"
    }

    private func ask(routing: @escaping Routing) {
        turn += 1
        let turn = turn
        let compacting = wantsCompacting
        messages.append(Message(role: .assistant, text: ""))
        phase = .waiting
        activities = []
        task = Task { [weak self] in
            var provider: String?
            do {
                let route = try await routing()
                guard let self, self.turn == turn else { return }
                provider = route.provider
                // A long chat is summarised first: everything but the new question.
                if compacting { try await self.summarise(via: route, through: self.messages.count - 2) }
                guard self.turn == turn else { return }
                let request = self.request(for: route)
                for try await event in route.service.reply(to: request) {
                    guard self.turn == turn else { return }
                    self.take(event, from: route.provider)
                }
                self.end(turn, failure: nil, provider: route.provider)
            } catch {
                self?.end(turn, failure: error, provider: provider)
            }
        }
    }

    /// Signs the reply with the route's author and asks for it with everything
    /// before it.
    private func request(for route: Route) -> ChatRequest {
        let asked = Array(messages.dropLast())
        // What the summary stands for isn't sent again.
        let sent = Array(asked.dropFirst(min(summarised, asked.count)))
        if let last = messages.indices.last { messages[last].author = route.author }
        let shared = self.shared
        // Up to date if it heard everything but the new question, and was
        // told the same things (search, shared page).
        let session = sessions[route.provider].flatMap {
            $0.heard == asked.count - 1 && $0.search == route.search && $0.shared == shared ? $0.id : nil
        }
        // An agent that carries a session on may not name it again.
        opened = session
        openedShared = shared
        searched = route.search
        return ChatRequest(
            model: route.model, messages: sent, instructions: instructions(for: route), resume: session, search: route.search
        )
    }

    /// The route's standing instructions with the shared page, and any tabs
    /// mentioned with @, described after them: exactly the route's
    /// instructions when there is nothing shared.
    private func instructions(for route: Route) -> String? {
        let earlier = summary.map { "Earlier in this chat, in summary (the messages themselves aren't repeated):\n" + $0 } ?? ""
        let context =
            [earlier, Instructions.page(self.page), Instructions.mentions(self.mentions)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !context.isEmpty else { return route.instructions }
        guard let standing = route.instructions, !standing.isEmpty else { return context }
        return standing + "\n\n" + context
    }

    /// Shows what's held: the first words at once, the rest a pace later.
    private func show(_ last: Int) {
        phase = .answering
        if messages[last].text.isEmpty, messages[last].reasoning.isEmpty { return flush() }
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: Self.pace)
            self?.flush()
        }
    }

    /// Puts what's held into the reply.
    private func flush() {
        flushing?.cancel()
        flushing = nil
        guard !held.text.isEmpty || !held.reasoning.isEmpty, let last = messages.indices.last, messages[last].role == .assistant
        else { return }
        messages[last].text += held.text
        messages[last].reasoning += held.reasoning
        held = ("", "")
    }

    private func take(_ event: ChatEvent, from provider: String) {
        guard let last = messages.indices.last else { return }
        switch event {
        case .session(let id):
            opened = id
        case .text(let more):
            held.text += more
            show(last)
        case .reasoning(let more):
            held.reasoning += more
            show(last)
        case .activity(let activity):
            if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index] = activity
            } else {
                activities.append(activity)
            }
            if let index = messages[last].steps.firstIndex(where: { $0.id == activity.id }) {
                messages[last].steps[index] = activity
            } else {
                messages[last].steps.append(activity)
            }
        case .usage(let spent):
            usage = spent
        case .source(let source):
            if !messages[last].sources.contains(where: { $0.id == source.id }) { messages[last].sources.append(source) }
        case .toolCall:
            // Carried out by the tool loop, which shows it as a step.
            break
        }
    }

    private func end(_ ended: Int, failure: Error?, provider: String?) {
        guard ended == turn else { return }
        flush()
        task = nil
        activities = []
        guard let failure, !(failure is CancellationError) else {
            if let provider, let opened { sessions[provider] = (opened, messages.count, searched, openedShared) }
            phase = .idle
            touch()
            return
        }
        // A reply that never started leaves nothing to show.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty, last.reasoning.isEmpty { messages.removeLast() }
        // A session that failed may be gone; the next try starts afresh.
        if let provider { sessions[provider] = nil }
        phase = .failed((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
        touch()
    }
}
