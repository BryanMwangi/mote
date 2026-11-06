import AppKit
import MoteCore

// Running a command by name: what a key does (KeyRouter), and what a quick
// action typed into the address field does (QuickActions, as Zen's).

extension Browser {
    /// What a key's command does.
    func run(_ command: KeyMap.Command) {
        switch command {
        case .newTab: newTab()
        case .newPrivateWindow: Windows.shared.open(private: true)
        // As Safari: a closed window once there's no closed tab left here.
        case .reopenTab: ghosts.isEmpty ? Windows.shared.reopenClosed() : reopen()
        case .closeTab:
            if peekTab != nil { closePeek() } else if let tab = active { close(tab) }
        case .duplicateTab: duplicate()
        case .nextTab: step(1)
        case .previousTab: step(-1)
        case .tab(let index): select(index: index)
        case .lastTab: select(index: tabs.count - 1)
        case .space(let index): switchSpace(index: index)
        case .back: back()
        case .forward: forward()
        case .reload: reload()
        case .reader: toggleReader()
        case .editAddress: edit()
        case .switcher:
            // ⌘K again moves the pick; letting go of ⌘ goes there.
            if editing, !field.offers.isEmpty { stepSummon() } else { summon() }
        case .pasteAndGo: pasteAndGo()
        case .copyAddress: copyAddress()
        case .find: openFind()
        case .findAgain(let backwards): finder.look(forward: !backwards)
        case .print: printPage()
        case .pauseSound: pauseMedia()
        case .floatVideo: toggleFloat()
        case .pageChat: togglePageChat()
        case .toggleSidebar: toggleSidebar()
        case .foldTabs: toggleFold()
        case .bookmark: bookmarkCurrent()
        case .history: recalling.toggle()
        case .downloads: showingDownloads.toggle()
        // Opens Settings, or brings it forward.
        case .settings: tuning = true
        case .hideElements: toggleHiding()
        case .hiddenElements: reviewing.toggle()
        case .undoHiding: undoHiding()
        case .zoomIn: zoom(by: 1.1)
        case .zoomOut: zoom(by: 1 / 1.1)
        case .actualSize: resetZoom()
        case .inspector: toggleInspector()
        case .split(let grid): splitKey(grid)
        case .stepSpace(let by): stepSpace(by)
        case .compactMode: toggleCompact()
        case .toggleToolbar: toggleToolbar()
        case .unsplit: if let group = activeID.flatMap(group(of:)) { unsplit(group: group) }
        }
    }

    /// A command from Settings › Keyboard, menu-only ones included.
    func perform(_ id: ShortcutID) {
        if let command = id.command { return run(command) }
        switch id {
        case .openFile: openFile()
        case .unloadTab: unloadActive()
        case .newWindow: Windows.shared.open(space: spaceID)
        case .newPrivateTab: newShyTab()
        case .reloadFromOrigin: reloadFromOrigin()
        case .savePage: savePage()
        case .screenshot: startScreenshot()
        case .passwords: logins.managing = true
        case .inspector: toggleInspector()
        case .console: showConsole()
        case .inspectElement: inspectElement()
        case .viewSource: if let tab = active { viewSource(of: tab) }
        case .responsive: toggleResponsive()
        case .inspectNetwork: showInspector(.network)
        case .inspectSources: showInspector(.sources)
        case .inspectStorage: showInspector(.storage)
        case .textDirection: switchTextDirection()
        case .processes: showingProcesses = true
        case .library: toggleLibrary()
        default: break
        }
    }

    /// One action the address field can offer.
    struct QuickAction {
        let id: String
        let title: String
        /// Its key, as the menus write it, if it has one.
        var keys = ""
        let run: () -> Void
    }

    /// What can be done now: every command with a name, and Zen's extras for
    /// the tab in front and the spaces.
    func quickActions() -> [QuickAction] {
        var actions = ShortcutID.allCases.map { id in
            QuickAction(id: id.rawValue, title: id.title, keys: prefs.shortcuts.combos(for: id).first?.text ?? "") { [weak self] in
                self?.perform(id)
            }
        }
        if let tab = active, !tab.isBlank {
            actions += [
                tab.kept
                    ? QuickAction(id: "unpin", title: "Unpin Tab") { [weak self] in self?.unkeep(tab) }
                    : QuickAction(id: "pin", title: "Pin Tab") { [weak self] in self?.keep(tab) },
                tab.pin != nil
                    ? QuickAction(id: "unessential", title: "Remove from Essentials") { [weak self] in self?.unpin(tab) }
                    : QuickAction(id: "essential", title: "Add to Essentials") { [weak self] in self?.pin(tab) },
                QuickAction(id: "unload", title: "Unload Tab") { [weak self] in self?.unload(tab) },
                QuickAction(id: "split", title: "New Split") { [weak self] in self?.newSplit() },
                QuickAction(id: "others", title: "Close Other Tabs") { [weak self] in self?.closeOthers(but: tab) },
                QuickAction(id: "route", title: "Always Open in This Space") { [weak self] in self?.alwaysOpenHere(tab) },
                QuickAction(id: "boost", title: "Boost This Site") { [weak self] in self?.boostSite() },
                QuickAction(id: "translate", title: tab.translated ? "Show Original" : "Translate Page") { [weak self] in
                    self?.toggleTranslation(tab)
                },
            ]
        }
        actions.append(QuickAction(id: "folder", title: "New Folder") { [weak self] in self?.newFolder() })
        if !folders.isEmpty {
            actions += [
                QuickAction(id: "collapse", title: "Collapse All Folders") { [weak self] in self?.collapseFolders(true) },
                QuickAction(id: "expand", title: "Expand All Folders") { [weak self] in self?.collapseFolders(false) },
            ]
        }
        if usesSpaces {
            actions.append(QuickAction(id: "space", title: "New Space") { [weak self] in self?.askForSpace() })
            actions += spaces.filter { $0.id != spaceID }.map { space in
                QuickAction(id: "space-\(space.id)", title: "Go to \(space.name)") { [weak self] in self?.switchSpace(to: space.id) }
            }
        }
        return actions
    }

    /// The actions `typed` finds, as suggestions above the pages.
    func actionSuggestions(for typed: String) -> [Suggestion] {
        guard Address.url(from: typed) == nil else { return [] }
        let actions = quickActions()
        return QuickActions.ranked(actions.map { (id: $0.id, title: $0.title) }, for: typed).compactMap { id in
            guard let action = actions.first(where: { $0.id == id }), let url = URL(string: "mote-action:\(id)") else { return nil }
            return Suggestion(key: action.title, title: action.keys, url: url, kind: .action)
        }
    }

    /// Runs the action a suggestion names, putting the field away first.
    func runAction(_ offer: Suggestion) {
        let id = offer.url.absoluteString.replacingOccurrences(of: "mote-action:", with: "")
        let action = quickActions().first { $0.id == id }
        editing = false
        field.clear()
        action?.run()
    }
}
