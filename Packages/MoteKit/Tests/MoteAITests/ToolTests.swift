import Foundation
import Testing

@testable import MoteAI

private func json(_ request: URLRequest) -> JSON? {
    request.httpBody.flatMap { JSON(parsing: String(decoding: $0, as: UTF8.self)) }
}

private let readTab = Tool(name: "read_tab", description: "Reads a tab", schema: #"{"type":"object","properties":{"tab":{"type":"string"}}}"#)
private let call = ToolCall(id: "c1", name: "read_tab", input: .object(["tab": .string("ab12")]))
private func asked() -> ChatRequest {
    var request = ChatRequest(model: "m", messages: [Message(role: .user, text: "What's in my other tab?")])
    request.tools = [readTab]
    request.exchanges = [ToolExchange(call: call, result: "A page about cats", said: "Let me look.")]
    return request
}

@Suite("Tools")
struct ToolTests {
    @Test("The loop runs what the model asks for and asks again with the result, then stops")
    func loop() async throws {
        let service = RoleService { request in
            request.exchanges.isEmpty ? [.text("Looking."), .toolCall(call)] : [.text("It's about cats.")]
        }
        let ran = Ran()
        let loop = ToolLoop(service: service, tools: [readTab], describe: { _ in "Reading a tab" }) { called in
            await ran.add(called.name)
            return ToolOutput("A page about cats")
        }
        let events = try await collect(loop.reply(to: ChatRequest(model: "m", messages: [Message(role: .user, text: "Hi")])))
        #expect(await ran.names == ["read_tab"])
        #expect(service.requests.count == 2)
        #expect(service.requests[0].tools == [readTab])
        #expect(service.requests[1].exchanges == [ToolExchange(call: call, result: "A page about cats", said: "Looking.")])
        let text = events.compactMap { if case .text(let piece) = $0 { piece } else { nil } }.joined()
        #expect(text == "Looking.\n\nIt's about cats.")
        let steps = events.compactMap { if case .activity(let step) = $0 { step } else { nil } }
        #expect(steps.map(\.done) == [false, true])
        #expect(!events.contains { if case .toolCall = $0 { true } else { false } })
    }

    @Test("Calls of a tool that runs together run at once, and come back in the order asked")
    func together() async throws {
        let spawn = Tool(name: "spawn_agent", description: "A sub-agent")
        let calls = ["a", "b", "c"].map { ToolCall(id: $0, name: "spawn_agent", input: .object(["task": .string($0)])) }
        let service = RoleService { request in request.exchanges.isEmpty ? calls.map { .toolCall($0) } : [.text("Done.")] }
        let ran = Ran()
        let loop = ToolLoop(service: service, tools: [spawn], describe: { _ in "Agent" }, together: ["spawn_agent"]) { called in
            await ran.add("start " + called.id)
            // Each waits for the others to have started: one after another, they never would.
            for _ in 0..<100 where await ran.names.count < 3 { try? await Task.sleep(for: .milliseconds(5)) }
            return ToolOutput((await ran.names.count == 3 ? "with the others " : "alone ") + called.id)
        }
        _ = try await collect(loop.reply(to: ChatRequest(model: "m", messages: [Message(role: .user, text: "Go")])))
        #expect(await ran.names.count == 3)
        #expect(service.requests[1].exchanges.map(\.result) == ["with the others a", "with the others b", "with the others c"])
    }

    @Test("Anthropic is sent the tools, and each call with its result")
    func anthropicRequest() throws {
        let body = try #require(json(AnthropicService(base: URL(string: "https://x")!, key: "k").request(for: asked())))
        #expect(body["tools"]?[0]?["name"]?.string == "read_tab")
        #expect(body["tools"]?[0]?["input_schema"]?["type"]?.string == "object")
        let messages = body["messages"]?.array ?? []
        #expect(messages.count == 3)
        #expect(messages[1]["content"]?[0]?["text"]?.string == "Let me look.")
        #expect(messages[1]["content"]?[1]?["type"]?.string == "tool_use")
        #expect(messages[1]["content"]?[1]?["input"]?["tab"]?.string == "ab12")
        #expect(messages[2]["content"]?[0]?["tool_use_id"]?.string == "c1")
        #expect(messages[2]["content"]?[0]?["content"]?.string == "A page about cats")
    }

    @Test("Anthropic's tool use comes out whole once its block ends")
    func anthropicDecodes() throws {
        var decoder = AnthropicDecoder()
        let lines = [
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"read_tab","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"tab\":"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"ab12\"}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
        ]
        let events = try lines.flatMap { try decoder.read($0) }
        #expect(events == [.toolCall(call)])
    }

    @Test("Chat Completions is sent the tools as functions, and each call with its result")
    func openAIRequest() throws {
        let body = try #require(json(OpenAIChatService(base: URL(string: "https://x")!, key: nil).request(for: asked())))
        #expect(body["tools"]?[0]?["function"]?["name"]?.string == "read_tab")
        let messages = body["messages"]?.array ?? []
        #expect(messages[1]["tool_calls"]?[0]?["function"]?["arguments"]?.string == #"{"tab":"ab12"}"#)
        #expect(messages[2]["role"]?.string == "tool")
        #expect(messages[2]["tool_call_id"]?.string == "c1")
    }

    @Test("Chat Completions' tool calls come in pieces and out whole at the end")
    func openAIDecodes() throws {
        var decoder = OpenAIChatDecoder()
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_tab","arguments":"{\"tab\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"ab12\"}"}}]}}]}"#,
        ]
        #expect(try lines.flatMap { try decoder.read($0) }.isEmpty)
        #expect(try decoder.finish() == [.toolCall(call)])
    }

    @Test("Responses is sent function calls and their output, and reads a call once it's done")
    func responses() throws {
        let body = try #require(json(ResponsesService(base: URL(string: "https://x")!, key: nil).request(for: asked())))
        #expect(body["tools"]?[0]?["name"]?.string == "read_tab")
        let input = body["input"]?.array ?? []
        #expect(input.map { $0["type"]?.string ?? $0["role"]?.string ?? "" } == ["user", "assistant", "function_call", "function_call_output"])
        var decoder = ResponsesDecoder()
        let line =
            #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"read_tab","arguments":"{\"tab\":\"ab12\"}"}}"#
        #expect(try decoder.read(line) == [.toolCall(call)])
    }
}

