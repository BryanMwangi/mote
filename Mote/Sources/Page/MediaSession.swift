import Foundation
import WebKit

// What a tab plays, for the media strip at the foot of the sidebar
// (MediaStrip.swift): the page reports it, and the strip's buttons go back
// to the page as commands. See Scripts/src/media-session.ts.

/// What a page says it's playing.
struct MediaState: Equatable, Decodable {
    var title: String
    var artist: String
    var playing: Bool
    /// The media session actions the site handles itself.
    var actions: [String]
    /// The site describes what plays or handles its controls: a player.
    var session: Bool?

    var hasNext: Bool { actions.contains("nexttrack") }
}

/// Hears a page's media reports. The script runs in the page's own world, so
/// the page could send these itself; they only ever change its own tab's strip.
final class MediaRelay: NSObject, WKScriptMessageHandler, TabRelay {
    static let name = "media"
    /// Drawn at launch, so a page can't guess it before Mote sends a command.
    static let commandEvent = "mote-media-\(UUID().uuidString)"

    private struct Config: Encodable {
        let handler: String
        let commandEvent: String
    }

    static let script = InjectedScript.source("media-session", config: Config(handler: name, commandEvent: commandEvent))

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, text.utf8.count < 4096 else { return }
        let state = try? JSONDecoder().decode(MediaState?.self, from: Data(text.utf8))
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built, message.frameInfo.isMainFrame else { return }
            tab.mediaChanged(state)
        }
    }
}

/// The strip's buttons.
enum MediaCommand: String {
    case toggle, next, previous
}

extension Tab {
    func mediaChanged(_ state: MediaState?) {
        if media != state { media = state }
    }

    /// Sends a button press to the page, in its own world where the script listens.
    func send(_ command: MediaCommand) {
        guard let web = built else { return }
        let event = Self.jsonString(MediaRelay.commandEvent)
        let detail = Self.jsonString(command.rawValue)
        web.evaluateJavaScript("window.dispatchEvent(new CustomEvent(\(event), { detail: \(detail) }))", in: nil, in: .page)
        // Shown at once; the page's report follows.
        if command == .toggle, var state = media {
            state.playing.toggle()
            mediaChanged(state)
        }
    }

    private static func jsonString(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }
}
