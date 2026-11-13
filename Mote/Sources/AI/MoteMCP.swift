import Foundation
import MoteAI
import Network

/// Mote's tools over MCP, for an agent on the Mac (Claude Code) that calls
/// them itself: JSON-RPC over HTTP on 127.0.0.1, behind a token made at
/// launch that only the agents Mote starts are given. Started the first
/// time an agent is asked something with tools on. The tools are
/// AssistantTools, so they do what they do for the API providers, asking
/// the person before anything is done in a page.
@MainActor
final class MoteMCP {
    static let shared = MoteMCP()

    /// The tools for the turn under way, set as it's asked.
    var tools: AssistantTools?
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var port: UInt16?

    /// Where the agent finds it; nil until it's listening.
    var server: ToolServer? {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return nil }
        return ToolServer(url: url, token: token)
    }

    /// Listens, if it isn't, and waits until it is (a second at most).
    func start() async -> ToolServer? {
        if let server { return server }
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            guard let made = try? NWListener(using: parameters) else { return nil }
            made.newConnectionHandler = { connection in
                MainActor.assumeIsolated { MoteMCP.shared.serve(connection) }
            }
            made.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    if case .ready = state { MoteMCP.shared.port = made.port?.rawValue }
                }
            }
            made.start(queue: .main)
            listener = made
        }
        for _ in 0..<20 where port == nil { try? await Task.sleep(for: .milliseconds(50)) }
        return server
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, into: Data())
    }

    /// Reads one request (headers and its body), answers it, and closes.
    private func read(_ connection: NWConnection, into had: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            MainActor.assumeIsolated {
                var got = had
                if let data { got.append(data) }
                guard error == nil, got.count < 4 << 20 else { return connection.cancel() }
                guard let request = HTTPRequest(got) else {
                    if done { connection.cancel() } else { self.read(connection, into: got) }
                    return
                }
                Task { @MainActor in
                    let (status, body) = await self.answer(request)
                    var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    if !body.isEmpty { head += "Content-Type: application/json\r\n" }
                    connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private func answer(_ request: HTTPRequest) async -> (String, Data) {
        guard request.headers["authorization"] == "Bearer \(token)" else { return ("401 Unauthorized", Data()) }
        guard request.method == "POST" else { return ("405 Method Not Allowed", Data()) }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
            let method = message["method"] as? String
        else { return ("400 Bad Request", Data()) }
        // A notification wants no answer.
        guard let id = message["id"] else { return ("202 Accepted", Data()) }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]], "serverInfo": ["name": "Mote", "version": "1"],
            ]
        case "tools/list":
            result = ["tools": (tools?.list ?? []).map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }]
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = (params?["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let input = arguments.flatMap { JSON(parsing: String(decoding: $0, as: UTF8.self)) } ?? .object([:])
            guard let tools else {
                result = ["content": [["type": "text", "text": "Mote's tools are off."]], "isError": true]
                break
            }
            let said = await tools.run(ToolCall(id: UUID().uuidString, name: name, input: input))
            result = ["content": [["type": "text", "text": said]], "isError": false]
        case "ping":
            result = [:]
        default:
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "No such method"]]
            return ("200 OK", (try? JSONSerialization.data(withJSONObject: error)) ?? Data())
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return ("200 OK", (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }
}

/// An HTTP request, once its headers and body have all come.
private struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " ").first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        method = String(first)
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