@Suite("Tool pictures")
struct ToolPictureTests {
    @Test("A screenshot goes to Anthropic as an image beside the words; others are told it can't be shown")
    func pictures() throws {
        var request = ChatRequest(model: "m", messages: [Message(role: .user, text: "Look")])
        request.tools = [Tool(name: "screenshot_tab", description: "Looks")]
        request.exchanges = [ToolExchange(call: ToolCall(id: "s1", name: "screenshot_tab", input: .object([:])), result: "Here it is.", image: Data([1, 2, 3]))]
        let anthropic = try #require(AnthropicService(base: URL(string: "https://x")!, key: "k").request(for: request).httpBody)
        let body = try #require(JSON(parsing: String(decoding: anthropic, as: UTF8.self)))
        let result = body["messages"]?[2]?["content"]?[0]?["content"]
        #expect(result?[1]?["type"]?.string == "image")
        #expect(result?[1]?["source"]?["data"]?.string == Data([1, 2, 3]).base64EncodedString())
        let chat = try #require(OpenAIChatService(base: URL(string: "https://x")!, key: nil).request(for: request).httpBody)
        #expect(String(decoding: chat, as: UTF8.self).contains("can't be shown it here"))
    }
}

@Suite("Tools for agents")
struct AgentToolTests {
    private static let server = ToolServer(url: URL(string: "http://127.0.0.1:4567/mcp")!, token: "secret")
    private static func request() -> ChatRequest {
        var request = ChatRequest(model: "", messages: [Message(role: .user, text: "Hi")])
        request.tools = [Tool(name: "list_tabs", description: "Tabs")]
        request.toolServer = server
        return request
    }
    private static let program = URL(fileURLWithPath: "/bin/agent")
    private static let folder = URL(fileURLWithPath: "/tmp/mote-agent")

    @Test("An agent gets Mote's server with the token in its environment, never in its arguments")
    func everyAgent() {
        let commands = [
            ClaudeCodeAgent().command(for: Self.request(), executable: Self.program, workspace: Self.folder),
            CodexAgent().command(for: Self.request(), executable: Self.program, workspace: Self.folder),
            OpenCodeAgent().command(for: Self.request(), executable: Self.program, workspace: Self.folder),
            GeminiCLIAgent().command(for: Self.request(), executable: Self.program, workspace: Self.folder),
        ]
        for command in commands {
            #expect(command.environment[ToolServer.tokenVariable] == "secret")
            #expect(!command.arguments.joined(separator: " ").contains("secret"))
            let said = command.arguments.joined(separator: " ") + (command.environment["OPENCODE_CONFIG_CONTENT"] ?? "")
                + command.files.values.joined()
            #expect(said.contains("127.0.0.1:4567/mcp"))
        }
        #expect(commands[0].arguments.contains("mcp__mote"))
        // A tool may take an hour: a question the person answers later, a sub-agent's task.
        #expect(commands[0].environment["MCP_TOOL_TIMEOUT"] == "3600000")
        #expect(commands[1].arguments.contains("mcp_servers.mote.tool_timeout_sec=3600"))
        #expect(commands[3].files.values.joined().contains("3600000"))
        #expect(commands[3].files.keys.first?.path == "/tmp/mote-agent/.gemini/settings.json")
    }

    @Test("Without tools, no server")
    func none() {
        var request = Self.request()
        request.tools = []
        let claude = ClaudeCodeAgent().command(for: request, executable: Self.program, workspace: Self.folder)
        #expect(claude.arguments.contains(#"{"mcpServers":{}}"#))
        #expect(claude.environment.isEmpty)
    }
}

private actor Ran {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
