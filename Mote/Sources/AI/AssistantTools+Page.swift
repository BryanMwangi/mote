import AppKit
import Combine
import MoteAI
import MoteCore
import WebKit

/// Inside a page: reading it with what can be clicked or typed into, and
/// clicking, writing, choosing, ticking, scrolling, pressing keys, finding
/// words and reading tables there. The page side is Scripts/src/assistant-page.ts,
/// run on demand in Mote's own world.
extension AssistantTools {
    var pageTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        let element = #""element":{"type":"integer","description":"Its number from read_tab"}"#
        func schema(_ properties: String, _ required: [String]) -> String {
            "{\"type\":\"object\",\"properties\":{\(properties)},\"required\":[\(required.map { "\"\($0)\"" }.joined(separator: ","))]}"
        }
        var tools = [
            Tool(
                name: "read_tab",
                description:
                    "An open tab's text, and a numbered list of what can be clicked or typed into. Numbers stay the same until the page changes.",
                schema: schema(tab, ["tab"])),
            Tool(name: "get_selection", description: "The words the person has selected in a tab (the one in front, if none is given).", schema: schema(tab, [])),
            Tool(
                name: "find_in_page", description: "Where words appear in a tab, up to twenty places, each with what's around it.",
                schema: schema(tab + #","text":{"type":"string"}"#, ["tab", "text"])),
            Tool(name: "extract_tables", description: "A tab's tables, as Markdown.", schema: schema(tab, ["tab"])),
            Tool(
                name: "read_field", description: "What a field or editor read_tab listed holds now. Never a password.",
                schema: schema(tab + "," + element, ["tab", "element"])),
        ]
        // Listed even with acting off: asked for, the model hears how to turn it on.
        tools += [
            Tool(name: "click", description: "Clicks an element read_tab listed. Asks first, per site.", schema: schema(tab + "," + element, ["tab", "element"])),
            Tool(
                name: "write",
                description:
                    "Writes text into a field, text area or editor read_tab listed (an email's body, a reply, a form), replacing what's there, inserting at the caret, or appending. Without an element, where the person's caret is in the tab in front. Asks first, per site. Never passwords.",
                schema: schema(
                    tab + "," + element + #","text":{"type":"string"},"how":{"type":"string","enum":["replace","insert","append"]}"#, ["text"])),
            Tool(
                name: "select_option", description: "Picks an option, by its value or words, in a list read_tab listed. Asks first, per site.",
                schema: schema(tab + "," + element + #","value":{"type":"string"}"#, ["tab", "element", "value"])),
            Tool(
                name: "check", description: "Ticks or unticks a box read_tab listed. Asks first, per site.",
                schema: schema(tab + "," + element + #","on":{"type":"boolean"}"#, ["tab", "element"])),
            Tool(
                name: "scroll", description: "Scrolls a tab: to the top or bottom, to an element, or by some points (a screen if none).",
                schema: schema(tab + "," + element + #","to":{"type":"string","enum":["top","bottom"]},"by":{"type":"number"}"#, ["tab"])),
            Tool(
                name: "press_key",
                description: "Presses a key in a tab, at an element or wherever the focus is: Enter, Escape, Tab, Backspace, Space, or an arrow. Asks first, per site.",
                schema: schema(
                    tab + "," + element + #","key":{"type":"string","enum":["Enter","Escape","Tab","Backspace","Space","ArrowUp","ArrowDown","ArrowLeft","ArrowRight"]}"#,
                    ["tab", "key"])),
        ]
        return tools
    }

    func runPage(_ call: ToolCall) async -> String? {
        let input = call.input
        let names = ["read_tab", "get_selection", "find_in_page", "extract_tables", "read_field", "click", "write", "fill", "select_option", "check", "scroll", "press_key"]
        guard names.contains(call.name) else { return nil }
        // The selection needs no tab named: the one in front.
        if call.name == "get_selection", input["tab"] == nil {
            guard let tab = browser.active else { return "There's no tab in front." }
            return (await page(tab, "selection")).flatMap { $0.isEmpty ? nil : $0 } ?? "Nothing is selected."
        }
        // Writing where the caret is: the tab in front.
        let found = find(input) ?? (call.name == "write" && input["tab"] == nil ? browser.active.flatMap { active in everyTab.first { $0.tab === active } } : nil)
        guard let found else { return "There's no open tab with that id; list the tabs again." }
        let tab = found.tab
        if call.name == "read_tab" {
            // A PDF: its text page by page, and whether it has fields.
            if let text = await pdfText(of: tab) { return text }
            _ = tab.wake()
            let text = await tab.capturePageContext()?.text ?? ""
            let outline = await page(tab, "outline") ?? ""
            return "\(tab.label)\n\(tab.address?.absoluteString ?? "")\n\n\(String(text.prefix(Self.most)))\n\nElements:\n\(outline)"
        }
        guard tab.built != nil, let address = tab.address else { return "“\(tab.label)” is asleep; read it first, which wakes it." }
        let n = input["element"]?.int
        var args: [String: Any] = [:]
        if let n { args["n"] = n }
        switch call.name {
        case "get_selection":
            let said = await page(tab, "selection") ?? ""
            return said.isEmpty ? "Nothing is selected in “\(tab.label)”." : said
        case "find_in_page":
            let found = (await page(tab, "find", ["text": input["text"]?.string ?? ""]) ?? "").split(separator: Self.item).map(String.init)
            return found.isEmpty ? "The words aren't on the page." : found.enumerated().map { "\($0.offset + 1). …\($0.element)…" }.joined(separator: "\n")
        case "extract_tables":
            return (await page(tab, "tables")).flatMap { $0.isEmpty ? nil : $0 } ?? "The page has no tables."
        case "read_field":
            return Self.said(await page(tab, "read", args), n: n)
        case "scroll":
            guard await permit(.gentle, "") else { return refused }
            if let to = input["to"]?.string { args["to"] = to }
            if let by = input["by"]?.double { args["by"] = by }
            show(found, "Scrolling")
            tab.agent.effects.send(.scroll(down: input["to"]?.string != "top" && (input["by"]?.double ?? 1) > 0))
            defer { tab.agent.end() }
            return Self.said(await page(tab, "scroll", args), n: n, done: "Scrolled.")
        default:
            break
        }
        // Acting in the page: shown on the page, asked per site, naming what and where.
        let what = n == nil ? "where the caret is" : Self.named(await page(tab, "describe", args), call.name, n: n ?? 0)
        show(found, Self.caption(call.name, what: what))
        let box = n == nil ? nil : Self.box(await page(tab, "rect", args))
        if let box { tab.agent.effects.send(.move(box)) }
        defer { tab.agent.end(then: finished(found)) }
        let site = Address.siteName(for: address)
        let text = input["text"]?.string ?? ""
        let question: String
        switch call.name {
        case "click": question = "Click \(what) on \(site)?"
        case "write", "fill": question = "Write “\(text.prefix(80))\(text.count > 80 ? "…" : "")” into \(what) on \(site)?"
        case "select_option": question = "Choose “\(input["value"]?.string ?? "")” in \(what) on \(site)?"
        case "check": question = "\(input["on"]?.bool == false ? "Untick" : "Tick") \(what) on \(site)?"
        default: question = "Press \(input["key"]?.string ?? "Enter") at \(what) on \(site)?"
        }
        guard await permit(.inPage(address), question) else { return refused }
        // The page mustn't have moved to another site while asked.
        guard Address.siteHost(of: tab.address) == Address.siteHost(of: address) else { return "The page changed; read the tab again." }
        if let box { tab.agent.effects.send(call.name == "click" ? .click(box) : call.name == "write" || call.name == "fill" ? .write(box) : .move(box)) }
        // The cursor gets there first.
        if box != nil, !Glow.stillness { try? await Task.sleep(for: .milliseconds(380)) }
        switch call.name {
        case "click":
            return Self.said(await page(tab, "click", args), n: n, done: "Clicked.")
        case "write", "fill":
            args["text"] = text
            args["how"] = input["how"]?.string ?? "replace"
            return Self.said(await page(tab, "write", args), n: n, done: "Written.")
        case "select_option":
            args["value"] = input["value"]?.string ?? ""
            return Self.said(await page(tab, "choose", args), n: n, done: "Chosen.")
        case "check":
            args["on"] = input["on"]?.bool ?? true
            return Self.said(await page(tab, "check", args), n: n, done: input["on"]?.bool == false ? "Unticked." : "Ticked.")
        default:
            return await press(input["key"]?.string ?? "Enter", in: tab, args: args)
        }
    }

    /// The work shown on the tab's page: it comes to the front, and the
    /// overlay says who's doing what, with Stop.
    private func show(_ found: Found, _ caption: String) {
        if found.browser.active !== found.tab || found.parked { bringForward(found) }
        found.tab.agent.begin(caption, by: driver, stop: stopTurn)
    }

    /// Once the work on a tab that has gone out of sight is done, a notice.
    private func finished(_ found: Found) -> () -> Void {
        { [weak browser = found.browser, tab = found.tab] in
            guard let browser, browser.active !== tab else { return }
            browser.announce(
                Announcement(
                    "Done on “\(tab.label)”", symbol: "sparkle", action: .init(title: "Show") { [weak browser] in browser?.select(tab) }))
        }
    }

    /// An element by what it says, else by what it is.
    private static func named(_ said: String?, _ tool: String, n: Int) -> String {
        if let said, !said.isEmpty { return "“\(said)”" }
        switch tool {
        case "write", "fill": return "the text box"
        case "check": return "the box"
        case "select_option": return "the list"
        default: return "element \(n)"
        }
    }

    private static func caption(_ tool: String, what: String) -> String {
        switch tool {
        case "click": "Clicking \(what)"
        case "write", "fill": "Writing in \(what)"
        case "select_option": "Choosing in \(what)"
        case "check": "Ticking \(what)"
        default: "Pressing a key at \(what)"
        }
    }

    /// The page script's rectangle, in CSS pixels.
    private static func box(_ json: String?) -> CGRect? {
        guard let json, let place = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double],
            let x = place["x"], let y = place["y"], let w = place["w"], let h = place["h"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A key: through WebKit as a real key when the page is on screen, so
    /// the page can't tell it from the person's; else as the page's own events.
    private func press(_ key: String, in tab: Tab, args: [String: Any]) async -> String {
        if args["n"] != nil, await page(tab, "focus", args) == "gone" { return Self.said("gone", n: args["n"] as? Int) }
        let codes: [String: (UInt16, String)] = [
            "Enter": (36, "\r"), "Escape": (53, "\u{1b}"), "Tab": (48, "\t"), "Backspace": (51, "\u{7f}"), "Space": (49, " "),
            "ArrowUp": (126, "\u{F700}"), "ArrowDown": (125, "\u{F701}"), "ArrowLeft": (123, "\u{F702}"), "ArrowRight": (124, "\u{F703}"),
        ]
        guard let web = tab.built, let window = web.window, let (code, characters) = codes[key] else {
            var events = args
            events["key"] = key
            return Self.said(await page(tab, "key", events), n: nil, done: "Pressed \(key).")
        }
        window.makeFirstResponder(web)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)
            else { continue }
            type == .keyDown ? web.keyDown(with: event) : web.keyUp(with: event)
        }
        return "Pressed \(key)."
    }

    /// A page script's answer in words the model can act on.
    private static func said(_ result: String?, n: Int?, done: String = "Done.") -> String {
        switch result {
        case "done": return done
        case "gone": return "Element \(n ?? 0) is gone: the page changed; read the tab again."
        case "password": return "Mote never writes into, or reads, a password field."
        case "nowhere": return "Nothing has the caret in that tab; name an element."
        case "locked": return "That field can't be changed."
        case "not-editable": return "That isn't something to write in."
        case "not-a-list": return "That isn't a list to choose from."
        case .some(let other) where other.hasPrefix("no-option: "): return "No such option. It offers: \(other.dropFirst(11))"
        case .some(let other): return other
        case nil: return "The page didn't answer; it may be loading. Try again."
        }
    }

    private static let pageScript = InjectedScript.source("assistant-page") + "\nreturn moteAssistantPage.run(op, args);"

    /// Runs one of the page script's operations in a tab, in Mote's world:
    /// its answer as text (a list's items joined by `Self.item`, anything
    /// else as JSON); nil when the page didn't answer.
    func page(_ tab: Tab, _ op: String, _ args: [String: Any] = [:]) async -> String? {
        await withCheckedContinuation { done in
            tab.web.callInAppWorld(Self.pageScript, arguments: ["op": op, "args": args]) { value in
                let text: String? =
                    switch value {
                    case let said as String: said
                    case let list as [String]: list.joined(separator: Self.item)
                    case .some(let other) where JSONSerialization.isValidJSONObject(other):
                        (try? JSONSerialization.data(withJSONObject: other)).map { String(decoding: $0, as: UTF8.self) }
                    default: nil
                    }
                done.resume(returning: text)
            }
        }
    }

    /// Between a list's items in `page`'s answer.
    static let item = "\u{1e}"
}
