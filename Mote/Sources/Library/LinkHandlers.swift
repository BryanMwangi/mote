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

    /// The schemes listed in Settings before any a site has tried.
    static let common = ["mailto", "tel", "sms", "facetime", "webcal"]
    /// Schemes sites have tried to open, each with the last site that did.
    private static let seenKey = "links.seen"

    /// Every scheme to list: the common ones, those set, and those sites tried.
    static var schemes: [String] {
        let set = (Storage.settings.dictionary(forKey: key) ?? [:]).keys
        let seen = (Storage.settings.dictionary(forKey: seenKey) ?? [:]).keys
        return common + Set(set).union(seen).subtracting(common).sorted()
    }

    /// A site tried to open a link of `scheme`: kept, to list and choose for.
    static func seen(_ scheme: String, from host: String?) {
        let scheme = scheme.lowercased()
        guard !scheme.isEmpty, scheme.count < 64 else { return }
        var all = Storage.settings.dictionary(forKey: seenKey) ?? [:]
        all[scheme] = host ?? ""
        Storage.settings.set(all, forKey: seenKey)
    }

    /// The last site that tried to open a link of `scheme`.
    static func askedBy(_ scheme: String) -> String? {
        (Storage.settings.dictionary(forKey: seenKey)?[scheme] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The Mac's app for `scheme`, by name; nil for none, or Mote.
    static func systemApp(for scheme: String) -> String? {
        guard let app = URL(string: scheme + ":x").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)),
            app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
        else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func appName(_ id: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Mail links from other apps come to Mote, for what's chosen for mailto.
    static var moteTakesMail: Bool {
        URL(string: "mailto:x").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    static func takeMail() async {
        try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
    }

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
