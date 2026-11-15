import Observation
import WebKit

/// What sites ask to use: whatever WebKit asks Mote about, the camera,
/// microphone, notifications, location, screen sharing and speech recognition.
/// Each question shows over its own tab's page, from the top, and goes with
/// it when the tab moves on; an answer kept is the site's from then on.
@MainActor
@Observable
final class SitePermissions {
    enum Kind: Hashable, Identifiable {
        case capture(WKMediaCaptureType)
        case notifications
        case location
        /// Sharing the screen or a window; the system then asks which.
        case screen
        /// Turning speech into text, for the page.
        case speech

        /// Where the answer is kept.
        fileprivate func key(_ host: String) -> String {
            switch self {
            case .capture(let type): "capture.\(host)|\(type.rawValue)"
            case .notifications: "notify.\(host)"
            case .location: "location.\(host)"
            case .screen: "screen.\(host)"
            case .speech: "speech.\(host)"
            }
        }

        var id: String { key("") }

        /// The settings' name for it.
        var title: String {
            switch self {
            case .capture(.camera): "Camera"
            case .capture(.microphone): "Microphone"
            case .capture: "Camera and Microphone"
            case .notifications: "Notifications"
            case .location: "Location"
            case .screen: "Screen Sharing"
            case .speech: "Speech Recognition"
            }
        }

        var what: String {
            switch self {
            case .capture(.camera): "use your camera"
            case .capture(.microphone): "use your microphone"
            case .capture: "use your camera and microphone"
            case .notifications: "send you notifications"
            case .location: "use your location"
            case .screen: "share your screen"
            case .speech: "recognize your speech"
            }
        }

        var symbol: String {
            switch self {
            case .capture(.microphone): "mic.fill"
            case .capture: "video.fill"
            case .notifications: "bell.badge.fill"
            case .location: "location.fill"
            case .screen: "rectangle.on.rectangle"
            case .speech: "waveform"
            }
        }
    }

    struct Ask: Identifiable, Equatable {
        let id = UUID()
        let tab: Tab.ID
        let host: String
        let kind: Kind
    }

    /// Questions waiting, oldest first; each tab shows its first.
    private(set) var asks: [Ask] = []
    @ObservationIgnored private var answers: [UUID: (Bool) -> Void] = [:]

    /// Answers from what the site was told before, or asks. The same question
    /// again from the same tab waits on the one already asked.
    func ask(_ kind: Kind, host: String, tab: Tab.ID, answer: @escaping (Bool) -> Void) {
        if let kept = Self.remembered(host, kind) { return answer(kept) }
        if Self.blocksNew(kind) { return answer(false) }
        if let same = asks.first(where: { $0.tab == tab && $0.host == host && $0.kind == kind }) {
            let first = answers[same.id]
            answers[same.id] = {
                first?($0)
                answer($0)
            }
            return
        }
        let ask = Ask(tab: tab, host: host, kind: kind)
        answers[ask.id] = answer
        asks.append(ask)
    }

    func first(for tab: Tab.ID) -> Ask? { asks.first { $0.tab == tab } }

    func answer(_ ask: Ask, allow: Bool, remember: Bool) {
        if remember { Self.remember(ask.host, ask.kind, allow) }
        asks.removeAll { $0.id == ask.id }
        answers.removeValue(forKey: ask.id)?(allow)
    }

    /// The tab left the page that asked, or closed: its questions are turned
    /// down, and nothing is kept.
    func drop(tab: Tab.ID) {
        for ask in asks where ask.tab == tab { answer(ask, allow: false, remember: false) }
    }

    /// The answer kept for `host`: allowed, blocked, or nil to ask.
    static func remembered(_ host: String, _ kind: Kind) -> Bool? {
        Storage.settings.object(forKey: kind.key(host)) as? Bool
    }

    static func remember(_ host: String, _ kind: Kind, _ allowed: Bool?) {
        if let allowed { Storage.settings.set(allowed, forKey: kind.key(host)) } else { Storage.settings.removeObject(forKey: kind.key(host)) }
        // No longer allowed to notify: its push subscriptions go too.
        if kind == .notifications, allowed != true { Task { @MainActor in WebPushService.shared.forget(host: host) } }
    }

    /// Each site with an answer kept, by host.
    static func sites(_ kind: Kind) -> [(host: String, allowed: Bool)] {
        let probe = kind.key("\u{1}")
        let (head, tail) = (probe.components(separatedBy: "\u{1}")[0], probe.components(separatedBy: "\u{1}")[1])
        return Storage.settings.dictionaryRepresentation()
            .compactMap { key, value -> (String, Bool)? in
                guard key.hasPrefix(head), key.hasSuffix(tail), let allowed = value as? Bool else { return nil }
                let host = String(key.dropFirst(head.count).dropLast(tail.count))
                return host.isEmpty || host.contains("|") || host.hasPrefix("*") ? nil : (host, allowed)
            }
            .sorted { $0.0 < $1.0 }
    }

    /// Sites that haven't been answered are turned down without asking.
    static func blocksNew(_ kind: Kind) -> Bool { Storage.settings.bool(forKey: kind.key("*new")) }

    static func blockNew(_ kind: Kind, _ on: Bool) {
        if on { Storage.settings.set(true, forKey: kind.key("*new")) } else { Storage.settings.removeObject(forKey: kind.key("*new")) }
    }

    /// Forgets every answer kept.
    func forgetAll() {
        for key in Storage.settings.dictionaryRepresentation().keys where (["capture.", "notify.", "location.", "screen.", "speech."].contains(where: key.hasPrefix)) && !key.contains("*new") {
            Storage.settings.removeObject(forKey: key)
        }
    }
}
