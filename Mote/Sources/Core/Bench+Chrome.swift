import AppKit
import AuthenticationServices
import MoteCore
import WebKit

// Bench commands on the browser around the pages: its state, its panels and
// settings, spaces, previews and link windows.

extension Bench {
    var chromeCommands: [String: Command] {
        [
            "probe": Self.probe, "ui": Self.ui, "consent": Self.consent, "little": Self.little, "space": Self.space, "peek": Self.peek,
            "window": Self.window, "windows": Self.windows, "quit": Self.quit, "link": Self.link,
        ]
    }

    /// The whole state of the window and its parts.
    private static func probe(_ call: BenchCall) {
        let browser = call.browser
        let window = AppDelegate.window
        let describe = { (window: NSWindow) in "\(type(of: window)) “\(window.title)”" }
        var out: [String: Any] = [
            "settings": browser.tuning, "welcome": browser.welcoming, "passwords": browser.logins.managing, "history": browser.recalling,
            "downloads": browser.showingDownloads, "bookmarks": browser.bookmarking, "field": browser.editing,
            "suggesting": browser.logins.choices != nil, "offering": browser.logins.offer != nil,
            "modal": NSApp.modalWindow.map(describe) ?? "",
            "look": browser.prefs.look.rawValue, "appearance": NSApp.appearance?.name.rawValue ?? "system",
            "spaceName": browser.spaces.first { $0.id == browser.spaceID }?.name ?? "",
            "spaceScheme": browser.spaces.first { $0.id == browser.spaceID }?.theme?.scheme?.rawValue ?? "none",
            "windowLook": browser.window.map { $0.appearance?.name.rawValue ?? "app's" } ?? "no window",
            "key": NSApp.keyWindow.map(describe) ?? "",
            // The Edit menu's items and their keys, for copy and paste.
            "editMenu": (NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map {
                "\($0.title) ⌘\($0.keyEquivalent) \($0.action.map(NSStringFromSelector) ?? "-")"
            },
            "transfers": browser.downloads.transfers.map {
                "\($0.name) \($0.state.rawValue) \($0.received)/\($0.total)\($0.resumeData == nil ? "" : " resumable")"
            },
            "keysQuieted": PageView.quieted, "peek": browser.peekTab?.address?.absoluteString ?? "", "folded": browser.folded,
            "peeking": browser.peeking, "toolbarMode": browser.prefs.toolbarMode.rawValue, "peekClick": browser.prefs.peekClick.rawValue,
            "spaceIndex": browser.spaces.firstIndex { $0.id == browser.spaceID } ?? -1,
            "settingsQuery": SettingsSearch.shared.query, "settingsFocusAsked": SettingsSearch.shared.focusAsked,
            "finding": browser.finder.showing, "asking": browser.field.asksAssistant, "profile": Storage.profile ?? "",
            "profiles": Profiles.shared.list.map(\.id), "sharedAt": Browser.sharedAt, "pageWindowMoves": PageView.windowMoves,
            "tabListAt": tabList(of: browser).map { Int($0.contentView.bounds.minY) } ?? -1, "beepsSpared": PageKeySink.caught,
            "pageTracking": (browser.active?.built?.trackingAreas ?? []).map {
                "\($0.owner.map { String(describing: type(of: $0)) } ?? "nil") \($0.options.rawValue)"
            }, "sharing": Browser.sharing,
            "siteCardRow": browser.siteCardRow.map(BenchWire.short) ?? "",
            "editingTab": browser.editingTab.map(BenchWire.short) ?? "",
            "responder": browser.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "folder": Storage.folder.path, "pageLanguage": browser.active?.pageLanguage ?? "",
            "translated": browser.active?.translation.map { "\($0.source)>\($0.target)" } ?? "",
            "toast": browser.announcer.showing?.text ?? "",
            "folders": browser.folders.map { folder in
                [
                    folder.name, folder.collapsed ? "closed" : "open", browser.folders.first { $0.id == folder.parent }?.name ?? "",
                    folder.live == nil ? "" : "\(LiveFeeds.shared.items(in: folder.id).count) items",
                ]
            },
            "offers": browser.field.offers.map { "\($0.kind):\($0.key)" }, "launching": browser.field.launching,
            "chatting": browser.chatting,
            "tabSettings": [
                browser.prefs.closeGoesBack, browser.prefs.backCloses, browser.prefs.stepSkipsEssentials, browser.prefs.stepSkipsSleeping,
            ], "settingsMatches": SettingsSearch.shared.found,
            "shortcutsChanged": browser.prefs.shortcuts.changed.keys.map(\.rawValue).sorted(),
            "sideHides": browser.prefs.sideHides, "lightsHidden": window.map { !TrafficLights.visible(in: $0) } ?? true,
            "siteCard": SiteCardPanel.isShown,
            "barEditing": browser.editingInBar, "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "passkeyAccess": passkeyAccess, "passkeyAsks": Passkeys.asked, "passkeyLast": Passkeys.last,
        ]
        out["windows"] = NSApp.windows.map { window -> [String: Any] in
            [
                "kind": "\(type(of: window))", "title": window.title, "visible": window.isVisible, "level": window.level.rawValue,
                "frame": [Int(window.frame.minX), Int(window.frame.minY), Int(window.frame.width), Int(window.frame.height)],
                "number": window.windowNumber,
            ]
        }
        let pages = browser.tabs.compactMap { $0.built?.configuration.preferences }
        // Whether each page has the Web Inspector on, and is held near 60 fps.
        out["inspector"] = pages.compactMap { $0.unpublishedFlag("_developerExtrasEnabled") }
        out["prefersNear60FPS"] = pages.compactMap(FrameRate.prefersNear60)
        if let window {
            out["lights"] = BenchCall.lights(of: window)
            if let preview = browser.peekTab?.built, preview.window != nil {
                out["peekFrame"] = BenchCall.topLeft(preview.convert(preview.bounds, to: nil), in: window.frame.height)
            }
            // The address field and its suggestions.
            out["barZones"] = KeepZone.views.allObjects.filter { $0.window === window }.map {
                BenchCall.topLeft($0.convert($0.bounds, to: nil), in: window.contentLayoutRect.height)
            }
            // The split view's panes, by tab, from the window's top left.
            out["splits"] = browser.splits.values.map { $0.ids.map { String($0.uuidString.lowercased().prefix(8)) } }
            if let stage = browser.stageView, let active = browser.activeID {
                let frames = (browser.shownSplit ?? SplitLayout(active)).frames(in: stage.bounds, gap: Browser.splitGap)
                out["panes"] = Dictionary(
                    uniqueKeysWithValues: frames.map { id, frame in
                        let shown = stage.convert(frame, to: nil)
                        return (String(id.uuidString.lowercased().prefix(8)), BenchCall.topLeft(shown, in: window.contentLayoutRect.height))
                    })
            }
            if let content = window.contentView {
                let card = browser.layout(in: content.bounds.size).card
                out["card"] = [Int(card.minX), Int(card.minY), Int(card.width), Int(card.height)]
            }
        }
        call.answer(out)
    }

    /// Whether macOS lets browsers other than Safari use this Mac's passkeys.
    private static var passkeyAccess: String {
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: "authorized"
        case .denied: "denied"
        default: "notDetermined"
        }
    }

