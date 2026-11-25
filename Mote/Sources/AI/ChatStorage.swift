import MoteAI
import SwiftUI

/// Settings › AI › Chats › Manage: how much room chats take on this Mac,
/// each with the files attached to it and the pictures its steps took,
/// largest first; deleting one deletes its files.
struct ChatStorageSheet: View {
    struct Chat: Identifiable {
        let entry: ChatArchive.Entry
        let bytes: Int64
        let files: Int64
        var id: UUID { entry.id }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var chats: [Chat]?

    private var total: Int64 { chats?.reduce(0) { $0 + $1.bytes } ?? 0 }
    private var files: Int64 { chats?.reduce(0) { $0 + $1.files } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(20) }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 550)
        .task { await measure() }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22, weight: .regular)).foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: 52, height: 52).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Chats").font(.title3.weight(.semibold))
            Text("Each chat keeps its messages, copies of the files you attached, and the pictures the assistant took.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let chats, !chats.isEmpty {
                HStack {
                    Text("All chats")
                    Spacer()
                    Text(files > 0 ? "\(ChatFiles.size(total)), files \(ChatFiles.size(files))" : ChatFiles.size(total))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            LazyVStack(spacing: 0) {
                ForEach(chats ?? []) { chat in
                    ChatSizeRow(chat: chat) { delete(chat) }.padding(.horizontal, 12).padding(.vertical, 7)
                    if chat.id != chats?.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .overlay {
                if chats == nil { ProgressView().controlSize(.small) }
                else if chats?.isEmpty == true { Text("No chats are kept.").foregroundStyle(.secondary) }
            }
            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Every kept chat's room, measured off the main thread.
    private func measure() async {
        let archive = Assistant.shared.chats
        let kept = archive.entries.map { (entry: $0, where: archive.storage(of: $0.id)) }
        chats = await Task.detached(priority: .userInitiated) {
            kept.map { item in
                let chat = Int64((try? item.where.chat.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                let files = ChatFiles.size(of: item.where.files)
                return Chat(entry: item.entry, bytes: chat + files, files: files)
            }
            .sorted { $0.bytes > $1.bytes }
        }.value
    }

    private func delete(_ chat: Chat) {
        let also = chat.files > 0 ? " and its files (\(ChatFiles.size(chat.files)))" : ""
        guard Dialogs.confirm("Delete “\(chat.entry.title)”?", "The chat\(also) can't be brought back.", button: "Delete") else { return }
        Assistant.shared.chats.delete(chat.id, forGood: true)
        chats?.removeAll { $0.id == chat.id }
    }
}

/// A chat: its title, when, and its size; Delete on hover.
private struct ChatSizeRow: View {
    let chat: ChatStorageSheet.Chat
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.entry.title).lineLimit(1).truncationMode(.tail)
                Text(chat.entry.updated.formatted(date: .abbreviated, time: .omitted) + (chat.files > 0 ? " · files \(ChatFiles.size(chat.files))" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hovering {
                Button("Delete", action: delete).buttonStyle(.borderless).controlSize(.small)
            } else {
                Text(ChatFiles.size(chat.bytes)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
