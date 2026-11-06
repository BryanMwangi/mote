import MoteCore
import SwiftUI

/// The "…" at the end of the toolbar (or the sidebar's top, with the toolbar
/// hidden), as Zen's app menu: windows, the library, the page and zoom in
/// reach, without the menu bar. A native menu, so its submenus open beside
/// it while it stays.
struct AppMenuButton: View {
    let browser: Browser
    @State private var anchor = WeakView(NSView())

    var body: some View {
        Door(icon: "ellipsis", help: "Mote") {
            guard let view = anchor.view else { return }
            AppMenu.make(for: browser).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        }
        .background(MenuSpot(spot: anchor))
    }
}

/// Marks the button the menu drops from.
private struct MenuSpot: FillsRoom {
    let spot: WeakView
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        spot.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { spot.view = view }
}

@MainActor
enum AppMenu {
    static func make(for browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let page = browser.active?.isBlank == false
        let item = { (symbol: String, id: ShortcutID) -> NSMenuItem in
            line(id.title, symbol, combo: browser.prefs.shortcuts.combos(for: id).first) { browser.perform(id) }
        }
        switch Updater.shared.stage {
        case .waiting, .offered:
            menu.addItem(line("Update Available — Install Now", "arrow.up.circle.fill") { Updater.shared.install() })
            menu.addItem(.separator())
        case .ready:
            let ready = line("Updated — It Opens Next Launch", "checkmark.circle.fill") {}
            ready.isEnabled = false
            menu.addItem(ready)
            menu.addItem(.separator())
        default: break
        }
        let profiles = Profiles.shared
        if !profiles.list.isEmpty {
            menu.addItem(
                sub(
                    "Open Profile", "person.crop.circle",
                    [ActionItem("Default") { profiles.open(nil) }]
                        + profiles.list.map { profile in ActionItem(profile.name) { profiles.open(profile.id) } }
                ))
            menu.addItem(.separator())
        }
        menu.items += [item("plus.square", .newTab), item("macwindow", .newWindow), item("eyeglasses", .newPrivateWindow), .separator()]
        // The menu bar's own, with their recent pages and folders.
        for (title, symbol) in [("History", "clock.arrow.circlepath"), ("Bookmarks", "book")] {
            if let original = NSApp.mainMenu?.item(withTitle: title)?.submenu {
                // Brought up to date first: SwiftUI rebuilds the menu bar's
                // menus only as they open, so a copy would show them as last seen.
                original.delegate?.menuNeedsUpdate?(original)
                original.update()
            }
            if let bar = NSApp.mainMenu?.item(withTitle: title)?.submenu?.copy() as? NSMenu {
                // A search box (a view) doesn't come over in a copy.
                let items = bar.items.filter { !$0.title.isEmpty || $0.isSeparatorItem }
                bar.removeAllItems()
                menu.addItem(sub(title, symbol, items))
            }
        }
        menu.items += [
            item("arrow.down.circle", .downloads), item("key", .passwords),
            line("Extensions", "puzzlepiece.extension") { browser.openSettings(at: .extensions) }, .separator(),
        ]
        let translate = line("Translate Page…", "translate") { if let tab = browser.active { browser.toggleTranslation(tab) } }
        translate.isEnabled = browser.active?.pageLanguage != nil || browser.active?.translated == true
        let pageItems = [
            item("printer", .print), item("square.and.arrow.down", .savePage), translate, item("doc.text.magnifyingglass", .find),
        ]
        for each in pageItems where !page { each.isEnabled = false }
        menu.items += pageItems
        if let tab = browser.active {
            let zoom = NSMenuItem()
            zoom.view = ZoomRow(browser: browser, tab: tab)
            menu.addItem(zoom)
        }
        menu.items += [
            .separator(), item("gearshape", .settings),
            sub(
                "More Tools", "wrench.and.screwdriver",
                [ShortcutID.screenshot, .inspector, .console, .viewSource, .responsive, .processes].map { id in
                    line(id.title, "", combo: browser.prefs.shortcuts.combos(for: id).first) { browser.perform(id) }
                }),
            line("About Mote", "info.circle") { NSApp.orderFrontStandardAboutPanel(nil) },
        ]
        return menu
    }

    private static func line(_ title: String, _ symbol: String, combo: KeyCombo? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title, run)
        if !symbol.isEmpty { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        // Shown as the menu bar shows it: one character keys only.
        if let combo, combo.key.count == 1 {
            item.keyEquivalent = combo.key.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if combo.command { mask.insert(.command) }
            if combo.shift { mask.insert(.shift) }
            if combo.option { mask.insert(.option) }
            if combo.control { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    private static func sub(_ title: String, _ symbol: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.submenu = NSMenu()
        item.submenu?.items = items
        return item
    }
}

/// − 100% + and full screen, for the page in front: AppKit controls, as a
/// menu runs its own event loop that SwiftUI views in it don't keep up with.
private final class ZoomRow: NSView {
    private let browser: Browser
    private let tab: Tab
    private let percent = NSTextField(labelWithString: "")

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Zoom")
        title.font = .menuFont(ofSize: 0)
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percent.alignment = .center
        percent.textColor = .secondaryLabelColor
        let out = button("minus", #selector(zoomOut)), into = button("plus", #selector(zoomIn))
        let whole = button("arrow.up.left.and.arrow.down.right", #selector(fullScreen))
        let reset = NSClickGestureRecognizer(target: self, action: #selector(actualSize))
        percent.addGestureRecognizer(reset)
        let row = NSStackView(views: [icon, title, NSView(), out, percent, into, whole])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        percent.widthAnchor.constraint(equalToConstant: 44).isActive = true
        addSubview(row)
        for control in [out, into, whole] { control.isEnabled = !tab.isBlank }
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        return button
    }

    private func show() { percent.stringValue = "\(Int((tab.zoom * 100).rounded()))%" }

    @objc private func zoomIn() {
        browser.zoom(by: 1.1)
        show()
    }

    @objc private func zoomOut() {
        browser.zoom(by: 1 / 1.1)
        show()
    }

    @objc private func actualSize() {
        browser.resetZoom()
        show()
    }

    @objc private func fullScreen() {
        enclosingMenuItem?.menu?.cancelTracking()
        browser.window?.toggleFullScreen(nil)
    }
}
