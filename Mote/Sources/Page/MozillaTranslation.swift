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
final class MozillaTranslation: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    static let shared = MozillaTranslation()

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
    /// Pairs whose model the engine holds.
    private var loaded: Set<String> = []

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
    private static func code(_ language: String) -> String {
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

    /// The texts translated from `source` to `target`, each with its place, a
    /// few at a time as they're done.
    func stream(_ texts: [String], from source: String, to target: String) -> AsyncThrowingStream<(Int, String), Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                do {
                    guard let route = await route(from: source, to: target) else { throw Failure("Mote can't translate this pair yet.") }
                    try await prepare(route)
                    var at = 0
                    for batch in stride(from: 0, to: texts.count, by: 16).map({ Array(texts[$0..<min($0 + 16, texts.count)]) }) {
                        try Task.checkCancellation()
                        let out = try await call("return moteTranslationEngine.translate(route, texts)", ["route": route, "texts": batch]) as? [String] ?? []
                        for (offset, text) in out.enumerated() { continuation.yield((at + offset, text)) }
                        at += batch.count
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

    /// The engine running, with the route's models in it, fetched first if need be.
    private func prepare(_ route: [String]) async throws {
        let known = await pairs()
        try await fetch(Self.engine)
        for pair in route { for file in known[pair]?.values ?? [:].values { try await fetch(file) } }
        try await call("await moteTranslationEngine.start(wasm)", ["wasm": Self.engine.hash])
        for pair in route where !loaded.contains(pair) {
            let files = (known[pair] ?? [:]).mapValues(\.hash)
            let ends = pair.split(separator: "-", maxSplits: 1).map(String.init)
            try await call(
                "await moteTranslationEngine.load(from, to, files, model)",
                ["from": ends[0], "to": ends[1], "files": files, "model": known[pair]?["model"]?.name ?? ""])
            loaded.insert(pair)
        }
    }

    /// A file on disk, by its hash, downloaded and checked if it isn't yet.
    private func fetch(_ file: File) async throws {
        let place = folder.appending(path: file.hash)
        if FileManager.default.fileExists(atPath: place.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (got, _) = try await URLSession.shared.download(from: Self.attachments.appending(path: file.location))
        let data = try Data(contentsOf: got, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.hash else {
            throw Failure("A translation file came down damaged; try again.")
        }
        try? FileManager.default.removeItem(at: place)
        try FileManager.default.moveItem(at: got, to: place)
    }

    // MARK: - The engine's page

    private func view() async -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        // Never shown, and never put to sleep for it.
        config.preferences.inactiveSchedulingPolicy = .none
        let made = WKWebView(frame: .zero, configuration: config)
        made.navigationDelegate = self
        web = made
        await withCheckedContinuation { done in
            loading = done
            made.loadHTMLString(
                "<!doctype html><script src=\"glue.js\"></script><script src=\"engine.js\"></script>",
                baseURL: URL(string: "\(Self.scheme)://app/"))
        }
        return made
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
