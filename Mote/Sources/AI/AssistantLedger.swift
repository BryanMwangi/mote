import Combine
import Foundation

/// What the assistant did, each chat's, with how to put it back: closed tabs
/// reopen, moved tabs go back, a pin comes off, a bookmark change is undone,
/// a field gets its old words. Kept until Mote quits. The model undoes with
/// `undo_actions`; the person with Undo under the chat's last reply.
@MainActor
final class AssistantLedger: ObservableObject {
    static let shared = AssistantLedger()

    struct Entry: Identifiable {
        let id: String
        let chat: UUID?
        /// The turn it was done in: all of one turn's undo together.
        let turn: UUID
        /// What was done, as the model was told.
        let what: String
        /// Puts it back, saying how it went; nil when it can't be.
        let undo: (@MainActor () async -> String)?
        let at = Date()
        var undone = false
    }

    @Published private(set) var entries: [Entry] = []
    /// Each chat's turn under way or last answered: the one Undo under the
    /// last reply puts back.
    @Published private(set) var current: [UUID?: UUID] = [:]

    func begin(_ turn: UUID, chat: UUID?) { current[chat] = turn }

    /// What the chat's latest turn did that can be put back, for the Undo under it.
    func latest(in chat: UUID?) -> [Entry] {
        guard let turn = current[chat] else { return [] }
        return open(in: chat).filter { $0.turn == turn }
    }

    /// Notes something done; returns its id for the model, or nil when it
    /// can't be undone (which the model is told).
    @discardableResult
    func record(_ what: String, chat: UUID?, turn: UUID, undo: (@MainActor () async -> String)?) -> String? {
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        entries.append(Entry(id: id, chat: chat, turn: turn, what: what, undo: undo))
        // A few hundred at most.
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
        return undo == nil ? nil : id
    }

    /// The chat's actions not yet undone, newest first.
    func open(in chat: UUID?) -> [Entry] {
        entries.filter { $0.chat == chat && !$0.undone && $0.undo != nil }.reversed()
    }

    /// The last turn's that can still be undone, newest first.
    func lastTurn(in chat: UUID?) -> [Entry] {
        guard let turn = entries.last(where: { $0.chat == chat && $0.undo != nil })?.turn else { return [] }
        return open(in: chat).filter { $0.turn == turn }
    }

    /// Undoes these, newest first, and says how each went.
    func undo(_ ids: [String], in chat: UUID?) async -> [String] {
        var said: [String] = []
        for entry in open(in: chat) where ids.contains(entry.id) {
            guard let undo = entry.undo, let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            entries[index].undone = true
            said.append("\(entry.id): " + (await undo()))
        }
        let missing = ids.filter { id in !said.contains { $0.hasPrefix(id + ":") } }
        if !missing.isEmpty { said.append("Nothing to undo for \(missing.joined(separator: ", ")); list them with undo_actions.") }
        return said
    }
}
