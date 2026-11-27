import AppKit
import MoteAI
import MoteCore

/// The tabs: listing them with what they're doing, bringing one forward,
/// opening, closing and reopening, moving anywhere (spaces, windows, folders,
/// out of them), pinning, essentials, muting, reloading, going places; and
/// the folders: listing, renaming, deleting. Every change says which tabs it
/// touched and how to put it back.
extension AssistantTools {
    private static let tabsSchema = #""tabs":{"type":"array","items":{"type":"string"},"description":"Tab ids from list_tabs"}"#
    private static let dryRun = #""dry_run":{"type":"boolean","description":"Say what would happen, without doing it or asking"}"#
    private static let folderSchema = #""folder":{"type":"string","description":"A folder's id from list_folders, or its name"}"#

    var tabTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        let object = { (properties: String, required: [String]) in
            "{\"type\":\"object\",\"properties\":{\(properties)}" + (required.isEmpty ? "" : ",\"required\":[\(required.map { "\"\($0)\"" }.joined(separator: ","))]") + "}"
        }
        return [
            Tool(
                name: "list_tabs",
                description:
                    "Every open tab in every window and space (not private ones): id, title, address, whether it's in front, an essential, pinned, in a folder (with the folder's id), playing sound, muted or asleep, when it was last used, its window and space.",
                schema: object(#""window":{"type":"integer"},"space":{"type":"string"}"#, [])),
            Tool(name: "select_tab", description: "Brings a tab to the front, in its window and space.", schema: object(tab, ["tab"])),
            Tool(
                name: "open_tab",
                description:
                    "Opens an address in a new tab, and gives its id. Asks the person first, per site. It opens in this chat's own window; give window (its number from list_tabs) only when the person asks for another.",
                schema: object(#""url":{"type":"string"},"background":{"type":"boolean"},"window":{"type":"string","description":"Only when the person asks: the window's number from list_tabs"}"#, ["url"])),
            Tool(
                name: "close_tabs",
                description:
                    "Closes tabs, asking the person once for all of them. Says which closed, each with a closed id for reopen_tabs. Essentials and pinned tabs only let their page go and stay.",
                schema: object("\(Self.tabsSchema),\(Self.dryRun)", ["tabs"])),
            Tool(
                name: "recently_closed",
                description: "Tabs closed recently in each window, newest first, each with the closed id reopen_tabs takes.",
                schema: object("", [])),
            Tool(
                name: "reopen_tabs", description: "Reopens closed tabs by their closed ids (from close_tabs or recently_closed), where they were, with their history.",
                schema: object(#""closed":{"type":"array","items":{"type":"string"}}"#, ["closed"])),
            Tool(
                name: "move_tabs",
                description:
                    "Moves tabs: to another space (by name), another window (by number, or \"new\"), into a folder (id or name; made if there's no such name, and the tabs are pinned there), out of their folder but still pinned (out_of_folder), or back among the open tabs, unpinned (to_open_tabs). Asks first for spaces and windows.",
                schema: object(
                    "\(Self.tabsSchema),\"space\":{\"type\":\"string\",\"description\":\"The name of the space to move them to, as list_spaces gives it\"},\"window\":{\"type\":\"string\",\"description\":\"The window's number from list_tabs, or \\\"new\\\"\"},\(Self.folderSchema),\"out_of_folder\":{\"type\":\"boolean\"},\"to_open_tabs\":{\"type\":\"boolean\"},\(Self.dryRun)",
                    ["tabs"])),
            Tool(name: "pin_tabs", description: "Pins tabs, or unpins them (pinned: false).", schema: object("\(Self.tabsSchema),\"pinned\":{\"type\":\"boolean\"}", ["tabs"])),
            Tool(
                name: "essentials", description: "Adds tabs to the essentials (the icons at the top), or takes them out (add: false) back to the open tabs.",
                schema: object("\(Self.tabsSchema),\"add\":{\"type\":\"boolean\"}", ["tabs"])),
            Tool(name: "mute_tabs", description: "Mutes tabs, or unmutes them (muted: false).", schema: object("\(Self.tabsSchema),\"muted\":{\"type\":\"boolean\"}", ["tabs"])),
            Tool(name: "reload_tabs", description: "Reloads tabs.", schema: object(Self.tabsSchema, ["tabs"])),
            Tool(
                name: "navigate", description: "In an open tab: goes to an address, or back or forward. Asks first, per site.",
                schema: object("\(tab),\"url\":{\"type\":\"string\"},\"go\":{\"type\":\"string\",\"enum\":[\"back\",\"forward\"]}", ["tab"])),
            Tool(
                name: "list_folders", description: "The folders of pinned tabs in every space: id, name, the folder it's in, its space, and its tabs.",
                schema: object("", [])),
            Tool(name: "rename_folder", description: "Renames a folder.", schema: object("\(Self.folderSchema),\"name\":{\"type\":\"string\"}", ["folder", "name"])),
            Tool(
                name: "delete_folder",
                description:
                    "Deletes a folder. keep_tabs (the default) keeps its tabs and folders, pinned, where it was; keep_tabs: false closes its tabs too. Asks first.",
                schema: object("\(Self.folderSchema),\"keep_tabs\":{\"type\":\"boolean\"},\(Self.dryRun)", ["folder"])),
        ]
    }

    func runTab(_ call: ToolCall) async -> String? {
        let input = call.input
        switch call.name {
        case "list_tabs":
            return listTabs(window: input["window"]?.int, space: input["space"]?.string)
        case "select_tab":
            guard await permit(.gentle, "") else { return refused }
            guard let found = find(input) else { return Self.noTab }
            bringForward(found)
            return "\(Self.line(found.tab)) is in front."
        case "open_tab":
            let (target, refusal) = await destination(input["url"]?.string)
            guard let url = target else { return refusal ?? "That isn't a web address, or a file:// one." }
            // A local page's folder is allowed already; a site is asked about.
            if !url.isFileURL, !(await permit(.inPage(url), "Open \(url.absoluteString) in a new tab?")) { return refused }
            // This chat's window, unless the person asked for another by number.
            var into = browser
            if let number = input["window"]?.string {
                let windows = Windows.shared.all
                guard let index = Int(number), windows.indices.contains(index - 1) else { return "There's no window \(number); there are \(windows.count)." }
                into = windows[index - 1]
            }
            let tab = into.open(url, foreground: input["background"]?.bool != true)
            let undo = record("Opened \(url.absoluteString)") { [weak browser = into] in
                guard let browser, browser.tab(tab.id) != nil else { return "It was already closed." }
                browser.closeTogether([tab])
                return "Closed it again."
            }
            return "Opened \(url.absoluteString) in tab \(Self.id(tab))." + undo
        case "close_tabs":
            return await closeTabs(input)
        case "recently_closed":
            return recentlyClosed()
        case "reopen_tabs":
            return reopen(input["closed"]?.array.compactMap(\.string) ?? [])
        case "move_tabs":
            return await moveTabs(input)
        case "pin_tabs":
            return await pinTabs(input)
        case "essentials":
            return await essentials(input)
        case "mute_tabs":
            guard await permit(.gentle, "") else { return refused }
            let (found, missing) = find(all: input)
            guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
            let muting = input["muted"]?.bool ?? true
            let changed = found.filter { $0.tab.muted != muting }.map(\.tab)
            changed.forEach { $0.toggleMute() }
            let undo = record("\(muting ? "Muted" : "Unmuted") \(Self.names(changed))") { changed.forEach { $0.toggleMute() }; return "Put back." }
            return "\(muting ? "Muted" : "Unmuted"):\n" + Self.lines(changed) + undo + Self.missing(missing)
        case "reload_tabs":
            guard await permit(.gentle, "") else { return refused }
            let (found, missing) = find(all: input)
            for item in found where !item.parked { item.tab.reload() }
            let away = found.filter(\.parked)
            return "Reloaded:\n" + Self.lines(found.filter { !$0.parked }.map(\.tab))
                + (away.isEmpty ? "" : "\nIn other spaces, loading when shown:\n" + Self.lines(away.map(\.tab))) + Self.missing(missing)
        case "navigate":
            return await navigate(input)
        case "list_folders":
            return listFolders()
        case "rename_folder":
            return await renameFolder(input)
        case "delete_folder":
            return await deleteFolder(input)
        default:
            return nil
        }
    }

    // MARK: - Saying what was touched

    static let noTab = "There's no open tab with that id; list the tabs again."

    /// A tab as the model is told it: “title” site (id).
    static func line(_ tab: Tab) -> String {
        "“\(tab.label)” \(tab.address.map { Address.displayString(for: $0) } ?? "") (\(id(tab)))"
    }

    static func lines(_ tabs: [Tab]) -> String {
        tabs.isEmpty ? "- none" : tabs.map { "- " + line($0) }.joined(separator: "\n")
    }

    /// Notes what was done for undo; the words telling the model how.
    func record(_ what: String, undo: (@MainActor () async -> String)?) -> String {
        guard let id = AssistantLedger.shared.record(what, chat: chat, turn: turn, undo: undo) else { return "\nThis can't be undone." }
        return "\nUndo with undo_actions [\"\(id)\"]."
    }

    // MARK: - Listing

    private func listTabs(window: Int?, space: String?) -> String {
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        let shown = everyTab.filter { found in
            (window == nil || found.window == window)
                && (space == nil || found.space?.name.localizedCaseInsensitiveCompare(space ?? "") == .orderedSame)
                && !found.tab.isBlank
        }
        guard !shown.isEmpty else { return "No tabs match." }
        let folders = Dictionary(allFolders.map { ($0.folder.id, $0.folder.name) }, uniquingKeysWith: { first, _ in first })
        return shown.map { found in
            let tab = found.tab
            var marks: [String] = []
            if !found.parked, found.browser.activeID == tab.id { marks.append("in front") }
            if tab.pin != nil { marks.append("essential") } else if tab.kept { marks.append("pinned") }
            if let folder = tab.folder, let name = folders[folder] { marks.append("in folder “\(name)” (\(Self.short(folder)))") }
            if tab.noisy { marks.append("playing sound") }
            if tab.muted { marks.append("muted") }
            if tab.asleep { marks.append("asleep") }
            if tab.pdf != nil { marks.append("a PDF") }
            // Where agents, sub-agents too, are at work, and on what.
            if tab.agent.working { marks.append("an agent at work: \(tab.agent.caption)") }
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
        // The chat doing the work stays in view on the tab it went to.
        let left = found.browser.active
        found.browser.select(found.tab)
        if let chat, left?.pageChat?.id == chat, found.browser.carryChat(from: left, to: found.tab, replacing: true) {
            found.browser.syncPageChat()
        }
    }

    // MARK: - Closing and reopening

    private func closeTabs(_ input: JSON) async -> String {
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let tabs = found.map(\.tab)
        let names = Self.names(tabs)
        if input["dry_run"]?.bool == true { return "Would close:\n" + Self.lines(tabs) + Self.missing(missing) }
        guard await permit(.destructive, tabs.count == 1 ? "Close \(names)?" : "Close \(tabs.count) tabs: \(names)?") else {
            return refused
        }
        let held = tabs.filter(\.held)
        let loose = found.filter { !$0.tab.held }
        // Each window's closed tabs, by the ghosts its closing left.
        var reopenable: [(ghost: Browser.Ghost, browser: Browser)] = []
        let byWindow = Dictionary(grouping: found, by: { ObjectIdentifier($0.browser) }).values.compactMap { group in group.first.map { ($0.browser, group) } }
        for (window, group) in byWindow {
            let before = Set(window.ghosts.map(\.id))
            window.closeTogether(group.map(\.tab))
            reopenable += window.ghosts.filter { !before.contains($0.id) }.map { ($0, window) }
        }
        var said = "Closed:\n" + Self.lines(loose.map(\.tab))
        if !reopenable.isEmpty {
            said += "\nClosed ids for reopen_tabs: " + reopenable.map { Self.short($0.ghost.id) }.joined(separator: ", ") + "."
        }
        if !held.isEmpty { said += "\nEssentials and pinned tabs stay; their pages were let go:\n" + Self.lines(held) }
        let ghosts = reopenable
        said += record("Closed \(Self.names(loose.map(\.tab)))") {
            for (ghost, window) in ghosts where window.ghosts.contains(ghost) { window.reopen(ghost, front: false) }
            return "Reopened \(ghosts.count)."
        }
        return said + Self.missing(missing)
    }

    private func recentlyClosed() -> String {
        let listed = Windows.shared.all.enumerated().flatMap { index, window in
            window.isPrivate ? [] : window.ghosts.reversed().map { "\(Self.short($0.id))\t\($0.label)\t\($0.url.absoluteString)\twindow \(index + 1)" }
        }
        return listed.isEmpty ? "No tabs were closed lately." : listed.prefix(50).joined(separator: "\n")
    }

    private func reopen(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "Give closed ids from close_tabs or recently_closed." }
        var opened: [Tab] = []
        var missing: [String] = []
        for id in ids.map({ $0.lowercased() }) {
            guard let window = Windows.shared.all.first(where: { $0.ghosts.contains { Self.short($0.id) == id } }),
                let ghost = window.ghosts.first(where: { Self.short($0.id) == id }), let tab = window.reopen(ghost, front: false)
            else {
                missing.append(id)
                continue
            }
            opened.append(tab)
        }
        return (opened.isEmpty ? "" : "Reopened:\n" + Self.lines(opened))
            + (missing.isEmpty ? "" : "\nNo closed tab has the id \(missing.joined(separator: ", ")); list them with recently_closed.")
    }

    // MARK: - Pinning and essentials

    private func pinTabs(_ input: JSON) async -> String {
        guard await permit(.gentle, "") else { return refused }
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let pinning = input["pinned"]?.bool ?? true
        let changed = found.filter { $0.tab.pin == nil && $0.tab.kept != pinning }
        let was = changed.map { ($0.tab, $0.browser, $0.tab.folder) }
        for item in changed { pinning ? item.browser.keep(item.tab) : item.browser.unkeep(item.tab) }
        let skipped = found.filter { $0.tab.pin != nil }.map(\.tab)
        var said = "\(pinning ? "Pinned" : "Unpinned"):\n" + Self.lines(changed.map(\.tab))
        if !skipped.isEmpty { said += "\nEssentials, left as they are (use essentials to take one out):\n" + Self.lines(skipped) }
        said += record("\(pinning ? "Pinned" : "Unpinned") \(Self.names(changed.map(\.tab)))") {
            for (tab, window, folder) in was {
                if pinning { window.unkeep(tab) } else { window.keep(tab); tab.folder = folder }
            }
            return "Put back."
        }
        return said + Self.missing(missing)
    }

    private func essentials(_ input: JSON) async -> String {
        guard await permit(.gentle, "") else { return refused }
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let adding = input["add"]?.bool ?? true
        let changed = found.filter { ($0.tab.pin != nil) != adding && !$0.parked }
        let was = changed.map { ($0.tab, $0.browser, $0.tab.kept, $0.tab.folder) }
        for item in changed { adding ? item.browser.pin(item.tab) : item.browser.unpin(item.tab) }
        let away = found.filter(\.parked).map(\.tab)
        var said = (adding ? "Added to the essentials:\n" : "Taken out of the essentials:\n") + Self.lines(changed.map(\.tab))
        if !away.isEmpty { said += "\nIn a space not showing; show it first:\n" + Self.lines(away) }
        said += record("\(adding ? "Added" : "Took") \(Self.names(changed.map(\.tab))) \(adding ? "to" : "out of") the essentials") {
            for (tab, window, kept, folder) in was {
                if adding {
                    window.unpin(tab)
                    if kept { window.keep(tab); tab.folder = folder }
                } else {
                    window.pin(tab)
                }
            }
            return "Put back."
        }
        return said + Self.missing(missing)
    }

    // MARK: - Moving

    private func moveTabs(_ input: JSON) async -> String {
        let (found, missing) = find(all: input)
        guard !found.isEmpty else { return "None of those tabs is open." + Self.missing(missing) }
        let tabs = found.map(\.tab)
        let names = Self.names(tabs)
        let dry = input["dry_run"]?.bool == true
        if let folder = input["folder"]?.string, !folder.isEmpty {
            let target = folderNamed(folder)
            if dry { return "Would put these in folder “\(target?.folder.name ?? folder)”:\n" + Self.lines(tabs) }
            guard await permit(.gentle, "") else { return refused }
            let here = found.filter { !$0.parked && $0.browser === browser }
            let id = target?.folder.id ?? browser.folder(named: folder)
            let was = here.map { ($0.tab, $0.tab.kept, $0.tab.folder) }
            for item in here { browser.move(item.tab, toFolder: id) }
            let away = found.filter { item in !here.contains { $0.tab === item.tab } }.map(\.tab)
            var said = "Put in “\(target?.folder.name ?? folder)” (\(Self.short(id))):\n" + Self.lines(here.map(\.tab))
            if !away.isEmpty { said += "\nIn another window or space; bring them here first:\n" + Self.lines(away) }
            let made = target == nil
            said += record("Put \(Self.names(here.map(\.tab))) in a folder") { [weak browser] in
                guard let browser else { return "That window is closed." }
                for (tab, kept, folder) in was {
                    tab.folder = folder
                    if !kept { browser.unkeep(tab) }
                }
                // A folder made for them goes too, if nothing else went in.
                if made, !browser.tabs.contains(where: { $0.folder == id }) {
                    FolderStore.shared.change(browser.spaceID) { $0.removeAll { $0.id == id } }
                }
                browser.writeSession(now: true)
                return "Put back."
            }
            return said + Self.missing(missing)
        }
        if input["out_of_folder"]?.bool == true || input["to_open_tabs"]?.bool == true {
            let open = input["to_open_tabs"]?.bool == true
            let moving = found.filter { !$0.parked && (open ? $0.tab.held : $0.tab.folder != nil) }
            if dry { return (open ? "Would unpin and put among the open tabs:\n" : "Would take out of their folders, still pinned:\n") + Self.lines(moving.map(\.tab)) }
            guard await permit(.gentle, "") else { return refused }
            let was = moving.map { ($0.tab, $0.browser, $0.tab.kept, $0.tab.folder, $0.tab.pin != nil) }
            for item in moving {
                if open {
                    if item.tab.pin != nil { item.browser.unpin(item.tab) }
                    item.browser.unfile(item.tab)
                } else {
                    item.browser.unfile(item.tab, toKeptAt: .max)
                }
            }
            var said = (open ? "Unpinned, now among the open tabs:\n" : "Out of their folders, still pinned:\n") + Self.lines(moving.map(\.tab))
            said += record("Moved \(Self.names(moving.map(\.tab))) out of their folders") {
                for (tab, window, kept, folder, essential) in was {
                    if essential { window.pin(tab) } else if kept { window.keep(tab); tab.folder = folder }
                }
                return "Put back."
            }
            return said + Self.missing(missing)
        }
        if let name = input["space"]?.string {
            guard let space = browser.spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                return "There's no space called “\(name)”. Spaces: \(browser.spaces.map(\.name).joined(separator: ", "))."
            }
            let movable = found.filter { !$0.parked && $0.browser === browser && $0.space?.id != space.id }
            let left = found.filter { item in !movable.contains { $0.tab === item.tab } }.map(\.tab)
            let notMoved = left.isEmpty ? "" : "\nNot moved (already in “\(space.name)”, or in another window or space):\n" + Self.lines(left)
            guard !movable.isEmpty else { return "Nothing moved to “\(space.name)”." + notMoved + Self.missing(missing) }
            if dry { return "Would move to “\(space.name)”:\n" + Self.lines(movable.map(\.tab)) + notMoved }
            let moving = Self.names(movable.map(\.tab))
            guard await permit(.destructive, "Move \(movable.count == 1 ? moving : "\(movable.count) tabs: \(moving)") to “\(space.name)”?") else {
                return refused
            }
            let from = browser.spaceID
            let addresses = movable.compactMap { $0.tab.pending ?? $0.tab.address }
            // As they are in that space now: one that keeps its own data opens them afresh, with new ids.
            let went = movable.compactMap { browser.move($0.tab, toSpace: space.id) }
            guard !went.isEmpty else { return "Couldn't move them to “\(space.name)”: Mote's spaces may be off, or the tabs have no address." + notMoved }
            var said = "Moved to “\(space.name)” (ids as they are there now):\n" + Self.lines(went)
            if went.count < movable.count { said += "\nCouldn't move \(movable.count - went.count) of them." }
            said += notMoved
            said += record("Moved \(Self.names(went)) to “\(space.name)”") { [weak browser] in
                guard let browser else { return "That window is closed." }
                // By address: a space that keeps its own data made fresh tabs.
                let there = browser.parked[space.id]?.tabs ?? []
                let back = there.filter { tab in addresses.contains { $0 == (tab.pending ?? tab.address) } }
                guard browser.spaceID == from else { return "Show the space they came from first." }
                for tab in back { browser.bring(tab, from: space.id, at: nil) }
                return back.isEmpty ? "They were moved on or closed since." : "Moved \(back.count) back."
            }
            return said + Self.missing(missing)
        }
        if let window = input["window"]?.string {
            let windows = Windows.shared.all
            let target: Browser? = window == "new" ? nil : Int(window).flatMap { windows.indices.contains($0 - 1) ? windows[$0 - 1] : nil }
            guard window == "new" || target != nil else { return "There's no window \(window); there are \(windows.count)." }
            let movable = found.filter { !$0.parked && !$0.tab.held && $0.browser !== target }
            if dry { return "Would move to \(window == "new" ? "a new window" : "window \(window)"):\n" + Self.lines(movable.map(\.tab)) }
            guard await permit(.destructive, "Move \(tabs.count == 1 ? names : "\(tabs.count) tabs: \(names)") to \(window == "new" ? "a new window" : "window \(window)")?") else {
                return refused
            }
            var into = target
            var moved: [(Tab, Browser)] = []
            for item in movable {
                item.browser.move(item.tab, to: into)
                moved.append((item.tab, item.browser))
                // The rest follow the first into the window it made.
                if into == nil { into = Windows.shared.all.last }
            }
            var said = "Moved to \(window == "new" ? "a new window" : "window \(window)"):\n" + Self.lines(moved.map(\.0))
            let left = found.filter { item in !moved.contains { $0.0 === item.tab } }.map(\.tab)
            if !left.isEmpty { said += "\nNot moved (essentials, pinned tabs, other spaces stay):\n" + Self.lines(left) }
            let went = moved
            said += record("Moved \(Self.names(moved.map(\.0))) to another window") {
                var back = 0
                for (tab, home) in went {
                    guard let now = Windows.shared.all.first(where: { $0.tab(tab.id) != nil }), now !== home else { continue }
                    now.move(tab, to: home)
                    back += 1
                }
                return "Moved \(back) back."
            }
            return said + Self.missing(missing)
        }
        return "Say where to: a space, a window, a folder, out_of_folder, or to_open_tabs."
    }

    private func navigate(_ input: JSON) async -> String {
        guard let found = find(input) else { return Self.noTab }
        let tab = found.tab
        let was = tab.address
        if let go = input["go"]?.string {
            guard let here = tab.address, await permit(.inPage(here), "Go \(go) in “\(tab.label)”?") else {
                return refused
            }
            go == "back" ? tab.back() : tab.forward()
            return "Went \(go) in \(Self.line(tab))."
        }
        let (target, refusal) = await destination(input["url"]?.string)
        guard let url = target else { return refusal ?? "Give an address, or go: back or forward." }
        if !url.isFileURL, !(await permit(.inPage(url), "Go to \(url.absoluteString) in “\(tab.label)”?")) { return refused }
        found.browser.go(tab, to: url)
        return "Going to \(url.absoluteString) in tab \(Self.id(tab)), from \(was?.absoluteString ?? "nothing")."
            + record("Took \(Self.line(tab)) to \(url.absoluteString)") { tab.back(); return "Went back." }
    }

    // MARK: - Folders

    /// Every space's folders of tabs.
    var allFolders: [(space: UUID, folder: Folder)] {
        FolderStore.shared.bySpace.flatMap { space, folders in folders.filter { $0.live == nil }.map { (space, $0) } }
    }

    /// A folder by id (or the start of one) or name, the space in front's first.
    func folderNamed(_ text: String) -> (space: UUID, folder: Folder)? {
        let all = allFolders.sorted { a, _ in a.space == browser.spaceID }
        let key = text.lowercased()
        return all.first { Self.short($0.folder.id) == key || $0.folder.id.uuidString.lowercased() == key }
            ?? all.first { $0.folder.name.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    /// The window showing a space, for changes to its folders' tabs.
    private func window(showing space: UUID) -> Browser? {
        Windows.shared.all.first { $0.spaceID == space && !$0.isPrivate }
    }

    private func listFolders() -> String {
        let folders = allFolders
        guard !folders.isEmpty else { return "There are no folders." }
        let names = Dictionary(folders.map { ($0.folder.id, $0.folder.name) }, uniquingKeysWith: { a, _ in a })
        let spaces = Dictionary(browser.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let tabs = everyTab
        return folders.map { space, folder in
            let inside = tabs.filter { $0.tab.folder == folder.id }.map { "“\($0.tab.label)” (\(Self.id($0.tab)))" }
            return [
                Self.short(folder.id), folder.name, folder.parent.flatMap { names[$0] }.map { "in “\($0)”" } ?? "",
                "space “\(spaces[space] ?? "?")”", inside.isEmpty ? "no tabs" : inside.joined(separator: ", "),
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func renameFolder(_ input: JSON) async -> String {
        guard let named = input["folder"]?.string, let found = folderNamed(named) else { return "There's no such folder; list them with list_folders." }
        guard let name = input["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "Give the new name." }
        guard await permit(.gentle, "") else { return refused }
        let was = found.folder.name
        let rename = { (to: String) in
            FolderStore.shared.change(found.space) { folders in
                if let at = folders.firstIndex(where: { $0.id == found.folder.id }) { folders[at].name = to }
            }
        }
        rename(name)
        return "Renamed “\(was)” to “\(name)” (\(Self.short(found.folder.id)))." + record("Renamed folder “\(was)” to “\(name)”") {
            rename(was)
            return "Named “\(was)” again."
        }
    }

    private func deleteFolder(_ input: JSON) async -> String {
        guard let named = input["folder"]?.string, let found = folderNamed(named) else { return "There's no such folder; list them with list_folders." }
        guard let window = window(showing: found.space) else { return "Its space isn't showing in any window; show it first." }
        let keeping = input["keep_tabs"]?.bool ?? true
        let folder = found.folder
        let family = Folder.family(of: folder.id, in: window.folders)
        let inside = window.tabs.filter { $0.folder.map(family.contains) == true }
        if input["dry_run"]?.bool == true {
            return "Would delete “\(folder.name)”" + (keeping ? ", keeping its tabs pinned:\n" : " and close its tabs:\n") + Self.lines(inside)
        }
        let question =
            keeping
            ? "Delete the folder “\(folder.name)”? Its tabs stay pinned." : "Delete the folder “\(folder.name)” and close its \(inside.count) tabs?"
        guard await permit(.destructive, question) else { return refused }
        let before = window.folders
        let homes = inside.map { ($0, $0.folder) }
        let ghostsBefore = Set(window.ghosts.map(\.id))
        if keeping { window.unpackFolder(folder.id) } else { window.deleteFolder(folder.id) }
        let ghosts = window.ghosts.filter { !ghostsBefore.contains($0.id) }
        let said = "Deleted the folder “\(folder.name)”" + (keeping ? "; its tabs stay pinned:\n" : ", and closed:\n") + Self.lines(inside)
        return said + record("Deleted folder “\(folder.name)”") { [weak window] in
            guard let window else { return "That window is closed." }
            FolderStore.shared.change(found.space) { folders in
                for old in before where !folders.contains(where: { $0.id == old.id }) { folders.append(old) }
            }
            if keeping {
                for (tab, home) in homes where window.tab(tab.id) != nil { tab.folder = home }
            } else {
                for ghost in ghosts {
                    guard let tab = window.reopen(ghost, front: false), let home = homes.first(where: { $0.0.address == ghost.url })?.1 else { continue }
                    window.keep(tab)
                    tab.folder = home
                }
            }
            window.writeSession(now: true)
            return "Put the folder back, with its tabs."
        }
    }
}
