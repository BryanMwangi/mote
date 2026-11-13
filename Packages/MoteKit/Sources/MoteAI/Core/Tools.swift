import Foundation

// Tools the model may call, carried out by the app: it says what it wants
// (`ChatEvent.toolCall`), the app does it, and the model is asked again with
// what came back (`ChatRequest.exchanges`), until it answers.

/// Something the model can ask the app to do.
public struct Tool: Equatable, Sendable {
    public var name: String
    public var description: String
    /// What it takes, as a JSON Schema object.
    public var parameters: JSON

    /// Its input's JSON Schema as Foundation objects, for an MCP listing.
    public var schema: Any { parameters.plain }

    /// `schema`: the JSON Schema of its input, as text.
    public init(name: String, description: String, schema: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        parameters = JSON(parsing: schema) ?? .object([:])
    }
}

/// The app's tools over MCP, on this Mac, for an agent that runs them itself.
public struct ToolServer: Equatable, Sendable {
    public var url: URL
    /// Sent as a bearer token; nothing else on the Mac has it.
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Its name to the agent, whose tools come as `mcp__mote__…`.
    public static let name = "mote"
    /// The environment variable an agent finds the token in, so it isn't
    /// written into its settings or the process list.
    public static let tokenVariable = "MOTE_MCP_TOKEN"
}

extension ChatRequest {
    /// Mote's tool server, when the request offers tools through one.
    var mcp: ToolServer? { tools.isEmpty ? nil : toolServer }
}

/// The model asking for a tool.
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: JSON

    public init(id: String, name: String, input: JSON) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// A tool the model asked for this turn, and what came of it.
public struct ToolExchange: Equatable, Sendable {
    public var call: ToolCall
    public var result: String
    /// What the model wrote before asking, kept with its first call.
    public var said: String

    public init(call: ToolCall, result: String, said: String = "") {
        self.call = call
        self.result = result
        self.said = said
    }
}

/// A provider's replies with tools: each round's calls are carried out by
/// `run`, one after another, and the model asked again, until it answers
/// without asking or `rounds` are used up. What the model writes on the way
/// stays in the reply; each call shows as a step.
public struct ToolLoop: ChatService {
    let service: any ChatService
    let tools: [Tool]
    /// A line for the step, such as "Reading example.com".
    let describe: @Sendable (ToolCall) -> String
    let run: @Sendable (ToolCall) async -> String
    /// An agent's: it reaches the tools here itself, and the loop only tells it so.
    let server: ToolServer?
    static let rounds = 8

    public init(
        service: any ChatService, tools: [Tool], server: ToolServer? = nil, describe: @escaping @Sendable (ToolCall) -> String,
        run: @escaping @Sendable (ToolCall) async -> String
    ) {
        self.service = service
        self.tools = tools
        self.server = server
        self.describe = describe
        self.run = run
    }

    /// Told to the model with the tools, so it knows to use them.
    static func note(_ tools: [Tool]) -> String {
        "You can use Mote's tools while you answer: " + tools.map(\.name).joined(separator: ", ")
            + ". Use them when the question is about the person's other tabs, a page, their history or bookmarks, or asks you to act in a page; Mote asks the person before anything is done in a page."
    }

    public func reply(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        var told = request
        told.instructions = [request.instructions, Self.note(tools)].compactMap { $0 }.joined(separator: "\n\n")
        if let server {
            told.tools = tools
            told.toolServer = server
            return service.reply(to: told)
        }
        let request = told
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let (service, tools, describe, run) = (service, tools, describe, run)
        let task = Task {
            do {
                var request = request
                request.tools = tools
                var wrote = false
                for _ in 0..<Self.rounds {
                    var calls: [ToolCall] = []
                    var said = ""
                    for try await event in service.reply(to: request) {
                        try Task.checkCancellation()
                        switch event {
                        case .toolCall(let call):
                            calls.append(call)
                        case .text(let text):
                            // A new round's words are a new paragraph.
                            if said.isEmpty, wrote { continuation.yield(.text("\n\n")) }
                            said += text
                            continuation.yield(event)
                        default:
                            continuation.yield(event)
                        }
                    }
                    wrote = wrote || !said.isEmpty
                    guard !calls.isEmpty else { break }
                    for (index, call) in calls.enumerated() {
                        let step = Activity(id: call.id, title: describe(call))
                        continuation.yield(.activity(step))
                        let result = await run(call)
                        try Task.checkCancellation()
                        var done = step
                        done.done = true
                        continuation.yield(.activity(done))
                        request.exchanges.append(ToolExchange(call: call, result: result, said: index == 0 ? said : ""))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

extension ToolLoop {
    /// A step's line for one of Mote's tools, by name.
    public static func title(of name: String, input: JSON?) -> String {
        let site = input?["url"]?.string.flatMap(URL.init(string:)).map { Source(url: $0, title: "").site }
        switch name {
        case "list_tabs": return "Looking at your tabs"
        case "read_tab": return "Reading a tab"
        case "read_page": return site.map { "Reading \($0)" } ?? "Reading a page"
        case "search_history": return "Searching your history"
        case "search_bookmarks": return "Searching your bookmarks"
        case "open_tab": return site.map { "Opening \($0)" } ?? "Opening a tab"
        case "click": return "Clicking on the page"
        case "fill": return "Typing on the page"
        case "close_tabs": return "Closing tabs"
        case "select_tab": return "Switching tabs"
        case "move_tabs": return "Moving tabs"
        case "pin_tabs": return input?["pinned"]?.bool == false ? "Unpinning tabs" : "Pinning tabs"
        case "mute_tabs": return input?["muted"]?.bool == false ? "Unmuting tabs" : "Muting tabs"
        case "reload_tabs": return "Reloading tabs"
        case "navigate": return site.map { "Going to \($0)" } ?? "Going \(input?["go"]?.string ?? "elsewhere")"
        default: return name
        }
    }
}

extension JSON {
    /// The text of `value` as JSON, for an API that takes a tool's input as text.
    var encoded: String { JSON.encode(plain) }
}
