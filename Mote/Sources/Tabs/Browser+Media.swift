import Foundation
import MoteCore

// The media strips' tabs: what plays somewhere you aren't looking.
extension Browser {
    /// How long a paused tab stays in the strip.
    private static let pausedFor: TimeInterval = 10 * 60

    /// After the change that called it has landed: `@Published` tells before
    /// the new value is stored.
    func notePlayingSoon() {
        Task { @MainActor [weak self] in self?.notePlaying() }
    }

    /// The tabs heard, in any space, other than the one in front, the one
    /// heard last first. As in Safari and Firefox only real media counts: what
    /// WebKit hears now, a site's own player (a media session), or something
    /// heard not long ago and paused. Muted backgrounds and GIF-like videos
    /// don't. A strip put away stays away until its tab starts playing again.
    func notePlaying() {
        let now = Date()
        let heard = (tabs + parkedTabs)
            .filter { tab in
                guard tab !== active, !tab.shy, let media = tab.media else { return false }
                return tab.noisy || media.session == true
                    || tab.lastAudible.map { now.timeIntervalSince($0) < Self.pausedFor } == true
            }
            .sorted { ($0.lastAudible ?? .distantPast) > ($1.lastAudible ?? .distantPast) }
        let sounding = Set(heard.filter { $0.media?.playing == true }.map(\.id))
        putAway.subtract(sounding.subtracting(wasPlaying))
        wasPlaying = sounding
        let shown = heard.filter { !putAway.contains($0.id) }
        if shown.map(\.id) != players.map(\.id) { players = shown }
    }

    /// Takes a strip away; its tab plays on.
    func putAway(_ tab: Tab) {
        putAway.insert(tab.id)
        notePlaying()
    }

    /// A strip's icon: back to its tab, in its space.
    func showPlaying(_ tab: Tab) {
        if !tabs.contains(where: { $0 === tab }),
            let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key
        {
            switchSpace(to: space)
        }
        if tabs.contains(where: { $0 === tab }) { select(tab) }
    }
}
