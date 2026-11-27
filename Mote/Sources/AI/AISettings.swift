import AppKit
import MoteAI
import MoteCore
import SwiftUI

/// Settings › AI: who answers when asked, with which model, and what each
/// provider needs: a key, an address, or its program on the Mac.
struct AISettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var keyDraft = ""
    @State private var checking = false
    @State private var managingChats = false
    @State private var checked: (provider: String, result: String)?
    private var assistant: Assistant { .shared }

    var body: some View {
        let provider = assistant.provider
        SettingsSection(
            "Asking",
            note: "In a new tab, ↩ searches with \(prefs.engine.name(custom: prefs.customEngine)) and ⌘J switches to asking the assistant."
        ) {
            SettingRow("Ask with", provider.summary, symbol: "sparkles", tint: Tint.purple) { providerPicker }
            RowRule()
            SettingRow("Model", modelDetail(provider), symbol: "cpu", tint: Tint.indigo) { ModelField(provider: provider) }
            if provider.kind == .cloud {
                RowRule()
                keyRow(provider)
            }
            if provider.movable {
                RowRule()
                AddressRow(provider: provider)
            }
            if let agent = provider.agent {
                RowRule()
                programRow(provider, agent: agent)
            }
            RowRule()
            SettingRow(
                "Tab asks", "In the floating search, Tab asks about the page what you typed", symbol: "arrow.right.to.line",
                tint: Tint.purple, keywords: ["floating search", "tab key"], on: $prefs.tabAsks)
            RowRule()
            SettingRow(
                "Show token count", "While a reply works, the tokens it has spent so far; /usage shows the chat's",
                symbol: "number", tint: Tint.gray, keywords: ["tokens", "usage", "cost"], on: $prefs.showsTokens)
            RowRule()
            SettingRow(
                "Summarise long chats at", "Larger means fewer summaries, but each call late in a long chat reads more and costs more",
                symbol: "text.append", tint: Tint.gray, keywords: ["summary", "compact", "context", "tokens"]
            ) {
                Picker("", selection: $prefs.summariseAt) {
                    Text("Auto (90% of the model's window)").tag(0)
                    Text("100k tokens").tag(100_000)
                    Text("200k tokens").tag(200_000)
                    Text("500k tokens").tag(500_000)
                }
                .labelsHidden()
                .fixedSize()
            }
            RowRule()
            SettingRow(
                "Search the web", provider.searches ? webDetail(provider) : "\(provider.name) can't search the web", symbol: "globe",
                tint: Tint.blue, on: Binding(get: { assistant.searchesWeb }, set: { assistant.searchesWeb = $0 })
            )
            .disabled(!provider.searches)
            RowRule()
            SettingRow("Check it works", checkDetail(provider), symbol: "checkmark.seal", tint: Tint.green) {
                if checking { Ring(size: 12) } else { Pill("Check") { check(provider) } }
            }
        }
        .id(provider.id)

        SettingsSection(
            "Tools", note: "The assistant asks before every action unless you allow a site for that chat. Never in private tabs, never passwords."
        ) {
            SettingRow(
                "Read your tabs and the web", "Open tabs, pages it looks up, your history and bookmarks", symbol: "doc.text.magnifyingglass",
                tint: Tint.blue, on: $prefs.aiReads)
            if prefs.aiReads, prefs.aiActs {
                RowRule()
                SettingRow(
                    "When it acts", prefs.aiMode == .ask ? "It asks before each action" : prefs.aiMode == .trusted ? "It acts on the trusted sites without asking" : "It tests the developer sites freely, with developer tools",
                    symbol: "hand.raised", tint: Tint.orange, keywords: AIMode.allCases.map(\.title)
                ) {
                    Segmented(options: AIMode.allCases.map { ($0, $0.title) }, selection: $prefs.aiMode)
                }
                if prefs.aiMode == .trusted {
                    RowRule()
                    sites("Trusted sites", "github.com, mail.google.com", $prefs.aiTrusted)
                }
                if prefs.aiMode == .developer {
                    RowRule()
                    sites("Developer sites", "localhost:*, staging.example.com", $prefs.aiDevSites)
                }
                RowRule()
                SettingRow(
                    "Work in the background", "Each tab it starts on comes forward unless this is on; /background switches one chat",
                    symbol: "rectangle.stack", tint: Tint.orange, on: $prefs.aiBackground)
                RowRule()
                sites("May sign in to", "Added when you allow it", $prefs.aiSignIn)
                RowRule()
                FoldersRow(prefs: prefs)
            }
            if prefs.aiReads {
                RowRule()
                SettingRow(
                    "Act for you", "Open, switch and close tabs, click and type in pages, asking first", symbol: "cursorarrow.click.2", tint: Tint.orange,
                    on: $prefs.aiActs)
            }
            RowRule()
            SettingRow(
                "Let coding agents use Mote",
                "AI agents can test your developer sites in Mote",
                symbol: "hammer", tint: Tint.indigo, keywords: ["AI", "agents", "developer"], on: $prefs.agentsUseMote)
            if prefs.agentsUseMote {
                RowRule()
                SettingRow("Sites they may test", "The same as Settings › AI › Developer sites", symbol: "globe", tint: Tint.indigo) {
                    TextField("localhost:*, staging.example.com", text: $prefs.aiDevSites).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                RowRule()
                // For the agent chosen to ask with, or any agent.
                let agent = provider.agent
                SettingRow(
                    agent == nil ? "Set up an agent" : "Set up \(provider.name)", MoteMCP.shared.setupDetail(for: agent), symbol: "doc.on.clipboard", tint: Tint.indigo) {
                    HStack(spacing: 8) {
                        Pill(agent == nil ? "Copy Address" : "Copy for \(provider.name)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MoteMCP.shared.setup(for: agent), forType: .string)
                        }
                        Pill("Reset Token") { MoteMCP.shared.resetOutsideToken() }
                            .help("Agents set up before can no longer use Mote")
                    }
                }
            }
        }

        SettingsSection(
            "Chat sidebar",
        ) {
            SettingRow(
                "Sidebar shows", "Mote's chat, or an AI app's site", symbol: "sidebar.right", tint: Tint.purple,
                keywords: SidebarSite.all.map(\.name)
            ) {
                Picker("", selection: siteChoice) {
                    Text("Mote's Chat").tag("")
                    ForEach(SidebarSite.all, id: \.address) { Text($0.name).tag($0.address) }
                    Text("Other Site…").tag(SidebarSite.other)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if otherSite {
                RowRule()
                SettingRow("Site", "Its address", symbol: "link", tint: Tint.purple) {
                    TextField("example.com", text: $prefs.chatSite).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            if prefs.chatSite.isEmpty {
                RowRule()
                SettingRow(
                    "One chat for all tabs", "The chat stays as you switch tabs, about the page in front", symbol: "bubble.left.and.text.bubble.right",
                    tint: Tint.indigo, on: $prefs.oneChat)
            }
            RowRule()
            SettingRow(
                "Chats in the sidebar", "Your newest chats, as a folder above your pinned tabs", symbol: "bubble.left.and.bubble.right",
                tint: Tint.indigo, keywords: ["chats", "conversations", "tabs"], on: $prefs.chatsInSidebar)
            RowRule()
            SettingRow(
                "Chat storage", "See how much space a chat and its attachments consume",
                symbol: "internaldrive", tint: Tint.gray, keywords: ["chats", "files", "attachments", "space", "storage"]
            ) {
                Pill("Manage") { managingChats = true }
            }
        }
        .sheet(isPresented: $managingChats) { ChatStorageSheet() }

        MemorySection()

        SettingsSection(
            "On this Mac",
            note:
                "Agents use their own accounts and work in a folder owned by Mote"
        ) {
            ForEach(Array(Provider.all.filter { $0.kind != .cloud }.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowRule() }
                ProviderRow(provider: item)
            }
            RowRule()
            SettingRow(
                "Installed something new?", "Mote looks for agents where your shell finds them", symbol: "magnifyingglass", tint: Tint.gray
            ) {
                if assistant.looking { Ring(size: 12) } else { Pill("Look Again") { Task { await assistant.lookAround(again: true) } } }
            }
        }

        SettingsSection("With an API key", note: "Keys stay in the Mac's keychain.") {
            ForEach(Array(Provider.all.filter { $0.kind == .cloud }.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowRule() }
                ProviderRow(provider: item)
            }
        }
        .task { await assistant.lookAround() }
    }

    // MARK: - Choosing

    /// A list of sites, typed with commas.
    private func sites(_ title: String, _ example: String, _ list: Binding<String>) -> some View {
        SettingRow(title, nil, symbol: "globe", tint: Tint.gray) {
            TextField(example, text: list).textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }

    /// The sidebar's site among the known ones, or "Other Site…" for an address typed.
    private var otherSite: Bool { !prefs.chatSite.isEmpty && !SidebarSite.all.contains { $0.address == prefs.chatSite } }

    private var siteChoice: Binding<String> {
        Binding(
            get: { otherSite ? SidebarSite.other : prefs.chatSite },
            set: { prefs.chatSite = $0 == SidebarSite.other ? "https://" : $0 })
    }

    private var providerPicker: some View {
        Picker(
            "",
            selection: Binding(get: { assistant.providerID }, set: { assistant.providerID = $0 })
        ) {
            Section("On This Mac") {
                ForEach(Provider.all.filter { $0.kind != .cloud }) { Text($0.name).tag($0.id) }
            }
            Section("With an API Key") {
                ForEach(Provider.all.filter { $0.kind == .cloud }) { Text($0.name).tag($0.id) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func webDetail(_ provider: Provider) -> String {
        provider.search == .online
            ? "Through OpenRouter every question would search, so only Research does"
            : "Looks things up when a question needs it, and cites its sources"
    }

    private func modelDetail(_ provider: Provider) -> String {
        if assistant.status(of: provider) == .needsKey { return "Add a key to see \(provider.name)'s models" }
        if let failure = assistant.listFailures[provider.id] { return failure }
        if assistant.listing.contains(provider.id) { return "Asking \(provider.name) for its models…" }
        if let count = assistant.models[provider.id]?.count, count > 0 { return "\(count) to choose from" }
        return provider.kind == .agent ? "Empty uses the agent's own default" : "The model's id, as the provider names it"
    }

    // MARK: - Keys

    @ViewBuilder
    private func keyRow(_ provider: Provider) -> some View {
        if assistant.hasKey(for: provider) {
            SettingRow("API key", "Saved in the keychain", symbol: "key", tint: Tint.yellow) {
                Pill("Remove") { assistant.setKey("", for: provider) }
            }
        } else {
            SettingRow(
                "API key", provider.needsKey ? "Needed to ask \(provider.name)" : "If the server asks for one", symbol: "key",
                tint: Tint.yellow
            ) {
                if let page = provider.keyPage {
                    Pill("Get a Key") {
                        browser.tuning = false
                        browser.open(page, foreground: true)
                    }
                }
            }
            HStack(spacing: 8) {
                SecureField("", text: $keyDraft, prompt: Text("Paste the key"))
                    .textFieldStyle(.plain)
                    .textStyle(.row)
                    .onSubmit { saveKey(provider) }
                Pill("Save", filled: !keyDraft.isEmpty) { saveKey(provider) }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(EdgeInsets(top: 0, leading: 47, bottom: 10, trailing: 12))
        }
    }

    private func saveKey(_ provider: Provider) {
        guard !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if assistant.setKey(keyDraft, for: provider) {
            keyDraft = ""
            check(provider)
        } else {
            checked = (provider.id, "The keychain didn't take the key")
        }
    }

    // MARK: - Programs

    private func programRow(_ provider: Provider, agent: Provider.Agent) -> some View {
        let chosen = assistant.setup(for: provider).program?.isEmpty == false
        let detail: String =
            if let program = assistant.program(of: provider) {
                program.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            } else if assistant.found == nil {
                "Looking…"
            } else {
                "Not found. Install it with: \(agent.install)"
            }
        return SettingRow("Program", detail, symbol: "terminal", tint: Tint.gray) {
            if chosen {
                Pill("Use Found") { assistant.change(provider) { $0.program = nil } }
            } else {
                Pill("Choose…") { chooseProgram(for: provider) }
            }
        }
    }

    private func chooseProgram(for provider: Provider) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This"
        panel.message = "Choose the \(provider.agent?.program ?? "agent") program"
        if panel.runModal() == .OK, let url = panel.url { assistant.change(provider) { $0.program = url.path } }
    }

    // MARK: - Checking

    private func checkDetail(_ provider: Provider) -> String {
        if let checked, checked.provider == provider.id { return checked.result }
        switch assistant.status(of: provider) {
        case .ready: return "Asks \(provider.name) for its models"
        case .looking: return "Looking for \(provider.name)…"
        case .missing: return "\(provider.name) isn't installed"
        case .needsKey: return "Add a key first"
        case .unavailable(let reason): return reason
        }
    }

    private func check(_ provider: Provider) {
        checking = true
        checked = nil
        Task {
            assistant.forgetModels(of: provider)
            if provider.kind == .local { await assistant.checkServers() }
            let models = await assistant.listModels(of: provider)
            checking = false
            if let failure = assistant.listFailures[provider.id] {
                checked = (provider.id, failure)
            } else if assistant.status(of: provider) != .ready {
                checked = (provider.id, checkDetail(provider))
            } else {
                checked = (provider.id, models.isEmpty ? "It answered, with no models listed" : "It works — \(models.count) models")
            }
        }
    }
}

/// A provider, how it stands, and a button to use it.
private struct ProviderRow: View {
    let provider: Provider
    private var assistant: Assistant { .shared }

    var body: some View {
        let status = assistant.status(of: provider)
        SettingRow(provider.name, detail(status), symbol: symbol, tint: tint) {
            if provider.id == assistant.providerID {
                Label("In use", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(status == .ready ? Palette.safe : Palette.faint).frame(width: 6, height: 6)
                        .accessibilityLabel(status == .ready ? "Ready" : "Not ready")
                    Pill("Use") { assistant.providerID = provider.id }
                        .disabled(status != .ready && status != .needsKey)
                        .opacity(status != .ready && status != .needsKey ? 0.4 : 1)
                }
            }
        }
    }

    private func detail(_ status: Assistant.Status) -> String {
        switch status {
        case .ready:
            if let program = assistant.program(of: provider) {
                return "Found at \(program.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
            }
            return provider.kind == .cloud && assistant.hasKey(for: provider) ? "Key saved" : provider.summary
        case .looking: return "Looking…"
        case .missing: return "Not installed"
        case .needsKey: return provider.summary
        case .unavailable(let reason): return reason
        }
    }

    private var symbol: String {
        switch provider.connection {
        case .agent: "terminal"
        case .apple: "apple.logo"
        case .openAI where provider.kind == .local: "desktopcomputer"
        default: "cloud"
        }
    }

    private var tint: Color {
        switch provider.kind {
        case .agent: Tint.orange
        case .local: provider.connection == .apple ? Tint.gray : Tint.teal
        case .cloud: Tint.blue
        }
    }
}

/// The model's id, typed or picked from what the provider lists.
private struct ModelField: View {
    let provider: Provider
    @State private var draft = ""
    private var assistant: Assistant { .shared }

    var body: some View {
        let listed = assistant.models[provider.id] ?? provider.suggested
        HStack(spacing: 4) {
            TextField("", text: $draft, prompt: Text(provider.defaultModel.isEmpty ? "Default" : provider.defaultModel))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 170)
                .onSubmit(save)
            Menu {
                if provider.kind == .agent { Button("Default") { pick("") } }
                ForEach(listed.prefix(80)) { model in
                    Button(model.name == model.id ? model.id : "\(model.name) — \(model.id)") { pick(model.id) }
                }
                if listed.isEmpty { Text("None listed") }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
        .onAppear { draft = assistant.setup(for: provider).model ?? "" }
        .onChange(of: draft) { save() }
        .task { await assistant.listModels(of: provider) }
    }

    private func pick(_ id: String) { draft = id }

    private func save() {
        let id = draft.trimmingCharacters(in: .whitespaces)
        guard id != (assistant.setup(for: provider).model ?? "") else { return }
        assistant.change(provider) { $0.model = id.isEmpty ? nil : id }
    }
}

/// Where a movable provider is: a server on another port or another Mac.
private struct AddressRow: View {
    let provider: Provider
    @State private var draft = ""
    private var assistant: Assistant { .shared }

    var body: some View {
        SettingRow("Address", "Where the server answers", symbol: "network", tint: Tint.teal) {
            TextField("", text: $draft, prompt: Text(provider.base?.absoluteString ?? "http://"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 210)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
                .onSubmit {
                    save()
                    Task { await assistant.checkServers() }
                }
        }
        .onAppear { draft = assistant.setup(for: provider).address ?? "" }
        .onChange(of: draft) { save() }
    }

    private func save() {
        let address = draft.trimmingCharacters(in: .whitespaces)
        guard address != (assistant.setup(for: provider).address ?? "") else { return }
        assistant.change(provider) { $0.address = address.isEmpty ? nil : address }
        assistant.forgetModels(of: provider)
    }
}

/// AI apps the chat sidebar can show.
struct SidebarSite {
    let name: String
    let address: String

    static let all = [
        SidebarSite(name: "Claude", address: "https://claude.ai/new"),
        SidebarSite(name: "ChatGPT", address: "https://chatgpt.com/"),
        SidebarSite(name: "Gemini", address: "https://gemini.google.com/app"),
        SidebarSite(name: "Perplexity", address: "https://www.perplexity.ai/"),
    ]
    /// The picker's tag for an address typed in.
    static let other = "other"
}

/// Settings › AI › Memory: what the assistant keeps from chat to chat, each
/// removable, and a way to keep nothing.
/// The folders the assistant may attach files from, for good: added when the
/// person says "Always allow" in a chat, or here.
private struct FoldersRow: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingRow(
            "May attach files from", prefs.aiFolders.isEmpty ? "Added when you allow it, or here" : "To upload fields in pages",
            symbol: "paperclip", tint: Tint.orange, keywords: ["upload", "files", "folders", "attach"]
        ) {
            Pill("Add Folder…") { add() }
        }
        ForEach(prefs.aiFolders, id: \.self) { folder in
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text((folder as NSString).abbreviatingWithTildeInPath).font(TextStyle.body.font).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Door(icon: "xmark", help: "Don't allow") { prefs.aiFolders.removeAll { $0 == folder } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "The assistant may attach files from these folders to pages"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let folder = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !prefs.aiFolders.contains(folder) { prefs.aiFolders.append(folder) }
        }
    }
}

private struct MemorySection: View {
    @ObservedObject private var memories = Memories.shared
    @State private var managing = false

    var body: some View {
        SettingsSection(
            "Memory",
            note: "What you ask the assistant to remember, told to every chat. Never from a private window."
        ) {
            SettingRow("Remember things", "Across chats, when you ask it to", symbol: "brain", tint: Tint.purple, on: $memories.on)
            RowRule()
            SettingRow(
                "Memories", memories.all.isEmpty ? "None kept yet" : "\(memories.all.count) kept", symbol: "list.bullet.rectangle",
                tint: Tint.gray, keywords: ["memory", "forget", "remember"]
            ) {
                Pill("Manage") { managing = true }
            }
        }
        .sheet(isPresented: $managing) { MemorySheet() }
    }
}

/// Settings › AI › Memories › Manage: what the assistant keeps about the
/// person, each to read whole or forget, and forgetting all of it.
private struct MemorySheet: View {
    @ObservedObject private var memories = Memories.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(20) }
            Divider()
            HStack {
                if !memories.all.isEmpty {
                    Button("Forget Everything…", role: .destructive) {
                        guard
                            Dialogs.confirm(
                                "Forget everything?", "The assistant forgets all \(memories.all.count) things it kept about you. This can't be undone.",
                                button: "Forget Everything")
                        else { return }
                        memories.forgetAll()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 560)
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain").font(.system(size: 24, weight: .regular)).foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: 52, height: 52).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Memories").font(.title3.weight(.semibold))
            Text("What you asked the assistant to remember. Every chat is told these.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            // Not lazy: a lazy stack keeps a row's first height, so one opened
            // whole ran over the next. Memories are few.
            VStack(spacing: 0) {
                ForEach(memories.all) { memory in
                    MemoryRow(memory: memory) { _ = memories.forget(memory.id) }
                    if memory.id != memories.all.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .overlay { if memories.all.isEmpty { Text("Nothing kept.").foregroundStyle(.secondary) } }
            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A memory: when it was kept, three lines that open to the whole, Forget on hover.
private struct MemoryRow: View {
    let memory: Memories.Memory
    let forget: () -> Void
    @State private var whole = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.text).lineLimit(whole ? nil : 3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(memory.made.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.quick) { whole.toggle() } }
            Button("Forget", action: forget).buttonStyle(.borderless).controlSize(.small).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
