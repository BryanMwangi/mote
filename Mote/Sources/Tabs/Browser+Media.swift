import Foundation
import MoteCore

// The media strip's tab: what plays somewhere you aren't looking.
extension Browser {
    /// How long a paused tab stays in the strip.
    private static let pausedFor: TimeInterval = 10 * 60

    /// After the change that called it has landed: `@Published` tells before
    /// the new value is stored.
    func notePlayingSoon() {
        Task { @MainActor [weak self] in self?.notePlaying() }
    }

    /// The tab most recently playing, in any space, other than the one in
    /// front: playing now, or paused not long ago.
    func notePlaying() {
        let now = Date()
        let pick = (tabs + parkedTabs)
            .filter { tab in
                guard tab !== active, !tab.shy, let media = tab.media else { return false }
                return media.playing || tab.noisy || tab.lastPlayed.map { now.timeIntervalSince($0) < Self.pausedFor } == true
            }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        if playing !== pick { playing = pick }
    }

    /// The strip's icon: back to the tab, in its space.
    func showPlaying() {
        guard let tab = playing else { return }
        if !tabs.contains(where: { $0 === tab }),
            let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key
        {
            switchSpace(to: space)
        }
        if tabs.contains(where: { $0 === tab }) { select(tab) }
    }
}
