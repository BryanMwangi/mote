import AppKit
import MoteAI
import MoteCore

/// The tabs: listing them with what they're doing, bringing one forward,
/// opening, closing, moving, pinning, muting, reloading, and going places.
extension AssistantTools {
    private static let tabsSchema = #""tabs":{"type":"array","items":{"type":"string"},"description":"Tab ids from list_tabs"}"#
    private static let dryRun = #""dry_run":{"type":"boolean","description":"Say what would happen, without doing it or asking"}"#

    var tabTools: [Tool] {
        var tools = [
            Tool(
                name: "list_tabs",
                description:
                    "Every open tab in every window and space (not private ones): id, title, address, whether it's in front, an essential, pinned, in a folder, playing sound, muted or asleep, when it was last used, its window and space.",
                schema: #"{"type":"object","properties":{"window":{"type":"integer"},"space":{"type":"string"}}}"#)
        ]
        guard acts else { return tools }
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        tools += [
            Tool(name: "select_tab", description: "Brings a tab to the front, in its window and space.", schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
            Tool(
                name: "open_tab", description: "Opens an address in a new tab. The person is asked first.",
                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
            Tool(
                name: "close_tabs",
                description:
                    "Closes tabs, such as duplicates or ones not used in a while, asking the person once for all of them; they can reopen them all from the notice. Essentials and pinned tabs only let their page go.",
                schema: "{\"type\":\"object\",\"properties\":{\(Self.tabsSchema),\(Self.dryRun)},\"required\":[\"tabs\"]}"),
            Tool(
                name: "move_tabs",
                description:
                    "Moves tabs to another space (by name), another window (by number, or \"new\"), or into a folder by name (made if there's none; the tabs are pinned there). Asks first for spaces and windows.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(Self.tabsSchema),\"space\":{\"type\":\"string\"},\"window\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\"},\(Self.dryRun)},\"required\":[\"tabs\"]}"),
            Tool(
                name: "pin_tabs", description: "Pins tabs, or unpins them (pinned: false).",
                schema: "{\"type\":\"object\",\"properties\":{\(Self.tabsSchema),\"pinned\":{\"type\":\"boolean\"}},\"required\":[\"tabs\"]}"),
            Tool(
                name: "mute_tabs", description: "Mutes tabs, or unmutes them (muted: false).",
                schema: "{\"type\":\"object\",\"properties\":{\(Self.tabsSchema),\"muted\":{\"type\":\"boolean\"}},\"required\":[\"tabs\"]}"),
            Tool(name: "reload_tabs", description: "Reloads tabs.", schema: "{\"type\":\"object\",\"properties\":{\(Self.tabsSchema)},\"required\":[\"tabs\"]}"),
            Tool(
                name: "navigate", description: "In an open tab: goes to an address, or back or forward. Asks first, per site.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"url\":{\"type\":\"string\"},\"go\":{\"type\":\"string\",\"enum\":[\"back\",\"forward\"]}},\"required\":[\"tab\"]}"),
        ]
        return tools
    }

    func runTab(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "list_tabs":
            return listTabs(window: input["window"]?.int, space: input["space"]?.string)
        case "select_tab":
            guard await permit(.gentle, "") else { return refused }
            guard let found = find(input) else { return "There's no open tab with that id; list the tabs again." }
            bringForward(found)
            return "“\(found.tab.label)” is in front."
        case "open_tab":
            guard let url = web(input["url"]?.string) else { return "That isn't a web address." }
            guard await permit(.inPage(url), "Open \(url.absoluteString) in a new tab?") else { return refused }
            browser.open(url, foreground: true)
            return "Opened."
        case "close_tabs":
            return await closeTabs(input)
        case "move_tabs":
            return await moveTabs(input)
        case "pin_tabs":
            guard await permit(.gentle, "") else { return refused }
            let (found, missing) = find(all: input)
            let pinning = input["pinned"]?.bool ?? true
            for item in found where item.tab.pin == nil && item.tab.kept != pinning {
                pinning ? item.browser.keep(item.tab) : item.browser.unkeep(item.tab)
            }
            return "\(pinning ? "Pinned" : "Unpinned") \(found.count)." + Self.missing(missing)
        case "mute_tabs":
            guard await permit(.gentle, "") else { return refused }
            let (found, missing) = find(all: input)
            let muting = input["muted"]?.bool ?? true
            for item in found where item.tab.muted != muting { item.tab.toggleMute() }
            return "\(muting ? "Muted" : "Unmuted") \(found.count)." + Self.missing(missing)
        case "reload_tabs":
            guard await permit(.gentle, "") else { return refused }
            let (found, missing) = find(all: input)
            for item in found where !item.parked { item.tab.reload() }
            let away = found.filter(\.parked).count
            return "Reloaded \(found.count - away)." + (away > 0 ? " \(away) in other spaces load when shown." : "") + Self.missing(missing)
        case "navigate":
            return await navigate(input)
        default:
            return nil
        }
    }

    // MARK: -

    private func listTabs(window: Int?, space: String?) -> String {
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        let shown = everyTab.filter { found in
            (window == nil || found.window == window)
                && (space == nil || found.space?.name.localizedCaseInsensitiveCompare(space ?? "") == .orderedSame)
                && !found.tab.isBlank
        }
        guard !shown.isEmpty else { return "No tabs match." }
        let folders = Dictionary(FolderStore.shared.bySpace.values.flatMap { $0 }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return shown.map { found in
            let tab = found.tab
            var marks: [String] = []
            if !found.parked, found.browser.activeID == tab.id { marks.append("in front") }
            if tab.pin != nil { marks.append("essential") } else if tab.kept { marks.append("pinned") }
            if let folder = tab.folder, let name = folders[folder] { marks.append("in folder “\(name)”") }
            if tab.noisy { marks.append("playing sound") }
            if tab.muted { marks.append("muted") }
            if tab.asleep { marks.append("asleep") }
            let place = "window \(found.window)" + (found.space.map { ", space “\($0.name)”" } ?? "")
            return [
                Self.id(tab), tab.label, tab.address?.absoluteString ?? "", marks.joined(separator: ", "),
                "used \(when.localizedString(for: tab.touched, relativeTo: Date()))", place,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// To the front: its window, its space, then the tab.
    func bringForward(_ found: Found) {
        found.browser.window?.makeKeyAndOrderFront(nil)
        if found.parked, let space = found.space { found.browser.switchSpace(to: space.id) }
        found.browser.select(found.tab)
    }

    private func closeTabs(_ input: JSON) async -> String {
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let tabs = found.map(\.tab)
        let names = Self.names(tabs)
        if input["dry_run"]?.bool == true { return "Would close \(tabs.count): \(names)." + Self.missing(missing) }
        guard await permit(.destructive, tabs.count == 1 ? "Close \(names)?" : "Close \(tabs.count) tabs: \(names)?") else {
            return refused
        }
        for (browser, group) in Dictionary(grouping: found, by: { ObjectIdentifier($0.browser) }).compactMap({ ($0.value.first?.browser, $0.value) }) {
            browser?.closeTogether(group.map(\.tab))
        }
        return "Closed \(tabs.count); the person can reopen them all from the notice." + Self.missing(missing)
    }

    private func moveTabs(_ input: JSON) async -> String {
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let tabs = found.map(\.tab)
        let names = Self.names(tabs)
        if let folder = input["folder"]?.string, !folder.isEmpty {
            if input["dry_run"]?.bool == true { return "Would put \(tabs.count) in folder “\(folder)”: \(names)." }
            guard await permit(.gentle, "") else { return refused }
            let here = found.filter { !$0.parked && $0.browser === browser }
            let id = browser.folder(named: folder)
            for item in here { browser.move(item.tab, toFolder: id) }
            let away = found.count - here.count
            return "Put \(here.count) in “\(folder)”." + (away > 0 ? " \(away) are in another window or space; bring them here first." : "") + Self.missing(missing)
        }
        if let name = input["space"]?.string {
            guard let space = browser.spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                return "There's no space called “\(name)”. Spaces: \(browser.spaces.map(\.name).joined(separator: ", "))."
            }
            if input["dry_run"]?.bool == true { return "Would move \(tabs.count) to “\(space.name)”: \(names)." }
            guard await permit(.destructive, "Move \(tabs.count == 1 ? names : "\(tabs.count) tabs: \(names)") to “\(space.name)”?") else {
                return refused
            }
            let movable = found.filter { !$0.parked && $0.browser === browser && $0.space?.id != space.id }
            for item in movable { browser.move(item.tab, toSpace: space.id) }
            return "Moved \(movable.count) to “\(space.name)”." + Self.missing(missing)
        }
        if let window = input["window"]?.string {
            let windows = Windows.shared.all
            let target: Browser? = window == "new" ? nil : Int(window).flatMap { windows.indices.contains($0 - 1) ? windows[$0 - 1] : nil }
            guard window == "new" || target != nil else { return "There's no window \(window); there are \(windows.count)." }
            if input["dry_run"]?.bool == true { return "Would move \(tabs.count) to \(window == "new" ? "a new window" : "window \(window)"): \(names)." }
            guard await permit(.destructive, "Move \(tabs.count == 1 ? names : "\(tabs.count) tabs: \(names)") to \(window == "new" ? "a new window" : "window \(window)")?") else {
                return refused
            }
            var moved = 0
            var into = target
            for item in found where !item.parked && !item.tab.held && item.browser !== into {
                item.browser.move(item.tab, to: into)
                moved += 1
                // The rest follow the first into the window it made.
                if into == nil { into = Windows.shared.all.last }
            }
            return "Moved \(moved)." + (moved < found.count ? " Essentials, pinned tabs and ones in other spaces stay." : "") + Self.missing(missing)
        }
        return "Say where to: a space, a window, or a folder."
    }

    private func navigate(_ input: JSON) async -> String {
        guard let found = find(input) else { return "There's no open tab with that id; list the tabs again." }
        let tab = found.tab
        if let go = input["go"]?.string {
            guard let here = tab.address, await permit(.inPage(here), "Go \(go) in “\(tab.label)”?") else {
                return refused
            }
            go == "back" ? tab.back() : tab.forward()
            return "Went \(go)."
        }
        guard let url = web(input["url"]?.string) else { return "Give an address, or go: back or forward." }
        guard await permit(.inPage(url), "Go to \(url.absoluteString) in “\(tab.label)”?") else { return refused }
        found.browser.go(tab, to: url)
        return "Going to \(url.absoluteString)."
    }
}
