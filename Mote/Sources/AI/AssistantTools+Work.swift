import AppKit
import MoteAI
import MoteCore

/// Work across tabs and for the person: reading several tabs at once to
/// compare or combine them, filling a whole form in one go, and what to
/// remember from chat to chat.
extension AssistantTools {
    var workTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        var tools = [
            Tool(
                name: "read_tabs",
                description:
                    "Reads up to 12 tabs at once, side by side: each one's title, address and text (a PDF's too), shorter the more there are. Use it to compare, summarise or combine several tabs, rather than read_tab one by one. Give tab ids, or matching: words in their titles or addresses.",
                schema: #"{"type":"object","properties":{"tabs":{"type":"array","items":{"type":"string"}},"matching":{"type":"string"}}}"#),
            Tool(
                name: "fill_form",
                description:
                    "Fills a whole form in a tab in one go: fields by the numbers read_tab listed, or by their labels, to text; \"on\"/\"off\" for check boxes; an option for lists. Says what went where, and which fields the page would still refuse. Asks first, per site. Never passwords: use sign_in. Doesn't submit it.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"values\":{\"type\":\"object\",\"description\":\"Element number or label to value\"}},\"required\":[\"tab\",\"values\"]}"),
        ]
        guard !outside else { return tools }
        tools += [
            Tool(
                name: "remember",
                description:
                    "Keeps something for every chat from now on: what the person asks you to remember, or a plainly lasting preference they state. Not passing details, never passwords or secrets.",
                schema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#),
            Tool(name: "forget", description: "Forgets something remembered, by its id.", schema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#),
            Tool(name: "memories", description: "What's remembered, with ids.", schema: #"{"type":"object","properties":{}}"#),
        ]
        return tools
    }

    func runWork(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "read_tabs":
            return await readTabs(input)
        case "fill_form":
            return await fillForm(input)
        case "remember":
            guard !outside, !browser.isPrivate else { return "Nothing is remembered from a private window." }
            guard Memories.shared.on else { return "Memory is off: the person can turn it on in Settings › AI › Memory." }
            guard let text = input["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "Say what to remember." }
            let memory = Memories.shared.remember(text)
            return "Remembered [\(memory.id)]: \(memory.text)" + record("Remembered “\(memory.text.prefix(60))”") {
                _ = Memories.shared.forget(memory.id)
                return "Forgot it again."
            }
        case "forget":
            guard let id = input["id"]?.string, let gone = Memories.shared.forget(id.lowercased()) else {
                return "Nothing remembered has that id; list them with memories."
            }
            return "Forgot: \(gone.text)" + record("Forgot “\(gone.text.prefix(60))”") {
                Memories.shared.remember(gone.text)
                return "Remembered it again."
            }
        case "memories":
            let all = Memories.shared.all
            return all.isEmpty ? "Nothing is remembered." : all.map { "\($0.id)\t\($0.text)" }.joined(separator: "\n")
        default:
            return nil
        }
    }

    // MARK: Many tabs

    private func readTabs(_ input: JSON) async -> String {
        var chosen = find(all: input).found
        if let words = input["matching"]?.string?.lowercased(), !words.isEmpty {
            let needles = words.split(separator: " ").map(String.init)
            chosen += everyTab.filter { found in
                let haystack = (found.tab.label + " " + (found.tab.address?.absoluteString ?? "")).lowercased()
                return needles.allSatisfy(haystack.contains) && !chosen.contains { $0.tab === found.tab }
            }
        }
        chosen = Array(chosen.filter { !$0.tab.isBlank }.prefix(12))
        guard !chosen.isEmpty else { return "No tabs match; list them with list_tabs." }
        // Shared out: twelve tabs get less each than two.
        let each = max(2_500, Self.most * 3 / chosen.count)
        // All at once: each read waits on its own page, not on the others'.
        let reads = chosen.map { found in Task { await self.readOne(found.tab, most: each) } }
        var read: [String] = []
        for one in reads { read.append(await one.value) }
        return read.joined(separator: "\n\n════════\n\n")
    }

    /// One tab's text for read_tabs: a PDF's pages, a page awake as it is, or
    /// one asleep read out of sight rather than woken.
    private func readOne(_ tab: Tab, most: Int) async -> String {
        let head = "\(Self.line(tab))\n"
        if let text = await pdfText(of: tab) { return head + String(text.prefix(most)) }
        if tab.built != nil, !tab.asleep, let text = await tab.capturePageContext()?.text, !text.isEmpty {
            return head + String(text.prefix(most))
        }
        guard let url = tab.pending ?? tab.address, ["http", "https"].contains(url.scheme ?? "") else { return head + "(nothing to read)" }
        return head + String((await ReadAway.text(of: url, store: tab.store)).prefix(most))
    }

    // MARK: Forms

    private func fillForm(_ input: JSON) async -> String {
        guard let found = find(input) else { return Self.noTab }
        let tab = found.tab
        guard let values = input["values"]?.fields, !values.isEmpty else { return "Give the fields and what goes in them." }
        guard tab.built != nil, let address = tab.address else { return "\(Self.line(tab)) is asleep; read it first, which wakes it." }
        guard await permit(.inPage(address), "Fill \(values.count) field\(values.count == 1 ? "" : "s") on \(Address.siteHost(of: address) ?? "this page")?") else {
            return refused
        }
        if let taken = taken(tab) { return taken }
        working(on: tab, "Filling in the form")
        defer { found.tab.agent.end() }
        var rows: [String] = []
        var undo: [(Int, String)] = []
        for (key, value) in values.sorted(by: { (Int($0.key) ?? .max) < (Int($1.key) ?? .max) }) {
            let text = value.string ?? value.int.map(String.init) ?? value.bool.map { $0 ? "on" : "off" } ?? ""
            // A number read_tab gave, or the field whose label says so.
            var n = Int(key)
            if n == nil { n = (await page(tab, "find-field", ["label": key])).flatMap(Int.init) }
            guard let n else {
                rows.append("- “\(key)”: no field has that label")
                continue
            }
            let kind = await page(tab, "kind", ["n": n]) ?? ""
            let result: String?
            switch kind {
            case "checkbox", "radio":
                result = await page(tab, "check", ["n": n, "on": ["on", "yes", "true", "1", "x"].contains(text.lowercased())])
            case "select":
                result = await page(tab, "choose", ["n": n, "value": text])
            case "password":
                result = "password"
            case "file":
                result = "file"
            default:
                let was = await page(tab, "read", ["n": n])
                result = await page(tab, "write", ["n": n, "text": text, "how": "replace"])
                if result == "done", let was { undo.append((n, was)) }
            }
            rows.append("- \(key) → “\(text)”: " + (result == "done" ? "filled" : Self.formSaid(result)))
        }
        let filled = undo
        // What the page would still refuse, so the model fixes it before sending.
        if let left = await page(tab, "problems"), !left.isEmpty {
            rows.append("Not accepted yet (required and empty, or invalid):\n" + left.replacingOccurrences(of: Self.item, with: "\n"))
        }
        return "In \(Self.line(tab)), not submitted:\n" + rows.joined(separator: "\n") + record("Filled a form in \(Self.line(tab))") { [weak self] in
            guard let self else { return "Not now." }
            for (n, was) in filled { _ = await self.page(tab, "write", ["n": n, "text": was, "how": "replace"]) }
            return "Put the fields back as they were."
        }
    }

    private static func formSaid(_ result: String?) -> String {
        switch result {
        case "gone": "gone (the page changed; read the tab again)"
        case "password": "left alone: Mote never writes passwords; use sign_in"
        case "file": "an upload field: use attach_file"
        case "no-options": "its list didn't open; click it, read the tab and pick the option"
        case "locked": "can't be changed"
        case "not-editable": "not something to write in"
        case .some(let other) where other.hasPrefix("no-option: "): "no such option; it offers \(other.dropFirst(11))"
        case .some(let other): other
        case nil: "the page didn't answer"
        }
    }
}
