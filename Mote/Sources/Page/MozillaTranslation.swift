import Combine
import CryptoKit
import Foundation
import WebKit

/// Mozilla's translation engine, for the languages macOS can't translate:
/// bergamot-translator, Firefox's Marian models, to and from English (a pair
/// without English goes through it). Nothing is fetched until a page needs
/// it: the engine (about 5 MB) once, and each pair's model (about 35 MB) the
/// first time; both from Mozilla's servers, checked, and kept in Mote's folder.
/// It runs in a web view of its own that no window shows.
@MainActor
final class MozillaTranslation: NSObject, ObservableObject, WKURLSchemeHandler, WKNavigationDelegate {
    static let shared = MozillaTranslation()

    /// Languages being downloaded, and how far each has got (0–1).
    @Published private(set) var downloading: [String: Double] = [:]

    /// A file the engine needs, as Mozilla's registry lists it.
    struct File: Codable, Equatable {
        let name: String
        let location: String
        let hash: String
        let size: Int
        let version: String
    }

    /// The engine itself, pinned: the version Firefox's script beside it
    /// (Resources/bergamot-translator.js) was built for.
    static let engine = File(
        name: "bergamot-translator.wasm", location: "main-workspace/translations-wasm/05082c31-aee8-4249-9e01-c1865afd7520.wasm",
        hash: "a3a89d9ad0a4ed8f27bf3e403701b23f5709816f6376438503f2fa5b0182c2dc", size: 4_960_506, version: "3.0")

    private static let records = URL(string: "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/translations-models/records")!
    private static let attachments = URL(string: "https://firefox-settings-attachments.cdn.mozilla.net/")!
    private static let scheme = "mote-translation"

    private var folder: URL { Storage.folder.appending(path: "Translations", directoryHint: .isDirectory) }
    /// Each pair's files ("is-en" → "model"/"lex"/"vocab" → file), newest version of each.
    private var registry: [String: [String: File]]?
    private var web: WKWebView?
    private var loading: CheckedContinuation<Void, Never>?
    /// The engine's page while it's being made, so two translations share it.
    private var making: Task<WKWebView, Never>?
    /// Pairs whose model the engine holds, or is taking in.
    private var loaded: [String: Task<Void, Error>] = [:]
    /// Texts translated already, by route and text: a site's menus and
    /// footers come back at once on its next page.
    private var done: [String: String] = [:]

    // MARK: - What it translates

    /// Every language it translates to or from.
    func languages() async -> Set<String> {
        Set((await pairs()).keys.flatMap { $0.split(separator: "-", maxSplits: 1).map(String.init) })
    }

    /// The pairs to go through from `source` to `target`: one, or two through English; nil when it can't.
    func route(from source: String, to target: String) async -> [String]? {
        let known = await pairs()
        let (from, to) = (Self.code(source), Self.code(target))
        if known["\(from)-\(to)"] != nil { return ["\(from)-\(to)"] }
        guard from != "en", to != "en", known["\(from)-en"] != nil, known["en-\(to)"] != nil else { return nil }
        return ["\(from)-en", "en-\(to)"]
    }

    /// Mozilla's codes are short ("is", "zh-Hans"): a region doesn't matter, a script does.
    static func code(_ language: String) -> String {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first?.lowercased() else { return language }
        if first == "zh" { return parts.contains("Hant") || parts.contains("TW") || parts.contains("HK") ? "zh-Hant" : "zh-Hans" }
        return first == "no" ? "nb" : first
    }

