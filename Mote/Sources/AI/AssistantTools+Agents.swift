import Foundation
import MoteAI
import MoteCore

/// Sub-agents: the assistant hands a self-contained part of the work to an
/// agent of its own, which works through it with the same tools and reports
/// back. Several started in one round work at once. One level only: an
/// agent can't start agents.
extension AssistantTools {
    var agentTools: [Tool] {
        guard spawn != nil else { return [] }
        return [
            Tool(
                name: "spawn_agent",
                description:
                    "Hands a self-contained part of the work to a sub-agent with your tools, which does it and reports back what it found or did. Start several in one go to work on separate parts at once (research two topics, check several tabs). Give it everything it needs in task: it doesn't see this chat.",
                schema: #"{"type":"object","properties":{"task":{"type":"string","description":"What to do and what to report, complete on its own"}},"required":["task"]}"#
            )
        ]
    }

    func runAgents(_ call: ToolCall) async -> ToolOutput? {
        guard call.name == "spawn_agent", let spawn else { return nil }
        guard let task = call.input["task"]?.string, !task.isEmpty else {
            return ToolOutput("Give the agent its task.", outcome: .failed)
        }
        return await spawn(task)
    }

    /// A sub-agent's run: `task` through `base` with fresh tools of its own,
    /// over MCP for an agent on the Mac. Its tokens count toward the chat's.
    static func runAgent(
        _ task: String, through base: any ChatService, model: String, overMCP: Bool, chat: UUID?, driver: String
    ) async -> ToolOutput {
        guard let tools = AssistantTools.current(chat: chat, driver: driver) else {
            return ToolOutput("Mote's tools are off.", outcome: .failed)
        }
        let server = overMCP ? await MoteMCP.shared.server(for: tools) : nil
        let loop = ToolLoop(service: base, tools: tools.list, server: server, describe: AssistantTools.describe) { call in
            await tools.run(call)
        }
        let request = ChatRequest(model: model, messages: [Message(role: .user, text: task)], instructions: Self.agentBrief)
        var text = ""
        var steps = 0
        var spent: Usage?
        defer { if let spent, let chat { Assistant.shared.conversation(chat)?.count(spent) } }
        do {
            for try await event in loop.reply(to: request) {
                switch event {
                case .text(let more): text += more
                case .activity(let step) where step.done: steps += 1
                case .usage(let used): spent = spent + used
                default: break
                }
            }
        } catch {
            let had = text.isEmpty ? "" : "\n\nIt had written:\n" + text
            return ToolOutput("The agent stopped: \(error.localizedDescription)" + had, outcome: .failed)
        }
        let done = "Done after \(steps) step\(steps == 1 ? "" : "s")"
        return ToolOutput(text.isEmpty ? "The agent finished without a report." : text, detail: done)
    }

    private static let agentBrief = """
        You are a sub-agent working for another assistant in Mote, a web browser. Do the task you're given with \
        your tools, then answer with a short report of what you found or did: facts, addresses and results, \
        not the steps. Nobody sees this but that assistant.
        """
}
