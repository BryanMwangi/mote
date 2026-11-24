import CoreServices
import MoteCore
import SwiftUI

/// The page menu's Look Up, in place of WebKit's dictionary-only one: the
/// Mac's dictionary for a word or a short phrase, and a few results from the
/// web, as Siri lists them, with a search for the rest. The words go to
/// DuckDuckGo for the results, as a search would; nothing else does.
@MainActor
enum LookUp {
    static func show(_ words: String, from view: NSView, at spot: NSRect, browser: Browser, tab: Tab?) {
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: LookUpView(words: words, browser: browser) { [weak popover, weak tab] url in
                popover?.close()
                _ = browser.open(url, foreground: true, from: tab)
            } search: { [weak popover, weak tab] in
                popover?.close()
                if let tab { browser.tab(tab, searches: words) }
            })
        // The popover follows its content as the results come in.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: spot, of: view, preferredEdge: .maxY)
    }

    /// The Mac's dictionary entry for `words`, as plain text: nil for more
    /// than a few words, or none found.
    nonisolated static func definition(of words: String) -> String? {
        guard words.split(separator: " ").count <= 3, words.count <= 40 else { return nil }
        let range = CFRange(location: 0, length: (words as NSString).length)
        guard let found = DCSCopyTextDefinition(nil, words as CFString, range)?.takeRetainedValue() else { return nil }
        let text = (found as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private struct LookUpView: View {
    let words: String
    let browser: Browser
    let open: (URL) -> Void
    let search: () -> Void

    @State private var definition: String?
    @State private var results: [WebResult]?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let definition {
                    section("Dictionary") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(definition).font(.system(size: 13)).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                            Button("Open in Dictionary") {
                                if let url = URL(string: "dict://\(words.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? words)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link).font(.system(size: 11.5))
                        }
                    }
                }
                section("From the Web") {
                    if let results, !results.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                if index > 0 { Divider().padding(.vertical, 2) }
                                ResultRow(result: result) { open(result.url) }
                            }
                        }
                    } else if results != nil || failed {
                        Text(failed ? "The web couldn't be reached." : "Nothing found on the web.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            Button(action: search) {
                Text("Search \(browser.searchEngineName ?? "the Web")")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding([.horizontal, .bottom], 12)
        }
        .frame(width: 380)
        .task {
            let words = words
            definition = await Task.detached(priority: .userInitiated) { LookUp.definition(of: words) }.value
        }
        .task { await fetch() }
    }

    /// A small heading over a rule, as macOS's Look Up sets its sections.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .medium))
                Rectangle().fill(.separator).frame(height: 1)
            }
            content()
        }
    }

    private func fetch() async {
        var request = URLRequest(url: WebResults.address(for: words), timeoutInterval: 8)
        // A browser's, as any page fetched from here; nothing of the person's.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(decoding: data, as: UTF8.self)
            results = await Task.detached(priority: .userInitiated) { WebResults.parse(html: html) }.value
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private struct ResultRow: View {
        let result: WebResult
        let open: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if !result.snippet.isEmpty {
                        Text(result.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(result.site).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -6)
            .onHover { hovering = $0 }
            .help(result.url.absoluteString)
        }
    }
}
