import Combine
import MoteCore
import WebKit

// Everything Mote does against ads and trackers, in one place:
//
// - Requests: a WebKit content rule list (ContentBlockingRules), compiled
//   once per launch. WebKit applies it in its network layer: no script runs
//   per request.
// - Pages: uBlock Origin's own filter lists, fetched as it fetches them and
//   kept up to date over the air, each list on its own schedule (hours, for
//   its quick fixes). Before a page loads, the rules for its site become
//   scripts and styles: uBlock Origin's scriptlets (`##+js(...)`, its code,
//   brought in by Tools/ublock/sync.mjs) and the site's element hiding.
// - YouTube, without the lists (never fetched, or not for two weeks):
//   Mote's own script (YouTubeAds), so ads stay out if they ever go dark.

@MainActor
final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()

    private(set) var list: WKContentRuleList?
    /// Pages made before the list was ready; they get it when it is.
    private var waiting: [WKUserContentController] = []

    /// Why the list couldn't be made. Nothing is blocked then, whatever
    /// Settings says, so Settings shows it.
    @Published private(set) var trouble: String?

    /// Open pages follow it after `apply(to:)`, from their next request.
    var enabled = true

    /// Sites where blocking is off because it broke them.
    private(set) var paused = Set(Storage.settings.stringArray(forKey: pausedKey) ?? [])
    private static let pausedKey = "shield.paused"

    func isPaused(on site: String?) -> Bool {
        site.map(paused.contains) ?? false
    }

    func pause(_ site: String, _ off: Bool) {
        if off { paused.insert(site) } else { paused.remove(site) }
        Storage.settings.set(paused.sorted(), forKey: Self.pausedKey)
    }

    private func blocks(_ site: String?) -> Bool { enabled && !isPaused(on: site) }

    func compile() {
        guard list == nil else { return }
        trouble = nil
        guard let rules = try? ContentBlockingRules.json() else { return trouble = "Couldn't build the block list" }
        guard let store = WKContentRuleListStore.default() else { return trouble = "WebKit has nowhere to compile it" }
        store.compileContentRuleList(forIdentifier: "mote-ad-blocker", encodedContentRuleList: rules) { [weak self] compiled, error in
            MainActor.assumeIsolated { self?.compiled(compiled, error) }
        }
    }

    private func compiled(_ compiled: WKContentRuleList?, _ error: Error?) {
        guard let compiled else { return trouble = error?.localizedDescription ?? "Compiling the block list failed" }
        list = compiled
        if enabled { waiting.forEach { set($0, blocking: true) } }
        waiting = []
    }

    /// A new page: the list now, or once it's compiled.
    func protect(_ controller: WKUserContentController) {
        guard list != nil else { return waiting.append(controller) }
        if enabled { set(controller, blocking: true) }
    }

    /// The pages holding the list, so a navigation that changes nothing
    /// doesn't send it to the page again.
    private let holding = NSHashTable<WKUserContentController>.weakObjects()

    /// Before loading a page from `site`: the list only counts from when
    /// it's added, so this runs as the navigation starts.
    func tune(_ controller: WKUserContentController, for site: String?) {
        set(controller, blocking: blocks(site))
    }

    /// `enabled` changed: open pages follow.
    func apply(to controllers: [WKUserContentController]) {
        controllers.forEach { set($0, blocking: enabled) }
    }

    private func set(_ controller: WKUserContentController, blocking: Bool) {
        guard let list, holding.contains(controller) != blocking else { return }
        if blocking {
            // One copied from an opener's may hold it already, untracked.
            controller.remove(list)
            controller.add(list)
            holding.add(controller)
        } else {
            controller.remove(list)
            holding.remove(controller)
        }
    }

    // MARK: - uBlock Origin's lists

    /// A filter list, from uBlock Origin's own servers (two, in case one is down).
    nonisolated struct FilterList: Sendable {
        let name: String
        let addresses: [String]
        /// uBlock Origin's own lists may use the scriptlets that need trust.
        let trusted: Bool
    }

    /// The lists uBlock Origin starts with, as far as pages go.
    nonisolated static let lists: [FilterList] = [
        ("ublock-filters", "filters/filters.min.txt", true),
        ("ublock-quick-fixes", "filters/quick-fixes.min.txt", true),
        ("ublock-unbreak", "filters/unbreak.min.txt", true),
        ("ublock-privacy", "filters/privacy.min.txt", true),
        ("ublock-badware", "filters/badware.min.txt", true),
        ("easylist", "thirdparties/easylist.txt", false),
    ].map { name, path, trusted in
        FilterList(
            name: name,
            addresses: [
                "https://ublockorigin.github.io/uAssetsCDN/" + path, "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/" + path,
            ], trusted: trusted)
    }

    private static let listFolder = Storage.base.appending(path: "Filter Lists", directoryHint: .isDirectory)

    private var rules = FilterRules()
    /// When the oldest list was last fetched; nil before any was.
    private(set) var listsUpdated: Date?
    /// Each site's scripts and styles, made once per set of rules.
    private var made: [String: PageRules] = [:]
    private var updating: Task<Void, Never>?

    /// Reads the lists kept, then keeps them up to date while Mote runs.
    func startLists() {
        guard updating == nil else { return }
        updating = Task { [weak self] in
            await self?.read()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Parses every list kept, away from the main thread, and takes the result.
    private func read() async {
        let aliases = Scriptlets.aliases
        let folder = Self.listFolder
        let (parsed, oldest) = await Task.detached(priority: .utility) {
            var rules = FilterRules()
            var oldest: Date?
            for list in Self.lists {
                let file = folder.appending(path: list.name + ".txt")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                rules.add(text, trusted: list.trusted, aliases: aliases)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date < oldest ?? .distantFuture { oldest = date }
            }
            return (rules, oldest)
        }.value
        rules = parsed
        listsUpdated = oldest
        made = [:]
    }

    /// Fetches each list that's due, and reads them all again if any came.
    func refresh(force: Bool = false) async {
        try? FileManager.default.createDirectory(at: Self.listFolder, withIntermediateDirectories: true)
        var fetched = false
        for list in Self.lists {
            let file = Self.listFolder.appending(path: list.name + ".txt")
            guard force || Self.due(file) else { continue }
            for address in list.addresses {
                guard let url = URL(string: address),
                    let (data, response) = try? await URLSession.shared.data(
                        for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)),
                    (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1024,
                    let text = String(data: data, encoding: .utf8), text.hasPrefix("[") || text.hasPrefix("!")
                else { continue }
                try? data.write(to: file, options: .atomic)
                fetched = true
                break
            }
        }
        if fetched { await read() }
    }

    /// Whether a list kept in `file` is due, by what it says of itself:
    /// `! Diff-Expires: 317 minutes` (how often uBlock Origin looks for its
    /// fixes), else `! Expires: 5 days`; an hour at the least.
    nonisolated static func due(_ file: URL, now: Date = .now) -> Bool {
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            let handle = try? FileHandle(forReadingFrom: file)
        else { return true }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 2048)) ?? Data(), as: UTF8.self)
        return now.timeIntervalSince(date) >= max(60 * 60, expiry(head))
    }

    /// How long a list lasts, by its header; a day when it doesn't say.
    nonisolated static func expiry(_ head: String) -> TimeInterval {
        func seconds(_ key: String) -> TimeInterval? {
            guard let line = head.split(separator: "\n").first(where: { $0.hasPrefix("! \(key):") }) else { return nil }
            let words = line.dropFirst(key.count + 3).split(separator: " ")
            guard let count = words.first.flatMap({ Double($0) }), let unit = words.dropFirst().first?.lowercased() else { return nil }
            if unit.hasPrefix("minute") { return count * 60 }
            if unit.hasPrefix("hour") { return count * 60 * 60 }
            if unit.hasPrefix("day") { return count * 24 * 60 * 60 }
            return nil
        }
        return seconds("Diff-Expires") ?? seconds("Expires") ?? 24 * 60 * 60
    }

    /// Whether Mote's own YouTube script stands in for the lists: none
    /// read yet, or none fetched for two weeks.
    var usesFallback: Bool {
        rules.count == 0 || (listsUpdated.map { Date.now.timeIntervalSince($0) > 14 * 24 * 60 * 60 } ?? true)
    }

    /// What a page from `host` gets in it: scripts in the page's world and in
    /// Mote's, and styles; nothing with blocking off there.
    struct PageRules: Equatable {
        var page = ""
        var isolated = ""
        var styles = ""

        var isEmpty: Bool { page.isEmpty && isolated.isEmpty && styles.isEmpty }
    }

    func pageRules(for host: String?) -> PageRules {
        guard let host = host?.lowercased(), !host.isEmpty, blocks(Address.siteHost(of: URL(string: "https://" + host))) else {
            return PageRules()
        }
        if let kept = made[host] { return kept }
        var out = PageRules()
        let matches = rules.matches(on: host)
        if !matches.isEmpty {
            let calls = matches.scriptlets.compactMap { match -> (Scriptlets.Entry, [String])? in
                guard let entry = Scriptlets.byName[match.args[0]], entry.call != nil, match.trusted || entry.trusted != true else {
                    return nil
                }
                return (entry, Array(match.args.dropFirst()))
            }
            out.page = Scriptlets.code(calls.filter { $0.0.isolated != true }, for: matches.names, prelude: Scriptlets.nativeProxies)
            out.isolated = Scriptlets.code(calls.filter { $0.0.isolated == true }, for: matches.names)
            out.styles = Self.styleScript(matches, for: matches.names)
        }
        if usesFallback { out.page += "(() => {\n\(Scriptlets.nativeProxies)\n})();\n" + YouTubeAds.script }
        if made.count > 100 { made = [:] }
        made[host] = out
        return out
    }

    /// The scripts that put `rules` in the next document of every frame of their site.
    static func userScripts(_ rules: PageRules) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if !rules.page.isEmpty {
            scripts.append(WKUserScript(source: rules.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        for source in [rules.isolated, rules.styles] where !source.isEmpty {
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        }
        return scripts
    }

    /// The site's element hiding, one rule each, so one WebKit can't read
    /// leaves the others standing.
    private static func styleScript(_ matches: FilterRules.Matches, for names: [String]) -> String {
        guard !matches.hidden.isEmpty || !matches.styles.isEmpty else { return "" }
        let rules = matches.hidden.map { $0 + " { display: none !important; }" } + matches.styles
        return """
            (() => {
              \(Scriptlets.frameCheck(names))
              const style = document.createElement('style');
              (document.head || document.documentElement).appendChild(style);
              for (const rule of \(Scriptlets.json(rules))) {
                try { style.sheet.insertRule(rule, style.sheet.cssRules.length); } catch {}
              }
            })();
            """
    }
}

/// uBlock Origin's scriptlets (Mote/Resources/Scripts/ublock-scriptlets.json).
nonisolated enum Scriptlets {
    struct Entry: Decodable, Sendable {
        let name: String
        let aliases: [String]?
        let isolated: Bool?
        let trusted: Bool?
        let needs: [String]?
        /// The function a rule calls; none for a helper.
        let call: String?
        let code: String
    }

    private struct Library: Decodable {
        let version: String
        let scriptlets: [Entry]
    }

    private nonisolated static let library: Library? = Bundle.main.url(forResource: "ublock-scriptlets", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Library.self, from: $0) }

    nonisolated static let byName: [String: Entry] = Dictionary(
        (library?.scriptlets ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    nonisolated static let aliases: [String: String] = Dictionary(
        (library?.scriptlets ?? []).flatMap { entry in (entry.aliases ?? []).map { ($0, entry.name) } },
        uniquingKeysWith: { first, _ in first })

    /// The scriptlets `calls` names, each run with its arguments, as uBlock
    /// Origin puts them together: every function they need declared once, in
    /// a scope of their own, each call apart so one failing leaves the others.
    nonisolated static func code(_ calls: [(Entry, [String])], for names: [String], prelude: String = "") -> String {
        guard !calls.isEmpty else { return "" }
        var declared = Set<String>()
        var functions: [String] = []
        var needed = calls.map(\.0.name)
        while let name = needed.first {
            needed.removeFirst()
            guard declared.insert(name).inserted, let entry = byName[name] else { continue }
            functions.append(entry.code)
            needed += entry.needs ?? []
        }
        let runs = calls.map { entry, args in "try { \(entry.call ?? "")(...\(json(args))); } catch {}" }
        return """
            (function moteScriptlets() {
            \(frameCheck(names))
            \(prelude)
            const scriptletGlobals = {};
            \(functions.joined(separator: "\n"))
            \(runs.joined(separator: "\n"))
            })();

            """
    }

    /// WebKit gives a Proxy of a function away in its source text
    /// (`function ProxyObject()`), where Chrome's reads as any native
    /// function's; sites look for it, and the scriptlets' Proxies (those
    /// uBlock Origin's own fixes make with `new Proxy` too) would show. So,
    /// before them, every Proxy of a function made in the page reads as the
    /// function it stands for, as uBlock Origin makes its own read.
    nonisolated static let nativeProxies = """
        {
          const targets = new WeakMap();
          const nativeToString = Function.prototype.toString;
          const toString = new Proxy(nativeToString, {
            apply(target, self, args) {
              while (targets.has(self)) self = targets.get(self);
              return Reflect.apply(target, self, args);
            },
          });
          const NativeProxy = Proxy;
          const proxy = new NativeProxy(NativeProxy, {
            construct(target, args, newTarget) {
              const made = Reflect.construct(target, args, newTarget);
              if (typeof args[0] === 'function') targets.set(made, args[0]);
              return made;
            },
          });
          targets.set(toString, nativeToString);
          targets.set(proxy, NativeProxy);
          Function.prototype.toString = toString;
          self.Proxy = proxy;
        }
        """

    /// Returns unless the frame's own site is one the rules were for: a
    /// page's frames from elsewhere (an ad's) get their own site's, not its.
    nonisolated static func frameCheck(_ names: [String]) -> String {
        """
        {
          let host = location.hostname;
          if (!host) { try { host = new URL(self.origin).hostname; } catch {} }
          const hosts = [host];
          for (let at = host.indexOf('.'); at !== -1; at = host.indexOf('.', at + 1)) hosts.push(host.slice(at + 1));
          const own = [...hosts];
          for (let name of hosts) for (let dot = name.lastIndexOf('.'); dot > 0; dot = name.lastIndexOf('.')) { name = name.slice(0, dot); own.push(name + '.*'); }
          const names = new Set(\(json(names)));
          if (!own.some((name) => names.has(name))) return;
        }
        """
    }

    nonisolated static func json(_ strings: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(strings), as: UTF8.self)) ?? "[]"
    }
}

