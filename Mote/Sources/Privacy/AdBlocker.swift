import Combine
import MoteCore
import WebKit

// Ads and trackers are blocked by a WebKit content rule list, compiled once
// per launch. WebKit applies it in its network layer: no script runs per
// request.

@MainActor
final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()

    private(set) var list: WKContentRuleList?
    /// Pages made before the list was ready; they get it when it is.
    private var waiting: [WKUserContentController] = []

    /// Why the list couldn't be made. Nothing is blocked then, whatever
    /// Settings says, so Settings shows it.
    @Published private(set) var trouble: String?

    /// Open pages follow it after `apply(to:)`, from their next request.
    var enabled = true

    /// Sites where blocking is off because it broke them.
    private(set) var paused = Set(Storage.settings.stringArray(forKey: pausedKey) ?? [])
    private static let pausedKey = "shield.paused"

    func isPaused(on site: String?) -> Bool {
        site.map(paused.contains) ?? false
    }

    func pause(_ site: String, _ off: Bool) {
        if off { paused.insert(site) } else { paused.remove(site) }
        Storage.settings.set(paused.sorted(), forKey: Self.pausedKey)
    }

    private func blocks(_ site: String?) -> Bool { enabled && !isPaused(on: site) }

    /// Whether a page from `site` gets ads taken out of it (see YouTubeAds).
    func blocksAds(on site: String?) -> Bool { blocks(site) }

    func compile() {
        guard list == nil else { return }
        trouble = nil
        guard let rules = try? ContentBlockingRules.json() else { return trouble = "Couldn't build the block list" }
        guard let store = WKContentRuleListStore.default() else { return trouble = "WebKit has nowhere to compile it" }
        store.compileContentRuleList(forIdentifier: "mote-ad-blocker", encodedContentRuleList: rules) { [weak self] compiled, error in
            MainActor.assumeIsolated { self?.compiled(compiled, error) }
        }
    }

    private func compiled(_ compiled: WKContentRuleList?, _ error: Error?) {
        guard let compiled else { return trouble = error?.localizedDescription ?? "Compiling the block list failed" }
        list = compiled
        if enabled { waiting.forEach { set($0, blocking: true) } }
        waiting = []
    }

    /// A new page: the list now, or once it's compiled.
    func protect(_ controller: WKUserContentController) {
        guard list != nil else { return waiting.append(controller) }
        if enabled { set(controller, blocking: true) }
    }

    /// The pages holding the list, so a navigation that changes nothing
    /// doesn't send it to the page again.
    private let holding = NSHashTable<WKUserContentController>.weakObjects()

    /// Before loading a page from `site`: the list only counts from when
    /// it's added, so this runs as the navigation starts.
    func tune(_ controller: WKUserContentController, for site: String?) {
        set(controller, blocking: blocks(site))
    }

    /// `enabled` changed: open pages follow.
    func apply(to controllers: [WKUserContentController]) {
        controllers.forEach { set($0, blocking: enabled) }
    }

    private func set(_ controller: WKUserContentController, blocking: Bool) {
        guard let list, holding.contains(controller) != blocking else { return }
        if blocking {
            // One copied from an opener's may hold it already, untracked.
            controller.remove(list)
            controller.add(list)
            holding.add(controller)
        } else {
            controller.remove(list)
            holding.remove(controller)
        }
    }
}
