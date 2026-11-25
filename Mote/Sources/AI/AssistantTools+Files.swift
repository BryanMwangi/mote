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
        if let taken = taken(tab) { return taken }
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
            guard await allow(folder) else {
                return "The person didn't allow files from \((folder as NSString).abbreviatingWithTildeInPath) to be attached."
            }
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
        working(on: tab, "Attaching \(names)")
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

    /// Where the assistant may go: a web address, or a local page (file://)
    /// in a folder allowed for this chat, asked for first if it isn't. The
    /// address, or why not; neither for what isn't an address at all.
    func destination(_ text: String?) async -> (url: URL?, refusal: String?) {
        if let url = web(text) { return (url, nil) }
        guard let text, let given = URL(string: text), given.isFileURL else { return (nil, nil) }
        let file = given.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: file.path) else { return (nil, "There's no file at \(file.path).") }
        let folder = file.deletingLastPathComponent().path
        if !allowed(folder), !(await allow(folder)) {
            return (nil, "The person didn't allow the assistant into \((folder as NSString).abbreviatingWithTildeInPath).")
        }
        return (file, nil)
    }

    /// Whether files in `folder` may be attached: it, or a folder it is in,
    /// is allowed for good or for this chat.
    private func allowed(_ folder: String) -> Bool {
        // Both sides as the file system resolves them: /private/tmp and /tmp are one folder.
        let real = { (path: String) in URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path }
        let folder = real(folder)
        let granted = (prefs.aiFolders + Array(chat.flatMap { Self.chatFolders[$0] } ?? [])).map(real)
        return granted.contains { folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Asks the person to let files from `folder` be attached: in the chat
    /// while its reply runs, else in an alert, as a helper working after the
    /// reply has ended asks (it was refused, unasked, before).
    private func allow(_ folder: String) async -> Bool {
        guard let chat else { return false }
        let shown = (folder as NSString).abbreviatingWithTildeInPath
        let thisChat = "Allow for this chat", always = "Always allow", deny = "Don't allow"
        guard let conversation = Assistant.shared.conversation(chat), conversation.busy else {
            let alert = NSAlert()
            alert.messageText = "Let the assistant use files from \(shown)?"
            alert.informativeText = (subAgent ? "One of its helpers asks, working on your task." : "The assistant asks, working on your task.") + " It can open them and attach them to pages."
            alert.addButton(withTitle: "Allow for This Chat")
            alert.addButton(withTitle: "Always Allow")
            alert.addButton(withTitle: "Don't Allow").keyEquivalent = "\u{1b}"
            let answer: NSApplication.ModalResponse
            if let window = browser.window {
                answer = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
            } else {
                answer = alert.runModal()
            }
            switch answer {
            case .alertFirstButtonReturn: Self.chatFolders[chat, default: []].insert(folder)
            case .alertSecondButtonReturn: if !prefs.aiFolders.contains(folder) { prefs.aiFolders.append(folder) }
            default: return false
            }
            return true
        }
        let question = Conversation.Question(
            text: "Let the assistant use files from \(shown): open them, and attach them to pages?",
            options: [
                .init(label: thisChat, description: "Until this chat is over"),
                .init(label: always, description: "Listed in Settings › AI, where you can take it back"),
                .init(label: deny),
            ])
        switch await asking(conversation, question) {
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
