import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// Translating a page, as Firefox (and so Zen) offers it: when a page is in a
/// language you don't read, a quiet button beside the address translates it
/// with Apple's Translation framework, on this Mac. Mote's script runs only
/// when asked, in its own world, so a translation extension sees the page
/// as it was; Show Original puts it back.
extension Browser {
    /// Notes the language a page is in, when it's one you don't read.
    func noteLanguage(of tab: Tab) {
        tab.translated = false
        tab.pageLanguage = nil
        guard prefs.offersTranslation, !tab.shy, let web = tab.built else { return }
        let sample = "(document.documentElement.lang || '') + '\\n' + (document.body ? document.body.innerText.slice(0, 2000) : '')"
        web.evaluateInAppWorld(sample) { [weak tab] value in
            guard let text = value as? String else { return }
            // Recognised off the main thread: it's a few milliseconds a page.
            Task {
                let code = await Task.detached(priority: .utility) { Self.language(of: text) }.value
                guard let code, !Self.reads(code) else { return }
                tab?.pageLanguage = code
            }
        }
    }

    /// The language a page's sample is in: what its text reads as, or what
    /// its `lang` (the sample's first line) says.
    private nonisolated static func language(of sample: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.drop { $0 != "\n" }))
        let code = recognizer.dominantLanguage?.rawValue ?? String(sample.prefix { $0 != "\n" }.prefix(2))
        return code.isEmpty ? nil : code
    }

    /// Whether `code` is one of the languages the Mac is set to read.
    private nonisolated static func reads(_ code: String) -> Bool {
        let wanted = Locale.Language(identifier: code).languageCode
        return Locale.preferredLanguages.contains { Locale.Language(identifier: $0).languageCode == wanted }
    }

    /// The button: translate the page, or show it as it was.
    func toggleTranslation(_ tab: Tab) {
        if tab.translated {
            tab.built?.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.restore()")
            tab.translated = false
            return
        }
        guard let code = tab.pageLanguage, #available(macOS 15, *) else { return }
        translating = TranslationJob(tab: tab.id, source: code)
    }

    /// Runs with the session SwiftUI hands over (see TranslationHost), as
    /// Firefox translates: what's on screen first, each distinct piece of
    /// text once however often it repeats, and the results written in as
    /// they stream back, a few at a time, rather than a batch at a time.
    @available(macOS 15, *)
    func translate(with session: TranslationSession) async {
        guard let job = translating, let tab = tab(job.tab), let web = tab.built else { return }
        defer { translating = nil }
        let texts = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            web.evaluateInAppWorld(Self.collect) { done.resume(returning: $0 as? [String] ?? []) }
        }
        guard !texts.isEmpty else { return }
        tab.translated = true
        var pending: [String: String] = [:]
        var flushed = ContinuousClock.now
        let flush = {
            guard !pending.isEmpty, let json = try? JSONEncoder().encode(pending), let text = String(data: json, encoding: .utf8) else {
                return
            }
            web.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.put(\(text))")
            pending = [:]
            flushed = .now
        }
        do {
            for try await (index, text) in Self.stream(texts, in: session) {
                guard tab.translated else { return }
                pending[String(index)] = text
                // Soon for the first lines, which are what's on screen; then in small groups.
                if pending.count >= 24 || ContinuousClock.now - flushed > .milliseconds(80) { flush() }
            }
            flush()
        } catch {
            flush()
            announce("This page couldn't be translated")
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
          const skip = /^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|TEXTAREA|SVG)$/;
          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
            acceptNode: n => {
              const p = n.parentElement;
              if (!p || skip.test(p.tagName) || p.isContentEditable) return NodeFilter.FILTER_REJECT;
              return n.nodeValue.trim().length > 1 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            }
          });
          const nodes = [];
          for (let n = walker.nextNode(); n && nodes.length < 5000; n = walker.nextNode()) nodes.push(n);
          const original = nodes.map(n => n.nodeValue);
          const height = innerHeight;
          const away = nodes.map((n, i) => {
            const r = n.parentElement.getBoundingClientRect();
            return [r.bottom < 0 ? height - r.bottom : r.top > height ? r.top - height : 0, i];
          }).sort((a, b) => a[0] - b[0]);
          const groups = new Map();
          for (const [, i] of away) {
            const text = original[i].trim();
            if (!groups.has(text)) groups.set(text, []);
            groups.get(text).push(i);
          }
          const places = [...groups.values()];
          window.__moteTranslation = {
            put: found => {
              for (const g in found) for (const i of places[g] || []) nodes[i].nodeValue = original[i].replace(original[i].trim(), found[g]);
            },
            restore: () => nodes.forEach((n, i) => { n.nodeValue = original[i]; })
          };
          return [...groups.keys()];
        })()
        """
}

/// The session, carried to the one task that streams with it.
@available(macOS 15, *)
nonisolated private struct Held: @unchecked Sendable {
    let session: TranslationSession
}

/// A page waiting to be translated: which tab, from what language.
struct TranslationJob: Equatable {
    let tab: Tab.ID
    let source: String
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
                    browser.translating.map { TranslationSession.Configuration(source: Locale.Language(identifier: $0.source)) }
                ) {
                    session in await browser.translate(with: session)
                }
        }
    }
}
