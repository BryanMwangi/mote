import Foundation

// The words every provider is spoken to in, and answers in. A provider turns
// a `ChatRequest` into a stream of `ChatEvent`s; everything above it (the
// conversation, the views) knows nothing of how that happens.

public enum Role: String, Codable, Sendable {
    case user, assistant
}

/// One turn of a conversation.
public struct Message: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var role: Role
    public var text: String
    /// The model's thinking before it answered, when it shares it.
    public var reasoning: String
    /// What wrote an assistant's message, as the chat shows it ("Claude Code · sonnet").
    public var author: String?
    /// The reply was stopped before it was done.
    public var interrupted: Bool
    /// Pages the reply drew on, in the order they turned up.
    public var sources: [Source]
    /// What was done on the way to the reply: searches, pages read.
    public var steps: [Activity]
    /// Files the person attached, kept with the chat; nil when none.
    public var files: [Attachment]?

    public init(
        id: UUID = UUID(), role: Role, text: String, reasoning: String = "", author: String? = nil, interrupted: Bool = false,
        sources: [Source] = [], steps: [Activity] = [], files: [Attachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.author = author
        self.interrupted = interrupted
        self.sources = sources
        self.steps = steps
        self.files = files
    }
}

/// A file the person attached to a message: a copy Mote keeps in the chat's
/// folder (`ChatArchive.files(of:)`), so it stays when the original goes.
public struct Attachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The copy's name in the chat's folder.
    public var file: String
    /// The original's name, as it shows.
    public var name: String
    public var bytes: Int64
    public var id: String { file }

    public init(file: String, name: String, bytes: Int64) {
        self.file = file
        self.name = name
        self.bytes = bytes
    }
}

/// What a provider is asked for: a reply to the last message of `messages`.
public struct ChatRequest: Equatable, Sendable {
    /// The model's id; empty for the provider's own default.
    public var model: String
    /// The whole conversation so far, ending with the user's new message.
    public var messages: [Message]
    /// Standing instructions, as a system prompt.
    public var instructions: String?
    /// A session the provider opened earlier (see `ChatEvent.session`). Those
    /// that keep their own history carry on from it and need only the new
    /// message; the rest ignore it.
    public var resume: String?
    /// Search the web for the answer, with the provider's own search.
    public var search: Bool
    /// Tools the model may ask the app to use (see ToolLoop).
    public var tools: [Tool] = []
    /// The tools asked for in this reply so far, and their results.
    public var exchanges: [ToolExchange] = []
    /// Where an agent on the Mac reaches `tools` itself, over MCP.
    public var toolServer: ToolServer?

    public init(model: String, messages: [Message], instructions: String? = nil, resume: String? = nil, search: Bool = false) {
        self.model = model
        self.messages = messages
        self.instructions = instructions
        self.resume = resume
        self.search = search
    }

    /// The message to answer.
    public var prompt: String { messages.last(where: { $0.role == .user })?.text ?? "" }
}

/// What comes back, piece by piece.
public enum ChatEvent: Equatable, Sendable {
    /// The provider keeps the conversation itself under this id; pass it back
    /// as `ChatRequest.resume` next time.
    case session(String)
    /// More of the answer.
    case text(String)
    /// More of the model's thinking.
    case reasoning(String)
    /// Something the model is doing on the way, such as using a tool.
    case activity(Activity)
    /// A picture a step took (a screenshot), as JPEG, to show with the step.
    case picture(step: String, Data)
    /// What the turn cost, once known.
    case usage(Usage)
    /// What the turn has spent so far, for a provider that only says what it
    /// cost at the end: shown while it works, and replaced by `usage`.
    case spending(Usage)
    /// A page the provider found or read on the way.
    case source(Source)
    /// The model asks for a tool (see ToolLoop).
    case toolCall(ToolCall)
}

