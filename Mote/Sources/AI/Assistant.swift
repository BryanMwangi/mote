import Foundation
import MoteAI
import Observation

/// The assistant every window asks: which provider answers, how each is set
/// up, and what's installed on the Mac. Chats themselves are `Conversation`s,
/// one per chat tab; this only gets them a route to a provider.
///
/// The choices are kept in the settings store, keys in the keychain.
@MainActor
@Observable
final class Assistant {
    static let shared = Assistant()

    /// Whether a provider can answer, as Settings shows it.
    enum Status: Equatable {
        case ready
        case looking
        case missing(String)
        case needsKey
        case unavailable(String)
    }

    /// The provider that answers.
    var providerID: String {
        didSet { Storage.settings.set(providerID, forKey: Keys.provider) }
    }

    /// How questions are answered: from the model alone, from a quick web
    /// search, or by researching the web in depth.
    enum Mode: String, CaseIterable, Identifiable {
        case chat, search, research

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chat: "Chat"
            case .search: "Web search"
            case .research: "Research"
            }
        }

        var symbol: String {
            switch self {
            case .chat: "bubble.left"
            case .search: "network"
            case .research: "binoculars"
            }
        }

        /// What it does, in a few words.
        var detail: String {
            switch self {
            case .chat: "Answers from what the model knows."
            case .search: "Searches the web when a question needs it, and cites its sources."
            case .research: "Reads many sources and writes a report. Takes minutes."
            }
        }
    }

    /// The mode asked for; one that needs searching falls back to chat with a
    /// provider that can't search (see `mode(with:)`).
    var chosenMode: Mode {
        didSet { Storage.settings.set(chosenMode.rawValue, forKey: Keys.mode) }
    }

    /// The assistant may search the web when it judges a question needs it
    /// (Settings › AI). Research searches whatever this says.
    var searchesWeb: Bool {
        didSet { Storage.settings.set(searchesWeb, forKey: Keys.web) }
    }

    /// The next question is researched in depth.
    var researching: Bool {
        get { chosenMode == .research }
        set { chosenMode = newValue ? .research : .chat }
    }

    /// The mode the next question goes in.
    var mode: Mode { mode(with: provider) }

    /// Research when asked for; otherwise searching when the model judges it
    /// worth it, where the provider lets the model judge. OpenRouter's
    /// `:online` searches for every question, so it only searches in research.
    func mode(with provider: Provider) -> Mode {
        guard let search = provider.search else { return .chat }
        if chosenMode == .research { return .research }
        return searchesWeb && search != .online ? .search : .chat
    }

    private(set) var setups: [String: ProviderSetup]
    /// What was found on the Mac; nil until the first look.
    private(set) var found: ToolLocator.Found?
    private(set) var looking = false
    /// Models listed by each provider, once asked.
    private(set) var models: [String: [Model]] = [:]
    private(set) var listing: Set<String> = []
    /// Why a provider's list couldn't be had.
    private(set) var listFailures: [String: String] = [:]
    /// Servers on the Mac that didn't answer when last asked.
    private(set) var offline: Set<String> = []
    /// Bumped when a key changes, so views asking `hasKey` look again.
    private(set) var keysChanged = 0

    @ObservationIgnored let secrets: Secrets
    @ObservationIgnored private var search: Task<ToolLocator.Found, Never>?
    /// Model lists being fetched, so a second asker waits for the first.
    @ObservationIgnored private var lists: [String: Task<[Model], Never>] = [:]
    @ObservationIgnored private var serversChecked: Date?

    /// Where the agents work: a folder of Mote's own, never a project.
    static var workspace: URL { Storage.folder.appending(path: "Assistant", directoryHint: .isDirectory) }

    private enum Keys {
        static let provider = "ai.provider"
        static let setups = "ai.setups"
        static let mode = "ai.mode"
        static let web = "ai.web"
    }

    init(secrets: Secrets? = nil) {
        // A service of its own per test world, so test runs never read or
        // change the real keys.
        let service = "io.github.mote-browser.mote.ai" + (Storage.world.map { ".\($0)" } ?? "")
        self.secrets = secrets ?? KeychainSecrets(service: service, label: Storage.world.map { "Mote AI (\($0))" } ?? "Mote AI")
        let stored = Storage.settings.string(forKey: Keys.provider).flatMap(Provider.named)
        providerID = stored?.id ?? "claude-code"
        // Before modes there was only a switch for searching.
        chosenMode =
            Storage.settings.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:))
            ?? (Storage.settings.bool(forKey: "ai.search") ? .search : .chat)
        searchesWeb = Storage.settings.object(forKey: Keys.web) as? Bool ?? true
        setups =
            Storage.settings.data(forKey: Keys.setups).flatMap { try? JSONDecoder().decode([String: ProviderSetup].self, from: $0) } ?? [:]
    }

    var provider: Provider { Provider.named(providerID) ?? Provider.all[0] }

    func setup(for provider: Provider) -> ProviderSetup { setups[provider.id] ?? ProviderSetup() }

    func change(_ provider: Provider, _ edit: (inout ProviderSetup) -> Void) {
        var setup = setup(for: provider)
        edit(&setup)
        setups[provider.id] = setup
        if let data = try? JSONEncoder().encode(setups) { Storage.settings.set(data, forKey: Keys.setups) }
    }

    // MARK: - Keys

    func hasKey(for provider: Provider) -> Bool {
        _ = keysChanged
        return secrets.hasKey(for: provider.id)
    }

    @discardableResult
    func setKey(_ key: String, for provider: Provider) -> Bool {
        let saved = secrets.setKey(key, for: provider.id)
        keysChanged += 1
        models[provider.id] = nil
        listFailures[provider.id] = nil
        return saved
    }

    // MARK: - What's installed

    /// Looks for the agents' programs, once unless asked again. Callers
    /// arriving while a look is under way wait for it, and find `found` set.
    @discardableResult
    func lookAround(again: Bool = false) async -> ToolLocator.Found {
        if !again, let found { return found }
        if let search { return await search.value }
        looking = true
        let names = Provider.Agent.allCases.map(\.program)
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached { await ToolLocator().find(names) }.value
            self?.found = result
            self?.search = nil
            self?.looking = false
            return result
        }
        search = task
        async let servers: Void = checkServers()
        let result = await task.value
        await servers
        return result
    }

    /// Asks each server on the Mac (Ollama, LM Studio) whether it's running.
    func checkServers() async {
        serversChecked = Date()
        let servers = Provider.all.filter { $0.kind == .local && $0.base != nil }
        for provider in servers {
            let answers = await connector.reachable(provider, setup: setup(for: provider))
            if answers { offline.remove(provider.id) } else { offline.insert(provider.id) }
        }
    }

    private var connector: Connector {
        Connector(workspace: Self.workspace, tools: found ?? ToolLocator.Found(tools: [:], path: nil))
    }

    func status(of provider: Provider) -> Status {
        switch provider.connection {
        case .agent(let agent):
            guard found != nil else { return .looking }
            return connector.program(for: agent, setup: setup(for: provider)) == nil ? .missing(agent.install) : .ready
        case .apple:
            return AppleIntelligence.unavailable.map(Status.unavailable) ?? .ready
        case .openAI, .anthropic:
            if offline.contains(provider.id) {
                return .unavailable("Not running at \(connector.base(for: provider, setup: setup(for: provider))?.host() ?? "its address")")
            }
            return provider.needsKey && !hasKey(for: provider) ? .needsKey : .ready
        }
    }

    /// Where the program was found, for Settings.
    func program(of provider: Provider) -> URL? {
        provider.agent.flatMap { connector.program(for: $0, setup: setup(for: provider)) }
    }

    func model(for provider: Provider) -> String { connector.model(for: provider, setup: setup(for: provider)) }

    /// The name of the model in use, as its provider lists it.
    func modelName(for provider: Provider) -> String {
        let id = model(for: provider)
        guard !id.isEmpty else { return provider.kind == .agent ? "Default model" : "No model" }
        return (models[provider.id] ?? provider.suggested).first { $0.id == id }?.name ?? id
    }

    // MARK: - Models

    /// Asks the provider for its models, keeping the answer. A failure is
    /// kept too, so nothing is started again until `forgetModels`.
    @discardableResult
    func listModels(of provider: Provider) async -> [Model] {
        if let known = models[provider.id] { return known }
        if listFailures[provider.id] != nil { return provider.suggested }
        if let running = lists[provider.id] { return await running.value }
        listing.insert(provider.id)
        let task = Task { @MainActor [self] in
            defer {
                listing.remove(provider.id)
                lists[provider.id] = nil
            }
            if provider.agent != nil { await lookAround() }
            do {
                let listed = try await connector.models(for: provider, setup: setup(for: provider), key: secrets.key(for: provider.id))
                models[provider.id] = listed
                return listed
            } catch {
                listFailures[provider.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return provider.suggested
            }
        }
        lists[provider.id] = task
        return await task.value
    }

    /// Gets ready to ask: finds the programs, sees which servers run, and
    /// lists the chosen provider's models. Called when asking looks likely
    /// (the pointer on the model chip, ⌘ held over the composer), so nothing
    /// is started for someone who never asks.
    func prepare() {
        Task {
            await lookAround()
            if serversChecked.map({ Date().timeIntervalSince($0) > 15 }) ?? true { await checkServers() }
            await listModels(of: provider)
        }
    }

    func forgetModels(of provider: Provider) {
        models[provider.id] = nil
        listFailures[provider.id] = nil
    }

    // MARK: - Asking

    /// A route to the chosen provider, or why there isn't one. A provider with
    /// no model chosen and no default gets the first it lists.
    func route(to provider: Provider? = nil, chat: UUID? = nil) async throws -> Conversation.Route {
        let provider = provider ?? self.provider
        if provider.agent != nil { await lookAround() }
        // Whatever failed before (a server not yet started) is tried again.
        if listFailures[provider.id] != nil { forgetModels(of: provider) }
        var model = model(for: provider)
        if model.isEmpty, provider.kind != .agent {
            guard let first = await listModels(of: provider).first else {
                throw listFailures[provider.id].map(AIError.failed) ?? AIError.needsModel(provider.name)
            }
            change(provider) { $0.model = first.id }
            model = first.id
        }
        let mode = mode(with: provider)
        let search = mode != .chat
        var service = try connector.service(for: provider, setup: setup(for: provider), key: secrets.key(for: provider.id), search: search)
        // Research runs many replies of the provider's: a plan, researchers
        // that search, a writer that doesn't. Only researchers get the search method.
        if mode == .research {
            service = Research(service: service)
        } else if let tools = AssistantTools.current(chat: chat, driver: provider.name) {
            // Mote's own tools: the model asks, Mote does it, the model goes on.
            // An agent on the Mac runs them itself, from Mote over MCP.
            let overMCP = provider.agent != nil
            let server = overMCP ? await MoteMCP.shared.server(for: tools) : nil
            // Sub-agents run on the same model, without the tools loop around it.
            let (base, driver) = (service, provider.name)
            tools.overMCP = overMCP
            tools.spawn = { task, id, news in
                // Named on the page it works in, so two agents' work tells apart.
                await AssistantTools.runAgent(
                    task, through: base, model: model, overMCP: overMCP, chat: chat, driver: "\(driver) · \(id)", news: news)
            }
            service = ToolLoop(
                service: service, tools: tools.list, server: server, describe: AssistantTools.describe, together: ["spawn_agent"]
            ) { call in
                await tools.run(call)
            }
        }
        let author = model.isEmpty ? provider.name : "\(provider.name) · \(modelName(for: provider))"
        return Conversation.Route(
            provider: provider.id, model: model, author: author, service: service,
            instructions: [
                Instructions.compose(search: mode == .search, thorough: mode == .research), Memories.shared.note,
                chat.flatMap { ChatModes.shared.mode(of: $0) == .plan ? Self.planning : nil },
            ]
            .compactMap { $0 }.joined(separator: "\n\n"),
            search: search)
    }

    /// Told to the model while the chat is in Plan.
    static let planning = """
        The person has this chat in Plan mode: don't act yet. Look around as much as you need with the tools that only \
        read (tabs, pages, history), and ask the person with ask_person where a choice is theirs. Then end with a short \
        numbered plan of what you'll do, naming the tabs, spaces and sites each step touches, and stop there. The person \
        runs the plan, or says what to change.
        """

    /// Every chat kept, for the list of past chats and for chat tabs that
    /// come back at launch.
    let chats = ChatArchive(folder: Storage.file("Chats"))

    /// Keeps `conversation` in the archive from now on, as it changes.
    func keep(_ conversation: Conversation) {
        conversation.changed = { [chats] in chats.save($0.saved) }
        conversation.folder = chats.files(of: conversation.id)
        // Known by its id, so opening it again finds this one rather than a copy.
        if reopened[conversation.id]?.chat == nil { reopened[conversation.id] = WeakChat(conversation) }
    }

    /// A kept chat, ready to carry on and still being kept.
    /// The one already open, if it is: tabs sharing a chat share one.
    func reopen(_ id: UUID) -> Conversation? {
        if let open = reopened[id]?.chat { return open }
        guard let saved = chats.load(id) else { return nil }
        let conversation = Conversation(saved: saved)
        keep(conversation)
        return conversation
    }

    private var reopened: [UUID: WeakChat] = [:]

    /// Puts a chat away in the list, or back; an open one keeps it.
    func archive(_ id: UUID, _ on: Bool) {
        reopened[id]?.chat?.archived = on
        chats.archive(id, on)
    }

    /// Sends `text` in `conversation` to the chosen provider.
    /// `carrying`: Mote's own nudge to go on with the task list, not the
    /// person's words, which start the count of nudges again.
    func ask(_ text: String, in conversation: Conversation, carrying: Bool = false) {
        answering[conversation.id] = WeakChat(conversation)
        if !carrying { carried[conversation.id] = nil }
        conversation.finished = { [weak self] chat in
            self?.carryOn(chat)
            // A plan done while the person is elsewhere: macOS tells them it's ready.
            guard ChatModes.shared.mode(of: chat.id) == .plan, !WebNotifications.sees(chat: chat.id) else { return }
            let name = self?.provider.name ?? "The assistant"
            Task { await WebNotifications.shared.tell(chat: chat.id, "Plan ready for review", "\(name) has a plan for “\(chat.title)”") }
        }
        conversation.send(text, routing: { [self] in try await route(chat: conversation.id) })
    }

    // MARK: - Carrying on

    /// The most nudges in a row before it waits for the person.
    static let mostCarries = 12
    /// Each chat's nudges in a row, and its task list when last nudged.
    private var carried: [UUID: (count: Int, tasks: [TaskItem])] = [:]

    /// A turn ended cleanly (not stopped, not failed). A chat on Auto with its
    /// task list still open goes on by itself, as a person would say "carry
    /// on", up to `mostCarries` times in a row. Not when it ended by asking
    /// the person something, nor when the last nudge got the list no further.
    private func carryOn(_ chat: Conversation) {
        let open = chat.tasks.filter { $0.state == .open }.count
        let before = carried[chat.id]
        let asked = chat.messages.last?.steps.contains { $0.title == "Asking you" } == true
        guard ChatModes.shared.mode(of: chat.id) == .auto, open > 0, !asked, chat.queued.isEmpty,
            (before?.count ?? 0) < Self.mostCarries, before.map({ $0.tasks != chat.tasks }) ?? true
        else { return carried[chat.id] = nil }
        let count = (before?.count ?? 0) + 1
        carried[chat.id] = (count, chat.tasks)
        Task { @MainActor [weak self, weak chat] in
            try? await Task.sleep(for: .seconds(1))
            // Anything else meanwhile (the person wrote, or stopped it) comes first.
            guard let self, let chat, !chat.busy, chat.queued.isEmpty, case .idle = chat.phase else { return }
            self.ask(
                "Carry on with your task list: \(open) item\(open == 1 ? "" : "s") still open. "
                    + "(Mote carries on by itself in Auto, \(count) of \(Self.mostCarries) in a row; mark items as you go.)",
                in: chat, carrying: true)
        }
    }

    /// Conversations asked something, by id, so a tool's Stop can stop one.
    private var answering: [UUID: WeakChat] = [:]

    private final class WeakChat {
        weak var chat: Conversation?
        init(_ chat: Conversation) { self.chat = chat }
    }

    /// The chat with this id, while it's open.
    func conversation(_ id: UUID) -> Conversation? { answering[id]?.chat }

    /// Stops the reply under way in the chat with this id.
    func stop(chat id: UUID) {
        answering[id]?.chat?.stop()
    }

    /// Summarises the chat so far (`/compact`), through whatever provider is chosen now.
    func compact(_ conversation: Conversation) {
        answering[conversation.id] = WeakChat(conversation)
        conversation.compact(routing: { [self] in try await route(chat: conversation.id) })
    }

    /// Asks again for the last reply, through whatever provider is chosen now.
    func retry(in conversation: Conversation) {
        answering[conversation.id] = WeakChat(conversation)
        conversation.retry(routing: { [self] in try await route(chat: conversation.id) })
    }
}
