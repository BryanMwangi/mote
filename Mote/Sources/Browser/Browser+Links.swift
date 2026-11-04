import Foundation
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
    /// The preview over the page (shift-click's).
    case preview
    case bookmark
}

extension Browser {
    /// A private window's tab: all of them share its store, which keeps nothing.
    func privateTab() -> Tab {
        Tab(shy: true, configuration: Web.configuration(shy: true, store: privateStore))
    }

    /// A link sent somewhere other than a tab here. It opens afresh there, as
    /// Firefox does: the page it came from doesn't follow it to another
    /// store.
    func open(_ url: URL, as opening: LinkOpening, from opener: Tab?) {
        switch opening {
        case .tab(let background):
            open(url, foreground: !background, from: opener)
        case .window(let isPrivate):
            let window = Windows.shared.open(space: spaceID, private: isPrivate)
            // The new window's blank tab makes way for the link.
            let blank = window.active
            window.open(url, foreground: true)
            if let blank, blank.isBlank { window.close(blank) }
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
        case .preview:
            if let opener { peek(url, from: opener) }
        case .bookmark:
            bookmarks.add(url, title: url.host() ?? url.absoluteString)
            announce("Bookmarked")
        }
    }
}
