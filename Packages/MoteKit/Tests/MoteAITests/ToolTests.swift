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
            return "A page about cats"
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

private actor Ran {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
