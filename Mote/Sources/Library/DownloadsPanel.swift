import AppKit
import MoteCore
import SwiftUI
import UniformTypeIdentifiers

/// The Downloads panel: recent files, to open, find in Finder or forget.
struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var downloads: Downloads

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.showingDownloads = false }) {
            if !downloads.transfers.isEmpty {
                Card {
                    ForEach(Array(downloads.transfers.enumerated()), id: \.element.id) { index, transfer in
                        if index > 0 { Rule() }
                        TransferRow(transfer: transfer, browser: browser).padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            }
            if downloads.kept.isEmpty, !downloads.transfers.isEmpty {
                EmptyView()
            } else if downloads.kept.isEmpty {
                Card { EmptyState("Nothing downloaded yet.") }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(downloads.kept.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Rule() }
                            FileRow(record: record, there: downloads.isThere(record), downloads: downloads)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 420)
            }
        } foot: {
            HStack {
                Text(
                    downloads.kept.isEmpty
                        ? "Files land in \(browser.downloadsFolder.lastPathComponent)" : "Clearing the list leaves the files where they are"
                )
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                Spacer()
                if !downloads.kept.isEmpty { Pill("Clear list") { downloads.forgetAll() } }
            }
        }
        .onAppear { downloads.lookAgain() }
    }
}

/// A downloaded file; one that has been moved or deleted shows faded.
private struct FileRow: View {
    let record: DownloadRecord
    let there: Bool
    let downloads: Downloads

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileKind.icon(of: record, there: there))
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(there ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.system(size: 13))
                    .foregroundStyle(there ? Palette.ink : Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([there ? "" : "Deleted", record.from, When.said(record.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 2) {
                    if there { Door(icon: "magnifyingglass", help: "Show in Finder") { downloads.reveal(record) } }
                    Door(icon: "xmark", help: "Remove from List") { downloads.forget(record) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if there { downloads.open(record) } }
        .contextMenu { FileMenu(record: record, there: there, downloads: downloads) }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A download under way, paused or failed: its kind of file, how far it's
/// got and how fast, and pausing, going on or stopping it. In the Downloads
/// panel and the sidebar's popover.
struct TransferRow: View {
    @ObservedObject var transfer: Transfer
    let browser: Browser

    private var status: String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let got = transfer.total > 0 ? "\(size(transfer.received)) of \(size(transfer.total))" : size(transfer.received)
        switch transfer.state {
        case .running:
            let speed = transfer.rate > 0 ? " (\(size(Int64(transfer.rate)))/s)" : ""
            return "\(timeLeft) — \(got)\(speed)"
        case .paused: return "Paused — " + got
        case .failed: return transfer.resumeData == nil ? "Failed" : "Stopped — " + got
        }
    }

    private var timeLeft: String {
        guard transfer.total > 0, transfer.rate > 0 else { return "Unknown time left" }
        let seconds = Double(transfer.total - transfer.received) / transfer.rate
        return (Self.left.string(from: max(1, seconds)) ?? "") + " left"
    }

    private static let left: DateComponentsFormatter = {
        let format = DateComponentsFormatter()
        format.allowedUnits = [.hour, .minute, .second]
        format.unitsStyle = .short
        format.maximumUnitCount = 1
        return format
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileKind.icon(named: transfer.name))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(transfer.state == .failed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: transfer.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(transfer.state == .running ? nil : Palette.muted)
                Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 0) {
                switch transfer.state {
                case .running: Door(icon: "pause.fill", help: "Pause") { browser.downloads.pause(transfer) }
                case .paused: Door(icon: "play.fill", help: "Resume") { browser.resume(transfer) }
                case .failed: Door(icon: "arrow.clockwise", help: "Try Again") { browser.resume(transfer) }
                }
                Door(icon: "xmark", help: transfer.state == .running ? "Stop" : "Remove from List") { browser.downloads.cancel(transfer) }
            }
        }
        .contentShape(Rectangle())
        .contextMenu { TransferMenu(transfer: transfer, browser: browser) }
    }
}

/// The icon macOS shows for a kind of file, by its name's extension; a
/// file that's there, by itself.
enum FileKind {
    static func icon(named name: String) -> NSImage {
        let kind = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: kind)
    }

    static func icon(of record: DownloadRecord, there: Bool) -> NSImage {
        there ? NSWorkspace.shared.icon(forFile: record.path) : icon(named: record.name)
    }
}

/// A downloaded file's menu, wherever it's listed.
struct FileMenu: View {
    let record: DownloadRecord
    let there: Bool
    let downloads: Downloads

    var body: some View {
        Button("Open") { downloads.open(record) }.disabled(!there)
        Button("Show in Finder") { downloads.reveal(record) }.disabled(!there)
        if let source = record.source { Button("Copy Download Link") { Downloads.copy(source) } }
        Divider()
        Button("Remove from List") { downloads.forget(record) }
        Button("Move to Trash") { downloads.trash(record) }.disabled(!there)
    }
}

/// A download under way's menu.
struct TransferMenu: View {
    @ObservedObject var transfer: Transfer
    let browser: Browser

    var body: some View {
        switch transfer.state {
        case .running: Button("Pause") { browser.downloads.pause(transfer) }
        case .paused: Button("Resume") { browser.resume(transfer) }
        case .failed: Button("Try Again") { browser.resume(transfer) }
        }
        if let source = transfer.source { Button("Copy Download Link") { Downloads.copy(source) } }
        Divider()
        Button(transfer.state == .running ? "Cancel" : "Remove from List") { browser.downloads.cancel(transfer) }
    }
}
