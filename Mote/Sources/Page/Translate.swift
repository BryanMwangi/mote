import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Translating a page when a page is in a language the user doesn't read,
/// a quiet button beside the address translates it: with Apple's Translation
/// framework when macOS has the pair, else with Mozilla's engine
/// (MozillaTranslation). Which is the page's business, never the person's.
extension Browser {
    /// Notes the language a page is in, when it's one you don't read.
    func noteLanguage(of tab: Tab) {
        tab.translation = nil
        tab.pageLanguage = nil
        guard prefs.offersTranslation, !tab.shy, let web = tab.built else { return }
        web.evaluateInAppWorld(Self.languageSample) { [weak self, weak tab] value in
            guard let text = value as? String else { return }
            // Recognised off the main thread: it's a few milliseconds a page.
            Task {
                let code = await Task.detached(priority: .utility) { Self.language(of: text) }.value
                guard let code, !Self.reads(code), self?.prefs.neverTranslate.contains(code) == false else { return }
                tab?.pageLanguage = code
                // A language only Mozilla's engine does: ready before it's asked, if it's here already.
                if #available(macOS 15, *), let target = self?.translationTarget,
                    await Self.availability(from: code, to: target).map({ $0 == .unsupported }) ?? true,
                    let route = await MozillaTranslation.shared.route(from: code, to: target)
                {
                    try? await MozillaTranslation.shared.prepare(route, fetching: false)
                }
            }
        }
    }

    /// What a page's language is told from: its lang attribute, and its text's
    /// start, middle and end (a page in your language can still hold a
    /// foreign article, past where its menus and headings end).
    static let languageSample = """
        (() => {
          const text = document.body ? document.body.innerText : '', n = 2000, mid = Math.floor(text.length / 2);
          const parts = text.length <= 3 * n ? [text] : [text.slice(0, n), text.slice(mid - n / 2, mid + n / 2), text.slice(-n)];
          return (document.documentElement.lang || '') + '\\n' + parts.join('\\n');
        })()
        """

    /// The language a selection is in: its text, the page's own language
    /// trusted as for pages (see `language(of:)`).
    static func selectionLanguage(of text: String, page: String?) async -> String? {
        let sample = (page ?? "") + "\n" + text
        return await Task.detached(priority: .userInitiated) { language(of: sample) }.value
    }

    /// The language of a page in `web`, any language: for tabs.detectLanguage.
    static func pageLanguage(in web: WKWebView) async -> String? {
        let sample: String? = await withCheckedContinuation { done in
            web.evaluateInAppWorld(languageSample) { done.resume(returning: $0 as? String) }
        }
        guard let sample else { return nil }
        return await Task.detached(priority: .utility) { language(of: sample) }.value
    }

    /// The language a page's sample is in: one you don't read, when it's a
    /// fair share of the text even if not most of it; else what its text
    /// mostly reads as, or what its `lang` (the sample's first line) says.
    private nonisolated static func language(of sample: String) -> String? {
        // Line by line, weighed by length: over the whole text, a few foreign
        // paragraphs among many in your language read as yours alone.
        let recognizer = NLLanguageRecognizer()
        var shares: [String: Int] = [:]
        let text = String(sample.drop { $0 != "\n" })
        for line in text.split(separator: "\n") where line.count >= 30 {
            recognizer.reset()
            recognizer.processString(String(line))
            if let code = recognizer.dominantLanguage?.rawValue { shares[code, default: 0] += line.count }
        }
        let total = shares.values.reduce(0, +)
        let foreign = shares.filter { !reads($0.key) }.max { $0.value < $1.value }
        recognizer.reset()
        recognizer.processString(text)
        // What the page says it's in (its lang), trusted when the text reads
        // foreign too: macOS doesn't know every language (Estonian reads to it
        // as Finnish), and the page does.
        let declared = sample.prefix { $0 != "\n" }.split(separator: "-").first.map { $0.lowercased() } ?? ""
        let code = foreign.flatMap { $0.value * 5 >= total ? $0.key : nil } ?? recognizer.dominantLanguage?.rawValue ?? declared
        if !declared.isEmpty, !reads(declared), !code.isEmpty, !reads(code) { return declared }
        return code.isEmpty ? nil : code
    }

