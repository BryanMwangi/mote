/// Commands found by typing their name into the address field: "compact" finds
/// Compact Mode, "nw" New Window. Scored with exact and prefix matches always first.
public enum QuickActions {
    /// How many show among the suggestions at most.
    public static let most = 3
    static let threshold = 92
    static let exact = 1_000_000
    static let prefix = 100_000

    /// The ids whose titles `typed` finds, best first: none for two
    /// characters or fewer.
    public static func ranked<ID>(_ actions: [(id: ID, title: String)], for typed: String) -> [ID] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count > 2 else { return [] }
        return
            actions
            .map { (id: $0.id, score: score($0.title, query)) }
            .filter { $0.score > threshold }
            .sorted { $0.score > $1.score }
            .prefix(most)
            .map(\.id)
    }

    /// Every character of the query found in order, more for matches at a word's start and in runs, less for gaps.
    static func score(_ target: String, _ query: String) -> Int {
        let target = Array(target.lowercased()), query = Array(query.lowercased())
        guard !query.isEmpty, query.count <= target.count else { return 0 }
        if target == query { return exact }
        if target.starts(with: query) { return prefix + query.count }
        var score = 0, next = 0, last = -1, run = 0
        for (index, character) in target.enumerated() where next < query.count && character == query[next] {
            var bonus = 10
            if index == 0 || [" ", "-", "_"].contains(target[index - 1]) { bonus += 15 }
            if last == index - 1 {
                run += 1
                bonus += 20 * run
            } else {
                run = 0
            }
            if last != -1 { bonus -= min(index - last - 1, 10) }
            score += bonus
            last = index
            next += 1
        }
        return next == query.count ? score : 0
    }
}
