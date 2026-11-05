import Foundation
import MoteCore

/// Each space's open tabs, saved so they come back at launch: address,
/// title, essential letter, pinned or not, given name, and which tab was in front.
enum Session {
    nonisolated struct Entry: Codable, Sendable {
        var url: String
        var title: String
        var pin: String?
        /// A pinned tab; nil in older files and for the others.
        var kept: Bool?
        /// A name the user gave the tab.
        var name: String?
        /// A chat tab: the kept chat it shows, by id; `url` is empty.
        var chat: String?
        /// An essential or pinned tab's id, the same in every window (see
        /// Browser+Held.swift); nil in older files and for the others.
        var held: String?
        /// An essential or pinned tab's pinned address, when it has browsed
        /// on; nil in older files, where it's `url`.
        var home: String?
        /// A pinned tab's folder; nil in older files and for the others.
        var folder: String?
    }

    nonisolated struct Saved: Codable, Sendable {
        var tabs: [Entry]
        var active: Int
        /// Split views, by their tabs' places in `tabs`; nil in older files.
        var splits: [SplitLayout<Int>]? = nil

        static let empty = Saved(tabs: [], active: 0)
    }

    /// session.json for the first space, session-<id>.json for others.
    private static func file(_ space: UUID) -> JSONFile<Saved> {
        JSONFile(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func read(space: UUID = Space.firstID) -> Saved {
        file(space).load() ?? .empty
    }

    /// `now` saves before returning, for quitting.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ saved: Saved) {
        now ? file(space).saveNow(saved) : file(space).save(saved)
    }

    static func erase(space: UUID) {
        if space != Space.firstID { file(space).delete() }
    }

    // MARK: - Windows opened since the main one

    /// Such a window's open tabs in a space; its essentials and pinned tabs
    /// are the space's, kept in the main window's file.
    private static func file(window: UUID, space: UUID) -> JSONFile<Saved> {
        JSONFile("window-\(window.uuidString)-session-\(space.uuidString).json")
    }

    static func read(window: UUID, space: UUID) -> Saved {
        file(window: window, space: space).load() ?? .empty
    }

    static func write(now: Bool = false, window: UUID, space: UUID, _ saved: Saved) {
        now ? file(window: window, space: space).saveNow(saved) : file(window: window, space: space).save(saved)
    }

    static func erase(window: UUID, spaces: [UUID]) {
        for space in spaces { file(window: window, space: space).delete() }
    }
}
