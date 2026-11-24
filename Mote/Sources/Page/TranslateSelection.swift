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
        let host = NSHostingController(rootView: SelectionTranslationView(text: text, pageLanguage: pageLanguage, browser: browser))
        // The popover follows its content's size as the translation comes in.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
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
    /// How tall the original and translation stand, for the scroll view's height.
    @State private var tall: CGFloat = 120

    /// The translation's blue, as macOS's popover has it: lighter than the
    /// accent where the popover is dark, to read over a white page beneath.
    static let translated = Color(
        nsColor: NSColor(name: nil) { look in
            look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.36, green: 0.68, blue: 1, alpha: 1) : .systemBlue
        })

    /// The source language coming down the first time, and how far.
    private var downloaded: Double? { mozilla.downloading[MozillaTranslation.code(source)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The original and its translation scroll as one, as in macOS's popover.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    picker($source, tint: .secondary)
                    Original(text: text)
                    Divider().padding(.vertical, 4)
                    picker($target, tint: Self.translated)
                    Group {
                        if let result {
                            Text(result).font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.translated)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                }
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
            }
            // As tall as what's in it, up to 260 points; past that it scrolls.
            .frame(height: min(tall, 260))
            Divider()
            Button("Copy Translation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result ?? "", forType: .string)
            }
            .disabled(result == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
                    .foregroundStyle(tint)
                // White on both, as macOS draws them, to be seen on any page.
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.primary)
            }
            .font(.system(size: 11.5))
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

/// The selected text on one line; on hover a "more" fades in at its end, as
/// macOS shows it, and opens it in full.
@available(macOS 15, *)
private struct Original: View {
    let text: String
    @State private var whole = false
    @State private var hovering = false

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .lineLimit(whole ? nil : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: whole)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The line fades out under "more".
            .mask {
                if whole || !hovering || !(text.count > 40 || text.contains("\n")) {
                    Rectangle()
                } else {
                    LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 0.86)], startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay(alignment: .trailing) {
                if !whole, hovering, text.count > 40 || text.contains("\n") {
                    Button("more") { withAnimation(Motion.quick) { whole = true } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SelectionTranslationView.translated)
                        .transition(.opacity)
                }
            }
            .onHover { over in withAnimation(Motion.hover) { hovering = over } }
    }
}
