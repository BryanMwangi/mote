import Foundation
import MoteAI

/// The assistant's task list for a long piece of work (`Conversation.tasks`):
/// set at the start, marked as it goes, and given back to it whenever its
/// session starts afresh, so summarising never loses where things stand.
extension AssistantTools {
    var taskTools: [Tool] {
        [
            Tool(
                name: "task_list",
                description:
                    "Your task list for this chat, for work of several steps (applications, a site move, a form a page at a time). Set it at the start (set, with items), mark each item as it goes (done or skip, with a short note of where it stands: the tab, the site, the reference), add items found on the way (add), or read it. It survives the chat being summarised, so keep it current; while items are open in Auto mode, Mote has you carry on.",
                schema:
                    #"{"type":"object","properties":{"action":{"type":"string","enum":["set","add","done","skip","reopen","read"]},"items":{"type":"array","items":{"type":"string"},"description":"For set or add: the items, one short line each"},"id":{"type":"integer","description":"For done, skip or reopen: the item's number"},"note":{"type":"string","description":"Where it stands, in a few words"}},"required":["action"]}"#)
        ]
    }

    func runTasks(_ call: ToolCall) async -> String? {
        guard call.name == "task_list" else { return nil }
        guard let chat, let conversation = Assistant.shared.conversation(chat) else { return "There's no chat to keep a list in." }
        let input = call.input
        let items = input["items"]?.array.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        let note = input["note"]?.string
        switch input["action"]?.string {
        case "set":
            guard !items.isEmpty else { return "Give the items to set." }
            conversation.setTasks(items)
        case "add":
            guard !items.isEmpty else { return "Give the items to add." }
            conversation.addTasks(items)
        case let action? where ["done", "skip", "reopen"].contains(action):
            guard let id = input["id"]?.int else { return "Give the item's number." }
            let state: TaskItem.State = action == "done" ? .done : action == "skip" ? .skipped : .open
            guard conversation.markTask(id, state, note: note) else { return "There's no item \(id); read the list." }
        case "read":
            break
        default:
            return "Say what to do: set, add, done, skip, reopen or read."
        }
        return conversation.tasks.isEmpty ? "The list is empty." : TaskList.told(conversation.tasks)
    }
}
