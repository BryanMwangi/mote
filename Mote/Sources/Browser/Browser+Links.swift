import AppKit
import MoteCore
import WebKit

/// Where a link from the page's menu goes. WebKit's own "Open Link in New
/// Window" knows the link; Mote's items say where it goes, then send it
/// (see PageView's menu), and `createWebViewWith` reads this.
enum LinkOpening: Equatable {
    /// A tab here, in front or left behind.
    case tab(background: Bool)
    /// A new window, private or not.
    case window(private: Bool)
    /// A tab in another space, with that space's sign-ins.
    case space(UUID)
    case split
    /// The preview over the page (shift-click's).
    case preview
    case bookmark
    /// macOS's share picker, from where the link was clicked.
    case share(at: NSRect, in: NSView)
}

extension Browser {
    /// A private window's tab: all of them share its store, which keeps nothing.
    func privateTab() -> Tab {
        Tab(shy: true, configuration: Web.configuration(shy: true, store: privateStore))
    }

    /// Says a link went to a tab behind this one, with the way to it.
    func openedBehind(_ tab: Tab) {
        let show = Announcement.Action(title: "Show") { [weak self, weak tab] in
            if let tab { self?.select(tab) }
        }
        announce(Announcement("Opened in a new tab", symbol: "plus.square.on.square", action: show))
    }

    /// A link sent somewhere other than a tab here. It opens afresh there, as
    /// Firefox does: the page it came from doesn't follow it to another
    /// store.
    func open(_ url: URL, as opening: LinkOpening, from opener: Tab?) {
        switch opening {
        case .tab(let background):
            let tab = open(url, foreground: !background, from: opener)
            if background { openedBehind(tab) }
        case .window(let isPrivate):
            let window = Windows.shared.open(space: spaceID, private: isPrivate)
            // The new window's blank tab makes way for the link.
            let blank = window.active
            window.open(url, foreground: true)
            if let blank, blank.isBlank { window.close(blank) }
            window.announce(isPrivate ? "Opened in a new private window" : "Opened in a new window")
        case .space(let id):
            guard let space = spaces.first(where: { $0.id == id }) else { return }
            if id == spaceID { return open(url, as: .tab(background: true), from: opener) }
            let tab = Tab(configuration: Web.configuration(space: id))
            prepare(tab)
            tab.restore(url: url, title: url.host() ?? url.absoluteString, name: nil)
            if parked[id] == nil { parked[id] = loadRow(id) }
            parked[id]?.tabs.append(tab)
            writeSession(now: false, space: id, tabs: parked[id]?.tabs ?? [], active: parked[id]?.active)
            announce("Opened in \(space.name)")
        case .split:
            let tab = open(url, foreground: false, from: opener)
            if let beside = opener ?? active { split(tab, beside: beside, side: .right) }
        case .preview:
            if let opener { peek(url, from: opener) }
        case .bookmark:
            bookmarks.add(url, title: url.host() ?? url.absoluteString)
            announce("Bookmarked")
        case .share(let spot, let view):
            NSSharingServicePicker(items: [url]).show(relativeTo: spot, of: view, preferredEdge: .maxY)
        }
    }
}