    /// The registry, read once a launch and kept a week on disk.
    private func pairs() async -> [String: [String: File]] {
        if let registry { return registry }
        let kept = folder.appending(path: "models.json")
        let fresh = (try? kept.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
        var data = fresh ? try? Data(contentsOf: kept) : nil
        if data == nil, let (got, _) = try? await URLSession.shared.data(from: Self.records) {
            data = got
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? got.write(to: kept)
        }
        let parsed = data.flatMap { Self.parse($0) } ?? [:]
        if !parsed.isEmpty { registry = parsed }
        return parsed
    }

    private static func parse(_ data: Data) -> [String: [String: File]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let records = root["data"] as? [[String: Any]] else { return nil }
        var pairs: [String: [String: File]] = [:]
        for record in records {
            guard let from = record["fromLang"] as? String, let to = record["toLang"] as? String, let kind = record["fileType"] as? String,
                let version = record["version"] as? String, let name = record["name"] as? String,
                let attachment = record["attachment"] as? [String: Any], let location = attachment["location"] as? String,
                let hash = attachment["hash"] as? String, let size = attachment["size"] as? Int,
                // Firefox's own filter (a release channel, say): left to Firefox.
                (record["filter_expression"] as? String ?? "").isEmpty, ["model", "lex", "vocab", "srcvocab", "trgvocab"].contains(kind)
            else { continue }
            let file = File(name: name, location: location, hash: hash, size: size, version: version)
            let key = "\(from)-\(to)"
            if let had = pairs[key]?[kind], had.version.compare(version, options: .numeric) != .orderedAscending { continue }
            pairs[key, default: [:]][kind] = file
        }
        return pairs
    }

    // MARK: - Translating

    /// The texts translated from `source` to `target`, each with its place,
    /// as they're done: a few first (the screen), then about a thousand words
    /// a call, which is what the engine takes in one go.
    func stream(_ texts: [String], from source: String, to target: String) -> AsyncThrowingStream<(Int, String), Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    guard let route = await route(from: source, to: target) else { throw Failure("Mote can't translate this pair yet.") }
                    let key = route.joined(separator: ">") + "\u{1}"
                    var waiting: [Int] = []
                    for (index, text) in texts.enumerated() {
                        if let known = done[key + text] { continuation.yield((index, known)) } else { waiting.append(index) }
                    }
                    if !waiting.isEmpty { try await prepare(route) }
                    var at = 0
                    while at < waiting.count {
                        try Task.checkCancellation()
                        var batch: [Int] = []
                        var words = 0
                        let most = at == 0 ? 12 : 128
                        while at < waiting.count, batch.count < most, batch.isEmpty || words < 1000 {
                            batch.append(waiting[at])
                            words += texts[waiting[at]].split(separator: " ").count
                            at += 1
                        }
                        let out = try await call("return moteTranslationEngine.translate(route, texts)", ["route": route, "texts": batch.map { texts[$0] }]) as? [String] ?? []
                        for (index, text) in zip(batch, out) {
                            if done.count > 20_000 { done.removeAll() }
                            done[key + texts[index]] = text
                            continuation.yield((index, text))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ said: String) { errorDescription = said }
    }

    /// What the route still needs from Mozilla, by language, in bytes; empty once it's all here.
    func toDownload(_ route: [String]) async -> [String: Int] {
        let known = await pairs()
        var needed: [String: Int] = [:]
        let engine = FileManager.default.fileExists(atPath: folder.appending(path: Self.engine.hash).path) ? 0 : Self.engine.size
        for pair in route {
            let language = Self.language(of: pair)
            for file in (known[pair] ?? [:]).values where !FileManager.default.fileExists(atPath: folder.appending(path: file.hash).path) {
                needed[language, default: 0] += file.size
            }
        }
        if engine > 0, let first = route.first { needed[Self.language(of: first), default: 0] += engine }
        return needed
    }

    /// The languages kept on this Mac to translate, and the room each takes.
    func downloaded() async -> [(language: String, bytes: Int)] {
        var bytes: [String: Int] = [:]
        for (pair, files) in await pairs() where !files.isEmpty && files.values.allSatisfy(onDisk) {
            bytes[Self.language(of: pair), default: 0] += files.values.reduce(0) { $0 + $1.size }
        }
        return bytes.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    /// A language's files gone from this Mac, and the engine with the last of them.
    func remove(_ language: String) async {
        let known = await pairs()
        for (pair, files) in known where Self.language(of: pair) == language {
            files.values.forEach { try? FileManager.default.removeItem(at: folder.appending(path: $0.hash)) }
        }
        // The engine's page let go: it holds the models it took in.
        web = nil
        loaded = [:]
        done = [:]
        if await downloaded().isEmpty { try? FileManager.default.removeItem(at: folder.appending(path: Self.engine.hash)) }
    }

    private func onDisk(_ file: File) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: file.hash).path) }

    /// The language a pair is for: the one that isn't English.
    private static func language(of pair: String) -> String {
        pair.split(separator: "-", maxSplits: 1).map(String.init).first { $0 != "en" } ?? "en"
    }

    /// The engine running with the route's models in it, fetched first if
    /// need be; with `fetching` false, only when everything is here already
    /// (getting ready ahead of the person asking).
    func prepare(_ route: [String], fetching: Bool = true) async throws {
        let known = await pairs()
        let needed = await toDownload(route)
        if !needed.isEmpty {
            guard fetching else { return }
            for (language, total) in needed { downloading[language] = downloading[language] ?? 0; sizes[language] = total }
            defer { for language in needed.keys { downloading[language] = nil; sizes[language] = nil; got[language] = nil } }
            try await fetch(Self.engine, for: Self.language(of: route[0]))
            for pair in route { for file in (known[pair] ?? [:]).values { try await fetch(file, for: Self.language(of: pair)) } }
        }
        try await call("await moteTranslationEngine.start(wasm)", ["wasm": Self.engine.hash])
        for pair in route {
            let task =
                loaded[pair]
                ?? Task { @MainActor in
                    let files = (known[pair] ?? [:]).mapValues(\.hash)
                    let ends = pair.split(separator: "-", maxSplits: 1).map(String.init)
                    try await self.call(
                        "await moteTranslationEngine.load(from, to, files, model)",
                        ["from": ends[0], "to": ends[1], "files": files, "model": known[pair]?["model"]?.name ?? ""])
                }
            loaded[pair] = task
            do { try await task.value } catch {
                loaded[pair] = nil
                throw error
            }
        }
    }

    /// Bytes downloaded so far and in all, by language, for `downloading`.
    private var got: [String: Int] = [:]
    private var sizes: [String: Int] = [:]

    /// A file on disk, by its hash, downloaded and checked if it isn't yet;
    /// its progress counts toward `language`'s.
    private func fetch(_ file: File, for language: String) async throws {
        let place = folder.appending(path: file.hash)
        if FileManager.default.fileExists(atPath: place.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = got[language] ?? 0
        let moved: Result<Void, Error> = await withCheckedContinuation { done in
            let task = URLSession.shared.downloadTask(with: Self.attachments.appending(path: file.location)) { temporary, _, error in
                // Checked and kept here: the download goes once this returns.
                guard let temporary else { return done.resume(returning: .failure(error ?? URLError(.cannotOpenFile))) }
                guard let data = try? Data(contentsOf: temporary, options: .mappedIfSafe),
                    SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.hash
                else { return done.resume(returning: .failure(Failure("A translation file came down damaged; try again."))) }
                try? FileManager.default.removeItem(at: place)
                done.resume(returning: Result { try FileManager.default.moveItem(at: temporary, to: place) })
            }
            let watching = task.progress.observe(\.completedUnitCount) { progress, _ in
                let count = Int(progress.completedUnitCount)
                Task { @MainActor [weak self] in
                    guard let self, let total = self.sizes[language], total > 0, self.downloading[language] != nil else { return }
                    self.got[language] = before + count
                    self.downloading[language] = min(1, Double(before + count) / Double(total))
                }
            }
            objc_setAssociatedObject(task, &Self.watchKey, watching, .OBJC_ASSOCIATION_RETAIN)
            task.resume()
        }
        try moved.get()
        got[language] = before + file.size
    }

    nonisolated(unsafe) private static var watchKey: UInt8 = 0

    // MARK: - The engine's page

    private func view() async -> WKWebView {
        if let web { return web }
        if let making { return await making.value }
        let task = Task { @MainActor in await self.makeView() }
        making = task
        let made = await task.value
        making = nil
        return made
    }

    private func makeView() async -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        // Never shown, and never put to sleep for it.
        config.preferences.inactiveSchedulingPolicy = .none
        let made = WKWebView(frame: .zero, configuration: config)
        made.navigationDelegate = self
        await withCheckedContinuation { done in
            loading = done
            made.loadHTMLString(
                "<!doctype html><script src=\"glue.js\"></script><script src=\"engine.js\"></script>",
                baseURL: URL(string: "\(Self.scheme)://app/"))
        }
        web = made
        return made
    }

    /// The engine's page ended (memory, a crash): the next translation starts it again.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === web else { return }
            web = nil
            loaded = [:]
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loading?.resume()
            loading = nil
        }
    }

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        let page = await view()
        return try await page.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    // MARK: - Files for the page

    nonisolated func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // WebKit calls this on the main thread, where the task stays.
        nonisolated(unsafe) let task = task
        MainActor.assumeIsolated {
            let path = task.request.url?.path() ?? ""
            let data: Data?
            switch path {
            case "/glue.js": data = Bundle.main.url(forResource: "bergamot-translator", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
            case "/engine.js": data = Data(InjectedScript.source("translation-engine").utf8)
            default:
                // Only the files it fetched, by hash.
                let name = path.replacingOccurrences(of: "/files/", with: "")
                data = name.allSatisfy(\.isHexDigit) ? try? Data(contentsOf: folder.appending(path: name), options: .mappedIfSafe) : nil
            }
            guard let data, let url = task.request.url else {
                return task.didFailWithError(URLError(.fileDoesNotExist))
            }
            let type = path.hasSuffix(".js") ? "text/javascript" : "application/octet-stream"
            // An HTTP answer: `fetch` reads a plain one as failed.
            let headers = ["Content-Type": type, "Content-Length": String(data.count)]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
