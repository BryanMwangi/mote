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

    /// Runs with the session SwiftUI hands over (see TranslationHost): the
    /// page's text in batches, each written back as it comes.
    @available(macOS 15, *)
    func translate(with session: TranslationSession) async {
        guard let job = translating, let tab = tab(job.tab), let web = tab.built else { return }
        defer { translating = nil }
        let texts = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            web.evaluateInAppWorld(Self.collect) { done.resume(returning: $0 as? [String] ?? []) }
        }
        guard !texts.isEmpty else { return }
        tab.translated = true
        for start in stride(from: 0, to: texts.count, by: 80) {
            let batch = Array(texts[start..<min(start + 80, texts.count)])
            guard let responses = try? await Self.translations(of: batch, from: start, in: session) else {
                announce("This page couldn't be translated")
                return
            }
            var found: [String: String] = [:]
            for response in responses { if let id = response.clientIdentifier { found[id] = response.targetText } }
            guard tab.translated, let json = try? JSONEncoder().encode(found), let text = String(data: json, encoding: .utf8) else {
                return
            }
            web.evaluateInAppWorld("window.__moteTranslation && window.__moteTranslation.put(\(text))")
        }
    }

    /// The session works off the main actor; it's only ever used from one
    /// task at a time, the one `translationTask` runs.
    @available(macOS 15, *)
    private nonisolated static func translations(
        of texts: [String], from start: Int, in session: TranslationSession
    ) async throws -> [TranslationSession.Response] {
        nonisolated(unsafe) let session = session
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String(start + $0)) }
        return try await session.translations(from: requests)
    }

    /// The page's text nodes, kept in Mote's world with what they said, so
    /// they can be written to and put back; their text comes back trimmed.
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
          window.__moteTranslation = {
            put: found => { for (const i in found) { const n = nodes[i]; if (n) n.nodeValue = original[i].replace(original[i].trim(), found[i]); } },
            restore: () => nodes.forEach((n, i) => { n.nodeValue = original[i]; })
          };
          return original.map(t => t.trim());
        })()
        """
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
