import Combine
import Foundation

/// What the assistant keeps from chat to chat: things the person asked it to
/// remember, or plainly lasting preferences. Told to every chat; listed and
/// removable in Settings › AI › Memory; never from a private window.
@MainActor
final class Memories: ObservableObject {
    static let shared = Memories()

    nonisolated struct Memory: Codable, Identifiable, Equatable, Sendable {
        var id = String(UUID().uuidString.prefix(6)).lowercased()
        var text: String
        var made = Date()
    }

    @Published private(set) var all: [Memory]
    /// Settings › AI › Memory: off, nothing is kept or told.
    @Published var on: Bool {
        didSet { UserDefaults.standard.set(on, forKey: Self.onKey) }
    }
    private let file = JSONFile<[Memory]>("memories.json")
    private static let onKey = "ai.memory"
    /// The most kept; the oldest go first.
    static let most = 100

    private init() {
        all = file.load() ?? []
        on = UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true
    }

    @discardableResult
    func remember(_ text: String) -> Memory {
        let memory = Memory(text: String(text.prefix(500)))
        all.append(memory)
        if all.count > Self.most { all.removeFirst(all.count - Self.most) }
        file.save(all)
        return memory
    }

    func forget(_ id: String) -> Memory? {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let gone = all.remove(at: index)
        file.save(all)
        return gone
    }

    func forgetAll() {
        all = []
        file.save(all)
    }

    /// For every chat's instructions: what's kept, by id.
    var note: String? {
        guard on, !all.isEmpty else { return nil }
        return "What the person has asked you to remember (forget one with forget and its id):\n"
            + all.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
    }
}
