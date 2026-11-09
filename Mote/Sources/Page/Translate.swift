import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// Translating a page when a page is in a language the user doesn't read,
/// a quiet button beside the address translates it
/// with Apple's Translation framework.
extension Browser {
    /// Notes the language a page is in, when it's one you don't read.
    func noteLanguage(of tab: Tab) {
        tab.translation = nil
        tab.pageLanguage = nil
        guard prefs.offersTranslation, !tab.shy, let web = tab.built else { return }
        // The start, middle and end: a page in your language can still hold a
        // foreign article, past where its menus and headings end.
        let sample = """
            (() => {
              const text = document.body ? document.body.innerText : '', n = 2000, mid = Math.floor(text.length / 2);
              const parts = text.length <= 3 * n ? [text] : [text.slice(0, n), text.slice(mid - n / 2, mid + n / 2), text.slice(-n)];
              return (document.documentElement.lang || '') + '\\n' + parts.join('\\n');
            })()
            """
        web.evaluateInAppWorld(sample) { [weak self, weak tab] value in
            guard let text = value as? String else { return }
            // Recognised off the main thread: it's a few milliseconds a page.
            Task {
                let code = await Task.detached(priority: .utility) { Self.language(of: text) }.value
                guard let code, !Self.reads(code), self?.prefs.neverTranslate.contains(code) == false else { return }
                tab?.pageLanguage = code
            }
        }
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
        if let foreign = shares.filter({ !reads($0.key) }).max(by: { $0.value < $1.value }), foreign.value * 5 >= total {
            return foreign.key
        }
        recognizer.reset()
        recognizer.processString(text)
        let code = recognizer.dominantLanguage?.rawValue ?? String(sample.prefix { $0 != "\n" }.prefix(2))
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

    /// The languages macOS translates.
    @available(macOS 15, *)
    @concurrent nonisolated static func translatable() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
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

    /// Translates the page from `source` to `target`, once macOS says it can.
    func translate(_ tab: Tab, from source: String, to target: String) {
        guard #available(macOS 15, *) else { return }
        Task {
            let status = await Self.availability(from: source, to: target)
            guard status != .unsupported, source != target else {
                return announce("macOS can't translate \(Self.languageName(source)) to \(Self.languageName(target))")
            }
            translating = TranslationJob(tab: tab.id, source: source, target: target)
        }
    }

    /// Runs with the session SwiftUI hands over (see TranslationHost), as
    /// Firefox translates: what's on screen first, each distinct piece of
    /// text once however often it repeats, and the results written in as
    /// they stream back, a few at a time. The page's text comes 5000 pieces
    /// at a time, the ones around the screen first, until all of it's done.
    @available(macOS 15, *)
    func translate(with session: TranslationSession) async {
        guard let job = translating, let tab = tab(job.tab), let web = tab.built else { return }
        defer { if translating == job { translating = nil } }
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
            pending = [:]
            flushed = .now
        }
        var translated = 0, failed = false
        while tab.translation == job, let (base, texts) = await Self.next(in: web) {
            // Only what's foreign to you, each keeping its place among them all.
            let places = await Task.detached(priority: .userInitiated) { texts.indices.filter { !Self.alreadyRead(texts[$0]) } }.value
            if places.isEmpty { continue }
            do {
                for try await (index, text) in Self.stream(places.map { texts[$0] }, in: session) {
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
        if failed, translated == 0 { announce("This page couldn't be translated") }
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
    private nonisolated static func stream(_ texts: [String], in session: TranslationSession) -> AsyncThrowingStream<(Int, String), Error> {
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
          window.__moteTranslation = {
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
            restore: () => nodes.forEach((n, i) => { n.nodeValue = original[i]; })
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
/// so a wrong guess can be put right, and why when macOS can't.
@available(macOS 15, *)
struct TranslatePanel: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    @State private var from = ""
    @State private var to = ""
    @State private var languages: [String] = []
    @State private var status: LanguageAvailability.Status?

    /// What macOS translates, by name; asked once.
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
            status = nil
            guard !from.isEmpty, !to.isEmpty, from != to else { return }
            status = await Browser.availability(from: from, to: to)
        }
    }

    private var title: String {
        tab.translation.map { "This page is translated from \(Browser.languageName($0.source)) to \(Browser.languageName($0.target))" }
            ?? "Translate this page?"
    }

    private var ready: Bool {
        guard status == .installed || status == .supported else { return false }
        return tab.translation.map { $0.source != from || $0.target != to } ?? true
    }

    private var note: String? {
        switch status {
        case .unsupported where !languages.isEmpty && !languages.contains(from):
            "macOS can't translate \(Browser.languageName(from)) yet. If the page is in another language, choose it above."
        case .unsupported: "macOS can't translate \(Browser.languageName(from)) to \(Browser.languageName(to))."
        case .supported: "macOS downloads these languages the first time, then translates on this Mac."
        default: nil
        }
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
