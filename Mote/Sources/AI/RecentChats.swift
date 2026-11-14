import MoteAI
import SwiftUI

/// Every kept chat, in a tab of its own: a search over them, and the chats
/// by when they were last used.
struct ChatsPage: View {
    let browser: Browser
    var inPanel = false
    var didOpen: () -> Void = {}
    /// New Chat: in the chat sidebar, a fresh one there; elsewhere a new tab asking.
    var newChat: (() -> Void)? = nil
    @State private var query = ""
    @State private var showsArchived = false
    @State private var undo = ChatUndo()
    @FocusState private var searching: Bool

    private var archive: ChatArchive { Assistant.shared.chats }

    var body: some View {
        let all = archive.entries(matching: query)
        let found = all.filter { $0.archived != true }
        let archived = all.filter { $0.archived == true }
        let periods = ChatArchive.periods(of: found)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Chats").font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("\(archive.entries.count)").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Spacer()
                    if undo.chat != nil { UndoLink(undo: undo) }
                    Pill("New Chat") {
                        didOpen()
                        (newChat ?? browser.newAskingTab)()
                    }
                    .help("A new chat; this list keeps the others   /new")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
                SearchField(text: $query, prompt: "Search chats", focus: $searching)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, inPanel ? 14 : 32)
            .padding(.top, inPanel ? 18 : 56)
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if periods.isEmpty, archived.isEmpty {
                        Text(archive.entries.isEmpty ? "No chats yet. Ask in the chat sidebar (⇧⌘A), or from a new tab with ⌘J." : "No chat matches.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10)
                    }
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(periods, id: \.name) { period in
                            Text(period.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 10)
                                .padding(.top, period.name == periods.first?.name ? 0 : 18)
                                .padding(.bottom, 4)
                            ForEach(period.entries) { entry in row(entry) }
                        }
                        // Put away, out of the way until wanted.
                        if !archived.isEmpty {
                            Button {
                                withAnimation(Motion.quick) { showsArchived.toggle() }
                            } label: {
                                Label("Archived (\(archived.count))", systemImage: showsArchived ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.top, periods.isEmpty ? 0 : 18)
                            .padding(.bottom, 4)
                            if showsArchived || !query.isEmpty { ForEach(archived) { entry in row(entry) } }
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, inPanel ? 14 : 32)
                .padding(.bottom, inPanel ? 18 : 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(inPanel ? .clear : Palette.ground)
        .onAppear { searching = true }
        .animation(Motion.quick, value: found.map(\.id))
    }
}

extension ChatsPage {
    fileprivate func row(_ entry: ChatArchive.Entry) -> some View {
        ChatRow(entry: entry, showsTime: false) {
            browser.open(chat: entry.id)
            didOpen()
        } delete: {
            undo.delete(entry.id)
        } archive: {
            Assistant.shared.archive(entry.id, entry.archived != true)
        }
    }
}

/// Deletes a chat at once, and keeps it a few seconds so it can come back.
@MainActor
@Observable
final class ChatUndo {
    private(set) var chat: SavedChat?
    @ObservationIgnored private var forgetting: Task<Void, Never>?

    func delete(_ id: UUID) {
        let archive = Assistant.shared.chats
        chat = archive.load(id)
        archive.delete(id)
        forgetting?.cancel()
        forgetting = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.chat = nil
        }
    }

    func bringBack() {
        guard let chat else { return }
        Assistant.shared.chats.restore(chat)
        self.chat = nil
    }
}

private struct UndoLink: View {
    let undo: ChatUndo

    var body: some View {
        HStack(spacing: 8) {
            Text("Chat deleted").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            TextLink("Undo", strong: true) { undo.bringBack() }
        }
        .transition(.opacity)
    }
}

private struct TextLink: View {
    let title: String
    var arrow = false
    var strong = false
    let act: () -> Void
    @State private var hovering = false

    init(_ title: String, arrow: Bool = false, strong: Bool = false, act: @escaping () -> Void) {
        self.title = title
        self.arrow = arrow
        self.strong = strong
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11.5, weight: strong ? .medium : .regular))
                if arrow { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(hovering || strong ? Palette.ink.opacity(0.85) : Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A chat in a list: its title and when it was last used; on hover, a
/// button to delete it.
struct ChatRow: View {
    let entry: ChatArchive.Entry
    var showsTime = true
    let open: () -> Void
    let delete: () -> Void
    /// Archive, or take out of the archive.
    var archive: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 16)
            Text(entry.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if hovering, let archive {
                Button(action: archive) {
                    Image(systemName: entry.archived == true ? "tray.and.arrow.up" : "archivebox")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressed())
                .help(entry.archived == true ? "Take out of the archive" : "Archive this chat")
            }
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressed())
                .help("Delete this chat")
                .accessibilityLabel("Delete")
            } else if showsTime {
                Text(Date().timeIntervalSince(entry.updated) < 60 ? "Now" : When.said(entry.updated))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.faint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            if let archive { Button(entry.archived == true ? "Unarchive" : "Archive", action: archive) }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Delete", delete)
        .animation(Motion.hover, value: hovering)
    }
}
