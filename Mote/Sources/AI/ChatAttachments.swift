import AppKit
import MoteAI
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

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
                .frame(width: 20, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Attach files, or drop them here")
        .accessibilityLabel("Attach files")
    }
}

/// Files shown with Quick Look's own panel: a picture, a PDF, a document,
/// with the arrows between them when there are several.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var items: [URL] = []
    /// Closes it on a click elsewhere in Mote, while it's up.
    private var clicks: Any?

    private var panel: QLPreviewPanel? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil }

    /// Escape while it's up closes it; true when it did. Mote's own keys see
    /// Escape first, so they ask here before using it.
    func escape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, let panel, panel.isVisible else { return false }
        close()
        return true
    }

    /// Whether a key belongs to the panel (its arrows), not to Mote.
    func owns(_ event: NSEvent) -> Bool { event.window != nil && event.window === panel }

    private func close() {
        panel?.orderOut(nil)
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
    }

    func show(_ urls: [URL], at index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
        guard clicks == nil else { return }
        // A click anywhere else closes it, and still does what it does.
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let window = event.window.map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                guard let self else { return }
                if let panel = self.panel, panel.isVisible, window == ObjectIdentifier(panel) { return }
                self.close()
            }
            return event
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }
}

extension View {
    /// A file in the chat: a click shows it in Quick Look (among `all`, to
    /// step through), and the context menu has what else to do with it.
    func file(_ url: URL, among all: [URL]? = nil) -> some View {
        let all = all ?? [url]
        return contentShape(Rectangle())
            .onTapGesture { QuickLook.shared.show(all, at: all.firstIndex(of: url) ?? 0) }
            .contextMenu {
                Button("Quick Look") { QuickLook.shared.show(all, at: all.firstIndex(of: url) ?? 0) }
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
                Button("Save As…") { FileSaving.save(url) }
            }
    }
}

/// Saving a copy of a chat's file where the person picks.
@MainActor
enum FileSaving {
    static func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }
}

/// A file attached for the next message, as a chip: its picture or icon,
/// its name, and a way to let it go.
struct FileChip: View {
    let file: Attachment
    let folder: URL?
    let remove: () -> Void
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
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't attach this file")
        }
        .padding(.leading, 5).padding(.trailing, 4)
        .frame(height: 28)
        .background(Palette.wash, in: Rounded.row)
        .overlay(Rounded.row.strokeBorder(Palette.hairline))
        .modifier(FileAt(url: url))
        .help("\(file.name), \(ChatFiles.size(file.bytes))")
        .task(id: file.file) { icon = await Thumbnail.of(url, side: 36) }
    }
}

/// Quick Look and the menu, for a file that may not be there.
private struct FileAt: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.file(url) } else { content }
    }
}

/// Files attached for the next message, in a row that scrolls when they don't fit.
struct FileChips: View {
    let files: [Attachment]
    let folder: URL?
    let remove: (Attachment) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips.padding(.vertical, 1) }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(files) { file in FileChip(file: file, folder: folder) { remove(file) } }
        }
    }
}

/// Files sent with a message, over it at its side: pictures at their own
/// shape, other files as a card of their first page or their name, with
/// their kind. Wrapping, never scrolling.
struct SentFiles: View {
    let files: [Attachment]
    let folder: URL

    var body: some View {
        let urls = files.map { folder.appendingPathComponent($0.file) }
        TrailingFlow(spacing: 6) {
            ForEach(files) { file in
                SentFile(file: file, url: folder.appendingPathComponent(file.file)).file(folder.appendingPathComponent(file.file), among: urls)
            }
        }
    }
}

private struct SentFile: View {
    let file: Attachment
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    static let height: CGFloat = 110
    private var kind: String { (file.name as NSString).pathExtension.uppercased() }
    private var picture: Bool { UTType(filenameExtension: (file.name as NSString).pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        Group {
            if picture, let thumbnail {
                // At the picture's shape, within bounds.
                let ratio = thumbnail.size.width / max(1, thumbnail.size.height)
                Image(nsImage: thumbnail).resizable().scaledToFill()
                    .frame(width: min(240, max(70, Self.height * ratio)), height: Self.height)
            } else {
                card
            }
        }
        .clipShape(Rounded.card)
        .overlay(Rounded.card.strokeBorder(hovering ? Palette.ink.opacity(0.3) : Palette.hairline))
        .onHover { hovering = $0 }
        .help("\(file.name), \(ChatFiles.size(file.bytes))")
        .task(id: url) { thumbnail = await Thumbnail.of(url, side: 240) }
    }

    /// Its first page when there's one to show, else its name; its kind below.
    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail, !picture {
                Color.white
                Image(nsImage: thumbnail).resizable().scaledToFit().padding(.horizontal, 6).padding(.top, 6)
            } else {
                Palette.wash
                Text(file.name).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            }
            if !kind.isEmpty {
                Text(kind).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(7)
            }
        }
        .frame(width: 110, height: Self.height)
    }
}

