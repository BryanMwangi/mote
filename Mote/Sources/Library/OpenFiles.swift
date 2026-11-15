import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The kinds of file Mote opens itself, as Firefox does (Info.plist declares
/// them): whether Mote is their default app, and what happens to one when its
/// download finishes (Settings › General › Files).
enum OpenFiles: String, CaseIterable, Identifiable {
    case pdf, images, text, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDFs"
        case .images: "Images"
        case .text: "Web pages and text"
        case .media: "Audio and video"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .images: "photo"
        case .text: "doc.plaintext"
        case .media: "play.rectangle"
        }
    }

    /// What Mote is made the default for, the first standing for the kind.
    var types: [UTType] {
        switch self {
        case .pdf: [.pdf]
        case .images: [.png, .jpeg, .gif, .webP, .heic, .svg, .tiff, .bmp]
        case .text: [.html, .plainText, .json, .xml, UTType("net.daringfireball.markdown")].compactMap { $0 }
        case .media: [.mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .mp3, .wav]
        }
    }

    /// The kind of a file, by its name.
    static func of(_ file: URL) -> OpenFiles? {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .html) || type.conforms(to: .plainText) || type.conforms(to: .json) || type.conforms(to: .xml) { return .text }
        return nil
    }

    /// The app that opens this kind now.
    var opener: URL? { NSWorkspace.shared.urlForApplication(toOpen: types[0]) }
    var opensInMote: Bool { opener?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }

    /// Makes Mote the default app for every type of the kind.
    func makeMoteDefault() async {
        for type in types { try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) }
    }

    /// What happens when a download of this kind finishes.
    enum After: String, CaseIterable, Identifiable {
        case nothing, mote, app
        var id: String { rawValue }
    }

    /// The app that opens this kind now, by name; nil for none.
    var openerName: String? {
        opener.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    var afterKey: String { "files.after.\(rawValue)" }
    var after: After { Storage.settings.string(forKey: afterKey).flatMap(After.init) ?? .nothing }
}

/// Settings › General › Files: which app opens each kind from Finder, and
/// apart from that, what a finished download of each kind does.
struct FilesSettings: View {
    /// Looked at again after Mote is made a default.
    @State private var looked = 0

    var body: some View {
        SettingsSection("Opening files", note: "The app that opens each kind when you double-click one in Finder.") {
            ForEach(Array(OpenFiles.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowRule() }
                Opener(kind: kind, looked: $looked)
            }
        }
        .id(looked)
        SettingsSection(
            "After a download", note: "What Mote does when a download finishes. Mote shows PDFs in its reader and the rest in a tab."
        ) {
            ForEach(Array(OpenFiles.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowRule() }
                Downloaded(kind: kind)
            }
        }
        .id(looked)
    }

    private struct Opener: View {
        let kind: OpenFiles
        @Binding var looked: Int

        var body: some View {
            SettingRow(
                kind.title, kind.opensInMote ? "Opens in Mote" : "Opens in \(kind.openerName ?? "no app yet")", symbol: kind.symbol,
                tint: Tint.blue
            ) {
                if kind.opensInMote {
                    Label("Mote", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Pill("Open in Mote Instead") {
                        Task {
                            await kind.makeMoteDefault(); looked += 1
                        }
                    }
                    .help("Makes Mote the app these open in from Finder")
                }
            }
        }
    }

    private struct Downloaded: View {
        let kind: OpenFiles
        @AppStorage private var after: String

        init(kind: OpenFiles) {
            self.kind = kind
            _after = AppStorage(wrappedValue: OpenFiles.After.nothing.rawValue, kind.afterKey, store: Storage.settings)
        }

        var body: some View {
            SettingRow(kind.title, "When one finishes downloading", symbol: kind.symbol, tint: Tint.blue) {
                // “Its app” is Mote's own once Mote opens the kind.
                let shown = Binding(
                    get: { kind.opensInMote && after == OpenFiles.After.app.rawValue ? OpenFiles.After.mote.rawValue : after },
                    set: { after = $0 })
                Picker("", selection: shown) {
                    Text("Just Download It").tag(OpenFiles.After.nothing.rawValue)
                    Text("Open in Mote").tag(OpenFiles.After.mote.rawValue)
                    // Its own app, by name; Mote's already above when that's Mote.
                    if !kind.opensInMote, let name = kind.openerName {
                        Text("Open in \(name)").tag(OpenFiles.After.app.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                // One width down the list, whichever app a row names.
                .frame(width: 210)
            }
        }
    }
}
