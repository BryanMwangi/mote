import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What opens a link Mote doesn't load itself (mailto:, tel:, zoommtg:…), by
/// its scheme: asking each time, the Mac's app for it, an app chosen here, or
/// a web service (Gmail for mailto) in a tab. Settings › General › Links.
enum LinkHandler: Equatable {
    /// The Mac's own app, without asking for clicked mail and phone links (as before).
    case system
    case ask
    /// An app, by bundle id.
    case app(String)
    /// A web address with `%s` where the whole link goes, escaped.
    case web(String)

    /// Saved as one string each: "ask", "app:ID", "web:TEMPLATE".
    init?(saved: String) {
        if saved == "ask" { self = .ask } else if saved.hasPrefix("app:") { self = .app(String(saved.dropFirst(4))) } else if saved
            .hasPrefix("web:")
        { self = .web(String(saved.dropFirst(4))) } else { return nil }
    }

    var saved: String? {
        switch self {
        case .system: nil
        case .ask: "ask"
        case .app(let id): "app:" + id
        case .web(let template): "web:" + template
        }
    }

    /// The page a web handler opens for `url`.
    static func address(_ template: String, for url: URL) -> URL? {
        let escaped = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return URL(string: template.replacingOccurrences(of: "%s", with: escaped))
    }
}

@MainActor
enum LinkHandlers {
    private static let key = "links.handlers"
    /// Web services sites offered (registerProtocolHandler), by scheme: their names and templates.
    private static let offeredKey = "links.offered"

    /// The schemes listed in Settings, before any a site offered.
    static let common = ["mailto", "tel", "sms", "facetime", "webcal", "zoommtg", "slack", "msteams"]

    /// Web mail ready to choose for mailto.
    static let webMail: [(name: String, template: String)] = [
        ("Gmail", "https://mail.google.com/mail/?extsrc=mailto&url=%s"),
        ("Outlook", "https://outlook.live.com/mail/0/deeplink/compose?mailtouri=%s"),
        ("Fastmail", "https://app.fastmail.com/action/compose/?mailto=%s"),
    ]

    static func handler(for scheme: String) -> LinkHandler {
        (Storage.settings.dictionary(forKey: key)?[scheme.lowercased()] as? String).flatMap(LinkHandler.init(saved:)) ?? .system
    }

    static func set(_ handler: LinkHandler, for scheme: String) {
        var all = Storage.settings.dictionary(forKey: key) ?? [:]
        all[scheme.lowercased()] = handler.saved
        Storage.settings.set(all, forKey: key)
    }

    /// Web services sites have offered for a scheme.
    static func offered(for scheme: String) -> [(name: String, template: String)] {
        let all = Storage.settings.dictionary(forKey: offeredKey) as? [String: [String: String]] ?? [:]
        return (all[scheme.lowercased()] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The services to choose from for a scheme: web mail for mailto, and what sites offered.
    static func services(for scheme: String) -> [(name: String, template: String)] {
        let offered = offered(for: scheme)
        let builtIn = scheme == "mailto" ? webMail.filter { mail in !offered.contains { $0.template == mail.template } } : []
        return builtIn + offered
    }

    /// A site offering to open a scheme's links (registerProtocolHandler):
    /// asked about once, kept among the choices, and used if the person says so.
    static func offer(scheme: String, template: String, from page: URL?, over view: WKWebView) {
        let scheme = scheme.lowercased()
        guard let host = page?.host(), let page,
            let resolved = URL(string: template, relativeTo: page)?.absoluteURL, resolved.host() == host,
            ["https", "http"].contains(resolved.scheme ?? ""), resolved.absoluteString.contains("%s"),
            Self.allowed(scheme), !offered(for: scheme).contains(where: { $0.template == resolved.absoluteString })
        else { return }
        let alert = Dialogs.alert(
            "Open \(scheme) links with \(host)?", "\(host) can open \(scheme): links in a tab. You can change this in Settings › General › Links.",
            buttons: ["Use \(host)", "Not Now"])
        Dialogs.ask(alert, over: view) { yes in
            var all = Storage.settings.dictionary(forKey: offeredKey) as? [String: [String: String]] ?? [:]
            all[scheme, default: [:]][host] = resolved.absoluteString
            Storage.settings.set(all, forKey: offeredKey)
            if yes { set(.web(resolved.absoluteString), for: scheme) }
        }
    }

    /// The schemes a site may offer to open, as browsers allow them: the safe
    /// list, or a `web+` one of its own.
    private static func allowed(_ scheme: String) -> Bool {
        let safe: Set = [
            "bitcoin", "ftp", "ftps", "geo", "im", "irc", "ircs", "magnet", "mailto", "matrix", "mms", "news", "nntp", "openpgp4fpr",
            "sftp", "sip", "sms", "smsto", "ssh", "tel", "urn", "webcal", "wtai", "xmpp",
        ]
        return safe.contains(scheme) || (scheme.hasPrefix("web+") && scheme.count > 4 && scheme.dropFirst(4).allSatisfy(\.isLetter))
    }
}

/// `navigator.registerProtocolHandler`, which WebKit leaves out on the Mac:
/// put in the page's world, it tells Mote, which asks the person.
final class ProtocolHandlerRelay: NSObject, WKScriptMessageHandler, TabRelay {
    static let name = "moteProtocolHandler"
    static let script = """
        (() => {
          const post = (scheme, url) => {
            try { window.webkit.messageHandlers.\(name).postMessage({ scheme: String(scheme), url: String(url) }); } catch {}
          };
          Object.defineProperty(Navigator.prototype, 'registerProtocolHandler', {
            value: function registerProtocolHandler(scheme, url) { post(scheme, url); },
            configurable: true, writable: true,
          });
        })();
        """

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String], let scheme = body["scheme"],
            let template = body["url"], scheme.count < 64, template.count < 2048
        else { return }
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, message.webView === web else { return }
            LinkHandlers.offer(scheme: scheme, template: template, from: web.url, over: web)
        }
    }
}

