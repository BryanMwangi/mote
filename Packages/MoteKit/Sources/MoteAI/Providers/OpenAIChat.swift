import Foundation

/// The Chat Completions API that OpenAI made and most others copied: OpenAI,
/// OpenRouter, Groq, Mistral, DeepSeek, xAI, Gemini's compatible endpoint,
/// and the servers that run models on the Mac (Ollama, LM Studio).
public struct OpenAIChatService: ChatService {
    /// Up to the version, such as `https://api.openai.com/v1`.
    let base: URL
    let key: String?
    let headers: [String: String]
    /// Searches by asking for the model's `:online` variant, as OpenRouter offers.
    let online: Bool
    let transport: HTTPTransport

    public init(
        base: URL, key: String?, headers: [String: String] = [:], online: Bool = false, transport: HTTPTransport = URLSessionTransport()
    ) {
        self.base = base
        self.key = key
        self.headers = headers
        self.online = online
        self.transport = transport
    }

    public func reply(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let http = self.request(for: request)
        let transport = transport
        return .decoding({ try await transport.lines(for: http) }, with: OpenAIChatDecoder())
    }

    func request(for chat: ChatRequest) -> URLRequest {
        var messages: [[String: Any]] = []
        if let instructions = chat.instructions, !instructions.isEmpty { messages.append(["role": "system", "content": instructions]) }
        messages += chat.messages.filter { !$0.text.isEmpty }.map { ["role": $0.role.rawValue, "content": $0.text] }
        for exchange in chat.exchanges {
            let call: [String: Any] = [
                "id": exchange.call.id, "type": "function", "function": ["name": exchange.call.name, "arguments": exchange.call.input.encoded],
            ]
            messages.append(["role": "assistant", "content": exchange.said.isEmpty ? NSNull() : exchange.said, "tool_calls": [call]])
            messages.append(["role": "tool", "tool_call_id": exchange.call.id, "content": exchange.result])
        }
        var request = authorized(URLRequest(url: base.appending(path: "chat/completions")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let model = online && chat.search && !chat.model.hasSuffix(":online") ? chat.model + ":online" : chat.model
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if !chat.tools.isEmpty {
            body["tools"] = chat.tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters.plain]]
            }
        }
        request.httpBody = Data(JSON.encode(body).utf8)
        return request
    }

    /// The models the endpoint lists, by name.
    public func models() async throws -> [Model] {
        let data = try await transport.data(for: authorized(URLRequest(url: base.appending(path: "models"))))
        guard let json = JSON(parsing: String(decoding: data, as: UTF8.self)) else { throw AIError.malformed("model list") }
        // OpenAI and most others answer `data`; a few older servers `models`.
        let listed = json["data"]?.array ?? json["models"]?.array ?? []
        return listed.compactMap { entry in
            (entry["id"]?.string ?? entry["name"]?.string).map { Model(id: $0, name: entry["name"]?.string) }
        }
        .filter { Self.chats($0.id) }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Whether a listed model can hold a chat: lists mix in models for
    /// embeddings, speech, images and moderation, which these requests refuse.
    static func chats(_ id: String) -> Bool {
        let id = id.lowercased()
        return !["embed", "tts", "whisper", "dall-e", "moderation", "image", "transcribe", "audio", "realtime", "rerank"].contains {
            id.contains($0)
        }
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

public struct OpenAIChatDecoder: LineDecoder {
    /// Tool calls arriving in pieces, by their index in the reply.
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    public init() {}

    /// The tool calls, whole, once the reply has ended.
    public mutating func finish() throws -> [ChatEvent] {
        defer { calls = [:] }
        return calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return .toolCall(ToolCall(id: call.id, name: call.name, input: JSON(parsing: call.arguments) ?? .object([:])))
        }
    }

    public mutating func read(_ line: String) throws -> [ChatEvent] {
        guard let data = ServerSentEvents.data(in: line), data != "[DONE]", let json = JSON(parsing: data) else { return [] }
        if let error = json["error"], error != .null {
            throw AIError.failed(error["message"]?.string ?? error.string ?? "The provider reported an error")
        }
        var events: [ChatEvent] = []
        if let delta = json["choices"]?[0]?["delta"] {
            // DeepSeek and Ollama name the thinking `reasoning_content`, OpenRouter `reasoning`.
            for key in ["reasoning_content", "reasoning"] {
                if let text = delta[key]?.string, !text.isEmpty { events.append(.reasoning(text)) }
            }
            if let text = delta["content"]?.string, !text.isEmpty { events.append(.text(text)) }
            for call in delta["tool_calls"]?.array ?? [] {
                let index = call["index"]?.int ?? 0
                var whole = calls[index] ?? ("", "", "")
                if let id = call["id"]?.string { whole.id = id }
                if let name = call["function"]?["name"]?.string { whole.name += name }
                whole.arguments += call["function"]?["arguments"]?.string ?? ""
                calls[index] = whole
            }
            // Gateways that search (OpenRouter) cite their pages alongside.
            for annotation in delta["annotations"]?.array ?? [] {
                let citation = annotation["url_citation"] ?? annotation
                guard let address = citation["url"]?.string, let url = URL(string: address) else { continue }
                events.append(.source(Source(url: url, title: citation["title"]?.string ?? "")))
            }
        }
        if let usage = json["usage"], let input = usage["prompt_tokens"]?.int {
            events.append(.usage(Usage(input: input, output: usage["completion_tokens"]?.int ?? 0)))
        }
        return events
    }
}
