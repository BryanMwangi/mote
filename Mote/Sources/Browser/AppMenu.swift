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
                    ([nil] + profiles.list.map(\.id)).map { id in
                        let item = ActionItem(profiles.name(of: id)) { profiles.open(id) }
                        item.image = profiles.image(of: id, size: 16)
                        item.isEnabled = id != Storage.profile
                        return item
                    }
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
    private var lead: [NSView] = []
    private var controls: [NSView] = []

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        // As wide as the menu, however wide its other items make it.
        autoresizingMask = .width
        let icon = NSImageView(image: Self.symbol("plus.magnifyingglass"))
        icon.identifier = NSUserInterfaceItemIdentifier("plus.magnifyingglass")
        let title = NSTextField(labelWithString: "Zoom")
        title.font = .menuFont(ofSize: 0)
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percent.alignment = .center
        percent.textColor = .secondaryLabelColor
        let out = button("minus", #selector(zoomOut)), into = button("plus", #selector(zoomIn))
        let whole = button("arrow.up.left.and.arrow.down.right", #selector(fullScreen))
        let reset = NSClickGestureRecognizer(target: self, action: #selector(actualSize))
        percent.addGestureRecognizer(reset)
        lead = [icon, title]
        controls = [out, percent, into, whole]
        for view in lead + controls { addSubview(view) }
        for control in [out, into, whole] {
            control.isEnabled = !tab.isBlank
            control.alphaValue = tab.isBlank ? 0.35 : 1
        }
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The icon and "Zoom" where a menu item's icon and title go; the
    /// controls spread evenly from past "Zoom" to where shortcuts end.
    override func layout() {
        super.layout()
        guard lead.count == 2, controls.count == 4 else { return }
        let mid = bounds.midY
        lead[0].frame = NSRect(x: 14, y: mid - Self.box / 2, width: Self.box, height: Self.box)
        let title = lead[1].fittingSize
        lead[1].frame = NSRect(x: lead[0].frame.maxX + 6, y: mid - title.height / 2, width: title.width, height: title.height)
        let widths = controls.map { $0 === percent ? 44 : Self.box }
        let start = lead[1].frame.maxX + 18, end = bounds.maxX - 10
        let gap = max(0, (end - start - widths.reduce(0, +)) / CGFloat(controls.count - 1))
        var x = start
        for (view, width) in zip(controls, widths) {
            let height = view === percent ? view.fittingSize.height : Self.box
            view.frame = NSRect(x: x, y: mid - height / 2, width: width, height: height)
            x += width + gap
        }
    }

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        // A menu doesn't tint a borderless button's template, so the symbol
        // comes already in the menu's colour, drawn again when the look changes.
        let button = NSButton(image: Self.symbol(symbol), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        return button
    }

    /// Every symbol in one box, at one size.
    private static let box: CGFloat = 22

    private static func symbol(_ name: String) -> NSImage {
        let paint = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .medium)
            .applying(.init(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(paint) ?? NSImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for view in subviews {
            guard let name = view.identifier?.rawValue else { continue }
            (view as? NSButton)?.image = Self.symbol(name)
            (view as? NSImageView)?.image = Self.symbol(name)
        }
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
