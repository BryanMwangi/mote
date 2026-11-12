import AppKit
import UserNotifications
import WebKit

/// Sites' notifications, shown by macOS as Mote's: the page's title and
/// words, its site beneath, its icon beside. A click brings back the tab that
/// sent it, in its space, and tells the page. A site shows them once it is
/// allowed to (SitePermissions), and only while its tab is open.
@MainActor
final class WebNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebNotifications()

    /// Banners while Mote is in front, and clicks: in place before the
    /// first notification, extensions' included.
    func start() { UNUserNotificationCenter.current().delegate = self }

    /// Where a notification is kept: its tag's place when it has one, so a
    /// new one with the same tag takes the old one's.
    private static func identifier(host: String, id: String, tag: String) -> String {
        tag.isEmpty ? "page.\(id)" : "page.\(host).\(tag)"
    }

    /// Shows a notification for `tab`; false when macOS won't.
    func show(_ note: Note, from tab: Tab) async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                refused(by: tab)
                return false
            }
        } catch {
            NSLog("Notifications: macOS refused (%@)", error.localizedDescription)
            refused(by: tab)
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.host
        content.body = note.body
        content.threadIdentifier = note.host
        content.userInfo = ["tab": tab.id.uuidString, "page": note.id]
        if !note.silent { content.sound = .default }
        if let icon = Self.attachment(tab.icon) { content.attachments = [icon] }
        let request = UNNotificationRequest(
            identifier: Self.identifier(host: note.host, id: note.id, tag: note.tag), content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            NSLog("Notifications: macOS wouldn't show it (%@)", error.localizedDescription)
            return false
        }
    }

    /// Said once a launch: a site may notify, but macOS won't let Mote.
    private var toldRefused = false

    private func refused(by tab: Tab) {
        guard !toldRefused,
            let browser = Windows.shared.all.first(where: { $0.tab(tab.id) != nil || $0.parkedTabs.contains { $0 === tab } })
        else { return }
        toldRefused = true
        browser.announce(
            Announcement(
                "Notifications are off for Mote", detail: "Sites you allowed can't notify you until macOS lets Mote.",
                symbol: "bell.slash",
                action: .init(title: "Open Settings", perform: Self.openSystemSettings)))
    }

    /// Mote's page in System Settings › Notifications.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The page closed one it showed.
    func close(id: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let gone = delivered.filter { $0.request.content.userInfo["page"] as? String == id }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: gone)
        }
    }

    /// The site's icon, as a file macOS takes for the notification's picture.
    private static func attachment(_ icon: NSImage?) -> UNNotificationAttachment? {
        guard let icon, let tiff = icon.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "mote-notification-\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: file)
    }

    struct Note {
        let id: String
        let host: String
        let title: String
        let body: String
        let tag: String
        let silent: Bool
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let tab = (info["tab"] as? String).flatMap(UUID.init(uuidString:))
        let page = info["page"] as? String
        if let tab, let page { Task { @MainActor in Self.open(tab, page) } }
        done()
    }

    /// Back to the tab, in its window and space, and the page hears the click.
    private static func open(_ id: Tab.ID, _ page: String) {
        for browser in Windows.shared.all {
            guard let tab = (browser.tabs + browser.parkedTabs).first(where: { $0.id == id }) else { continue }
            NSApp.activate()
            browser.window?.makeKeyAndOrderFront(nil)
            browser.showPlaying(tab)
            let event = Tab.jsonString(NotificationRelay.clickEvent)
            tab.built?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent(\(event), { detail: \(Tab.jsonString(page)) }))", in: nil, in: .page)
            return
        }
    }
}

/// The notifications script's messages: how the site stands, asking, showing
/// and closing. Main frame only; the site is the frame's own origin.
final class NotificationRelay: NSObject, WKScriptMessageHandlerWithReply, TabRelay {
    static let name = "moteNotifications"
    /// Drawn at launch, so a page can't guess it.
    static let clickEvent = "mote-notification-\(UUID().uuidString)"

    private struct Config: Encodable {
        let handler: String
        let clickEvent: String
    }

    /// See Scripts/src/notifications.ts.
    static let script = InjectedScript.source("notifications", config: Config(handler: name, clickEvent: clickEvent))

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let host = message.frameInfo.securityOrigin.host
            guard let tab, let web = tab.built, message.webView === web, message.frameInfo.isMainFrame, !host.isEmpty,
                let body = message.body as? [String: Any]
            else { return replyHandler(nil, nil) }
            let state = { (allowed: Bool?) in allowed.map { $0 ? "granted" : "denied" } ?? "default" }
            switch body["kind"] as? String {
            case "state":
                replyHandler(state(SitePermissions.remembered(host, .notifications)), nil)
            case "ask":
                // Only when asked in answer to a click or a key: a site asking
                // as it loads hears nothing yet.
                guard let browser = Windows.shared.all.first(where: { $0.tab(for: web) != nil }),
                    SitePermissions.remembered(host, .notifications) != nil || (web as? PageView)?.mayOpenWindow == true
                else { return replyHandler("default", nil) }
                browser.permissions.ask(.notifications, host: host, tab: tab.id) { replyHandler(state($0), nil) }
                browser.bringOutQuestion(for: tab)
            case "show":
                guard SitePermissions.remembered(host, .notifications) == true, let id = body["id"] as? String else {
                    return replyHandler(false, nil)
                }
                let note = WebNotifications.Note(
                    id: id, host: host, title: String((body["title"] as? String ?? "").prefix(200)),
                    body: String((body["body"] as? String ?? "").prefix(1000)), tag: String((body["tag"] as? String ?? "").prefix(100)),
                    silent: body["silent"] as? Bool == true)
                Task { replyHandler(await WebNotifications.shared.show(note, from: tab), nil) }
            case "close":
                if let id = body["id"] as? String { WebNotifications.shared.close(id: id) }
                replyHandler(true, nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}
