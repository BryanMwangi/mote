import AppKit
import Combine
import MoteAI
import MoteCore
import WebKit

/// How a chat acts, switched with ⇧⇥ for that chat only, until switched
/// back or Mote quits. Asks: it asks before acting. Auto: it acts without
/// asking; what it does can be undone, and only what can't be (deleting
/// history) still asks. Plan: it only looks, and ends with a plan to approve.
enum ChatMode: String, CaseIterable {
    case asks, auto, plan

    var next: ChatMode { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

@MainActor
final class ChatModes: ObservableObject {
    static let shared = ChatModes()
    @Published private var modes: [UUID: ChatMode] = [:]
    /// What a chat was in before Plan, to go back to when the plan runs.
    private var beforePlan: [UUID: ChatMode] = [:]

    func mode(of chat: UUID) -> ChatMode { modes[chat] ?? .asks }

    func set(_ chat: UUID, _ mode: ChatMode) {
        if mode == .plan, self.mode(of: chat) != .plan { beforePlan[chat] = self.mode(of: chat) }
        modes[chat] = mode
    }

    func toggle(_ chat: UUID) { set(chat, mode(of: chat).next) }

    /// Out of Plan, into what it was before.
    func leavePlan(_ chat: UUID) { set(chat, beforePlan.removeValue(forKey: chat) ?? .asks) }

    /// Chats set apart from Settings › AI › Work in the background (/background).
    @Published private var behind: [UUID: Bool] = [:]

    /// Whether the chat's agents leave the tab in front alone, working on theirs behind it.
    func worksBehind(_ chat: UUID, else setting: Bool) -> Bool { behind[chat] ?? setting }

    /// Switches it for the chat; what it is now.
    func toggleBehind(_ chat: UUID, else setting: Bool) -> Bool {
        let now = !worksBehind(chat, else: setting)
        behind[chat] = now
        return now
    }
}

/// What the assistant may ask Mote to do while it answers (Settings › AI ›
/// Tools): read the tabs, any page, history and bookmarks; and, with Act for
/// you, manage tabs and act in pages, asking by how much is at stake (see
/// `permit`). Never in private tabs, never a password back.
///
/// The tools are grouped by what they work on: tabs (+Tabs), pages (+Page),
/// the person's data (+Data). Each group answers the calls it knows.
@MainActor
final class AssistantTools {
    let browser: Browser
    let acts: Bool
    let chat: UUID?
    /// Who's asking, for the page's pill ("Claude Code").
    let driver: String
    /// A coding agent Mote didn't start, over MCP: it sees and acts only on
    /// the developer sites (Settings › AI), never asks, and never reads the
    /// person's other tabs, history or bookmarks.
    let outside: Bool
    /// This turn, for undoing all it did together (AssistantLedger).
    let turn = UUID()
    /// Starts a sub-agent on a task (see AssistantTools+Agents); nil for a
    /// sub-agent's own tools, and an outside agent's.
    var spawn: ((String, String, @escaping @MainActor (AgentNews) -> Void) async -> ToolOutput)?
    /// Its tools are served over MCP to an agent on the Mac.
    var overMCP = false
    /// Told each tab this agent starts a step on (a sub-agent's run notes where it is).
    var onTab: ((Tab) -> Void)?
    /// The tabs this agent has started acting on: each comes forward once,
    /// when it starts, and after that it works on it wherever it is.
    var begun: Set<ObjectIdentifier> = []
    /// What read_tab last gave this agent for each tab, so the same again
    /// isn't sent again: every result stays in the chat the model rereads.
    var lastRead: [ObjectIdentifier: (text: String, outline: String)] = [:]
    /// Sites this chat may act on without asking again.
    private static var trusted: [UUID: Set<String>] = [:]

    /// The tools on now for the window in front, or nil with none on.
    static func current(chat: UUID?, driver: String = "Assistant") -> AssistantTools? {
        guard let browser = Browser.front ?? Windows.shared.main, browser.prefs.aiReads else { return nil }
        return AssistantTools(browser: browser, acts: browser.prefs.aiActs, chat: chat, driver: driver, outside: false)
    }

    /// For a coding agent from outside (Settings › General › Let coding agents use Mote).
    static func outside(driver: String) -> AssistantTools? {
        guard let browser = Browser.front ?? Windows.shared.main, browser.prefs.agentsUseMote else { return nil }
        return AssistantTools(browser: browser, acts: true, chat: nil, driver: driver, outside: true)
    }

    private init(browser: Browser, acts: Bool, chat: UUID?, driver: String, outside: Bool) {
        self.browser = browser
        self.acts = acts
        self.chat = chat
        self.driver = driver
        self.outside = outside
        AssistantLedger.shared.begin(turn, chat: chat)
    }

    var prefs: Preferences { browser.prefs }

    /// One of the sites developer tools may work on freely.
    func developerSite(_ url: URL?) -> Bool { SiteList.contains(prefs.aiDevSites, url) }

    /// The developer tools are offered: Developer mode, or an agent from outside.
    var developing: Bool { outside || (acts && prefs.aiMode == .developer) }

    /// The agent starts a step on a tab's page: shown there, holding the page
    /// from the person while its turn goes on.
    func working(on tab: Tab, _ caption: String) {
        let chat = chat
        tab.agent.begin(caption, by: driver, stop: stopTurn) { chat.flatMap { Assistant.shared.conversation($0) }?.busy == true }
    }

    /// Asks the person in the chat, telling them through macOS when they
    /// can't see it; the notice goes once they answer.
    func asking(_ conversation: Conversation, _ question: Conversation.Question) async -> String? {
        let unseen = !WebNotifications.sees(chat: conversation.id)
        if unseen { Task { await WebNotifications.shared.tell(chat: conversation.id, "\(driver) asks", question.text) } }
        defer { if unseen { WebNotifications.shared.untell(chat: conversation.id) } }
        return await conversation.ask(question)
    }

    /// Why the agent may not act on the tab now: the person took it.
    func taken(_ tab: Tab) -> String? {
        guard tab.agent.held else { return nil }
        return "The person took control of \(Self.line(tab)) and is using it. Don't act on it until they hand it back; work elsewhere, or ask them with ask_person."
    }

    /// Stops this turn: the pill's Stop.
    var stopTurn: (() -> Void)? {
        guard let chat else { return nil }
        return { Assistant.shared.stop(chat: chat) }
    }

    /// A sub-agent's: only what a part of the work needs, so each of its
    /// many calls carries fewer tool definitions.
    var subAgent = false

    var list: [Tool] {
        outside || subAgent
            ? tabTools + pageTools + pdfTools + workTools + (subAgent ? fileTools : []) + devTools
            : tabTools + spaceTools + pageTools + pdfTools + workTools + fileTools + signInTools + devTools + dataTools + ledgerTools + askTools
                + taskTools
                + agentTools
    }

    /// The step's line in the chat.
    nonisolated static func describe(_ call: ToolCall) -> String {
        ToolLoop.title(of: call.name, input: call.input)
    }

    func run(_ call: ToolCall) async -> ToolOutput {
        var said = await dispatch(call)
        if said.outcome == .done { said.outcome = outcome(of: said.text) }
        // Every result goes back to the model each round after: a long one
        // is cut, and said so, rather than filling the chat's room.
        if said.text.count > Self.longest {
            said.text = String(said.text.prefix(Self.longest))
                + "\n…cut here, \(said.text.count - Self.longest) more characters. Ask for less (a selector, a filter, a smaller part)."
        }
        // What the person added while it worked goes with this result.
        if let chat, let added = Assistant.shared.conversation(chat)?.takeSteering() {
            if said.detail == nil { said.detail = said.line }
            said.text += "\n\n[The person added while you worked: \(added)]"
        }
        return said
    }

    /// The most of any tool's result given back.
    static let longest = 40_000

    private func dispatch(_ call: ToolCall) async -> ToolOutput {
        if let said = await runAgents(call) { return said }
        if let said = await runDev(call) { return said }
        if let said = await runTab(call) { return ToolOutput(said) }
        if let said = await runPage(call) { return ToolOutput(said) }
        if let said = await runPDF(call) { return ToolOutput(said) }
        if let said = await runWork(call) { return ToolOutput(said) }
        if !outside, let said = await runSpaces(call) { return ToolOutput(said) }
        if !outside, let said = await runLedger(call) { return ToolOutput(said) }
        if !outside, let said = await runTasks(call) { return ToolOutput(said) }
        if !outside, let said = await runSignIn(call) { return ToolOutput(said) }
        if !outside, let said = await runFiles(call) { return ToolOutput(said) }
        if !outside, let said = await runData(call) { return ToolOutput(said) }
        if !outside, let said = await runAsk(call) { return ToolOutput(said) }
        return ToolOutput("There's no tool called \(call.name).", outcome: .failed)
    }

    /// How a tool's answer went, for its step in the chat: said no to, or
    /// failed, by the words the tools use for those.
    private func outcome(of text: String) -> Activity.Outcome {
        if text == refused || text == Self.declined || text == Self.planOnly || text == Self.actingOff || text.hasPrefix("The person didn't") { return .refused }
        let fine = ["No tabs match", "No history matches", "Nothing found", "None found"]
        if fine.contains(where: text.hasPrefix) { return .done }
        let failures = [
            "There's no", "That isn't", "That field can't", "That tab has no", "None of", "No ", "Not there", "The page didn't",
            "The page changed", "The page's", "Give ", "Say where", "It couldn't", "Nothing has", "Element ", "Mote never", "Mote has no", "Nothing moved",
            "Couldn't", "Can't",
        ]
        return failures.contains(where: text.hasPrefix) ? .failed : .done
    }

    // MARK: - Asking the person

    var askTools: [Tool] {
        guard chat != nil else { return [] }
        return [
            Tool(
                name: "ask_person",
                description:
                    "Asks the person in the chat and waits for their answers. Use it when what they want is unclear, or there's a real choice that's theirs (which of several tabs, which approach), rather than guessing. Ask one question, or up to 4 together when you need several things decided; they're shown one after another and the answers come back together. Give each 2 to 4 short options, the one you'd suggest first; they can always write their own answer instead. Not for permission to act: Mote asks that itself.",
                schema: #"""
                    {"type":"object","properties":{"questions":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"question":{"type":"string","description":"The question, complete and on its own"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string","description":"A few words"},"description":{"type":"string","description":"What picking it means"}},"required":["label"]},"description":"2 to 4 choices"},"multi_select":{"type":"boolean","description":"More than one may be picked"}},"required":["question","options"]}}},"required":["questions"]}
                    """#)
        ]
    }

    func runAsk(_ call: ToolCall) async -> String? {
        guard call.name == "ask_person" else { return nil }
        guard let chat, let conversation = Assistant.shared.conversation(chat) else { return "There's no chat to ask in." }
        // A list of questions; one given on its own, as the tool once took, counts too.
        let asked = call.input["questions"]?.array ?? (call.input["question"] != nil ? [call.input] : [])
        let questions = asked.prefix(4).compactMap { item -> Conversation.Question? in
            guard let text = item["question"]?.string, !text.isEmpty else { return nil }
            let options = (item["options"]?.array ?? []).prefix(4).compactMap { option -> Conversation.Question.Option? in
                guard let label = option["label"]?.string ?? option.string, !label.isEmpty else { return nil }
                return .init(label: label, description: option["description"]?.string)
            }
            return Conversation.Question(text: text, options: Array(options), several: item["multi_select"]?.bool == true)
        }
        guard !questions.isEmpty else { return "Give the question to ask." }
        var answers: [String] = []
        for (index, question) in questions.enumerated() {
            var question = question
            if questions.count > 1 { question.place = "\(index + 1) of \(questions.count)" }
            let got = answers.isEmpty ? "" : " Answered before then: " + answers.joined(separator: "; ") + "."
            guard let answer = await asking(conversation, question) else {
                return "The person didn't answer: the reply was stopped." + got
            }
            if answer == Conversation.dismissed {
                return "The person closed the question without answering." + got
                    + " Don't wait for an answer: carry on as best you can, and say what you assumed."
            }
            answers.append(questions.count == 1 ? answer : "“\(question.text)” → \(answer)")
        }
        return questions.count == 1 ? "The person answered: \(answers[0])" : "The person answered:\n" + answers.map { "- " + $0 }.joined(separator: "\n")
    }

    // MARK: - Undoing what was done

    var ledgerTools: [Tool] {
        [
            Tool(
                name: "undo_actions",
                description:
                    "Undoes what you did in this chat: by the ids your tools gave (\"Undo with undo_actions [...]\"), or everything in your last turn (last_turn: true). With neither, lists what can still be undone.",
                schema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"last_turn":{"type":"boolean"}}}"#)
        ]
    }

    func runLedger(_ call: ToolCall) async -> String? {
        guard call.name == "undo_actions" else { return nil }
        let ledger = AssistantLedger.shared
        var ids = call.input["ids"]?.array.compactMap(\.string) ?? []
        if call.input["last_turn"]?.bool == true { ids += ledger.lastTurn(in: chat).map(\.id) }
        guard !ids.isEmpty else {
            let open = ledger.open(in: chat)
            return open.isEmpty ? "Nothing you did in this chat is left to undo." : open.map { "\($0.id)\t\($0.what)" }.joined(separator: "\n")
        }
        guard await permit(.gentle, "") else { return refused }
        return (await ledger.undo(ids, in: chat)).joined(separator: "\n")
    }

    // MARK: - How much is at stake

    /// What a tool does, for how it's allowed.
    enum Risk {
        /// Only looks: never asks.
        case read
        /// Changes little and is easily undone (bringing a tab forward, muting):
        /// needs Act for you, never asks.
        case gentle
        /// Acts in a page, on a site: asks, unless this chat may act there.
        case inPage(URL)
        /// Closes, moves or deletes: asks every time, naming what it touches,
        /// unless the chat is on Auto (it can all be undone).
        case destructive
        /// Can't be undone (deleting history): asks every time, Auto or not.
        case irreversible
    }

    /// Whether the assistant may go ahead; asks the person when the risk says
    /// to. `question` names what would be done.
    /// Ask mode asks for every action. Trusted sites mode acts on its sites
    /// without asking; Developer mode on its sites. An agent from outside
    /// acts only on the developer sites, without asking, and never closes or
    /// moves the person's tabs.
    func permit(_ risk: Risk, _ question: @autoclosure () -> String) async -> Bool {
        if case .read = risk { return true }
        if planning { return false }
        switch risk {
        case .read:
            return true
        case .gentle:
            return acts
        case .inPage(let url):
            if outside { return developerSite(url) }
            guard acts else { return false }
            if let chat, ChatModes.shared.mode(of: chat) == .auto { return true }
            if prefs.aiMode == .trusted, SiteList.contains(prefs.aiTrusted, url) { return true }
            if prefs.aiMode == .developer, developerSite(url) { return true }
            return await ask(question(), trusting: Address.siteHost(of: url) ?? "")
        case .destructive:
            guard !outside, acts else { return false }
            if let chat, ChatModes.shared.mode(of: chat) == .auto { return true }
            return await ask(question(), trusting: nil)
        case .irreversible:
            return outside || !acts ? false : await ask(question(), trusting: nil)
        }
    }

    /// The chat is in Plan: it only looks.
    var planning: Bool { !outside && chat.map { ChatModes.shared.mode(of: $0) == .plan } == true }

    /// Why an action wasn't done, in words the model can act on.
    var refused: String {
        if planning { return Self.planOnly }
        if outside { return "Coding agents act only on the developer sites (Settings › AI): \(prefs.aiDevSites). Open one in a test tab with new_test_tab." }
        return acts ? Self.declined : Self.actingOff
    }

    /// The answer when acting is off.
    static let actingOff = "Acting for the person is off: they can turn on Settings › AI › Tools › Act for you."
    static let declined = "The person said no."
    static let planOnly = "Plan mode: nothing is done yet. Put this in your plan as a step instead, and carry on looking."

    /// `site`: one this chat may be allowed to act on from now on. Three
    /// choices, so a long task needn't stop at every step: this site for
    /// the rest of the chat, every site with the chat switched to Auto, or
    /// Cancel. (`once`, a single Allow, stays for a question that can't be
    /// trusted ahead: one with no site.)
    private func ask(_ question: String, trusting site: String?) async -> Bool {
        let site = site.map(Self.trustKey)
        if let chat, let site, Self.trusted[chat]?.contains(site) == true { return true }
        let once = "Allow", session = "Allow for this session", everything = "Allow all sites in this chat and switch to Auto",
            cancel = "Cancel"
        let first = site == nil ? once : session
        // In the chat, where the reply is: an alert only with no chat to ask in.
        if let chat, let conversation = Assistant.shared.conversation(chat), conversation.busy {
            let options = [
                Conversation.Question.Option(label: first, description: site.map { "On \($0), while Mote is open" }),
                .init(label: everything, description: "No more of these questions; Auto still asks before what can't be undone"),
                .init(label: cancel),
            ]
            let answer = await asking(conversation, Conversation.Question(text: question, options: options))
            return decide(answer, first: first, everything: everything, cancel: cancel, site: site, chat: chat, conversation: conversation)
        }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The assistant asks to do this for you."
        alert.addButton(withTitle: first)
        alert.addButton(withTitle: "Allow All Sites and Switch to Auto")
        // Escape is a no, as in the chat.
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        let answer: NSApplication.ModalResponse
        if let window = browser.window {
            // A stopped reply takes its question away, as Cancel: a late Allow can't act.
            answer = await withTaskCancellationHandler {
                await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
            } onCancel: {
                Task { @MainActor in window.endSheet(alert.window, returnCode: .alertThirdButtonReturn) }
            }
            guard !Task.isCancelled else { return false }
        } else {
            answer = alert.runModal()
        }
        let picked = answer == .alertFirstButtonReturn ? first : answer == .alertSecondButtonReturn ? everything : cancel
        return decide(picked, first: first, everything: everything, cancel: cancel, site: site, chat: chat, conversation: nil)
    }

    /// What a permission answer does: trusts the site, or every site with the
    /// chat on Auto; words of the person's own are a no, told to the model.
    private func decide(
        _ answer: String?, first: String, everything: String, cancel: String, site: String?, chat: UUID?, conversation: Conversation?
    ) -> Bool {
        switch answer {
        case first?:
            if let chat, let site { Self.trusted[chat, default: []].insert(site) }
            return true
        case everything?:
            if let chat { ChatModes.shared.set(chat, .auto) }
            return true
        case let answer?:
            if answer != cancel, answer != Conversation.dismissed { conversation?.addSteering(answer) }
            return false
        case nil:
            return false
        }
    }

    /// A site as permission counts it: its own domain, so a task moving
    /// between its subdomains (jobs. to apply.) isn't asked again. The last
    /// two labels, or three under a country's second level (co.uk, co.ke).
    static func trustKey(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let second = labels[labels.count - 2], top = labels[labels.count - 1]
        let countryLevel = top.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu", "or", "ne", "go"].contains(String(second))
        return labels.suffix(countryLevel ? 3 : 2).joined(separator: ".")
    }

    // MARK: - Tabs, wherever they are

    /// A tab as the assistant knows it: in which window, and in which space
    /// (`parked`: one not showing).
    struct Found {
        let tab: Tab
        let browser: Browser
        let window: Int
        let space: Space?
        let parked: Bool
    }

    /// Every tab the assistant can see: each window's, in every space; never
    /// private ones. An agent from outside sees only its own test tabs and
    /// the developer sites'.
    var everyTab: [Found] {
        let all = allTabs
        return outside ? all.filter { $0.tab.bench || developerSite($0.tab.pending ?? $0.tab.address) } : all
    }

    private var allTabs: [Found] {
        Windows.shared.all.enumerated().flatMap { index, browser -> [Found] in
            guard !browser.isPrivate else { return [] }
            let here = browser.tabs.map { Found(tab: $0, browser: browser, window: index + 1, space: browser.space, parked: false) }
            let away = browser.parked.flatMap { id, row in
                row.tabs.map { Found(tab: $0, browser: browser, window: index + 1, space: browser.spaces.first { $0.id == id }, parked: true) }
            }
            return (here + away).filter { !$0.tab.shy }
        }
    }

    /// The tab named by `input["tab"]`.
    func find(_ input: JSON) -> Found? {
        guard let id = input["tab"]?.string?.lowercased() else { return nil }
        return everyTab.first { Self.id($0.tab) == id }
    }

    /// The tabs named by `input["tabs"]`, and the ids that matched none.
    func find(all input: JSON) -> (found: [Found], missing: [String]) {
        let ids = (input["tabs"]?.array ?? []).compactMap { $0.string?.lowercased() }
        let every = everyTab
        let found = ids.compactMap { id in every.first { Self.id($0.tab) == id } }
        return (found, ids.filter { id in !found.contains { Self.id($0.tab) == id } })
    }

    static func id(_ tab: Tab) -> String { String(tab.id.uuidString.prefix(8)).lowercased() }

    /// "No tab ab12": what to say about ids that matched nothing.
    static func missing(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " No open tab has the id \(ids.joined(separator: ", ")); list the tabs again."
    }

    /// Names for a confirmation: the first few, and how many more.
    static func names(_ tabs: [Tab]) -> String {
        tabs.prefix(6).map { "“\($0.label)”" }.joined(separator: ", ") + (tabs.count > 6 ? " and \(tabs.count - 6) more" : "")
    }

    func web(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The most of a page's text given back.
    static let most = 20_000
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
