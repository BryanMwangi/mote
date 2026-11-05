/// A button at the sidebar's foot, beside the spaces. Which show, and in
/// what order, is the user's (Settings › Tabs, the plus menu, a right-click).
public enum FootButton: String, Codable, CaseIterable, Sendable {
    case chats, downloads, history, bookmarks, library, passwords, screenshot, newWindow, settings

    public var title: String {
        switch self {
        case .chats: "Chats"
        case .downloads: "Downloads"
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .library: "Library"
        case .passwords: "Passwords"
        case .screenshot: "Screenshot"
        case .newWindow: "New Window"
        case .settings: "Settings"
        }
    }

    /// What a new sidebar has.
    public static let standard: [FootButton] = [.chats, .library]

    /// The kept order, from how it's saved: unknown names dropped, each once.
    public static func read(_ saved: [String]?) -> [FootButton] {
        guard let saved else { return standard }
        var seen = Set<FootButton>()
        return saved.compactMap(FootButton.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    /// `list` with `button` moved `by` places, kept within it.
    public static func moving(_ button: FootButton, by offset: Int, in list: [FootButton]) -> [FootButton] {
        guard let at = list.firstIndex(of: button) else { return list }
        var list = list
        list.remove(at: at)
        list.insert(button, at: min(max(at + offset, 0), list.count))
        return list
    }
}
