import Observation
import WebKit

/// Camera and microphone requests from pages. A site's answer is remembered,
/// so each site asks once; WebKit holds the page until it hears back.
@MainActor
@Observable
final class CaptureRequests {
    struct Ask: Equatable, Identifiable {
        let host: String
        /// "camera", "microphone" or "camera and microphone".
        let wants: String
        var id: String { host + wants }
    }

    /// The request being asked about, if any.
    private(set) var asking: Ask?

    @ObservationIgnored private var answer: ((WKPermissionDecision) -> Void)?
    @ObservationIgnored private var key = ""

    private static let prefix = "capture."

    /// Answers from memory, or asks. Only one question is open at a time;
    /// another request meanwhile is denied rather than queued.
    func request(host: String, type: WKMediaCaptureType, answer: @escaping (WKPermissionDecision) -> Void) {
        let key = "\(host)|\(type.rawValue)"
        if let remembered = Storage.settings.object(forKey: Self.prefix + key) as? Bool {
            answer(remembered ? .grant : .deny)
            return
        }
        guard self.answer == nil else {
            answer(.deny)
            return
        }
        self.answer = answer
        self.key = key
        asking = Ask(host: host, wants: Self.name(for: type))
    }

    func allow() { decide(.grant) }
    func deny() { decide(.deny) }

    /// The answer kept for `host`: allowed, blocked, or nil to ask (Page Info).
    static func remembered(_ host: String, _ type: WKMediaCaptureType) -> Bool? {
        Storage.settings.object(forKey: prefix + "\(host)|\(type.rawValue)") as? Bool
    }

    static func remember(_ host: String, _ type: WKMediaCaptureType, _ allowed: Bool?) {
        let key = prefix + "\(host)|\(type.rawValue)"
        if let allowed { Storage.settings.set(allowed, forKey: key) } else { Storage.settings.removeObject(forKey: key) }
    }

    /// Forgets every remembered answer.
    func forgetAll() {
        for key in Storage.settings.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            Storage.settings.removeObject(forKey: key)
        }
    }

    private func decide(_ decision: WKPermissionDecision) {
        guard let answer else { return }
        Storage.settings.set(decision == .grant, forKey: Self.prefix + key)
        answer(decision)
        self.answer = nil
        key = ""
        asking = nil
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "camera and microphone"
        }
    }
}