public struct Activity: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A web search.
        case search
        /// Reading a page.
        case read
        /// Any other tool.
        case tool
        /// One part of a research, looked into by a researcher of its own.
        case task
        /// A stage of a research: planning, reviewing, writing.
        case phase
        /// A sub-agent at work; its own steps have ids that start with this one's and a dash.
        case agent
    }

    /// How a step ended.
    public enum Outcome: String, Codable, Sendable {
        case done
        /// The person said no, or acting is off.
        case refused
        case failed
        /// The reply was stopped, or failed, before the step finished.
        case interrupted
    }

    public var id: String
    /// Short, for a line in the chat ("Searching the web").
    public var title: String
    public var done: Bool
    public var kind: Kind
    /// How it ended, when it went other than well; nil for a step done as
    /// asked, as for steps from before outcomes were kept.
    public var outcome: Outcome?
    /// What it came to, in a line: "Closed “GitHub”, “Hacker News”".
    public var detail: String?
    /// Tokens it took, when it ran a model of its own (a sub-agent).
    public var spent: Int?
    /// A picture it took, by its name in the chat's folder.
    public var picture: String?
    /// A file on the Mac it read (read_file), by its path.
    public var file: String?

    public init(id: String, title: String, done: Bool = false, kind: Kind = .tool, outcome: Outcome? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.done = done
        self.kind = kind
        self.outcome = outcome
        self.detail = detail
    }

    /// Cut short: the reply ended before this step did.
    public var cutShort: Activity {
        var step = self
        guard !step.done else { return step }
        step.done = true
        step.outcome = .interrupted
        return step
    }

    /// A search for `query`.
    public static func search(_ id: String, _ query: String?, done: Bool = false) -> Activity {
        Activity(id: id, title: query.map { "Searching “\($0)”" } ?? "Searching the web", done: done, kind: .search)
    }

    /// Reading the page at `url`.
    public static func read(_ id: String, _ url: String?, done: Bool = false) -> Activity {
        let site = url.flatMap(URL.init(string:)).map { Source(url: $0, title: "").site }
        return Activity(id: id, title: site.map { "Reading \($0)" } ?? "Reading a page", done: done, kind: .read)
    }
}

public struct Usage: Equatable, Codable, Sendable {
    public var input: Int
    public var output: Int
    /// In US dollars, when the provider says.
    public var cost: Double?

    public init(input: Int, output: Int, cost: Double? = nil) {
        self.input = input
        self.output = output
        self.cost = cost
    }

    /// Two spends together; the cost while either says it.
    public static func + (a: Usage?, b: Usage) -> Usage {
        guard let a else { return b }
        let cost = a.cost == nil && b.cost == nil ? nil : (a.cost ?? 0) + (b.cost ?? 0)
        return Usage(input: a.input + b.input, output: a.output + b.output, cost: cost)
    }
}

/// Something that answers chat requests: a cloud API, a server on this Mac,
/// an installed agent, or the Mac's own model.
public protocol ChatService: Sendable {
    /// The reply, as it arrives. Ending the stream early stops the reply.
    func reply(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

/// Turns the lines a provider sends into events. Each reply gets a fresh one,
/// so it can remember what it has seen.
public protocol LineDecoder: Sendable {
    mutating func read(_ line: String) throws -> [ChatEvent]
    /// What's left once the lines have ended.
    mutating func finish() throws -> [ChatEvent]
}

extension LineDecoder {
    public mutating func finish() throws -> [ChatEvent] { [] }
}

extension AsyncThrowingStream where Element == ChatEvent, Failure == Error {
    /// Feeds `lines` through `decoder`, ending when they do. Ending the
    /// result early stops reading them.
    static func decoding<Lines: AsyncSequence & Sendable, Decoder: LineDecoder>(
        _ lines: @escaping @Sendable () async throws -> Lines, with decoder: Decoder
    ) -> Self where Lines.Element == String {
        let (stream, continuation) = makeStream()
        let task = Task {
            var decoder = decoder
            do {
                for try await line in try await lines() {
                    try Task.checkCancellation()
                    for event in try decoder.read(line) { continuation.yield(event) }
                }
                for event in try decoder.finish() { continuation.yield(event) }
                continuation.finish()
            } catch {
                // What the decoder held back still arrived before the failure.
                if !(error is CancellationError) { for event in (try? decoder.finish()) ?? [] { continuation.yield(event) } }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
