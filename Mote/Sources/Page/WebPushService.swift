import AppKit
import MoteCore
import UserNotifications

/// Sites' push subscriptions (the Push API), for sites allowed to notify:
/// WebKit gives apps no push, so Mote keeps the subscriptions itself on a
/// standard Web Push server, stays connected to it while Mote runs, and shows
/// what arrives as the site's notification. A site's messages are encrypted
/// to keys only Mote holds (WebPush).
@MainActor
final class WebPushService {
    static let shared = WebPushService()

    /// The push server: Mozilla's, which speaks the open Web Push protocol to
    /// any client over a WebSocket.
    ///
    /// For now. Mote is to have its own way in: a serverless relay to Apple's
    /// push service, with this server kept for builds that can't use it.
    private static let server = URL(string: "wss://push.services.mozilla.com/")!

    /// Mote says who it is, so the server's people can see and reach it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mote/\(Updater.version) (+https://github.com/mote-browser/mote)"
        ]
        return URLSession(configuration: configuration)
    }()

    nonisolated struct Subscription: Codable, Equatable, Sendable {
        /// The server's name for it.
        let channel: String
        let host: String
        /// The service worker registration's scope it belongs to.
        let scope: String
        let endpoint: String
        /// The site's own server key (VAPID), base64url; nil for none.
        let key: String?
        let keys: WebPush.Keys
    }

    private nonisolated struct Saved: Codable, Sendable {
        /// Who Mote is to the server.
        var uaid = ""
        var subscriptions: [Subscription] = []
    }

    private let file = JSONFile<Saved>("push.json")
    private lazy var saved = file.load() ?? Saved()
    private var socket: URLSessionWebSocketTask?
    private var ready = false
    /// Registrations waiting for the server's answer, by channel.
    private var waiting: [String: CheckedContinuation<String?, Never>] = [:]
    /// Subscribing while the connection opens: run once it's ready.
    private var whenReady: [() -> Void] = []
    private var retry: TimeInterval = 5
    private var pinger: Task<Void, Never>?
    /// When the server last said anything.
    private var lastHeard = Date.distantPast

    /// How the last pushes went, newest last, without their words: for the
    /// bench (`push`).
    private(set) var recent: [String] = []

    private func note(_ line: String) {
        recent.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
        if recent.count > 20 { recent.removeFirst() }
    }

    /// Where things stand, for the bench.
    var report: [String: Any] {
        [
            "connected": ready, "uaid": saved.uaid.isEmpty ? "" : "set",
            "subscriptions": saved.subscriptions.map { ["host": $0.host, "scope": $0.scope, "endpoint": String($0.endpoint.prefix(60)), "key": $0.key != nil] },
            "recent": recent,
        ]
    }

    /// At launch: connected if any site is subscribed.
    func start() {
        if !saved.subscriptions.isEmpty { connect() }
    }

    func subscription(host: String, scope: String) -> Subscription? {
        saved.subscriptions.first { $0.host == host && $0.scope == scope }
    }

    /// A subscription for the site's registration: the one it has, when the
    /// server key matches, or a new one. Nil when the server won't.
    func subscribe(host: String, scope: String, key: String?) async -> Subscription? {
        if let had = subscription(host: host, scope: scope) {
            if had.key == key { return had }
            unsubscribe(host: host, scope: scope)
        }
        let channel = UUID().uuidString.lowercased()
        let endpoint: String? = await withCheckedContinuation { done in
            waiting[channel] = done
            let register = { [weak self] in
                var message: [String: Any] = ["messageType": "register", "channelID": channel]
                if let key { message["key"] = key }
                self?.send(message)
            }
            if ready {
                register()
            } else {
                whenReady.append(register)
                connect()
            }
            // The server didn't answer.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.waiting.removeValue(forKey: channel)?.resume(returning: nil)
            }
        }
        guard let endpoint else { return nil }
        let made = Subscription(channel: channel, host: host, scope: scope, endpoint: endpoint, key: key, keys: .make())
        saved.subscriptions.append(made)
        file.save(saved)
        return made
    }

    func unsubscribe(host: String, scope: String) {
        guard let gone = subscription(host: host, scope: scope) else { return }
        saved.subscriptions.removeAll { $0 == gone }
        file.save(saved)
        if ready { send(["messageType": "unregister", "channelID": gone.channel]) }
    }

    /// A site may no longer notify: its subscriptions go.
    func forget(host: String) {
        for gone in saved.subscriptions where gone.host == host { unsubscribe(host: host, scope: gone.scope) }
    }

    // MARK: - The connection

    private func connect() {
        guard socket == nil else { return }
        let made = Self.session.webSocketTask(with: Self.server)
        socket = made
        made.resume()
        send([
            "messageType": "hello", "use_webpush": true, "uaid": saved.uaid, "channelIDs": saved.subscriptions.map(\Subscription.channel),
            "broadcasts": [String: String](),
        ])
        listen(made)
        pinger = Task { [weak self] in
            // Two pings. Firefox's: a `{}` message after 30 minutes without a
            // word from the server, answered within 10 seconds or the
            // connection is made again (its dom.push.pingInterval and
            // requestTimeout), so the server sees what it sees from Firefox.
            // And a WebSocket ping every 3 minutes, which the socket itself
            // answers: a connection quiet for about four minutes is let go
            // without a word, and looks open while hearing nothing (measured:
            // 240 s held, 280 s didn't).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                if Task.isCancelled { return }
                made.sendPing { error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in if self?.socket === made { self?.dropped() } }
                }
                guard let heard = self?.lastHeard, Date().timeIntervalSince(heard) >= 1800 else { continue }
                let asked = Date()
                self?.send([:])
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.socket === made else { return }
                if self.lastHeard < asked { self.dropped() }
            }
        }
    }

    private func listen(_ made: URLSessionWebSocketTask) {
        made.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === made else { return }
                switch result {
                case .success(.string(let text)):
                    self.lastHeard = Date()
                    if let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { self.heard(message) }
                    self.listen(made)
                case .success:
                    self.listen(made)
                case .failure(let error):
                    NSLog("Push: connection lost (%@)", error.localizedDescription)
                    self.note("connection lost: \(error.localizedDescription)")
                    self.dropped()
                }
            }
        }
    }

    /// Lost: again in a while, longer each time, while any site is subscribed.
    private func dropped() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        ready = false
        pinger?.cancel()
        for (_, done) in waiting { done.resume(returning: nil) }
        waiting = [:]
        whenReady = []
        guard !saved.subscriptions.isEmpty else { return }
        let wait = retry
        retry = min(retry * 2, 300)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.connect()
        }
    }

    private func heard(_ message: [String: Any]) {
        switch message["messageType"] as? String {
        case "hello":
            guard message["status"] as? Int == 200, let uaid = message["uaid"] as? String else { return dropped() }
            // A new name from the server: what it knew of Mote is gone, and so
            // are the sites' subscriptions; they subscribe again on their next visit.
            if uaid != saved.uaid {
                if !saved.uaid.isEmpty { saved.subscriptions = [] }
                saved.uaid = uaid
                file.save(saved)
            }
            ready = true
            retry = 5
            note("connected")
            let queued = whenReady
            whenReady = []
            queued.forEach { $0() }
        case "register":
            guard let channel = message["channelID"] as? String else { return }
            let endpoint = message["status"] as? Int == 200 ? message["pushEndpoint"] as? String : nil
            waiting.removeValue(forKey: channel)?.resume(returning: endpoint)
        case "notification":
            guard let channel = message["channelID"] as? String else { return }
            send(["messageType": "ack", "updates": [["channelID": channel, "version": message["version"] ?? "", "code": 100]]])
            guard let subscription = saved.subscriptions.first(where: { $0.channel == channel }) else {
                return note("a push for a channel Mote doesn't know")
            }
            let body = (message["data"] as? String).flatMap(WebPush.data(base64url:))
            // The scheme the site sent it in: the standard's, or the older one
            // whose parameters come as headers.
            let headers = message["headers"] as? [String: String] ?? [:]
            note("\(subscription.host): arrived, \(headers["encoding"] ?? "no data")")
            let words = body.flatMap { body -> Data? in
                do {
                    if headers["encoding"] == "aesgcm" {
                        return try WebPush.decrypt(
                            aesgcm: body, encryption: headers["encryption"] ?? "", cryptoKey: headers["crypto_key"] ?? "",
                            with: subscription.keys)
                    }
                    return try WebPush.decrypt(body, with: subscription.keys)
                } catch {
                    note("\(subscription.host): couldn't be read (\(error))")
                    NSLog("Push: a message from %@ couldn't be read (%@)", subscription.host, "\(error)")
                    return nil
                }
            }
            // Sent words Mote couldn't read: nothing to show.
            if body != nil, words == nil { return }
            deliver(words, for: subscription)
        default:
            break
        }
    }

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: - Showing

    /// A message arrived: shown as the site's notification, from what's in it
    /// (a title and words, as a notification or as data, and where a click goes).
    private func deliver(_ words: Data?, for subscription: Subscription) {
        let host = subscription.host
        // Allowed once; not any more.
        guard SitePermissions.remembered(host, .notifications) == true else {
            note("\(host): not shown, no longer allowed")
            return forget(host: host)
        }
        // What's in it, by the names push services use: a notification
        // object, data, or the message itself; or plain words.
        let object = words.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let places = [object?["notification"], object?["data"], object, object?["fcmOptions"]].compactMap { $0 as? [String: Any] }
        func first(_ names: [String]) -> String? {
            for place in places {
                for name in names { if let text = place[name] as? String, !text.isEmpty { return text } }
            }
            return nil
        }
        let title = first(["title", "heading", "subject"]) ?? host
        let body =
            first(["body", "content", "message", "text", "alert"]) ?? (object == nil ? words.map { String(decoding: $0, as: UTF8.self) } : nil)
            ?? ""
        let link = first(["link", "click_action", "targetUrl", "url", "action_url", "actionUrl", "launch_url"])
        // Only to the site's own pages.
        let origin = URL(string: "https://\(host)/")!
        let target = link.flatMap { URL(string: $0, relativeTo: origin)?.absoluteURL }.flatMap { $0.host() == host ? $0 : nil } ?? origin
        // Not over the site itself, in front.
        if NSApp.isActive, Windows.shared.main?.active?.address?.host() == host { return note("\(host): not shown, the site is in front") }
        note("\(host): shown")
        Task { await WebNotifications.shared.show(push: title, body: String(body.prefix(1000)), host: host, link: target) }
    }

    /// A click: the site's tab if one is open, at the link; or a new one.
    static func open(_ link: URL) {
        NSApp.activate()
        for browser in Windows.shared.all {
            guard let tab = (browser.tabs + browser.parkedTabs).first(where: { ($0.pending ?? $0.address)?.host() == link.host() }) else {
                continue
            }
            browser.window?.makeKeyAndOrderFront(nil)
            browser.showPlaying(tab)
            if link.path != "/" || link.query != nil { tab.go(to: link) }
            return
        }
        guard let main = Windows.shared.main else { return }
        main.window?.makeKeyAndOrderFront(nil)
        _ = main.open(link, foreground: true)
    }
}