/// Views in rows from the trailing edge, wrapping onto the next.
struct TrailingFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// What a step looked at: a picture it took, or a file it read, and the step.
struct StepShot: Identifiable, Equatable {
    let step: String
    let title: String
    let url: URL
    var id: String { step }

    /// A picture kept in the chat's folder first: it stays when a file read moves.
    static func of(_ steps: [Activity], in folder: URL?) -> [StepShot] {
        steps.compactMap { step in
            let url = step.picture.flatMap { name in folder?.appendingPathComponent(name) } ?? step.file.map { URL(fileURLWithPath: $0) }
            return url.map { StepShot(step: step.id, title: step.title, url: $0) }
        }
    }
}

/// What a reply's steps looked at, small at the end of its steps' line:
/// the last few, with how many more. Over one, a larger look below, clear
/// of them; a click shows them all in Quick Look.
struct StepShots: View {
    let shots: [StepShot]
    @State private var over: StepShot?
    /// Room in the chat under the line and over it, and the larger look's height.
    @State private var room = (below: CGFloat.infinity, above: CGFloat.zero)
    @State private var cardHeight: CGFloat = 250

    /// What the composer covers at the chat's foot.
    static let foot: CGFloat = 150

    /// Below the line when it fits there, else above it if it fits there.
    private var below: Bool { room.below >= cardHeight + 16 || room.above < cardHeight + 16 }

    static let shown = 3
    /// The small ones' side.
    static let side: CGFloat = 24

    var body: some View {
        let shown = Array(shots.suffix(Self.shown))
        HStack(spacing: 5) {
            if shots.count > shown.count {
                Text("+\(shots.count - shown.count)").font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(.trailing, 2)
            }
            ForEach(shown) { shot in
                StepFile(url: shot.url, all: shots.map(\.url), lit: over == shot)
                    .onHover { inside in
                        if inside { over = shot } else if over == shot { over = nil }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let over, let index = shots.firstIndex(of: over) {
                ShotCard(shot: over, place: shots.count > 1 ? "\(index + 1) of \(shots.count)" : nil)
                    // At its own size, not the line's, clear of the line either way.
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .offset(y: below ? StepShots.side + 8 : -(cardHeight + 8))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            let view = proxy.bounds(of: .named("chat"))?.height ?? .infinity
            let line = proxy.frame(in: .named("chat"))
            return CGRect(x: 0, y: line.minY, width: 0, height: view - Self.foot - line.maxY)
        } action: { measured in
            room = (below: measured.height, above: measured.minY)
        }
        .animation(Motion.quick, value: over)
    }
}

/// What a step looked at, small (a square at a line's end) or open (at
/// its own shape, under its step): one view either way, so it moves
/// between the two rather than being made again. A click shows it in Quick
/// Look among `all`.
struct StepFile: View {
    let url: URL
    var all: [URL] = []
    var open = false
    var lit = false
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        let ratio = image.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        let size =
            open ? CGSize(width: min(280, max(60, 150 * ratio)), height: min(150, 280 / max(ratio, 0.01))) : CGSize(width: StepShots.side, height: StepShots.side)
        Group {
            // Filling either way: open, its frame is already at its shape, and a
            // switch between filling and fitting can't move smoothly.
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Palette.wash }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: open ? 8 : 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: open ? 8 : 4, style: .continuous)
                .strokeBorder(lit || hovering ? Palette.ink.opacity(0.35) : Palette.hairline))
        .onHover { hovering = $0 }
        .file(url, among: all.isEmpty ? [url] : all)
        .task(id: url) { image = await Thumbnail.of(url, side: 560) }
    }
}

/// What a step looked at, larger: the picture at its shape, and under it
/// the step and where it is among them.
private struct ShotCard: View {
    let shot: StepShot
    let place: String?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    let ratio = image.size.width / max(1, image.size.height)
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: min(340, max(160, 220 * ratio)), height: min(220, 340 / max(ratio, 0.01)))
                } else {
                    Color.white.opacity(0.06).frame(width: 300, height: 180)
                }
            }
            HStack {
                Text(shot.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if let place { Text(place).foregroundStyle(.white.opacity(0.6)).monospacedDigit() }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.14))
        }
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .task(id: shot.url) { image = await Thumbnail.of(shot.url, side: 680) }
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