    /// Panels and settings, on or off.
    private static func ui(_ call: BenchCall) {
        let browser = call.browser, prefs = browser.prefs, request = call.request
        let switches: [(String, (Bool) -> Void)] = [
            ("settings", { browser.tuning = $0 }), ("passwords", { browser.logins.managing = $0 }), ("welcome", { browser.welcoming = $0 }),
            ("history", { browser.recalling = $0 }), ("downloads", { browser.showingDownloads = $0 }),
            ("bookmarks", { browser.bookmarking = $0 }), ("bookmarksbar", { prefs.bookmarksBar = $0 }),
            ("hidden", { browser.reviewing = $0 }), ("pages120", { prefs.fastPages = $0 }), ("sidebar", { prefs.sidebar = $0 }),
            ("spaces", { prefs.usesSpaces = $0 }), ("hides", { prefs.sideHides = $0 }), ("folded", { browser.folded = $0 }),
            ("peek", { browser.peeking = $0 }), ("bar", { if $0 { browser.edit() } else { browser.dismiss() } }),
            ("chats", { if $0 { browser.showChats() } }), ("peeklinks", { prefs.peeksLinks = $0 }),
            ("processes", { browser.showingProcesses = $0 }), ("import", { browser.importing = $0 }),
            ("sideright", { prefs.sideRight = $0 }),
            // The app brought forward, where focus moves as it does for a person.
            ("appfront", { if $0 { NSApp.activate(ignoringOtherApps: true); browser.window?.makeKeyAndOrderFront(nil) } }),
            (
                "fullscreen",
                { on in
                    guard let window = browser.window, window.styleMask.contains(.fullScreen) != on else { return }
                    window.toggleFullScreen(nil)
                }
            ),
        ]
        for (key, set) in switches { request.bool(key).map(set) }
        if let look = request.string("look").flatMap(Look.init) { prefs.look = look }
        // The newest download under way or stopped: pause, resume or stop it.
        if let what = request.string("download"), let transfer = browser.downloads.transfers.first {
            switch what {
            case "pause": browser.downloads.pause(transfer)
            case "resume": browser.resume(transfer)
            default: browser.downloads.cancel(transfer)
            }
        }
        // A notice as it would show (test runs): an update's, or a plain line.
        if Storage.testing, let notice = request.string("notice") {
            let release = AppRelease(
                version: "0.2.0", build: 2, archive: URL(string: "https://example.com/Mote.zip")!,
                diskImage: URL(string: "https://example.com/Mote.dmg")!, notes: request.string("notes"))
            switch notice {
            case "update": browser.tell(.out(release))
            case "ready": browser.tell(.ready(release))
            case "manual": browser.tell(.manual(release))
            default: browser.announce(notice)
            }
        }
        // The site card: on, off, or open at its security detail.
        if let card = request.string("sitecard"), let tab = browser.active {
            if card == "off" {
                SiteCardPanel.hide()
            } else {
                SiteCardPanel.open(for: tab, in: browser, security: card == "security", beside: card == "row")
            }
        }
        // The preview's buttons (LinkPeek).
        if let what = request.string("peeklink") { if what == "keep" { browser.keepPeek() } else { browser.closePeek() } }
        // Renaming the tab in front, and finishing.
        if let text = request.string("edittab"), let tab = browser.active {
            browser.beginTabRename(tab)
            browser.tabDraft = text
        }
        if request.flag("finishedit") { browser.finishTabEdit() }
        // A tab of the front window made an essential, or not (test runs).
        let tab = { (id: String) in browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) } }
        if Storage.testing, let id = request.string("essential"), let found = tab(id) { browser.pin(found) }
        if Storage.testing, let id = request.string("unessential"), let found = tab(id) { browser.unpin(found) }
        if Storage.testing, let id = request.string("newwindow"), let found = tab(id) { browser.moveToNewWindow(found) }
        if Storage.testing, let id = request.string("share"), let found = tab(id) {
            browser.select(found)
            browser.share(beside: found)
        }
        if Storage.testing, let id = request.string("source"), let found = tab(id) { browser.viewSource(of: found) }
        // An essential or pinned tab back to its pinned page; the click that previews.
        if Storage.testing, let id = request.string("home"), let found = tab(id) { browser.goHome(found) }
        // The inspector at a panel: network, sources, storage, timeline.
        if let panel = request.string("inspect").flatMap({ InspectorPanel(rawValue: $0.capitalized) }) { browser.showInspector(panel) }
        if request.flag("textdirection") { browser.switchTextDirection() }
        // A screenshot of the tab in front (test runs): visible, whole, copy, the
        // overlay, or region:X,Y,W,H in the page's coordinates, scrolled to the top.
        if Storage.testing, let shot = request.string("screenshot") {
            let numbers = shot.hasPrefix("region:") ? shot.dropFirst(7).split(separator: ",").compactMap { Double($0) } : []
            if shot == "overlay" {
                browser.startScreenshot()
            } else if numbers.count == 4 {
                browser.active?.screenshot(
                    .region(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), scrolled: .zero))
            } else {
                browser.active?.screenshot(shot == "whole" ? .wholePage : .visible, copy: shot == "copy")
            }
        }
        // Folders (test runs): new:NAME[/PARENT], toggle:NAME, unpack:NAME, delete:NAME; TAB:NAME puts a tab in one.
        if Storage.testing, let what = request.string("folder") {
            let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
            let named = { (name: String) in browser.folders.first { $0.name == name } }
            switch (parts.first, parts.last) {
            case ("new", let spec?):
                let names = spec.split(separator: "/").map(String.init)
                let folder = Folder(name: names[0], parent: names.count > 1 ? named(names[1])?.id : nil)
                FolderStore.shared.change(browser.spaceID) { $0.append(folder) }
            case ("toggle", let name?): named(name).map { browser.toggleFolder($0.id) }
            // live:pulls:owner/repo, live:issues:owner/repo, live:feed:URL
            case ("live", let spec?):
                let bits = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let source: LiveSource? =
                    switch bits.first {
                    case "pulls": bits.last.flatMap(LiveSource.repo(in:)).map { .pulls(repo: $0) }
                    case "issues": bits.last.flatMap(LiveSource.repo(in:)).map { .issues(repo: $0) }
                    default: bits.last.flatMap(URL.init(string:)).map { .feed($0) }
                    }
                if let source {
                    let folder = Folder(name: spec, live: source)
                    FolderStore.shared.change(browser.spaceID) { $0.append(folder) }
                    LiveFeeds.shared.refresh(folder)
                }
            case ("unpack", let name?): named(name).map { browser.unpackFolder($0.id) }
            case ("delete", let name?): named(name).map { browser.deleteFolder($0.id) }
            // drag:TAB:NAME, a drag that ends over the folder's row, as a pointer would.
            case ("drag", let spec?):
                let bits = spec.split(separator: ":", maxSplits: 1).map(String.init)
                if let found = bits.first.flatMap(tab), let folder = bits.last.flatMap(named),
                    let spot = browser.folderSpots[folder.id]?.view, let window = spot.window
                {
                    let frame = window.convertToScreen(spot.convert(spot.bounds, to: nil))
                    ScriptedDrag.shared.pointer = NSPoint(x: frame.midX, y: frame.midY)
                    ScriptedDrag.shared.play(found.id, by: CGSize(width: 0, height: -20), over: 0.3) { ScriptedDrag.shared.pointer = nil }
                }
            case (let id?, let name?): if let found = tab(id) { browser.move(found, toFolder: named(name)?.id) }
            default: break
            }
        }
        // Space routing (test runs): HOST:SPACEINDEX adds a rule, clear removes them all.
        if Storage.testing, let what = request.string("route") {
            if what == "clear" {
                RouteStore.shared.change { $0.removeAll() }
            } else if let colon = what.lastIndex(of: ":"), let index = Int(what[what.index(after: colon)...]),
                browser.spaces.indices.contains(index)
            {
                let host = String(what[..<colon])
                RouteStore.shared.change { $0.append(SpaceRoute(reference: host, space: browser.spaces[index].id)) }
            }
        }
        // The space in front's colours (test runs): a preset's number, or off.
        if Storage.testing, let what = request.string("theme") {
            // A preset's number, off, or light / dark / auto for the space's look.
            if let scheme = ["light": SpaceTheme.Scheme.light, "dark": .dark, "auto": nil][what] {
                var theme = browser.spaces.first { $0.id == browser.spaceID }?.theme ?? SpaceTheme(colors: [])
                theme.scheme = scheme
                browser.setSpaceTheme(browser.spaceID, to: theme.colors.isEmpty && scheme == nil ? nil : theme)
            } else {
                let preset = Int(what).flatMap { SpaceTheme.presets.indices.contains($0) ? SpaceTheme.presets[$0] : nil }
                browser.setSpaceTheme(browser.spaceID, to: preset.map { SpaceTheme(colors: $0.colors, opacity: $0.opacity, grain: 1) })
            }
        }
        if request.flag("translate"), let tab = browser.active { browser.toggleTranslation(tab) }
        // Page Info for the tab in front, at a part (test runs): General, Media, Permissions, Security.
        if Storage.testing, let part = request.string("pageinfo"), let tab = browser.active {
            for window in NSApp.windows where window.title.hasPrefix("Page Info") { window.close() }
            PageInfo.opening = part
            if part != "off" { PageInfo.show(for: tab, in: browser) }
            PageInfo.opening = "General"
        }
        if Storage.testing, request.flag("translatepanel") { NotificationCenter.default.post(name: TranslateButton.ask, object: nil) }
        // Profiles (test runs only, so their own Motes stay in the test world): new:NAME, delete:ID.
        if Storage.testing, let what = request.string("profile") {
            if what.hasPrefix("new:") {
                Profiles.shared.add(named: String(what.dropFirst(4)), avatar: .init(symbol: "briefcase.fill", color: "#26456b"))
            }
            if what.hasPrefix("delete:") { Profiles.shared.delete(String(what.dropFirst(7))) }
        }
        // The site in front's boost (test runs): dim (brightness 0.7, Georgia), or reset.
        if Storage.testing, let what = request.string("boost"), let site = Address.siteHost(of: browser.active?.address) {
            switch what {
            case "editor": browser.boosting = site
            case "close": browser.boosting = nil
            case "tint": browser.setBoost(Boost(tint: "#2a5bd5", accent: "#ffd23f"), for: site)
            default: browser.setBoost(what == "reset" ? Boost() : Boost(brightness: 0.7, font: "Georgia"), for: site)
            }
        }
        if let query = request.string("settingsquery") { SettingsSearch.shared.query = query == "-" ? "" : query }
        // A command given a key (test runs): ID=cmd+e, ID=none, or reset.
        if Storage.testing, let what = request.string("shortcut") {
            let parts = what.split(separator: "=").map(String.init)
            if what == "reset" {
                prefs.shortcuts = Shortcuts()
            } else if what == "zen" {
                prefs.shortcuts = .zen
            } else if parts.count == 2, let id = ShortcutID(rawValue: parts[0]) {
                let mods = parts[1].split(separator: "+").map(String.init)
                let combo = mods.last.map {
                    KeyCombo(
                        $0, command: mods.contains("cmd"), shift: mods.contains("shift"), option: mods.contains("opt"),
                        control: mods.contains("ctrl"))
                }
                prefs.shortcuts.set(id, to: parts[1] == "none" ? nil : combo)
            }
        }
        if let click = request.string("peekclick").flatMap(PeekClick.init(rawValue:)) { prefs.peekClick = click }
        // Split view (test runs): TAB:SIDE beside the tab in front, a layout, or undone.
        if Storage.testing, let what = request.string("split") {
            let parts = what.split(separator: ":").map(String.init)
            if let found = tab(parts[0]), let side = parts.last.flatMap(SplitSide.init(rawValue:)), let active = browser.active {
                browser.split(found, beside: active, side: side)
            } else if let grid = SplitGrid(rawValue: what), let group = browser.activeID.flatMap(browser.group(of:)) {
                browser.relayout(group, grid)
            } else if what == "off", let group = browser.activeID.flatMap(browser.group(of:)) {
                browser.unsplit(group: group)
            }
        }
        // Responsive Design Mode for the tab in front: a preset's name, or off.
        if let name = request.string("device") { browser.active?.device = DeviceList.shared.device(named: name) }
        if let on = request.bool("extensions") { NotificationCenter.default.post(name: PageButton.ask, object: on) }
        // Snap's picker on the tab in front (test runs).
        if Storage.testing, let on = request.bool("snap"), on != browser.pickingElement { browser.toggleHiding() }
        if let on = request.bool("theming") { browser.themingSpace = on ? browser.spaceID : nil }
        if Storage.testing, request.flag("zenkeys") {
            let keys = ZenImporter.profiles().first.flatMap(ZenImporter.shortcuts(in:))
            return call.answer([
                "found": keys != nil,
                "changed": (keys?.changed ?? [:]).map { "\($0.key.title): \($0.value.map(\.text).joined(separator: " "))" }.sorted(),
            ])
        }
        // The app menu's items, for the bench: a popped-up menu holds the run loop.
        if Storage.testing, request.flag("appmenu") {
            let describe = { (item: NSMenuItem) -> String in
                item.isSeparatorItem
                    ? "—"
                    : "\(item.title)\(item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalent)]")"
                        + (item.submenu.map {
                            " › \($0.items.prefix(4).map { "\($0.state == .on ? "✓" : "")\($0.title)\($0.action == nil && $0.submenu == nil ? "(dead)" : "")" })"
                        } ?? "")
            }
            return call.answer(["items": AppMenu.make(for: browser).items.map(describe)])
        }
        // An import run straight (test runs): SOURCE|kind,kind|FILE; the sources' ids too.
        if Storage.testing, let asked = request.string("importrun") {
            let parts = asked.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let sources = ImportSource.found()
            guard let source = sources.first(where: { $0.id == parts[0] }) else {
                return call.answer(["sources": sources.map { ["id": $0.id, "name": $0.name, "kinds": $0.kinds.map(\.rawValue)] }])
            }
            let kinds = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { ImportKind(rawValue: String($0)) })
            let file = parts.count > 2 && !parts[2].isEmpty ? URL(fileURLWithPath: parts[2]) : nil
            Task {
                do {
                    let tally = try await browser.bring(kinds, from: source, file: file)
                    call.answer([
                        "tally": tally.summary, "bookmarks": tally.bookmarks, "history": tally.history, "passwords": tally.passwords,
                    ])
                } catch {
                    call.answer(["trouble": "\(error)"])
                }
            }
            return
        }
        // The Dock icon as it is now, to a PNG.
        if Storage.testing, let asked = request.string("dockicon") {
            // PATH@ID: another profile's, as its own Mote wears it.
            let parts = asked.split(separator: "@").map(String.init)
            let path = parts[0]
            let icon = parts.count > 1 ? Profiles.shared.dockIcon(for: parts[1]) : NSApp.applicationIconImage
            guard let tiff = icon?.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return call.fail("no icon") }
            try? png.write(to: URL(fileURLWithPath: path))
            return call.answer(["saved": path, "profile": Storage.profile ?? "first"])
        }
        // The app menu's zoom row drawn light and dark, PATH-light.png and PATH-dark.png.
        if Storage.testing, let path = request.string("zoomrow") {
            guard let row = AppMenu.make(for: browser).items.compactMap(\.view).first else { return call.fail("no zoom row") }
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                row.appearance = NSAppearance(named: look)
                row.layoutSubtreeIfNeeded()
                guard let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { continue }
                // A menu's ground behind, as the row has none of its own.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                (look == .aqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                row.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                row.cacheDisplay(in: row.bounds, to: bitmap)
                try? BenchPictures.save(bitmap, to: "\(path)-\(name).png")
            }
            return call.answer(["saved": path])
        }
        call.answer(["ok": true])
    }

    /// The consent item (Bench.Consent), and granting or revoking it.
    private static func consent(_ call: BenchCall) {
        guard call.testRun() else { return }
        let before = Consent.given
        switch call.request.string("action") {
        case "grant": Consent.grant()
        case "revoke": Consent.revoke()
        default: break
        }
        call.answer(["before": before, "after": Consent.given])
    }

    /// A link window made without showing it, or the last one kept or closed.
    private static func little(_ call: BenchCall) {
        let browser = call.browser
        switch call.request.string("what") ?? "" {
        case "keep": LinkWindow.all.last?.keep()
        case "close": LinkWindow.all.last?.close()
        case let text:
            guard let url = URL(string: text), !text.isEmpty else { return call.fail("little needs a url, keep or close") }
            LinkWindow.show(url, for: browser, front: false)
        }
        call.answer([
            "littles": LinkWindow.all.map { $0.tab.address?.absoluteString ?? "" },
            "tabs": browser.tabs.map { ($0.pin != nil ? "PIN " : $0.kept ? "KEPT " : "") + ($0.address?.host() ?? "blank") },
            "active": browser.active?.address?.host() ?? "",
        ])
    }

    /// Making, switching, deleting, moving and swiping spaces. A trackpad
    /// can't reach a window in the background, so swipes drive SpaceSwipe.
    private static func space(_ call: BenchCall) {
        guard call.testRun() else { return }
        let browser = call.browser, request = call.request, swipe = SpaceSwipe.shared
        let drag = {
            let dx = request.double("dx") ?? -120
            swipe.start(for: browser)
            swipe.began()
            for _ in 0..<12 { swipe.moved(along: dx / 12) }
        }
        switch request.string("action") ?? "" {
        case "new": browser.addSpace(named: request.string("name") ?? "Test", sharesSignIns: !request.flag("fresh"))
        case "go": browser.switchSpace(index: (request.int("index") ?? 1) - 1)
        case "delete": browser.deleteSpace(browser.spaceID)
        case "swipe":
            drag()
            swipe.ended()
        // Held mid-swipe, to look at.
        case "hold": drag()
        case "release": swipe.ended()
        case "move": request.int("index").map { browser.moveSpace(browser.spaceID, to: $0 - 1) }
        default: break
        }
        let out: [String: Any] = [
            "on": browser.prefs.usesSpaces, "current": browser.space.name,
            "spaces": browser.spaces.map {
                ["name": $0.name, "id": $0.id.uuidString, "downloads": $0.downloads ?? "", "shared": $0.sharesSignIns == true]
            },
            "parked": browser.parked.map { [$0.key.uuidString: $0.value.tabs.count] }, "tabs": browser.tabs.count,
            "making": browser.makingSpace,
            "swipe": Double(browser.spaceSwipe),
            "pages": Web.pages.allObjects.map { $0.configuration.websiteDataStore.identifier?.uuidString ?? "default" },
        ]
        // WebKit's stores a moment later, to check deleted spaces took theirs
        // along; with records, what's left in those being erased.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                MainActor.assumeIsolated {
                    var out = out
                    out["stores"] = ids.map(\.uuidString)
                    let erasing = (Storage.settings.stringArray(forKey: "spaces.erasing") ?? []).compactMap(UUID.init).filter(ids.contains)
                    guard request.flag("records"), !erasing.isEmpty else { return call.answer(out) }
                    Task { @MainActor in
                        var left: [String: [String]] = [:]
                        for id in erasing {
                            let records = await WKWebsiteDataStore(forIdentifier: id).dataRecords(
                                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                            left[id.uuidString] = records.map { "\($0.displayName): \($0.dataTypes.sorted().joined(separator: ","))" }
                        }
                        out["erasingRecords"] = left
                        call.answer(out)
                    }
                }
            }
        }
    }

    /// A link previewed over the tab in front, as a shift-click opens it; "close" shuts it.
    private static func peek(_ call: BenchCall) {
        guard call.testRun() else { return }
        if call.request.string("url") == "close" {
            call.browser.closePeek()
            return call.answer(["peek": ""])
        }
        guard let tab = call.browser.active, let url = call.request.string("url").flatMap(URL.init(string:)) else {
            return call.fail("peek needs a tab in front and an address")
        }
        call.browser.peek(url, from: tab)
        call.answer(["peek": url.absoluteString])
    }

    /// The browser window, through the Window menu, when a hidden launch has none.
    /// The browser windows, the front one marked; `new` opens one, `close N`
    /// and `front N` close it or bring it forward (test runs).
    private static func windows(_ call: BenchCall) {
        let request = call.request
        let all = { Windows.shared.all }
        if let action = request.string("action") {
            guard call.testRun() else { return }
            let index = (request.int("index") ?? 1) - 1
            switch action {
            case "new": Windows.shared.open()
            case "reopen": Windows.shared.reopenClosed()
            case "close": if all().indices.contains(index) { all()[index].window?.performClose(nil) }
            case "front": if all().indices.contains(index) { all()[index].window?.makeKeyAndOrderFront(nil) }
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            call.answer([
                "windows": all().enumerated().map { index, browser in
                    [
                        "index": index + 1, "front": browser === Browser.front, "extra": browser.extra, "space": browser.space.name,
                        "tabs": browser.tabs.map { $0.address?.host() ?? "blank" }, "shown": browser.window?.isVisible ?? false,
                    ] as [String: Any]
                }
            ])
        }
    }

    /// A link opened as a page menu item would (Browser+Links.swift), from
    /// the front window's tab in front (test runs).
    private static func link(_ call: BenchCall) {
        guard call.testRun(), let address = call.request.string("url"), let url = URL(string: address) else { return }
        let browser = call.browser
        let opening: LinkOpening? =
            switch call.request.string("where") ?? "" {
            case "tab": .tab(background: false)
            case "background": .tab(background: true)
            case "window": .window(private: false)
            case "private": .window(private: true)
            case "preview": .preview
            case "bookmark": .bookmark
            case "space": browser.spaces.first { $0.id != browser.spaceID }.map { .space($0.id) }
            default: nil
            }
        guard let opening else { return call.fail("where: tab, background, window, private, space, preview or bookmark") }
        browser.open(url, as: opening, from: browser.active)
        call.answer(["opened": true])
    }

    /// Quits as the menu would, saving every window (test runs).
    private static func quit(_ call: BenchCall) {
        guard call.testRun() else { return }
        call.answer(["quitting": true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private static func window(_ call: BenchCall) {
        guard call.testRun() else { return }
        if AppDelegate.window?.contentView != nil, NSApp.windows.contains(where: { $0 === AppDelegate.window }) {
            return call.answer(["window": "there"])
        }
        // As a link from another app brings it back (LinkInbox).
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            call.answer(["window": NSApp.windows.map { "\(type(of: $0))" }, "hidden": NSApp.isHidden])
        }
    }
}
