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

/// What a tool gives back: words, and a picture for one that looked (a screenshot).
public struct ToolOutput: Equatable, Sendable {
    public var text: String
    /// A JPEG.
    public var image: Data?
    /// How it went, for the step's line in the chat.
    public var outcome: Activity.Outcome
    /// What it came to, in a line for the chat; the text's first line if not given.
    public var detail: String?

    public init(_ text: String, image: Data? = nil, outcome: Activity.Outcome = .done, detail: String? = nil) {
        self.text = text
        self.image = image
        self.outcome = outcome
        self.detail = detail
    }

    /// The line the chat shows under the step.
    public var line: String {
        let first = detail ?? text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.count > 240 ? String(first.prefix(239)) + "…" : first
    }
}

/// A tool the model asked for this turn, and what came of it.
public struct ToolExchange: Equatable, Sendable {
    public var call: ToolCall
    public var result: String
    /// A picture the tool gave back, as a JPEG.
    public var image: Data?
    /// What the model wrote before asking, kept with its first call.
    public var said: String

    public init(call: ToolCall, result: String, image: Data? = nil, said: String = "") {
        self.call = call
        self.result = result
        self.image = image
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
    let run: @Sendable (ToolCall) async -> ToolOutput
    /// An agent's: it reaches the tools here itself, and the loop only tells it so.
    let server: ToolServer?
    static let rounds = 40

    public init(
        service: any ChatService, tools: [Tool], server: ToolServer? = nil, describe: @escaping @Sendable (ToolCall) -> String,
        run: @escaping @Sendable (ToolCall) async -> ToolOutput
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
            + ". Use them when the question is about the person's tabs, spaces, a page, their history or bookmarks, or asks you to act in Mote or a page; Mote asks the person when it should."
            + (tools.contains { $0.name == "run_script" }
                ? " When no tool does what's asked in a page, read the page, then do it with a short run_script."
                    + " For Mote itself, if no tool does it, say so plainly and name the setting or menu, rather than guessing." : "")
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
                var finished = false
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
                    guard !calls.isEmpty else {
                        finished = true
                        break
                    }
                    for (index, call) in calls.enumerated() {
                        let step = Activity(id: call.id, title: describe(call))
                        continuation.yield(.activity(step))
                        let result = await run(call)
                        try Task.checkCancellation()
                        var done = step
                        done.done = true
                        if result.outcome != .done { done.outcome = result.outcome }
                        done.detail = result.line.isEmpty ? nil : result.line
                        continuation.yield(.activity(done))
                        request.exchanges.append(
                            ToolExchange(call: call, result: result.text, image: result.image, said: index == 0 ? said : ""))
                    }
                }
                // Out of rounds with tools still wanted: said, so it's not a silent stop.
                if !finished {
                    continuation.yield(.text((wrote ? "\n\n" : "") + "_Stopped after \(Self.rounds) rounds of tools; ask again to carry on._"))
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
        case "fill", "write": return "Writing on the page"
        case "read_field": return "Reading a field"
        case "select_option": return "Choosing an option"
        case "check": return input?["on"]?.bool == false ? "Unticking a box" : "Ticking a box"
        case "scroll": return "Scrolling"
        case "press_key": return "Pressing \(input?["key"]?.string ?? "a key")"
        case "get_selection": return "Reading what you selected"
        case "find_in_page": return "Finding words on the page"
        case "extract_tables": return "Reading tables"
        case "screenshot_tab": return "Looking at the page"
        case "run_script": return "Running a script"
        case "console": return "Reading the console"
        case "network_errors": return "Checking failed requests"
        case "wait_for": return "Waiting for the page"
        case "responsive_design_mode": return input?["off"]?.bool == true ? "Back to the window's size" : "Trying a device's size"
        case "list_devices": return "Looking at device sizes"
        case "new_test_tab": return "Opening a test tab"
        case "close_test_tabs": return "Closing test tabs"
        case "sign_in": return "Signing in"
        case "ask_for_credentials": return "Asking you to sign in"
        case "add_bookmark": return "Bookmarking"
        case "organise_bookmarks": return "Tidying bookmarks"
        case "delete_history": return "Deleting history"
        case "downloads": return "Looking at downloads"
        case "save_for_later": return "Saving for later"
        case "save_page_as_pdf": return "Saving the page as PDF"
        case "export_markdown": return "Saving the page as Markdown"
        case "close_tabs": return "Closing tabs"
        case "select_tab": return "Switching tabs"
        case "move_tabs": return "Moving tabs"
        case "pin_tabs": return input?["pinned"]?.bool == false ? "Unpinning tabs" : "Pinning tabs"
        case "mute_tabs": return input?["muted"]?.bool == false ? "Unmuting tabs" : "Muting tabs"
        case "reload_tabs": return "Reloading tabs"
        case "navigate": return site.map { "Going to \($0)" } ?? "Going \(input?["go"]?.string ?? "elsewhere")"
        case "essentials": return input?["add"]?.bool == false ? "Taking tabs out of the essentials" : "Adding tabs to the essentials"
        case "recently_closed": return "Looking at closed tabs"
        case "reopen_tabs": return "Reopening tabs"
        case "list_folders": return "Looking at your folders"
        case "rename_folder": return "Renaming a folder"
        case "delete_folder": return "Deleting a folder"
        case "undo_actions": return (input?["ids"]?.array.isEmpty ?? true) && input?["last_turn"]?.bool != true ? "Looking at what can be undone" : "Undoing"
        case "pdf_fields": return "Reading the PDF's form fields"
        case "fill_pdf_fields": return "Filling in the PDF"
        case "read_tabs": return "Reading \(input?["tabs"]?.array.count ?? 0) tabs"
        case "remember": return "Remembering"
        case "forget": return "Forgetting"
        case "memories": return "Looking at what I remember"
        case "fill_form": return "Filling in the form"
        case "list_spaces": return "Looking at your spaces"
        case "new_space": return "Making a space"
        case "rename_space": return "Renaming a space"
        case "space_icon": return "Changing a space's icon"
        case "space_theme": return "Changing a space's colours"
        case "order_spaces": return "Reordering spaces"
        case "delete_space": return "Deleting a space"
        case "sidebar_foot": return "Arranging the sidebar's foot"
        case "page_appearance": return input?["look"]?.string == "auto" ? "Back to Mote's look" : "Showing the page in \(input?["look"]?.string ?? "another look")"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension JSON {
    /// The text of `value` as JSON, for an API that takes a tool's input as text.
    var encoded: String { JSON.encode(plain) }
}