    /// Whether a piece of text is surely in a language you read already, and
    /// so stays as it is: a page partly in yours keeps that part.
    private nonisolated static func alreadyRead(_ text: String) -> Bool {
        guard text.count >= 16 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, sure) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return sure >= 0.9 && reads(language.rawValue)
    }

    /// Whether `code` is one of the languages the Mac is set to read.
    private nonisolated static func reads(_ code: String) -> Bool {
        let wanted = Locale.Language(identifier: code).languageCode
        return Locale.preferredLanguages.contains { Locale.Language(identifier: $0).languageCode == wanted }
    }

    /// A language by name ("French").
    nonisolated static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// What pages translate to: the one last chosen, or the Mac's own.
    var translationTarget: String {
        prefs.translateTo.isEmpty
            ? Locale.preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "en"
            : prefs.translateTo
    }

    /// Whether macOS translates `source` to `target`, and has what it needs.
    @available(macOS 15, *)
    @concurrent nonisolated static func availability(from source: String, to target: String) async -> LanguageAvailability.Status? {
        try? await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    /// Every language Mote translates, whichever engine does it.
    @available(macOS 15, *)
    static func translatable() async -> [String] {
        let apple = await Task.detached { await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier) }.value
        let mozilla = await MozillaTranslation.shared.languages()
        // One entry a language: Apple's name for it ("zh-Hans") wins over Mozilla's ("zh-Hans", "nb").
        let known = Set(apple.map { Locale.Language(identifier: $0).languageCode?.identifier ?? $0 })
        return apple + mozilla.filter { !known.contains(Locale.Language(identifier: $0).languageCode?.identifier ?? $0) }
    }

    /// Whether Mote can translate `source` to `target`, with either engine.
    @available(macOS 15, *)
    static func canTranslate(from source: String, to target: String) async -> Bool {
        guard source != target else { return false }
        if let status = await availability(from: source, to: target), status != .unsupported { return true }
        return await MozillaTranslation.shared.route(from: source, to: target) != nil
    }

    /// The page menu's item, and the bench's: show the page as it was, or
    /// translate it to the usual language.
    func toggleTranslation(_ tab: Tab) {
        if tab.translated { return showOriginal(tab) }
        if let code = tab.pageLanguage { translate(tab, from: code, to: translationTarget) }
    }

    func showOriginal(_ tab: Tab) {
        tab.built?.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.restore()")
        tab.translation = nil
    }

    /// Translates the page from `source` to `target`: with macOS when it has
    /// the pair (through `translating` and TranslationHost), else Mozilla's engine.
    func translate(_ tab: Tab, from source: String, to target: String) {
        guard #available(macOS 15, *), source != target else { return }
        tab.translating = true
        Task {
            let job = TranslationJob(tab: tab.id, source: source, target: target)
            let status = await Self.availability(from: source, to: target)
            if let status, status != .unsupported {
                return translating = job
            }
            defer { tab.translating = false }
            guard let route = await MozillaTranslation.shared.route(from: source, to: target) else {
                return announce("Mote can't translate \(Self.languageName(source)) to \(Self.languageName(target)) yet")
            }
            // The first time for a language, it comes down first: say so, and how much.
            let needed = await MozillaTranslation.shared.toDownload(route)
            if !needed.isEmpty {
                let names = needed.keys.map(Self.languageName).sorted().joined(separator: " and ")
                let size = ByteCountFormatter.string(fromByteCount: Int64(needed.values.reduce(0, +)), countStyle: .file)
                announce(Announcement("Downloading \(names) to translate (\(size))", detail: "Once only; then it translates on this Mac.", symbol: "arrow.down.circle"))
            }
            // Down and ready before the page is read: the page is as it is then,
            // and it isn't called translated while nothing is.
            do { try await MozillaTranslation.shared.prepare(route) } catch {
                return announce(
                    needed.isEmpty
                        ? "This page couldn't be translated"
                        : "Couldn't download \(needed.keys.map(Self.languageName).sorted().joined(separator: " and ")); try again")
            }
            await run(job) { MozillaTranslation.shared.stream($0, from: source, to: target) }
        }
    }

    /// Runs with the session SwiftUI hands over (see TranslationHost).
    @available(macOS 15, *)
    func translate(with session: TranslationSession) async {
        guard let job = translating else { return }
        defer {
            if translating == job { translating = nil }
            self.tab(job.tab)?.translating = false
        }
        await run(job) { Self.stream($0, in: session) }
    }

    /// Translates the job's page through `engine`, as Firefox translates:
    /// what's on screen first, each distinct piece of text once however often
    /// it repeats, and the results written in as they stream back, a few at a
    /// time. The page's text comes 5000 pieces at a time, the ones around the
    /// screen first, until all of it's done.
    private func run(_ job: TranslationJob, engine: @escaping ([String]) -> AsyncThrowingStream<(Int, String), Error>) async {
        guard let tab = tab(job.tab), let web = tab.built else { return }
        let found = await withCheckedContinuation { done in
            web.evaluateInAppWorld(Self.collect) { done.resume(returning: $0 as? Bool == true) }
        }
        guard found else { return }
        tab.translation = job
        var pending: [String: String] = [:]
        var flushed = ContinuousClock.now
        let flush = {
            guard tab.translation == job, !pending.isEmpty, let json = try? JSONEncoder().encode(pending),
                let text = String(data: json, encoding: .utf8)
            else { return }
            web.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.put(\(text))")
            tab.translating = false
            pending = [:]
            flushed = .now
        }
        var translated = 0, failed = false
        // The page's text, then what it adds or redraws later, as Firefox follows it.
        while tab.translation == job {
          var stretch = await Self.next(in: web)
          if stretch == nil, await Self.more(in: web) { stretch = await Self.next(in: web) }
          guard let (base, texts) = stretch else { break }
          // The first hundred (the screen) start at once; the rest are sorted while they're translated.
          for part in [texts.indices.prefix(100), texts.indices.dropFirst(100)] where !part.isEmpty {
            // Only what's foreign to you, each keeping its place among them all.
            let places = await Task.detached(priority: .userInitiated) { part.filter { !Self.alreadyRead(texts[$0]) } }.value
            if places.isEmpty { continue }
            do {
                for try await (index, text) in engine(places.map { texts[$0] }) {
                    guard tab.translation == job else { return }
                    pending[String(base + places[index])] = text
                    translated += 1
                    // Soon for the first lines, which are what's on screen; then in small groups.
                    if pending.count >= 24 || ContinuousClock.now - flushed > .milliseconds(80) { flush() }
                }
            } catch {
                // A batch it can't take (a third language, say) is passed over, not the page.
                failed = true
            }
            flush()
          }
        }
        if failed, translated == 0 { announce("This page couldn't be translated") }
    }

    /// Waits for the page to show new text; false once it's gone or shown as it was.
    private static func more(in web: PageView) async -> Bool {
        await withCheckedContinuation { done in
            web.callInAppWorld("return window.__moteTranslation ? await window.__moteTranslation.more() : false", arguments: [:]) {
                done.resume(returning: $0 as? Bool == true)
            }
        }
    }

    /// The page's next texts to translate, and the place of the first among
    /// all of them; nil once there are none.
    private static func next(in web: PageView) async -> (Int, [String])? {
        await withCheckedContinuation { done in
            web.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.next()") { value in
                let next = value as? [String: Any]
                guard let base = next?["base"] as? Int, let texts = next?["texts"] as? [String] else { return done.resume(returning: nil) }
                done.resume(returning: (base, texts))
            }
        }
    }

    /// The translations as they come back, by each text's place. The session
    /// works off the main actor; only the one `translationTask` task uses it.
    @available(macOS 15, *)
    nonisolated static func stream(_ texts: [String], in session: TranslationSession) -> AsyncThrowingStream<(Int, String), Error> {
        let held = Held(session: session)
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
                    for try await response in held.session.translate(batch: requests) {
                        if let index = response.clientIdentifier.flatMap(Int.init) { continuation.yield((index, response.targetText)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The page's text nodes, kept in Mote's world with what they said, so
    /// they can be written to and put back. What comes back is each distinct
    /// text once, trimmed, the ones on screen first, then by distance from it.
    private static let collect = """
        (() => {
          if (window.__moteTranslation) window.__moteTranslation.restore();
          const skip = /^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|TEXTAREA|SVG)$/;
          // What's being edited stays as typed. Found once: asking each text
          // whether it's editable costs a style pass, ten times the walk.
          const editable = [...document.querySelectorAll('[contenteditable]:not([contenteditable="false"])')];
          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
          const nodes = [];
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            const p = n.parentElement;
            if (p && !skip.test(p.tagName) && n.nodeValue.trim().length > 1 && !(editable.length && editable.some(e => e.contains(p)))) nodes.push(n);
          }
          if (!nodes.length) return false;
          const original = nodes.map(n => n.nodeValue);
          // Where the screen is among them: the first text in or after what's on it.
          const seen = document.elementFromPoint(innerWidth / 2, innerHeight / 3);
          let lo = 0, hi = seen ? nodes.length : 0;
          while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if (seen.compareDocumentPosition(nodes[mid]) & Node.DOCUMENT_POSITION_FOLLOWING) hi = mid; else lo = mid + 1;
          }
          // In stretches of 5000: the one around the screen, those after it, then those before.
          const size = 5000, first = Math.max(0, Math.min(lo - size / 2, nodes.length - size));
          const stretches = [];
          for (let a = first; a < nodes.length; a += size) stretches.push([a, Math.min(a + size, nodes.length)]);
          for (let b = first; b > 0; b -= size) stretches.push([Math.max(0, b - size), b]);
          const groups = new Map(), places = [], done = [];
          const write = (i, text) => { nodes[i].nodeValue = original[i].replace(original[i].trim(), text); };
          // Text the page adds later, gathered a moment after it settles, as a
          // stretch of its own. Its own nodes rewritten (put) aren't new.
          const known = new WeakSet(nodes), fresh = new Set();
          let waiting = null, timer = 0;
          const take = n => {
            if (n.nodeType === 3) {
              const p = n.parentElement;
              if (p && !known.has(n) && !skip.test(p.tagName) && n.nodeValue.trim().length > 1) fresh.add(n);
            } else if (n.nodeType === 1 && !skip.test(n.tagName)) {
              const w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT);
              for (let t = w.nextNode(); t; t = w.nextNode()) take(t);
            }
          };
          const observer = new MutationObserver(records => {
            for (const r of records) r.type === 'characterData' ? take(r.target) : r.addedNodes.forEach(take);
            if (!fresh.size) return;
            clearTimeout(timer);
            timer = setTimeout(() => {
              const start = nodes.length;
              for (const n of fresh) if (n.isConnected) { nodes.push(n); original.push(n.nodeValue); known.add(n); }
              fresh.clear();
              if (nodes.length === start) return;
              stretches.push([start, nodes.length]);
              if (waiting) { waiting(true); waiting = null; }
            }, 300);
          });
          observer.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true });
          window.__moteTranslation = {
            // Resolves when there's more to translate; false once it's shown as it was.
            more: () => stretches.length ? Promise.resolve(true) : new Promise(r => { waiting = r; }),
            // The next stretch's new texts, nearest the screen first; texts
            // already translated are written in at once.
            next: () => {
              const stretch = stretches.shift();
              if (!stretch) return null;
              const height = innerHeight, base = places.length, texts = [], away = [];
              for (let i = stretch[0]; i < stretch[1]; i++) {
                const r = nodes[i].parentElement.getBoundingClientRect();
                away.push([r.bottom < 0 ? height - r.bottom : r.top > height ? r.top - height : 0, i]);
              }
              away.sort((a, b) => a[0] - b[0]);
              for (const [, i] of away) {
                const text = original[i].trim();
                let g = groups.get(text);
                if (g === undefined) {
                  g = places.push([]) - 1;
                  groups.set(text, g);
                  texts.push(text);
                }
                places[g].push(i);
                if (done[g] !== undefined) write(i, done[g]);
              }
              return { base, texts };
            },
            put: found => {
              for (const g in found) {
                done[g] = found[g];
                for (const i of places[g] || []) write(i, found[g]);
              }
            },
            restore: () => {
              observer.disconnect();
              clearTimeout(timer);
              if (waiting) { waiting(false); waiting = null; }
              nodes.forEach((n, i) => { n.nodeValue = original[i]; });
            }
          };
          return true;
        })()
        """
}

/// The session, carried to the one task that streams with it.
@available(macOS 15, *)
nonisolated private struct Held: @unchecked Sendable {
    let session: TranslationSession
}

/// A page translated, or waiting to be: which tab, from and to what language.
struct TranslationJob: Equatable {
    let tab: Tab.ID
    let source: String
    let target: String
    /// This time, apart from another to the same languages.
    let id = UUID()
}

/// Where SwiftUI hands Mote a translation session, as it only does through
/// a view (`translationTask`) on macOS 15. Draws nothing.
struct TranslationHost: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if #available(macOS 15, *) {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(
                    browser.translating.map {
                        TranslationSession.Configuration(
                            source: Locale.Language(identifier: $0.source), target: Locale.Language(identifier: $0.target))
                    }
                ) {
                    session in await browser.translate(with: session)
                }
        }
    }
}