/// Settings › General › Links: what opens each kind of link Mote doesn't load.
struct LinkSettings: View {
    /// Looked at again after Mote is made the default for mail.
    @State private var looked = 0

    var body: some View {
        SettingsSection("Links", note: "What opens links to mail, calls and other apps, which Mote doesn't open itself.") {
            ForEach(Array(LinkHandlers.common.enumerated()), id: \.element) { index, scheme in
                if index > 0 { RowRule() }
                Row(scheme: scheme)
            }
            RowRule()
            SettingRow(
                "Mail links from other apps", mailIsMote ? "Open here, as set above" : "Open in \(mailAppName ?? "no app yet")",
                symbol: "envelope", tint: Tint.blue
            ) {
                if mailIsMote {
                    Label("Mote", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Pill("Send to Mote") {
                        Task {
                            if let mail = URL(string: "mailto:") {
                                try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: mail.scheme ?? "mailto")
                            }
                            looked += 1
                        }
                    }
                    .help("Makes Mote the app mail links open in, then what's chosen above for mailto opens them")
                }
            }
        }
        .id(looked)
    }

    private var mailApp: URL? { URL(string: "mailto:x").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } }
    private var mailIsMote: Bool { mailApp?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
    private var mailAppName: String? { mailApp.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } }

    private struct Row: View {
        let scheme: String
        @State private var choice: String = ""

        var body: some View {
            SettingRow(scheme + ":", detail, symbol: symbol, tint: Tint.blue) {
                Picker("", selection: $choice) {
                    Text(systemTitle).tag("")
                    Text("Always Ask").tag("ask")
                    let services = LinkHandlers.services(for: scheme)
                    if !services.isEmpty {
                        Divider()
                        ForEach(services, id: \.template) { Text($0.name).tag("web:" + $0.template) }
                    }
                    if case .app(let id) = LinkHandlers.handler(for: scheme) {
                        Divider()
                        Text(appName(id) ?? id).tag("app:" + id)
                    }
                    Divider()
                    Text("Other App…").tag("pick")
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: choice) { _, now in
                    if now == "pick" { return pickApp() }
                    LinkHandlers.set(LinkHandler(saved: now) ?? .system, for: scheme)
                }
            }
            .onAppear { choice = LinkHandlers.handler(for: scheme).saved ?? "" }
        }

        private var system: URL? { URL(string: scheme + ":x").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } }
        private var systemTitle: String {
            guard let system, system.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { return "No App" }
            return FileManager.default.displayName(atPath: system.path).replacingOccurrences(of: ".app", with: "")
        }
        private var detail: String {
            switch LinkHandlers.handler(for: scheme) {
            case .system: system == nil ? "No app opens these yet" : "The Mac's app for them"
            case .ask: "Asks which, each time"
            case .app(let id): "Opens in \(appName(id) ?? id)"
            case .web: "Opens in a tab"
            }
        }
        private var symbol: String {
            switch scheme {
            case "mailto": "envelope"
            case "tel", "facetime": "phone"
            case "sms": "message"
            case "webcal": "calendar"
            default: "link"
            }
        }

        private func appName(_ id: String) -> String? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
        }

        private func pickApp() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            if panel.runModal() == .OK, let app = panel.url, let id = Bundle(url: app)?.bundleIdentifier {
                LinkHandlers.set(.app(id), for: scheme)
                choice = "app:" + id
            } else {
                choice = LinkHandlers.handler(for: scheme).saved ?? ""
            }
        }
    }
}
