import AppKit
import Combine
import MoteAI
import MoteCore
import WebKit

/// Chats switched to Auto with ⇧⇥: the assistant acts without asking, for
/// that chat only, until switched back or Mote quits; what it does can be
/// undone. Only what can't be (deleting history) still asks.
@MainActor
final class ChatModes: ObservableObject {
    static let shared = ChatModes()
    @Published private(set) var auto: Set<UUID> = []

    func toggle(_ chat: UUID) {
        if auto.contains(chat) { auto.remove(chat) } else { auto.insert(chat) }
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

    /// Stops this turn: the pill's Stop and Take over.
    var stopTurn: (() -> Void)? {
        guard let chat else { return nil }
        return { Assistant.shared.stop(chat: chat) }
    }

    var list: [Tool] {
        outside
            ? tabTools + pageTools + pdfTools + workTools + devTools
            : tabTools + pageTools + pdfTools + workTools + signInTools + devTools + dataTools + ledgerTools
    }

    /// The step's line in the chat.
    nonisolated static func describe(_ call: ToolCall) -> String {
        ToolLoop.title(of: call.name, input: call.input)
    }

    func run(_ call: ToolCall) async -> ToolOutput {
        var said = await dispatch(call)
        if said.outcome == .done { said.outcome = outcome(of: said.text) }
        return said
    }

    private func dispatch(_ call: ToolCall) async -> ToolOutput {
        if let said = await runDev(call) { return said }
        if let said = await runTab(call) { return ToolOutput(said) }
        if let said = await runPage(call) { return ToolOutput(said) }
        if let said = await runPDF(call) { return ToolOutput(said) }
        if let said = await runWork(call) { return ToolOutput(said) }
        if !outside, let said = await runLedger(call) { return ToolOutput(said) }
        if !outside, let said = await runSignIn(call) { return ToolOutput(said) }
        if !outside, let said = await runData(call) { return ToolOutput(said) }
        return ToolOutput("There's no tool called \(call.name).", outcome: .failed)
    }

    /// How a tool's answer went, for its step in the chat: said no to, or
    /// failed, by the words the tools use for those.
    private func outcome(of text: String) -> Activity.Outcome {
        if text == refused || text == Self.declined || text == Self.actingOff || text.hasPrefix("The person didn't") { return .refused }
        let fine = ["No tabs match", "No history matches", "Nothing found", "None found"]
        if fine.contains(where: text.hasPrefix) { return .done }
        let failures = [
            "There's no", "That isn't", "That field can't", "That tab has no", "None of", "No ", "Not there", "The page didn't",
            "The page changed", "The page's", "Give ", "Say where", "It couldn't", "Nothing has", "Element ", "Mote never", "Mote has no",
            "Couldn't", "Can't",
        ]
        return failures.contains(where: text.hasPrefix) ? .failed : .done
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
        switch risk {
        case .read:
            return true
        case .gentle:
            return acts
        case .inPage(let url):
            if outside { return developerSite(url) }
            guard acts else { return false }
            if let chat, ChatModes.shared.auto.contains(chat) { return true }
            if prefs.aiMode == .trusted, SiteList.contains(prefs.aiTrusted, url) { return true }
            if prefs.aiMode == .developer, developerSite(url) { return true }
            return await ask(question(), trusting: Address.siteHost(of: url) ?? "")
        case .destructive:
            guard !outside, acts else { return false }
            if let chat, ChatModes.shared.auto.contains(chat) { return true }
            return await ask(question(), trusting: nil)
        case .irreversible:
            return outside || !acts ? false : await ask(question(), trusting: nil)
        }
    }

    /// Why an action wasn't done, in words the model can act on.
    var refused: String {
        if outside { return "Coding agents act only on the developer sites (Settings › AI): \(prefs.aiDevSites). Open one in a test tab with new_test_tab." }
        return acts ? Self.declined : Self.actingOff
    }

    /// The answer when acting is off.
    static let actingOff = "Acting for the person is off: they can turn on Settings › AI › Tools › Act for you."
    static let declined = "The person said no."

    /// `site`: one this chat may be allowed to act on from now on.
    private func ask(_ question: String, trusting site: String?) async -> Bool {
        if let chat, let site, Self.trusted[chat]?.contains(site) == true { return true }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The assistant asks to do this for you."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = chat != nil && site != nil
        alert.suppressionButton?.title = "Allow on \(site ?? "") for this chat"
        let answer: NSApplication.ModalResponse
        if let window = browser.window {
            answer = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
        } else {
            answer = alert.runModal()
        }
        guard answer == .alertFirstButtonReturn else { return false }
        if let chat, let site, alert.suppressionButton?.state == .on { Self.trusted[chat, default: []].insert(site) }
        return true
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
