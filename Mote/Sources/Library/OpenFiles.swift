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
        case .text: [.html, .webArchive, .plainText, .json, .xml, UTType("net.daringfireball.markdown")].compactMap { $0 }
        case .media: [.mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .mp3, .wav]
        }
    }

    /// The kind of a file, by its name.
    static func of(_ file: URL) -> OpenFiles? {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .html) || type.conforms(to: .webArchive) || type.conforms(to: .plainText) || type.conforms(to: .json) || type.conforms(to: .xml) { return .text }
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
