import AppKit
import MoteCore
import WebKit

// Tab sleep: tabs left idle let their page go and keep their history, scroll
// and a snapshot to come back from (see Tab.sleep). The rules are TabSleep's.
extension Browser {
    static var sleepAfter: TimeInterval { TabSleep.idleLimit(setting: Storage.settings.double(forKey: "sleep.after")) }

    /// Starts the idle check and listens for memory pressure. Once, at launch.
    func watchForSleep() {
        let every = TabSleep.checkEvery(limit: Browser.sleepAfter)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        // A warning leaves the person's limit alone. While memory is critical
        // the longest idle tab sleeps every couple of seconds until it clears.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.squeeze(event.contains(.critical))
            }
        }
        source.resume()
        pressure = source
    }

    /// Puts every tab idle for `limit` to sleep, other spaces' included, longest idle first.
    func sleepIdle(within limit: TimeInterval = Browser.sleepAfter) {
        guard prefs.sleepsTabs else { return }
        for tab in sleepable(within: limit) { sleep(tab) }
    }

    /// The tabs that may sleep, idle for `limit`, longest idle first. Tabs on
    /// screen are in use, so their idle time starts again.
    private func sleepable(within limit: TimeInterval) -> [Tab] {
        for id in [activeID].compactMap({ $0 }) + (shownSplit?.ids ?? []) { tab(id)?.touch() }
        let candidates = (tabs + parkedTabs).filter { awake(because: $0) == nil }
        let ids = TabSleep.idle(candidates.map { (id: $0.id, touched: $0.touched) }, limit: limit, now: Date())
        return ids.compactMap { id in candidates.first { $0.id == id } }
    }

    /// While memory is critical, the longest idle tab sleeps every couple of
    /// seconds, until it clears or nothing more may sleep.
    private func squeeze(_ critical: Bool) {
        squeezing?.invalidate()
        squeezing = nil
        guard critical, prefs.sleepsTabs else { return }
        let timer = Timer(timeInterval: TabSleep.squeezeEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let tab = self.sleepable(within: 0).first else { return self.squeeze(false) }
                self.sleep(tab)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        squeezing = timer
        timer.fire()
    }

    /// Why a tab has to stay awake, or nil. Idle time is the caller's to check.
    /// `asked`: the user unloaded it, so only what would be lost or broken
    /// (a call, a download, its video out) keeps it awake, not what rest
    /// alone respects (pinned, sound, loading, the opener on screen).
    func awake(because tab: Tab, asked: Bool = false) -> String? {
        var facts = TabSleep.Facts()
        facts.onScreen = tab.id == activeID || shownSplit?.contains(tab.id) == true
        facts.pinned = tab.held
        facts.bench = tab.bench
        facts.blank = tab.isBlank
        facts.asleep = tab.asleep
        facts.hasPage = tab.built != nil
        facts.loading = tab.loading
        facts.playingSound = tab.noisy
        facts.floating = tab.floating || floating == tab.id
        if let web = tab.built {
            facts.onCall = web.cameraCaptureState != .none || web.microphoneCaptureState != .none
            facts.downloading = downloading.contains { $0.webView === web }
        }
        facts.openedTheTabOnScreen = active?.opener == tab.id
        facts.agentAtWork = tab.agent.working
        facts.keptAwake = tab.keptAwake
        if asked { (facts.pinned, facts.playingSound, facts.loading, facts.openedTheTabOnScreen) = (false, false, false, false) }
        return TabSleep.keepsAwake(facts)?.rawValue
    }

    /// Checks for unsent input, takes a snapshot, then lets the page go. Each
    /// step waits on the page, so whether the tab may still sleep is asked
    /// again after each: the user may have come back to it.
    func sleep(_ tab: Tab, asked: Bool = false, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab, asked: asked) { return done?(reason) ?? () }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed, !asked { return done?(TabSleep.Reason.typed.rawValue) ?? () }
            if let reason = awake(because: tab, asked: asked) { return done?(reason) ?? () }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = awake(because: tab, asked: asked) { return done?(reason) ?? () }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
