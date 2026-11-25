import Foundation

/// A step of a long task, on the list the assistant keeps for a chat
/// (`Conversation.tasks`): kept apart from the messages, so summarising a
/// long chat never loses where each part of the work stands.
public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case open, done, skipped
    }

    public var id: Int
    public var text: String
    public var state: State
    /// Where it stands: the tab, the site, a reference, why it was skipped.
    public var note: String?

    public init(id: Int, text: String, state: State = .open, note: String? = nil) {
        self.id = id
        self.text = text
        self.state = state
        self.note = note
    }
}

public enum TaskList {
    /// The list as the model is told it, each item with its number and state.
    public static func told(_ items: [TaskItem]) -> String {
        guard !items.isEmpty else { return "" }
        let open = items.filter { $0.state == .open }.count
        let lines = items.map { item in
            let mark = switch item.state {
            case .open: "[ ]"
            case .done: "[x]"
            case .skipped: "[-]"
            }
            return "\(mark) \(item.id). \(item.text)" + (item.note.map { " (\($0))" } ?? "")
        }
        return "Your task list for this chat, \(open) of \(items.count) open (keep it current with task_list; it survives summarising):\n"
            + lines.joined(separator: "\n")
    }
}
