import AppKit
import MoteAI
import QuickLookThumbnailing
import SwiftUI

/// Files in a chat: what the person attaches, copied into the chat's own
/// folder (`ChatFiles`) so the agent reads them by path, and the pictures
/// its steps take, shown so the person sees what it looked at.
extension Assistant {
    /// Copies `urls` into the chat's folder, for its next message. Copying
    /// is off the main thread; what can't be taken is said with `refused`.
    func attach(_ urls: [URL], to conversation: Conversation, refused: @escaping @MainActor (String) -> Void) {
        guard let folder = conversation.folder else { return refused("Files can't be attached to a private chat.") }
        let room = ChatFiles.mostAtOnce - conversation.attached.count
        guard room > 0 else { return refused("A message takes up to \(ChatFiles.mostAtOnce) files.") }
        let taken = Array(urls.prefix(room))
        Task.detached(priority: .userInitiated) {
            var kept: [Attachment] = [], problems: [String] = []
            for url in taken {
                do { kept.append(try ChatFiles.keep(url, in: folder)) } catch { problems.append(error.localizedDescription) }
            }
            if urls.count > taken.count { problems.append("A message takes up to \(ChatFiles.mostAtOnce) files.") }
            await MainActor.run {
                conversation.attached += kept
                if let first = problems.first { refused(first) }
            }
        }
    }

    /// Lets go of a file attached but not sent: its copy goes too.
    func unattach(_ file: Attachment, from conversation: Conversation) {
        conversation.attached.removeAll { $0 == file }
        if let folder = conversation.folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.file)) }
    }
}

/// The paperclip: picks files to attach.
struct AttachButton: View {
    let attach: ([URL]) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.message = "Files to attach: the chat keeps a copy of each"
            panel.prompt = "Attach"
            guard panel.runModal() == .OK else { return }
            attach(panel.urls)
        } label: {
            Image(systemName: "paperclip").font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Attach files, or drop them here")
        .accessibilityLabel("Attach files")
    }
}

/// A file in the chat, as a chip: its picture or icon, and its name. Opens
/// the kept copy; with `remove`, lets it go.
struct FileChip: View {
    let file: Attachment
    let folder: URL?
    var remove: (() -> Void)?
    @State private var icon: NSImage?

    private var url: URL? { folder?.appendingPathComponent(file.file) }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFill() } else { Image(systemName: "doc").foregroundStyle(Palette.muted) }
            }
            .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(file.name).font(.system(size: 11.5)).foregroundStyle(Palette.ink.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't attach this file")
            }
        }
        .padding(.leading, 5).padding(.trailing, remove == nil ? 9 : 4)
        .frame(height: 28)
        .background(Palette.wash, in: Rounded.row)
        .overlay(Rounded.row.strokeBorder(Palette.hairline))
        .contentShape(Rounded.row)
        .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
        .help("\(file.name), \(ChatFiles.size(file.bytes))")
        .task(id: file.file) { icon = await Thumbnail.of(url, side: 36) }
    }
}

/// Files in a row, scrolling across the column when they don't fit.
struct FileChips: View {
    let files: [Attachment]
    let folder: URL?
    var remove: ((Attachment) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips.padding(.vertical, 1) }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(files) { file in FileChip(file: file, folder: folder, remove: remove.map { remove in { remove(file) } }) }
        }
    }
}

/// The pictures a reply's steps took (screenshots), small, each opening full size.
struct StepPictures: View {
    let steps: [Activity]
    let folder: URL?

    var body: some View {
        let taken = steps.compactMap { step in step.picture.map { (step: step, file: $0) } }
        if let folder, !taken.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(taken, id: \.file) { shot in
                        StepPicture(url: folder.appendingPathComponent(shot.file), title: shot.step.title)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(height: 64)
        }
    }
}

private struct StepPicture: View {
    let url: URL
    let title: String
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Palette.wash }
        }
        .frame(width: 96, height: 62)
        .clipShape(Rounded.row)
        .overlay(Rounded.row.strokeBorder(hovering ? Palette.ink.opacity(0.3) : Palette.hairline))
        .contentShape(Rounded.row)
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onHover { hovering = $0 }
        .help("\(title): a picture the assistant took. Click to see it whole")
        .task(id: url) { image = await Thumbnail.of(url, side: 192) }
    }
}

/// A small picture of a file, made by Quick Look: an image's own, a
/// document's first page, or its icon.
enum Thumbnail {
    static func of(_ url: URL?, side: CGFloat) async -> NSImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
