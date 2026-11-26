import Foundation
import MoteAI
import MoteCore

/// Sub-agents: the assistant hands a self-contained part of the work to an
/// agent of its own, which works through it with the same tools and reports
/// back. Starting one returns at once, so a long task never holds a tool call
/// open: the assistant goes on, or waits for reports with wait_agents. Each
/// shows in the chat as a step saying what it's doing and what it has spent.
/// One level only: an agent can't start agents.
extension AssistantTools {
    var agentTools: [Tool] {
        guard spawn != nil else { return [] }
        return [
            Tool(
                name: "spawn_agent",
                description:
                    "Starts a sub-agent with your tools on a self-contained part of the work, and returns at once with its id while it works. Start several to work on separate parts at once (research two topics, fill forms in several tabs). Give it everything it needs in task: it doesn't see this chat. Collect what it reports with wait_agents.",
                schema: #"{"type":"object","properties":{"task":{"type":"string","description":"What to do and what to report, complete on its own"}},"required":["task"]}"#
            ),
            Tool(
                name: "wait_agents",
                description:
                    "Waits for sub-agents to finish, up to seconds (default 300, at most 600): the reports of those done or stopped, and for each still working, the tab it's on and what it's doing. Without ids, all this chat's agents whose reports you haven't had; with ids, those, reports given before included. Call it again to keep waiting.",
                schema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"seconds":{"type":"integer"}}}"#
            ),
            Tool(
                name: "stop_agent",
                description: "Stops a sub-agent that is still working, keeping what it had written.",
                schema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
            ),
        ]
    }

    func runAgents(_ call: ToolCall) async -> ToolOutput? {
        guard ["spawn_agent", "wait_agents", "stop_agent"].contains(call.name), let spawn else { return nil }
        switch call.name {
        case "spawn_agent":
            guard let task = call.input["task"]?.string, !task.isEmpty else {
                return ToolOutput("Give the agent its task.", outcome: .failed)
            }
            let run = AgentRuns.shared.start(task, chat: chat, work: spawn)
            return ToolOutput(
                "Started agent \(run.id). It works on while you go on; wait_agents gives its report.", detail: "Agent \(run.id) started")
        case "wait_agents":
            let ids = call.input["ids"].map { $0.array.compactMap(\.string).map { $0.uppercased() } }
            let seconds = min(600, max(1, call.input["seconds"]?.int ?? 300))
            return ToolOutput(await AgentRuns.shared.wait(ids, chat: chat, seconds: seconds, call: overMCP ? call.id : nil))
        default:
            let id = call.input["id"]?.string?.uppercased() ?? ""
            return ToolOutput(AgentRuns.shared.stop(id, chat: chat, call: overMCP ? call.id : nil))
        }
    }

    /// A sub-agent's run: `task` through `base` with fresh tools of its own,
    /// over MCP for an agent on the Mac, telling `news` of each step as it
    /// starts and ends, the tab it works on, and what it has spent. Its tokens
    /// count toward the chat's.
    static func runAgent(
        _ task: String, through base: any ChatService, model: String, overMCP: Bool, chat: UUID?, driver: String,
        news: @escaping @MainActor (AgentNews) -> Void = { _ in }
    ) async -> ToolOutput {
        guard let tools = AssistantTools.current(chat: chat, driver: driver) else {
            return ToolOutput("Mote's tools are off.", outcome: .failed)
        }
        tools.subAgent = true
        tools.overMCP = overMCP
        tools.onTab = { news(.tab($0)) }
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
                case .activity(let step):
                    if step.done { steps += 1 }
                    news(.step(step))
                case .usage(let used):
                    spent = spent + used
                    news(.spent(spent ?? used))
                case .spending(let sofar): news(.spent(spent.map { $0 + sofar } ?? sofar))
                default: break
                }
            }
        } catch {
            let had = text.isEmpty ? "" : "\n\nIt had written:\n" + text
            let why = error is CancellationError ? "it was stopped" : error.localizedDescription
            return ToolOutput("The agent stopped: \(why)" + had, outcome: .failed)
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

/// What a sub-agent tells as it works.
enum AgentNews {
    case step(Activity)
    case spent(Usage)
    case tab(Tab)
}

/// The sub-agents at work and done, by chat: what each is doing and where,
/// what it has spent, and its report until the assistant has had it.
@MainActor
final class AgentRuns {
    static let shared = AgentRuns()

    final class Run {
        let id: String
        let chat: UUID?
        let task: String
        var job: Task<Void, Never>?
        var doing = "Starting"
        var steps = 0
        var spent: Usage?
        var report: ToolOutput?
        /// The tab it last worked on, and when it last did anything.
        weak var tab: Tab?
        var heard = Date()
        /// Stopped with stop_agent.
        var stopped = false
        /// The assistant has had its report; or the call that carries it,
        /// until that answer is known to have reached the agent.
        var told = false
        var telling: String?

        init(id: String, chat: UUID?, task: String) {
            self.id = id
            self.chat = chat
            self.task = task
        }

        var working: Bool { report == nil }

        /// Its step in the chat.
        var step: Activity {
            let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
            let title = "Agent \(id) · " + (line.count > 70 ? String(line.prefix(69)) + "…" : line)
            let outcome: Activity.Outcome? = report.map { $0.outcome == .failed ? .failed : .done }
            var step = Activity(
                id: "agent-\(id)", title: title, done: report != nil, kind: .agent, outcome: outcome,
                detail: report == nil ? doing : report?.detail)
            step.spent = spent.map { $0.input + $0.output }
            return step
        }

        /// How it stands, for the assistant: where, doing what, since when.
        var standing: String {
            let since = Int(Date().timeIntervalSince(heard))
            let place = tab.map { " on “\($0.label)” (\(AssistantTools.id($0)))" } ?? ""
            if stopped { return "Agent \(id), stopping\(place)." }
            return "Agent \(id), working\(place): \(doing), \(steps) step\(steps == 1 ? "" : "s") so far, last \(since) s ago."
        }
    }

    private var runs: [Run] = []
    private var made = 0

    /// Starts `task` through `work`, shown in the chat, and returns at once.
    func start(
        _ task: String, chat: UUID?, work: @escaping (String, String, @escaping @MainActor (AgentNews) -> Void) async -> ToolOutput
    ) -> Run {
        made += 1
        let run = Run(id: "A\(made)", chat: chat, task: task)
        runs.append(run)
        // Kept for asking after, not for good: the oldest finished runs whose
        // reports have been had go once there are more than 30.
        while runs.count > 30, let old = runs.firstIndex(where: { $0.told && $0.report != nil }) { runs.remove(at: old) }
        show(run)
        run.job = Task { [weak self] in
            let report = await work(task, run.id) { [weak self, weak run] news in
                guard let self, let run, run.working else { return }
                run.heard = Date()
                switch news {
                case .spent(let spent): run.spent = spent
                case .tab(let tab): run.tab = tab
                case .step(let step):
                    run.doing = step.done ? "between steps" : step.title
                    if step.done { run.steps += 1 }
                    // Its own step, under it in the chat.
                    var own = step
                    own.id = "agent-\(run.id)-\(step.id)"
                    return self.show(run, step: own)
                }
                self.show(run)
            }
            guard let self, run.working else { return }
            run.report =
                run.stopped
                ? ToolOutput(
                    "Stopped after \(run.steps) step\(run.steps == 1 ? "" : "s"). What it had written:\n\(report.text)", outcome: .failed,
                    detail: "Stopped")
                : report
            show(run)
            followUp(run.chat)
        }
        return run
    }

    /// Waits up to `seconds` for the runs named (or all this chat's untold
    /// ones) to finish: the reports of those done, a line for each still
    /// working, read when it answers. Over MCP (`call`), a report counts as
    /// had only once that answer has reached the agent (see `delivered`).
    func wait(_ ids: [String]?, chat: UUID?, seconds: Int, call: String?) async -> String {
        let chosen = { self.runs.filter { $0.chat == chat && (ids?.contains($0.id) ?? !$0.told) } }
        guard !chosen().isEmpty else { return ids == nil ? "No agents are working, and every report has been given." : "No agent has those ids." }
        let end = ContinuousClock.now + .seconds(seconds)
        while chosen().contains(where: \.working), ContinuousClock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return chosen().map { run in
            guard let report = run.report else { return run.standing }
            tell(run, by: call)
            let how = run.stopped ? "stopped" : report.outcome == .failed ? "failed" : "done, \(report.detail ?? "")"
            return "Agent \(run.id) (\(how)):\n\(report.text)"
        }.joined(separator: "\n\n")
    }

    func stop(_ id: String, chat: UUID?, call: String?) -> String {
        guard let run = runs.first(where: { $0.id == id && $0.chat == chat }) else { return "No agent has that id." }
        guard run.working else {
            if run.told { return "Agent \(id) had already finished, and its report was given." }
            tell(run, by: call)
            return "Agent \(id) had already finished. Its report:\n\(run.report?.text ?? "")"
        }
        run.stopped = true
        run.job?.cancel()
        return "Stopping agent \(id) after \(run.steps) step\(run.steps == 1 ? "" : "s"); wait_agents gives what it had written."
    }

    /// A report handed to the assistant: had at once in a reply of Mote's
    /// own, or once the MCP answer `call` is sent (`delivered`).
    private func tell(_ run: Run, by call: String?) {
        if let call { run.telling = call } else { run.told = true }
    }

    /// The MCP answer to `call` reached the agent: what it carried is had.
    func delivered(_ call: String) {
        for run in runs where run.telling == call {
            run.told = true
            run.telling = nil
        }
    }

    private func show(_ run: Run, step: Activity? = nil) {
        guard let chat = run.chat, let conversation = Assistant.shared.conversation(chat) else { return }
        conversation.show(step: run.step)
        if let step { conversation.show(step: step, beside: run.step.id) }
    }

    /// Once the chat's agents are all done, reports the assistant hasn't had
    /// go to it in a turn of their own, when its reply is over.
    private func followUp(_ chat: UUID?) {
        guard let chat, !runs.contains(where: { $0.chat == chat && $0.working }) else { return }
        Task { [weak self] in
            while let conversation = Assistant.shared.conversation(chat), conversation.busy {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, let conversation = Assistant.shared.conversation(chat) else { return }
            let untold = runs.filter { $0.chat == chat && !$0.told && !$0.working }
            guard !untold.isEmpty else { return }
            untold.forEach { $0.told = true }
            let reports = untold.map { "Agent \($0.id), on “\($0.task.prefix(80))”:\n\($0.report?.text ?? "")" }
            Assistant.shared.ask(
                "Your sub-agents finished after your last reply. Their reports:\n\n" + reports.joined(separator: "\n\n")
                    + "\n\nCarry on with the task from here.", in: conversation, quiet: true)
        }
    }
}