/// The translate button's popover, as Firefox's: from and to what language,
/// so a wrong guess can be put right, and why when Mote can't.
@available(macOS 15, *)
struct TranslatePanel: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    @State private var from = ""
    @State private var to = ""
    @State private var languages: [String] = []
    @ObservedObject private var mozilla = MozillaTranslation.shared
    /// Whether the chosen pair can be translated; nil while asking.
    @State private var possible: Bool?

    /// Every language Mote translates, by name; asked once.
    @MainActor private static var supported: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Menu {
                    if let code = tab.pageLanguage {
                        Button("Never Offer for \(Browser.languageName(code))") {
                            browser.prefs.neverTranslate.append(code)
                            if !tab.translated { tab.pageLanguage = nil }
                            close()
                        }
                    }
                    Button("Don't Offer to Translate Pages") {
                        browser.prefs.offersTranslation = false
                        close()
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !tab.translated {
                choice("Translate from", $from, languages.contains(from) || from.isEmpty ? languages : languages + [from])
            }
            choice("Translate to", $to, languages.filter { $0 != from })
            ForEach(downloads, id: \.language) { download in
                VStack(alignment: .leading, spacing: 5) {
                    Text("Downloading \(Browser.languageName(download.language))…").font(.callout).foregroundStyle(.secondary)
                    ProgressView(value: download.done).controlSize(.small)
                }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(tab.translated ? "Show Original" : "Cancel") {
                    if tab.translated { browser.showOriginal(tab) }
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Translate") {
                    browser.prefs.translateTo = to
                    browser.translate(tab, from: from, to: to)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 300)
        .onAppear {
            from = tab.translation?.source ?? tab.pageLanguage ?? ""
            to = tab.translation?.target ?? browser.translationTarget
        }
        .task {
            if Self.supported == nil {
                Self.supported = await Browser.translatable().sorted { Browser.languageName($0) < Browser.languageName($1) }
            }
            languages = Self.supported ?? []
        }
        .task(id: from + ">" + to) {
            possible = nil
            guard !from.isEmpty, !to.isEmpty, from != to else { return }
            possible = await Browser.canTranslate(from: from, to: to)
        }
    }

    private var title: String {
        tab.translation.map { "This page is translated from \(Browser.languageName($0.source)) to \(Browser.languageName($0.target))" }
            ?? "Translate this page?"
    }

    /// The chosen languages coming down, the first time, and how far.
    private var downloads: [(language: String, done: Double)] {
        [from, to].compactMap { code in mozilla.downloading[MozillaTranslation.code(code)].map { (code, $0) } }
    }

    private var ready: Bool {
        guard possible == true else { return false }
        return tab.translation.map { $0.source != from || $0.target != to } ?? true
    }

    private var note: String? {
        guard possible == false else { return nil }
        return !languages.isEmpty && !languages.contains(from)
            ? "Mote can't translate \(Browser.languageName(from)) yet. If the page is in another language, choose it above."
            : "Mote can't translate \(Browser.languageName(from)) to \(Browser.languageName(to)) yet."
    }

    private func choice(_ title: String, _ code: Binding<String>, _ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Picker(title, selection: code) {
                ForEach(options, id: \.self) { Text(Browser.languageName($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