/// Mote's own answer to YouTube's ads, for when uBlock Origin's lists aren't
/// there (see `usesFallback`).
///
/// YouTube's video ads, before and in the middle of a video, aren't other
/// addresses a block list can stop: they come inside the player's own data
/// (`adPlacements`, `playerAds`, `adSlots`). As uBlock Origin's scriptlets
/// do, they're taken out of that data, in the page's own world, as it's read:
/// from `ytInitialPlayerResponse`, `JSON.parse` and fetched JSON. Only on
/// YouTube, and only with ad blocking on (see PageScripts).
///
/// YouTube looks for that: a patched function's source, name or length, or
/// a fresh frame's untouched copy. So, as uBlock Origin's do, each patch is a
/// Proxy of the native function, which reads as native even to
/// `Function.prototype.toString`; a frame added to the page is patched too;
/// and the callback YouTube runs when it finds tampering
/// (`onAbnormalityDetected`) is never run.
enum YouTubeAds {
    nonisolated static let script = """
        (() => {
          if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
          // Each patch, by the native function it stands for.
          const natives = new WeakMap();
          const nativeToString = Function.prototype.toString;
          const toString = new Proxy(nativeToString, {
            apply: (target, self, args) => Reflect.apply(target, natives.get(self) ?? self, args),
          });
          natives.set(toString, nativeToString);
          Function.prototype.toString = toString;
          const patch = (owner, name, apply) => {
            const native = owner?.[name];
            if (typeof native !== 'function' || natives.has(native)) return;
            const proxy = new Proxy(native, { apply });
            natives.set(proxy, native);
            owner[name] = proxy;
          };

          const keys = ['adPlacements', 'playerAds', 'adSlots'];
          const prune = (value) => {
            if (Array.isArray(value)) {
              value.forEach(prune);
            } else if (value && typeof value === 'object') {
              for (const key of keys) if (key in value) delete value[key];
              if (value.playerResponse) prune(value.playerResponse);
            }
            return value;
          };
          const patchRealm = (realm) => {
            patch(realm.JSON, 'parse', (target, self, args) => prune(Reflect.apply(target, self, args)));
            patch(realm.Response?.prototype, 'json', (target, self, args) => Reflect.apply(target, self, args).then(prune));
          };
          patchRealm(window);

          // A frame's own JSON.parse and Response would go round the patches.
          patch(Node.prototype, 'appendChild', (target, self, args) => {
            const added = Reflect.apply(target, self, args);
            try {
              if (args[0] instanceof HTMLIFrameElement && args[0].contentWindow) patchRealm(args[0].contentWindow);
            } catch {}
            return added;
          });

          // What YouTube runs on finding the page tampered with.
          patch(Promise.prototype, 'then', (target, self, args) => {
            if (typeof args[0] === 'function' && Reflect.apply(nativeToString, args[0], []).includes('onAbnormalityDetected')) {
              args[0] = function () {};
            }
            return Reflect.apply(target, self, args);
          });

          let initial;
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            get: () => initial,
            set: (value) => { initial = prune(value); },
          });
        })();
        """
}
