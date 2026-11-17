import AppKit
import MoteCore
import WebKit

// Extensions' buttons: what they show, what pressing one does, where their
// popups come from; and their keyboard shortcuts and context menu items.

@available(macOS 15.4, *)
extension Extensions {
    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        /// It may read and change the page in front: one without access
        /// to this site shows faded.
        let active: Bool
        /// It's a page action: a button for some pages, which it turns on
        /// for those it has something for.
        let pageAction: Bool
    }

    /// Beside the address: the extension whose proxy carries pages now, so
    /// it's plain which VPN is on, then those with something for the page
    /// in front (their page action on). As in Zen's address bar, which
    /// holds its add-ons' buttons until they'd crowd out the address: a few
    /// at most; the rest stay in the page panel.
    var addressButtons: [Button] {
        let all = buttons
        let vpn = ExtensionProxy.inUse.flatMap { id in all.first { $0.id == id } }
        let pages = all.filter { $0.pageAction && $0.enabled && $0.active && $0.id != vpn?.id }
        return Array(((vpn.map { [$0] } ?? []) + pages).prefix(Self.mostBesideAddress))
    }

    static let mostBesideAddress = 3

    /// Where extensions' popups hang from: the page button (PagePanel.swift).
    static let menuAnchor = "__menu"

    /// The running extensions' buttons, in the order they were installed.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        let page = front?.active?.address
        return installed.compactMap { item in
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            return Button(
                id: item.id, name: item.name, label: action.label.isEmpty ? item.name : action.label,
                icon: action.icon(for: CGSize(width: 16, height: 16)), badge: action.badgeText, enabled: action.isEnabled,
                active: page.map { context.hasAccess(to: $0, in: tab) } ?? false,
                pageAction: context.webExtension.manifest["page_action"] != nil)
        }
    }

    /// Its own button when it's showing, else the puzzle button: of the
    /// several drawn (the toolbar's, the sidebar's), the one on screen in
    /// the browser's window.
    func anchor(for id: String) -> NSView? {
        showing(anchors[id]) ?? showing(anchors[Self.menuAnchor])
    }

    private func showing(_ views: [WeakView]?) -> NSView? {
        // The window in front: a second window's buttons, not the first's.
        let front = self.front?.window ?? NSApp.keyWindow
        return views?.compactMap(\.view).last { view in
            guard let window = view.window, window.isVisible, front == nil || window === front else { return false }
            return !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
        }
    }

    /// Notes a view a popup may hang from; there may be one for `id` in each place it's drawn.
    func register(_ view: NSView, for id: String) {
        var views = (anchors[id] ?? []).filter { $0.view != nil && $0.view !== view }
        views.append(WeakView(view))
        anchors[id] = views
    }

    func press(_ id: String) {
        guard let context = contexts[id], !ExtensionPopup.shared.closes(id) else { return }
        let tab = activeAdapter
        if let tab { context.userGesturePerformed(in: tab) }
        let popsUp = context.action(for: tab)?.presentsPopup == true
        // sidePanel.setPanelBehavior({ openPanelOnActionClick: true }), or a
        // Firefox sidebar with no button of its own: the button toggles it.
        let sidebarOnly = context.webExtension.manifest["sidebar_action"] != nil && context.webExtension.manifest["browser_action"] == nil
        if ExtensionShims.panelOnClick.contains(id) || sidebarOnly, !popsUp { return ExtensionShims.togglePanel(context, owner: self) }
        // The popup directly: WebKit would build its own first, and swapping
        // it drops the new popup's first messages to the worker.
        if popsUp, let page = popup(of: context) { return ExtensionPopup.shared.show(page, for: context, from: anchor(for: id)) }
        context.performAction(for: tab)
    }

    /// For this tab: action.setPopup's choice, else the manifest's.
    private func popup(of context: WKWebExtensionContext) -> URL? {
        let choice = ExtensionRules.popup(
            overrides: ExtensionShims.popups[context.uniqueIdentifier] ?? [:], tab: browser?.active?.id.uuidString)
        switch choice {
        case .manifest: return Self.popupURL(for: context)
        case .none: return nil
        case .page(let path): return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
        }
    }

    /// The manifest's popup, with its query string.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        ExtensionRules.manifestPopup(context.webExtension.manifest).flatMap { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL }
    }

    /// A popup page's address, moved to its copy (ExtensionRules.popupCopy)
    /// so WebKit doesn't treat it as its own popup. Other pages are as they are.
    static func unpopped(_ url: URL) -> URL {
        guard url.scheme == scheme, let id = url.host, let context = shared.contexts[id],
            !url.lastPathComponent.contains(ExtensionRules.popupCopy)
        else { return url }
        let chosen = ExtensionShims.popups[id]?.values.map { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL } ?? []
        guard ([popupURL(for: context)] + chosen).contains(where: { $0?.path == url.path }),
            let original = ExtensionShims.inside(url.path, of: folder(for: id)),
            let data = try? Data(contentsOf: original)
        else { return url }
        let name = ExtensionRules.popupCopyName(of: original.lastPathComponent)
        let copy = original.deletingLastPathComponent().appendingPathComponent(name)
        if (try? Data(contentsOf: copy)) != data {
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return url }
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = ((url.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        return parts.url ?? url
    }

    /// Runs the extension command bound to this key, if there is one. A
    /// Firefox add-on's `_execute_sidebar_action` opens or closes its panel.
    func take(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags
        let typed = event.charactersIgnoringModifiers ?? ""
        let sidebar = contexts.values.first { context in
            ExtensionShortcut.suggested(for: "_execute_sidebar_action", in: context.webExtension.manifest)?.matches(
                key: typed, command: held.contains(.command), shift: held.contains(.shift), option: held.contains(.option),
                control: held.contains(.control)) == true
        }
        if let sidebar {
            ExtensionShims.togglePanel(sidebar, owner: self)
            return true
        }
        return contexts.values.first { $0.command(for: event) != nil }?.performCommand(for: event) ?? false
    }

    /// What extensions add to a page's context menu, but for those whose
    /// entries WebKit put there itself (`ownItems`).
    func menuItems(for tab: Tab, except placed: Set<String> = []) -> [NSMenuItem] {
        guard shows(tab) else { return [] }
        let adapter = adapter(for: tab)
        return contexts.filter { !placed.contains($0.key) }.values.flatMap { context in
            context.menuItems(for: adapter).map { Self.own($0, icon: icon(of: context)) }
        }
    }

    /// Extensions' entries WebKit put in a page's menu itself, each led by
    /// its extension's icon, as Chrome shows them: found by the extension's
    /// name on its submenu, by the titles of its own entries, or by the
    /// titles it gave them. Returns the extensions found, which aren't
    /// added again (a submenu named for the extension's short name, not its
    /// full one, showed twice).
    @discardableResult
    func ownItems(in menu: NSMenu, for tab: Tab?) -> Set<String> {
        let adapter = tab.map { self.adapter(for: $0) }
        var placed: Set<String> = []
        for (index, item) in menu.items.enumerated() where String(describing: type(of: item)).contains("WebExtensionMenuItem") {
            let found = contexts.first { id, context in
                if item.submenu != nil, context.webExtension.displayName == item.title { return true }
                if let adapter, context.menuItems(for: adapter).contains(where: { $0.title == item.title }) { return true }
                return menuTitles[id, default: []].contains { Self.title($0, matches: item.title) }
            }
            if let id = found?.key { placed.insert(id) }
            menu.removeItem(at: index)
            menu.insertItem(Self.own(item, icon: found.flatMap { icon(of: $0.value) }), at: index)
        }
        return placed
    }

    /// An entry's title as given (`%s` the selection) against one shown.
    private static func title(_ given: String, matches shown: String) -> Bool {
        let parts = given.replacingOccurrences(of: "&&", with: "&").components(separatedBy: "%s")
        guard parts.count > 1 else { return given == shown || given.replacingOccurrences(of: "&", with: "") == shown }
        return shown.hasPrefix(parts[0]) && shown.hasSuffix(parts[parts.count - 1])
    }

    private func icon(of context: WKWebExtensionContext) -> NSImage? {
        let size = CGSize(width: 16, height: 16)
        return context.action(for: activeAdapter)?.icon(for: size) ?? context.webExtension.icon(for: size)
    }

    /// Mote's copy of an extension's item, which runs the original: WebKit's
    /// items put back their titles as the menu updates, and a picture that
    /// isn't a symbol goes undrawn as an item's image, so the icon goes in a
    /// title that's Mote's to keep (BookmarkMenu.title).
    private static func own(_ item: NSMenuItem, icon: NSImage?) -> NSMenuItem {
        if item.isSeparatorItem { return .separator() }
        let made: NSMenuItem
        if let submenu = item.submenu {
            made = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            made.submenu = NSMenu(title: item.title)
            made.submenu?.items = submenu.items.map { own($0, icon: nil) }
        } else {
            made = ActionItem(item.title) {
                guard let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }
            made.state = item.state
            made.isEnabled = item.isEnabled
        }
        let picture = item.image.flatMap { $0.isTemplate ? nil : $0.copy() as? NSImage } ?? icon?.copy() as? NSImage
        picture?.size = NSSize(width: 16, height: 16)
        if let picture { made.attributedTitle = BookmarkMenu.title(item.title, icon: picture) } else { made.image = item.image }
        return made
    }
}
