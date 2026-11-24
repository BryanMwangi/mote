import SwiftUI
import Translation

/// The page menu's Translate for selected text, in place of macOS's own:
/// the same popover, but Mozilla's engine takes the languages macOS can't
/// (Hungarian, say), as pages are translated (Translate.swift).
@available(macOS 15, *)
@MainActor
enum SelectionTranslation {
    static func show(_ text: String, pageLanguage: String?, from view: NSView, at spot: NSRect, browser: Browser) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SelectionTranslationView(text: text, pageLanguage: pageLanguage, browser: browser))
        popover.show(relativeTo: spot, of: view, preferredEdge: .maxX)
    }
}

@available(macOS 15, *)
private struct SelectionTranslationView: View {
    let text: String
    let pageLanguage: String?
    let browser: Browser

    @ObservedObject private var mozilla = MozillaTranslation.shared
    @State private var source = ""
    @State private var target = ""
    @State private var languages: [String] = []
    @State private var result: String?
    @State private var problem: String?
    /// Set when macOS has the pair: its session translates (`translationTask`).
    @State private var apple: TranslationSession.Configuration?

    /// The source language coming down the first time, and how far.
    private var downloaded: Double? { mozilla.downloading[MozillaTranslation.code(source)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker($source)
            Text(text).font(.callout.weight(.medium)).lineLimit(3).truncationMode(.tail)
            Divider()
            picker($target)
            Group {
                if let result {
                    ScrollView {
                        Text(result).font(.body).foregroundStyle(Color.accentColor).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if let downloaded {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Downloading \(Browser.languageName(source))…").font(.callout).foregroundStyle(.secondary)
                        ProgressView(value: downloaded).controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 40, alignment: .topLeading)
            Divider()
            Button("Copy Translation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result ?? "", forType: .string)
            }
            .disabled(result == nil)
        }
        .padding(16)
        .frame(width: 360)
        .translationTask(apple) { session in
            do {
                for try await (_, translated) in Browser.stream([text], in: session) { result = translated }
            } catch {
                problem = "This couldn't be translated."
            }
        }
        .task {
            source = await Browser.selectionLanguage(of: text, page: pageLanguage) ?? pageLanguage ?? "en"
            target = browser.translationTarget
            languages = await Browser.translatable()
        }
        .task(id: "\(source)>\(target)") { await translate() }
    }

    private func picker(_ code: Binding<String>) -> some View {
        Picker("", selection: code) {
            ForEach(languages.contains(code.wrappedValue) || code.wrappedValue.isEmpty ? languages : [code.wrappedValue] + languages, id: \.self) {
                Text(Browser.languageName($0)).tag($0)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Through macOS when it has the pair, else Mozilla's engine.
    private func translate() async {
        guard !source.isEmpty, !target.isEmpty else { return }
        result = nil
        problem = nil
        apple = nil
        guard source != target else { return result = text }
        if let status = await Browser.availability(from: source, to: target), status != .unsupported {
            apple = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
            return
        }
        guard await MozillaTranslation.shared.route(from: source, to: target) != nil else {
            return problem = "Mote can't translate \(Browser.languageName(source)) to \(Browser.languageName(target)) yet."
        }
        do {
            for try await (_, text) in MozillaTranslation.shared.stream([text], from: source, to: target) { result = text }
        } catch {
            if !Task.isCancelled { problem = "This couldn't be translated." }
        }
    }
}
