import Foundation

/// When an idle tab may let its page go.
public enum TabSleep {
    /// What is known about a tab when deciding.
    public struct Facts: Sendable {
        public var onScreen = false
        public var pinned = false
        public var bench = false
        public var blank = false
        public var asleep = false
        public var hasPage = true
        public var loading = false
        public var playingSound = false
        public var floating = false
        public var onCall = false
        public var downloading = false
        /// The tab on screen was opened from it (a sign-in pop-up reports back).
        public var openedTheTabOnScreen = false
        /// The assistant is working on its page.
        public var agentAtWork = false
        /// The person asked for this tab to stay awake.
        public var keptAwake = false

        public init() {}
    }

    /// Why a tab stays awake. The descriptions are what the bench prints.
    public enum Reason: String, Sendable {
        case onScreen = "on screen"
        case pinned
        case bench = "a bench tab"
        case blank
        case asleep = "already asleep"
        case noPage = "no page"
        case loading = "still loading"
        case sound = "playing sound"
        case floating = "its video is out"
        case call = "on a call"
        case downloading
        case opener = "the page on screen came from it"
        case typed = "holding something typed"
        case agent = "the assistant is working on it"
        case kept = "kept awake"
    }

    /// The first reason the tab must stay awake, or nil if it may sleep.
    public static func keepsAwake(_ tab: Facts) -> Reason? {
        let checks: [(Bool, Reason)] = [
            (tab.onScreen, .onScreen), (tab.pinned, .pinned), (tab.bench, .bench), (tab.blank, .blank),
            (tab.asleep, .asleep), (!tab.hasPage, .noPage), (tab.loading, .loading), (tab.playingSound, .sound),
            (tab.floating, .floating), (tab.onCall, .call), (tab.downloading, .downloading),
            (tab.openedTheTabOnScreen, .opener), (tab.agentAtWork, .agent), (tab.keptAwake, .kept),
        ]
        return checks.first { $0.0 }?.1
    }

    /// Idle time before a tab sleeps: 30 minutes, or `setting` seconds when set.
    public static func idleLimit(setting: TimeInterval) -> TimeInterval {
        setting > 0 ? setting : 30 * 60
    }

    /// How often to look for idle tabs: a quarter of the limit, between 5
    /// seconds and a minute.
    public static func checkEvery(limit: TimeInterval) -> TimeInterval {
        min(60, max(5, limit / 4))
    }

    /// How often, while memory is critical, the longest idle tab goes to sleep.
    public static let squeezeEvery: TimeInterval = 2

    /// The tabs idle for at least `limit`, longest idle first.
    public static func idle<ID>(_ tabs: [(id: ID, touched: Date)], limit: TimeInterval, now: Date) -> [ID] {
        tabs.filter { now.timeIntervalSince($0.touched) >= limit }.sorted { $0.touched < $1.touched }.map(\.id)
    }
}
