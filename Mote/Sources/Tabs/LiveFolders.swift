import AppKit
import Combine
import MoteCore

/// What live folders show, kept between launches with what's been read,
/// fetched again every 15 minutes, each asking only for what changed
/// (ETags), so a quiet feed costs a 304.
@MainActor
final class LiveFeeds: ObservableObject {
    static let shared = LiveFeeds()
    /// How many of a folder's items show, newest first.
    static let shown = 15

    nonisolated private struct Saved: Codable, Sendable {
        var items: [UUID: [LiveItem]] = [:]
        var read: Set<String> = []
        var tags: [UUID: String] = [:]
    }

    @Published private var saved: Saved
    private let file = JSONFile<Saved>("live-folders.json")
    private var timer: Timer?

    private init() { saved = file.load() ?? Saved() }

    func items(in folder: UUID) -> [LiveItem] { saved.items[folder] ?? [] }
    func isRead(_ item: LiveItem) -> Bool { saved.read.contains(item.id) }

    func markRead(_ item: LiveItem) {
        guard saved.read.insert(item.id).inserted else { return }
        file.save(saved)
    }

    /// Every live folder now, then every 15 minutes.
    func start() {
        guard timer == nil else { return }
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFeeds.shared.refreshAll() }
        }
    }

    func refreshAll() {
        for folder in FolderStore.shared.bySpace.values.joined() where folder.live != nil { refresh(folder) }
    }

    func refresh(_ folder: Folder) {
        guard let source = folder.live, let address = source.address else { return }
        var request = URLRequest(url: address)
        request.setValue(saved.tags[folder.id], forHTTPHeaderField: "If-None-Match")
        if case .feed = source {} else { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else { return }
            saved.items[folder.id] = LiveItem.items(in: data, from: source)
            saved.tags[folder.id] = http.value(forHTTPHeaderField: "ETag")
            // Read marks only for what some folder still shows.
            let showing = Set(saved.items.values.joined().map(\.id))
            saved.read.formIntersection(showing)
            file.save(saved)
        }
    }

    func forget(_ folder: UUID) {
        saved.items[folder] = nil
        saved.tags[folder] = nil
        file.save(saved)
    }
}

extension Browser {
    /// A live folder a feed, or a GitHub repository's open pull
    /// requests or issues, asked for by its address.
    func newLiveFolder(_ kind: String) {
        let (title, placeholder) =
            switch kind {
            case "feed": ("Follow a Feed", "https://example.com/feed.xml")
            case "pulls": ("GitHub Pull Requests", "owner/repository")
            default: ("GitHub Issues", "owner/repository")
            }
        Prompt.name(title, placeholder: placeholder, confirm: "Follow") { [weak self] text in
            guard let self else { return }
            let source: LiveSource? =
                switch kind {
                case "feed": URL(string: text).flatMap { $0.scheme?.hasPrefix("http") == true ? .feed($0) : nil }
                case "pulls": LiveSource.repo(in: text).map { .pulls(repo: $0) }
                default: LiveSource.repo(in: text).map { .issues(repo: $0) }
                }
            guard let source else { return announce("That isn't a \(kind == "feed" ? "feed's address" : "repository")") }
            let name =
                switch source {
                case .feed(let url): url.host() ?? "Feed"
                case .pulls(let repo): "\(repo) pull requests"
                case .issues(let repo): "\(repo) issues"
                case .search(let query): query
                }
            let folder = Folder(name: name, live: source)
            FolderStore.shared.change(spaceID) { $0.append(folder) }
            LiveFeeds.shared.refresh(folder)
        }
    }

    /// A live folder's item, in a tab of its own, marked read.
    func open(_ item: LiveItem, foreground: Bool) {
        LiveFeeds.shared.markRead(item)
        if let tab = tabs.first(where: { $0.address == item.url }) { return select(tab) }
        open(item.url, foreground: foreground)
    }
}
