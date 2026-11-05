import AppKit
import Combine
import MoteCore

/// The sites that always open in a given space, kept in one file every window
/// shares (see SpaceRoute).
@MainActor
final class RouteStore: ObservableObject {
    static let shared = RouteStore()
    @Published private(set) var routes: [SpaceRoute]
    private let file = JSONFile<[SpaceRoute]>("routes.json")

    private init() { routes = file.load() ?? [] }

    func change(_ edit: (inout [SpaceRoute]) -> Void) {
        edit(&routes)
        file.save(routes)
    }
}

/// Space routing, as Zen's: a page heading for a site a rule gives to
/// another space opens there instead.
extension Browser {
    /// The space a navigation should go to instead of here, or nil to let it
    /// load: only for a loose tab's page, only to a space that's there.
    func routedSpace(for url: URL, from tab: Tab) -> UUID? {
        guard usesSpaces, !tab.held, url.scheme?.hasPrefix("http") == true,
            let space = SpaceRoute.space(for: url.absoluteString, in: RouteStore.shared.routes), space != spaceID,
            spaces.contains(where: { $0.id == space })
        else { return nil }
        return space
    }

    /// Opens `url` in `space`, as the rule says: going there with it when the
    /// tab it came from was in front. A tab with no page yet (a new tab, a
    /// link's new tab) goes, as its page went elsewhere.
    func route(_ url: URL, to space: UUID, from tab: Tab, fresh: Bool) {
        let front = tab.id == activeID
        if fresh, tabs.count > 1 { close(tab) }
        if front {
            switchSpace(to: space)
            open(url, foreground: true)
        } else {
            open(url, as: .space(space), from: nil)
        }
    }

    /// The rule that sends `tab`'s site to this space, if there is one.
    func routeHere(for tab: Tab) -> SpaceRoute? {
        guard let host = (tab.pending ?? tab.address)?.host() else { return nil }
        return RouteStore.shared.routes.first { $0.space == spaceID && $0.match == .contains && $0.reference == host }
    }

    /// Always Open in This Space: the tab's site, from now on.
    func alwaysOpenHere(_ tab: Tab) {
        guard let host = (tab.pending ?? tab.address)?.host(), let space = spaces.first(where: { $0.id == spaceID }) else { return }
        RouteStore.shared.change { routes in
            routes.removeAll { $0.match == .contains && $0.reference == host }
            routes.append(SpaceRoute(reference: host, space: spaceID))
        }
        announce("\(host) opens in \(space.name) from now on")
    }

    func forgetRoute(_ id: UUID) {
        RouteStore.shared.change { $0.removeAll { $0.id == id } }
    }
}
