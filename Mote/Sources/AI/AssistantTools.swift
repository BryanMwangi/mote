import AppKit
import MoteAI
import MoteCore
import WebKit

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
    /// Sites this chat may act on without asking again.
    private static var trusted: [UUID: Set<String>] = [:]

    /// The tools on now for the window in front, or nil with none on.
    static func current(chat: UUID?) -> AssistantTools? {
        guard let browser = Browser.front ?? Windows.shared.main, browser.prefs.aiReads else { return nil }
        return AssistantTools(browser: browser, acts: browser.prefs.aiActs, chat: chat)
    }

    private init(browser: Browser, acts: Bool, chat: UUID?) {
        self.browser = browser
        self.acts = acts
        self.chat = chat
    }

    var list: [Tool] { tabTools + pageTools + dataTools }

    /// The step's line in the chat.
    nonisolated static func describe(_ call: ToolCall) -> String {
        ToolLoop.title(of: call.name, input: call.input)
    }

    func run(_ call: ToolCall) async -> String {
        if let said = await runTab(call) { return said }
        if let said = await runPage(call) { return said }
        if let said = await runData(call) { return said }
        return "There's no tool called \(call.name)."
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
        /// Closes, moves or deletes: asks every time, naming what it touches.
        case destructive
    }

    /// Whether the assistant may go ahead; asks the person when the risk says
    /// to. `question` names what would be done.
    func permit(_ risk: Risk, _ question: @autoclosure () -> String) async -> Bool {
        switch risk {
        case .read: return true
        case .gentle: return acts
        case .inPage(let url): return acts ? await ask(question(), trusting: Address.siteHost(of: url) ?? "") : false
        case .destructive: return acts ? await ask(question(), trusting: nil) : false
        }
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

    /// Every tab the assistant can see: each window's, in every space; never private ones.
    var everyTab: [Found] {
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
