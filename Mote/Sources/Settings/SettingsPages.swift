import AuthenticationServices
import MoteCore
import SwiftUI

// What each Settings page holds.

struct GeneralSettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    // Asked when the page shows, not each time it's made: one asks Launch
    // Services, the other looks on disk.
    @State private var isDefault = false
    /// The browsers there's something to bring from, and the one picked.
    @State private var browsers: [String] = []
    @State private var from = ""
    @State private var importing = false

    var body: some View {
        content.onAppear {
            isDefault = AppDelegate.isDefault
            browsers = ChromiumImporter.installed().map(\.name) + (ZenImporter.profiles().isEmpty ? [] : ["Zen"])
            from = Self.preferredSource(among: browsers)
        }
    }

    /// The one last picked, else the Mac's default browser, else the first.
    private static func preferredSource(among browsers: [String]) -> String {
        if let kept = Storage.settings.string(forKey: "import.from"), browsers.contains(kept) { return kept }
        let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.deletingPathExtension()
            .lastPathComponent
        return browsers.first { app?.localizedCaseInsensitiveContains($0) == true } ?? browsers.first ?? ""
    }

    /// Brings what the browser has: Zen's spaces and tabs in their panel;
    /// a Chromium browser's bookmarks, history and passwords at once.
    private func bring() {
        Storage.settings.set(from, forKey: "import.from")
        if from == "Zen" {
            browser.tuning = false
            browser.importingZen = true
            return
        }
        guard let source = ChromiumImporter.installed().first(where: { $0.name == from }) else { return }
        importing = true
        Task {
            let bookmarks = browser.takeBookmarks(from: source)
            let places = await browser.takePlaces(from: source)
            let passwords = (try? await browser.logins.bring(from: source).get()) ?? 0
            importing = false
            browser.announce("From \(source.name): \(bookmarks) bookmarks, \(places) history entries, \(passwords) passwords")
        }
    }

    @ViewBuilder private var content: some View {
        ProfileRows()

        SettingsSection("Mote and your Mac") {
            SettingRow(
                "Default browser",
                isDefault ? "Links you click in other apps open here" : "Links from other apps still open in another browser",
                symbol: "star", tint: Tint.orange
            ) { defaultControl }
            RowRule()
            SettingRow(
                "Look", "Light, dark, or whatever the Mac is using. Pages follow when they can", symbol: "circle.lefthalf.filled",
                tint: Tint.indigo, keywords: ["appearance", "theme"] + Look.allCases.map(\.title)
            ) {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            RowRule()
            SettingRow(
                "Show the whole address", "The full web address in the toolbar. Off, it shows only the site", symbol: "link",
                tint: Tint.teal, on: $prefs.showsFullAddress)
        }

        if !browsers.isEmpty {
            SettingsSection("Coming from another browser") {
                SettingRow(
                    "Import from",
                    from == "Zen"
                        ? "Its spaces, essentials, pinned and open tabs. Nothing in Zen changes"
                        : "Its bookmarks, history and passwords. Nothing in \(from) changes",
                    symbol: "square.and.arrow.down",
                    tint: Tint.blue, keywords: ["import"] + browsers
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: $from) { ForEach(browsers, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        Pill(importing ? "Importing…" : "Import…", action: bring).disabled(importing)
                    }
                }
            }
        }
        SettingsSection("Searching", note: searchNote) {
            SettingRow(
                "Search with", "Used whenever what you type isn't an address", symbol: "magnifyingglass", tint: Tint.blue,
                keywords: ["search engine"] + SearchEngine.allCases.map(\.title)
            ) {
                Picker("", selection: $prefs.engine) { ForEach(SearchEngine.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            if prefs.engine == .custom {
                RowRule()
                TextField("", text: $prefs.customEngine, prompt: Text("https://example.com/search?q=%s"))
                    .textFieldStyle(.plain)
                    .textStyle(.row)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(EdgeInsets(top: 8, leading: 47, bottom: 10, trailing: 12))
            }
        }

        SettingsSection("Pages") {
            SettingRow(
                "Offer to translate pages",
                "A page in a language you don't read shows a translate button beside its address. Off if you'd rather use an extension",
                symbol: "translate", tint: Tint.blue, keywords: ["translation", "language"], on: $prefs.offersTranslation)
            if prefs.offersTranslation, !prefs.neverTranslate.isEmpty {
                RowRule()
                SettingRow(
                    "Never offered for", ListFormatter.localizedString(byJoining: prefs.neverTranslate.map(Browser.languageName)),
                    symbol: "nosign", tint: Tint.blue, keywords: ["translation", "language"]
                ) {
                    Button("Offer Again") { prefs.neverTranslate = [] }
                }
            }
        }

        SettingsSection("Links") {
            SettingRow(
                "Preview links", "\(prefs.peekClick.title) a link to see it over the page; keep it as a tab if you like it",
                symbol: "eye", tint: Tint.teal, on: $prefs.peeksLinks)
            if prefs.peeksLinks {
                RowRule()
                SettingRow(
                    "Preview with", "See a link over the page before opening it", symbol: "cursorarrow.click", tint: Tint.teal,
                    keywords: ["glance", "peek"] + PeekClick.allCases.map(\.title)
                ) {
                    Picker("", selection: $prefs.peekClick) { ForEach(PeekClick.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                }
            }
            RowRule()
            SettingRow(
                "Links from other apps in a small window", "Handy for a quick look. ⌘O moves it into your tabs",
                symbol: "macwindow.on.rectangle", tint: Tint.green, on: $prefs.littleLinks)
            RowRule()
            SettingRow(
                "Show where links go", "The address under the pointer, at the bottom of the page", symbol: "link", tint: Tint.blue,
                on: $prefs.showsLinks)
            RowRule()
            SettingRow(
                "Scroll with the middle button", "Press the wheel and move the mouse; press again to stop", symbol: "computermouse",
                tint: Tint.gray, on: $prefs.autoScroll)
            RowRule()
            SettingRow(
                "Fix spelling as you type", "The Mac's corrections and capitals in fields on the web", symbol: "textformat.abc",
                tint: Tint.pink, on: $prefs.autocorrect)
        }

        SettingsSection("Video", note: "⇧⌘P floats any video whenever you want.") {
            SettingRow(
                "Keep playing when you switch tabs", "Video from sites Mote knows floats above the page, and goes back when you return",
                symbol: "pip", tint: Tint.red, on: $prefs.floatsOnLeave)
            RowRule()
            SettingRow(
                "Keep playing when you switch apps", "The video stays on top of whatever you're doing", symbol: "rectangle.on.rectangle",
                tint: Tint.orange, on: $prefs.floatsAway)
            RowRule()
            SettingRow(
                "Throw it to a corner", "Swipe with two fingers and the floating video flies to the nearest corner",
                symbol: "arrow.up.left.and.arrow.down.right", tint: Tint.purple, on: $prefs.floatFlicks)
        }

        SettingsSection("Downloads") {
            SettingRow(
                "Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), symbol: "folder", tint: Tint.blue
            ) {
                Pill("Choose…", action: chooseFolder)
            }
            RowRule()
            SettingRow(
                "Ask every time", "Pick a place and a name for each file", symbol: "questionmark.folder", tint: Tint.teal,
                on: $prefs.asksWhereToSave)
        }

        SettingsSection("Under the hood") {
            SettingRow(
                "Pages at 120 Hz", "Smoother on ProMotion displays, at some cost to the battery. Open tabs follow once reloaded",
                symbol: "speedometer", tint: Tint.green, on: $prefs.fastPages)
            RowRule()
            SettingRow(
                "Let a script drive Mote", "A private socket for Tools/bench. Its tabs wear a flask and never jump to the front",
                symbol: "terminal", tint: Tint.gray, on: $prefs.bench)
        }
    }

    @ViewBuilder private var defaultControl: some View {
        if isDefault {
            Label("In use", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
        } else {
            Pill("Use Mote", filled: true) {
                AppDelegate.becomeDefault { worked in
                    isDefault = AppDelegate.isDefault
                    browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                }
            }
        }
    }

    private var searchNote: String? {
        guard prefs.engine == .custom else { return nil }
        guard SearchEngine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Until then, Google."
        }
        return "Searches go to \(prefs.engine.name(custom: prefs.customEngine))."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let folder = panel.url { prefs.downloads = folder }
    }
}

struct TabSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var routes = RouteStore.shared
    /// Minutes a tab goes unseen before it rests (`Browser.sleepAfter`).
    @State private var restAfter = Int(Browser.sleepAfter / 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where your tabs live").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).padding(.leading, 4)
            TabLayoutChoice(prefs: prefs, compact: true)
            Text("⇧⌘S switches between them.").font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(.leading, 4)
        }

        SettingsSection {
            if prefs.sidebar {
                SettingRow(
                    "Sidebar on the right", "The tabs on the window's right side; the traffic lights stay on the left",
                    symbol: "sidebar.right", tint: Tint.indigo, keywords: ["right side", "position"], on: $prefs.sideRight)
                RowRule()
                SettingRow(
                    "Buttons at the foot",
                    prefs.foot.isEmpty ? "None; the spaces have it to themselves" : prefs.foot.map(\.title).joined(separator: ", "),
                    symbol: "rectangle.bottomthird.inset.filled", tint: Tint.indigo, keywords: ["downloads", "history", "chats", "library"]
                ) {
                    Menu("Choose") {
                        ForEach(FootButton.allCases, id: \.self) { button in
                            Toggle(
                                button.title,
                                isOn: Binding(
                                    get: { prefs.foot.contains(button) },
                                    set: { prefs.foot = $0 ? prefs.foot + [button] : prefs.foot.filter { $0 != button } }))
                        }
                    }
                    .fixedSize()
                }
                RowRule()
                SettingRow(
                    "Tuck the sidebar away",
                    "The page takes the whole window; reach the left edge and your tabs slide out. ⌘S does it by hand",
                    symbol: "sidebar.left", tint: Tint.blue, on: $prefs.sideHides)
                RowRule()
            }
            SettingRow(
                "Toolbar",
                prefs.sidebar
                    ? "Hidden puts back, forward and the address at the top of the sidebar; on hover, reach the page's top edge"
                    : "On hover or hidden, it slides in when the pointer reaches the page's top edge. ⌘L brings it out",
                symbol: "menubar.rectangle", tint: Tint.green, keywords: ["compact"] + ToolbarMode.allCases.map(\.title)
            ) {
                Segmented(options: ToolbarMode.allCases.map { ($0, $0.title) }, selection: $prefs.toolbarMode)
            }
            RowRule()
            SettingRow(
                "Slides out after",
                "How long the pointer rests on the edge before tucked-away tabs or the toolbar come out",
                symbol: "timer", tint: Tint.teal
            ) {
                HStack(spacing: 8) {
                    Slider(value: $prefs.revealDelay, in: 0...0.5, step: 0.025).frame(width: 120)
                    Text(prefs.revealDelay == 0 ? "At once" : "\(Int((prefs.revealDelay * 1000).rounded())) ms")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            RowRule()
            SettingRow(
                "New tabs from a floating search",
                "⌘T opens a search over the page, and a tab only for what you pick. Escape leaves things as they were",
                symbol: "magnifyingglass", tint: Tint.blue, on: $prefs.newTabSearch)
            RowRule()
            SettingRow(
                "Beside each title", "What marks a tab, pinned ones too", symbol: "app.badge", tint: Tint.orange,
                keywords: ["favicon", "icon"] + Glyph.allCases.map(\.title)
            ) {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            RowRule()
            SettingRow(
                "How far you've read", "The tab you're on fills in as you scroll", symbol: "text.line.first.and.arrowtriangle.forward",
                tint: Tint.green, on: $prefs.showsReading)
            RowRule()
            SettingRow(
                "Bookmarks bar everywhere", "New tabs always show it; this keeps it over every page", symbol: "bookmark", tint: Tint.pink,
                on: $prefs.bookmarksBar)
        }

        SettingsSection("Moving between tabs") {
            SettingRow(
                "After closing a tab", "Go to the tab you used before it, or to the one beside it",
                symbol: "xmark.square", tint: Tint.blue, keywords: ["close", "recently used"]
            ) {
                Segmented(options: [(true, "Last used"), (false, "Beside it")], selection: $prefs.closeGoesBack)
            }
            RowRule()
            SettingRow(
                "Back closes a new tab", "On a tab opened from another, with no page to go back to, Back returns to where it came from",
                symbol: "chevron.left", tint: Tint.teal, on: $prefs.backCloses)
            RowRule()
            SettingRow(
                "⌃⇥ passes over essentials", "Next and previous tab stay among the tabs below them", symbol: "arrow.right.to.line",
                tint: Tint.orange, keywords: ["control tab", "ctrl-tab"], on: $prefs.stepSkipsEssentials)
            RowRule()
            SettingRow(
                "⌃⇥ passes over resting tabs", "Next and previous tab skip tabs that have let their page go", symbol: "moon",
                tint: Tint.indigo, keywords: ["control tab", "ctrl-tab", "sleeping"], on: $prefs.stepSkipsSleeping)
        }

        SettingsSection("Saving energy") {
            SettingRow(
                "Let quiet tabs rest",
                "Unseen for a while, a tab lets its page go and picks up where it was. Pinned tabs, sound, calls and unsent text keep it awake",
                symbol: "moon.zzz", tint: Tint.indigo, on: $prefs.sleepsTabs)
            if prefs.sleepsTabs {
                RowRule()
                SettingRow(
                    "Rest after", "How long a tab goes unseen first", symbol: "timer", tint: Tint.indigo, keywords: ["unload", "sleep"]
                ) {
                    Picker("", selection: $restAfter) {
                        ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: restAfter) { Storage.settings.set(Double(restAfter * 60), forKey: "sleep.after") }
                }
            }
        }

        SettingsSection("Spaces", note: "Mission Control's ⌃ shortcuts, if they're on, get those keys first.") {
            SettingRow(
                "Separate sets of tabs",
                "Each space can share your sign-ins or start clean. Move between them with ⌃1–⌃9, a two-finger swipe over the tabs, or their icon",
                symbol: "square.stack.3d.up", tint: Tint.purple, on: $prefs.usesSpaces)
            if prefs.usesSpaces { SpaceRows(browser: browser) }
        }

        if prefs.usesSpaces, !routes.routes.isEmpty {
            SettingsSection("Sites that open in a space", note: "Add one from a tab's menu: Always Open in This Space.") {
                ForEach(Array(routes.routes.enumerated()), id: \.element.id) { index, route in
                    if index > 0 { RowRule() }
                    SettingRow(
                        route.reference, route.match == .contains ? nil : route.match.rawValue.capitalized, symbol: "arrow.triangle.branch",
                        tint: Tint.purple, keywords: ["routing", "always open"]
                    ) {
                        HStack(spacing: 6) {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { route.space },
                                    set: { space in
                                        routes.change { list in
                                            if let at = list.firstIndex(where: { $0.id == route.id }) { list[at].space = space }
                                        }
                                    })
                            ) { ForEach(browser.spaces) { Text($0.name).tag($0.id) } }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            Door(icon: "xmark", help: "Remove") { browser.forgetRoute(route.id) }
                        }
                    }
                }
            }
        }
    }
}

/// A space's icon, opening the picker.
private struct IconButton: View {
    let space: Space
    let browser: Browser
    @State private var picking = false

    var body: some View {
        Door(icon: "face.smiling", on: picking, help: "Icon") { picking = true }
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                IconPicker(current: space.emoji ?? space.symbol) { icon in
                    browser.setSpaceIcon(space.id, to: icon)
                    picking = false
                }
            }
    }
}

/// Settings › Tabs › Spaces: each space, to rename, give an icon or move.
/// Clicking spaces' icons selects them: one can be deleted, several merged.
private struct SpaceRows: View {
    @ObservedObject var browser: Browser
    @State private var picked: Set<UUID> = []

    /// What's picked of what's still there.
    private var chosen: [Space] { browser.spaces.filter { picked.contains($0.id) } }

    var body: some View {
        ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
            RowRule()
            HStack(spacing: 11) {
                pickButton(for: space)
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(detail(space, at: index)).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    Door(icon: "pencil", help: "Rename") { SpaceMenu.rename(space, in: browser) }
                    iconMenu(for: space)
                    Door(icon: "chevron.up", help: "Move up") { browser.moveSpace(space.id, to: index - 1) }
                        .disabled(index == 0)
                    Door(icon: "chevron.down", help: "Move down") { browser.moveSpace(space.id, to: index + 1) }
                        .disabled(index == browser.spaces.count - 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .settingsSearch([space.name, "space"])
        }
        RowRule()
        HStack(spacing: 8) {
            footNote
            Spacer()
            if chosen.count == 1, let space = chosen.first {
                Pill("Delete") { SpaceMenu.confirmDelete(space, in: browser) }
                    .disabled(space.isFirst)
                    .help(space.isFirst ? "Holds Mote's main sign-ins, so it stays" : "Delete “\(space.name)”…")
            } else if chosen.count > 1 {
                Pill("Merge…") { confirmMerge(chosen) }
            }
            Pill("New Space…") {
                browser.tuning = false
                browser.askForSpace()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .settingsSearch(["New Space", "Delete or merge spaces"])
        .animation(Motion.quick, value: chosen.count)
        // A space deleted or merged away is no longer picked.
        .onChange(of: browser.spaces.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    @ViewBuilder
    private var footNote: some View {
        let text =
            switch chosen.count {
            case 0: "Click a space's icon to select it"
            case 1: chosen[0].isFirst ? "The first space holds Mote's main sign-ins and stays" : "1 selected"
            default: "\(chosen.count) selected"
            }
        Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
    }

    /// The icon, which picks the space or lets it go.
    private func pickButton(for space: Space) -> some View {
        let on = picked.contains(space.id)
        return Button {
            if on { picked.remove(space.id) } else { picked.insert(space.id) }
        } label: {
            SpaceGlyph(space: space, size: 13)
                .frame(width: 26, height: 26)
                .background(on ? Color.accentColor.opacity(0.18) : Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    if on { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Deselect" : "Select")
        .animation(Motion.quick, value: on)
    }

    private func detail(_ space: Space, at index: Int) -> String {
        let data =
            space.isFirst
            ? "Mote's main sign-ins" : space.ownData ? "Its own sign-ins" : "Shares the main sign-ins"
        let key = index < 9 ? " · ⌃\(index + 1)" : ""
        return (space.id == browser.spaceID ? "Showing · " : "") + data + key
    }

    /// Asks what the merged space is called, then merges.
    private func confirmMerge(_ spaces: [Space]) {
        let ids = Set(spaces.map(\.id))
        guard let target = browser.mergeTarget(of: ids) else { return }
        let others = spaces.filter { $0.id != target.id }
        let separate = others.contains { Spaces.store(for: $0.id) !== Spaces.store(for: target.id) }
        let names = others.map { "“\($0.name)”" }.joined(separator: ", ")
        let detail =
            "Their essentials, pinned and open tabs go into one space, without duplicates. \(names) "
            + (others.count == 1 ? "goes" : "go") + " into “\(target.name)”, which keeps all its own sign-ins"
            + (separate
                ? "; their cookies come along too, so most sites stay signed in, though a few that keep sign-ins another way will ask again."
                : ".")
        Prompt.name(
            "Merge \(spaces.count) Spaces", placeholder: target.name, initial: target.name, detail: detail, confirm: "Merge"
        ) { name in
            Task {
                let merged = await browser.mergeSpaces(ids, named: name)
                picked = []
                let tabs = merged.tabs == 1 ? "1 tab" : "\(merged.tabs) tabs"
                browser.announce(
                    merged.cookies > 0 ? "\(tabs) and \(merged.cookies) cookies merged into \(name)" : "\(tabs) merged into \(name)")
            }
        }
    }

    private func iconMenu(for space: Space) -> some View {
        IconButton(space: space, browser: browser)
    }

}

struct PasswordSettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsSection("Your passwords") {
            SettingRow("Saved passwords", "In the Mac's keychain, behind Touch ID", symbol: "key", tint: Tint.yellow) {
                Pill("Show…", action: openPasswords)
            }
            RowRule()
            SettingRow(
                "Bring them over", "From Chrome, Arc, Dia, Brave or Edge on this Mac. Nothing leaves it", symbol: "square.and.arrow.down",
                tint: Tint.blue
            ) {
                Pill("Import…", action: openPasswords)
            }
        }

        SettingsSection("While you sign in") {
            SettingRow("Offer to save", savingDetail, symbol: "plus.circle", tint: Tint.green, on: $prefs.savesPasswords)
            RowRule()
            SettingRow(
                "Suggest your accounts", "Click a sign-in field to see what you've saved for the site", symbol: "person.crop.circle",
                tint: Tint.teal, on: $prefs.fillsPasswords)
            RowRule()
            SettingRow("Passkeys", passkeyDetail, symbol: "touchid", tint: Tint.pink, on: $prefs.passkeys)
            if !PasswordStore.never.isEmpty {
                RowRule()
                SettingRow("Sites never asked", "\(PasswordStore.never.count) you said no to", symbol: "hand.raised.slash", tint: Tint.gray)
                {
                    Pill("Forget") {
                        PasswordStore.never = []
                        browser.announce("Every site can ask again")
                    }
                }
            }
        }
    }

    private func openPasswords() {
        browser.tuning = false
        browser.logins.managing = true
    }

    /// A password manager extension can take the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy { return "\(name) is looking after this instead" }
        return "Once a sign-in has worked. Say no and that site won't ask again"
    }

    private var passkeyDetail: String {
        if !prefs.passkeysPossible { return "This build can't use them: it lacks Apple's passkey entitlement" }
        if Passkeys.access == .denied { return "Blocked in System Settings › Privacy & Security › Passkeys Access for Web Browsers" }
        return "Sign in with Touch ID or a passkey from iCloud, where sites offer it"
    }
}

struct PrivacySettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var blocker = AdBlocker.shared

    var body: some View {
        SettingsSection("Blocking") {
            SettingRow(
                "Block ads and trackers", blocker.trouble ?? "Stops scripts whose only job is following you around",
                symbol: "shield.lefthalf.filled", tint: Tint.indigo, on: $prefs.shielded)
            if let trouble = blocker.trouble {
                RowRule()
                SettingRow(trouble, "Nothing is blocked until it works again", symbol: "exclamationmark.triangle", tint: Tint.orange) {
                    Pill("Try Again") { blocker.compile() }
                }
            }
            if let host = browser.hereHost, prefs.shielded, blocker.trouble == nil {
                RowRule()
                SettingRow("On \(host)", "If this site breaks, turn it off here; the page reloads", symbol: "globe", tint: Tint.blue) {
                    Switch(
                        on: Binding(
                            get: { !blocker.isPaused(on: host) },
                            set: { on in
                                blocker.pause(host, !on)
                                browser.reload()
                            }))
                }
            }
        }

        SettingsSection("Camera and microphone") {
            SettingRow("Remembered answers", "What you told each site that asked", symbol: "video", tint: Tint.green) {
                Pill("Forget") { browser.forgetCaptureChoices() }
            }
        }

        SettingsSection("Clearing up", note: "Each of these happens straight away.") {
            SettingRow("History", "Every page you've been to", symbol: "clock.arrow.circlepath", tint: Tint.blue) {
                Pill("Clear") { browser.clearHistory() }
            }
            RowRule()
            SettingRow("Cookies and sign-ins", "Signs you out of every site", symbol: "person.crop.circle.badge.xmark", tint: Tint.red) {
                Pill("Clear") { browser.clearSites() }
            }
            RowRule()
            SettingRow("Cache", "Copies kept so pages open faster", symbol: "internaldrive", tint: Tint.gray) {
                Pill("Clear") { browser.clearCache() }
            }
        }
    }
}

struct AboutSettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 8) {
            Logomark().fill(Palette.ink).aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit).frame(height: 44)
            Text("Mote").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Version \(Updater.version)").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .settingsSearch(["About Mote", "version \(Updater.version)"])

        SettingsSection("Updates") {
            if Updater.enabled {
                SettingRow(updateTitle, updateDetail, symbol: "arrow.triangle.2.circlepath", tint: Tint.blue) { updateControl }
                RowRule()
                SettingRow(
                    "Install on their own", "Off, Mote still checks at launch and daily, and waits for you",
                    symbol: "square.and.arrow.down.on.square",
                    tint: Tint.green, on: $prefs.installsUpdates)
            } else {
                SettingRow(
                    "Not in this copy", "It was built without a place to look for new versions", symbol: "arrow.triangle.2.circlepath",
                    tint: Tint.gray
                ) {
                    EmptyView()
                }
            }
        }

        SettingsSection("Help") {
            SettingRow(
                "Something wrong?", "Opens a report with your version filled in", symbol: "exclamationmark.bubble", tint: Tint.orange
            ) {
                Pill("Report…") { AppDelegate.writeFeedback() }
            }
        }
    }

    private var updateTitle: String {
        switch updater.stage {
        case .none: updater.checkFailed ? "Couldn't check for updates" : "Up to date"
        case .fetching(let next): "Getting Mote \(next.version)…"
        case .ready(let next): "Mote \(next.version) is ready"
        case .offered(let next), .waiting(let next): "Mote \(next.version) is out"
        }
    }

    private var updateDetail: String {
        if updater.checkFailed { return "Couldn't reach the update feed. Retrying in five minutes; you can also look now." }
        return switch updater.stage {
        case .none:
            updater.lastChecked.map { "Looked \($0.formatted(.relative(presentation: .named))); checks at launch and daily" }
                ?? "Checks at launch and daily"
        case .fetching(let next): next.notes ?? "In the background. Your settings and data stay put"
        case .ready(let next): next.notes ?? "It takes over next time Mote opens"
        case .offered(let next): next.notes ?? "Install it from the disk image, as the first time"
        case .waiting(let next): next.notes ?? "Checked and installed when you say so"
        }
    }

    @ViewBuilder private var updateControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Looking…" : "Look Now") {
                updater.check { result in
                    switch result {
                    case .success(nil): browser.announce("You have the latest version")
                    case .success: break
                    case .failure: browser.announce("Couldn't check for updates. Try again when you're online.")
                    }
                }
            }
            .disabled(updater.checking)
        case .fetching: Ring(size: 12)
        case .ready: Pill("Restart Mote", filled: true) { updater.relaunch() }
        case .offered(let next):
            Pill("Download", filled: true) {
                browser.tuning = false
                browser.open(next.diskImage, foreground: true)
            }
        case .waiting: Pill("Install", filled: true) { updater.install() }
        }
    }
}

/// Profiles, as Firefox's: each its own Mote that shares nothing with the
/// others. This one is marked; another opens as its own Mote. A click on
/// an avatar changes it; another profile's row offers its Dock badge on hover.
private struct ProfileRows: View {
    @ObservedObject private var profiles = Profiles.shared
    /// The profile being made (`making`) or changed.
    @State private var editing: Editing?

    private struct Editing {
        let id: String?
        let making: Bool
        var key: String { making ? "new" : id ?? "first" }
    }

    var body: some View {
        SettingsSection(
            "Profiles",
            note: "Each profile is its own Mote: its own tabs, history, passwords, sign-ins and extensions. A new one starts with these settings."
        ) {
            ProfileRow(id: nil, editing: { editing = Editing(id: nil, making: false) })
            ForEach(profiles.list) { profile in
                RowRule()
                ProfileRow(id: profile.id, editing: { editing = Editing(id: profile.id, making: false) })
            }
            RowRule()
            HStack {
                Spacer()
                Pill("New Profile…") { editing = Editing(id: nil, making: true) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .settingsSearch(["New Profile", "profiles", "avatar"])
        }
        .sheet(item: Binding(get: { editing.map(Keyed.init) }, set: { editing = $0?.editing })) { keyed in
            ProfileEditor(id: keyed.editing.id, making: keyed.editing.making) { editing = nil }
        }
    }

    /// Identifiable by a string, for the sheet.
    private struct Keyed: Identifiable {
        let editing: Editing
        var id: String { editing.key }
    }
}

private struct ProfileRow: View {
    let id: String?
    let editing: () -> Void
    @ObservedObject private var profiles = Profiles.shared
    @State private var hovering = false

    var body: some View {
        let here = id == Storage.profile
        let name = profiles.name(of: id)
        HStack(spacing: 11) {
            Button(action: editing) { ProfileAvatar(id: id, size: 24, squircle: true, profiles: profiles) }
                .buttonStyle(.plain)
                .help("Change the avatar")
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                if here { Text("This Mote").font(.system(size: 11.5)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                // Only another profile wears a badge; shown on hover, as Chrome's row tools.
                if let id, hovering || !profiles.avatar(of: id).inDock {
                    Toggle("Show in Dock", isOn: Binding(get: { profiles.avatar(of: id).inDock }, set: { profiles.showInDock(id, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .help("Its avatar on Mote's Dock icon while it runs")
                }
                if !here { Pill("Open") { profiles.open(id) } }
                if let id {
                    Door(icon: "pencil", help: "Edit") { editing() }
                    if !here {
                        Door(icon: "trash", help: "Delete") {
                            Prompt.confirm(
                                "Delete “\(name)”?",
                                detail:
                                    "Its tabs, history, passwords, sign-ins, extensions and settings are removed from this Mac. Quit it first if it's open.",
                                confirm: "Delete"
                            ) { profiles.delete(id) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .settingsSearch([name, "profile", "Show in Dock"])
    }
}
