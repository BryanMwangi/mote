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
            picker($source, tint: .secondary)
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Divider().padding(.vertical, 4)
            picker($target, tint: Color.accentColor)
            Group {
                if let result {
                    // As tall as it is, as macOS's grows; a long one stops at twelve lines.
                    Text(result).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor).textSelection(.enabled)
                        .lineLimit(12).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A language as macOS's popover shows it: its name and a small up-down
    /// chevron, no button around it; a menu of the others on a click.
    private func picker(_ code: Binding<String>, tint: some ShapeStyle) -> some View {
        let shown = languages.contains(code.wrappedValue) || code.wrappedValue.isEmpty ? languages : [code.wrappedValue] + languages
        return Menu {
            Picker("", selection: code) {
                ForEach(shown, id: \.self) { Text(Browser.languageName($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(code.wrappedValue.isEmpty ? "" : Browser.languageName(code.wrappedValue))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
