import AppKit
import MoteAI
import MoteCore
import UniformTypeIdentifiers

/// Files from the Mac put into a page's upload field, from folders the
/// person allows: for one chat, or for good (Settings › AI).
extension AssistantTools {
    var fileTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        return [
            Tool(
                name: "attach_file",
                description:
                    "Attaches files from this Mac to an upload field read_tab listed: the file field (shown or hidden), or the button or area over it. Give full paths, or paths starting with ~. Only from folders the person allows: Mote asks them the first time for each folder. Up to 25 MB a file. Doesn't submit the form.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"element\":{\"type\":\"integer\",\"description\":\"The number read_tab gave\"},\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"tab\",\"element\",\"paths\"]}"
            )
        ]
    }

    /// Folders allowed for one chat only, by chat.
    static var chatFolders: [UUID: Set<String>] = [:]

    /// The most of one file attached: pages refuse far less, and it goes
    /// through the page's script as text.
    static let largestFile = 25 << 20

    func runFiles(_ call: ToolCall) async -> String? {
        guard call.name == "attach_file" else { return nil }
        guard acts, !planning else { return refused }
        guard let found = find(call.input) else { return Self.noTab }
        let tab = found.tab
        guard let n = call.input["element"]?.int else { return "Say which field, by its number from read_tab." }
        guard tab.built != nil, let address = tab.address else { return "\(Self.line(tab)) is asleep; read it first, which wakes it." }
        let paths = (call.input["paths"]?.array ?? []).compactMap(\.string)
        guard !paths.isEmpty else { return "Give the paths of the files to attach." }
        var files: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            let facts = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard facts?.isRegularFile == true else { return "There's no file at \(path)." }
            guard (facts?.fileSize ?? 0) <= Self.largestFile else { return "\(url.lastPathComponent) is over 25 MB; Mote attaches files up to 25 MB." }
            files.append(url)
        }
        // Each folder not yet allowed is the person's to allow.
        for folder in Set(files.map { $0.deletingLastPathComponent().path }) where !allowed(folder) {
            guard await allow(folder) else { return Self.declined }
        }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        let site = Address.siteHost(of: address) ?? "this page"
        guard await permit(.inPage(address), "Attach \(names) on \(site)?") else { return refused }
        guard Address.siteHost(of: tab.address) == Address.siteHost(of: address) else { return "The page changed; read the tab again." }
        var sent: [[String: String]] = []
        for url in files {
            guard let data = try? Data(contentsOf: url) else { return "Couldn't read \(url.lastPathComponent)." }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            sent.append(["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()])
        }
        tab.agent.begin("Attaching \(names)", by: driver, stop: stopTurn)
        defer { tab.agent.end() }
        tab.built?.actedOnBehalf()
        switch await page(tab, "attach", ["n": n, "files": sent]) {
        case "done": return "Attached \(names) to element \(n) in \(Self.line(tab)). Not submitted; read the tab to see the page took it."
        case "gone": return "Element \(n) isn't there any more; read the tab again."
        case "not-a-file-field": return "Element \(n) isn't an upload field, nor next to one. Read the tab for the file field."
        case "one-file-only": return "That field takes one file; attach one."
        case "locked": return "That field can't take files now (it's disabled)."
        default: return "The page didn't take the files."
        }
    }

    /// Whether files in `folder` may be attached: it, or a folder it is in,
    /// is allowed for good or for this chat.
    private func allowed(_ folder: String) -> Bool {
        let granted = prefs.aiFolders + Array(chat.flatMap { Self.chatFolders[$0] } ?? [])
        return granted.contains { folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Asks the person, in the chat, to let files from `folder` be attached.
    private func allow(_ folder: String) async -> Bool {
        guard let chat, let conversation = Assistant.shared.conversation(chat), conversation.busy else { return false }
        let shown = (folder as NSString).abbreviatingWithTildeInPath
        let thisChat = "Allow for this chat", always = "Always allow", deny = "Don't allow"
        let question = Conversation.Question(
            text: "Let the assistant attach files from \(shown) to pages?",
            options: [
                .init(label: thisChat, description: "Until this chat is over"),
                .init(label: always, description: "Listed in Settings › AI, where you can take it back"),
                .init(label: deny),
            ])
        switch await conversation.ask(question) {
        case thisChat?:
            Self.chatFolders[chat, default: []].insert(folder)
            return true
        case always?:
            if !prefs.aiFolders.contains(folder) { prefs.aiFolders.append(folder) }
            return true
        case let answer?:
            // Words of their own instead: a no, with what they said told to the model.
            if answer != deny { conversation.addSteering(answer) }
            return false
        case nil:
            return false
        }
    }
}
