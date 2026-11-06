import Foundation
import MoteCore
import SwiftUI

/// Zen's profiles on this Mac, and their spaces and tabs as Mote will have
/// them. Reading Zen's files is ZenSession's job; this finds them.
nonisolated enum ZenImporter {
    struct Profile: Identifiable, Hashable {
        let name: String
        let folder: URL
        let isDefault: Bool

        var id: String { folder.path }
    }

    enum Trouble: Error {
        /// No session file Zen wrote could be read.
        case unreadable
    }

    private static let root = URL.applicationSupportDirectory.appending(path: "zen", directoryHint: .isDirectory)

    /// The profiles with a session to bring, the default first.
    static func profiles() -> [Profile] {
        guard let list = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
        let installs = try? String(contentsOf: root.appending(path: "installs.ini"), encoding: .utf8)
        return FirefoxProfiles.parse(profiles: list, installs: installs).compactMap { found in
            let folder = found.isRelative ? root.appending(path: found.path, directoryHint: .isDirectory) : URL(fileURLWithPath: found.path)
            guard sessionFiles(in: folder).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            return Profile(name: found.name, folder: folder, isDefault: found.isDefault)
        }
    }

    /// The keys a profile has: its changes over Zen's own (`customKeys.json`,
    /// as Zen keeps them now), or every key in its old file.
    static func shortcuts(in profile: Profile) -> Shortcuts? {
        shortcuts(from: profile.folder.appending(path: "customKeys.json"))
            ?? shortcuts(from: profile.folder.appending(path: "zen-keyboard-shortcuts.json"))
    }

    /// The keys in either of Zen's files, picked out by what's in it.
    static func shortcuts(from file: URL) -> Shortcuts? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ZenKeys.shortcuts(customKeys: data) ?? ZenKeys.shortcuts(legacy: data)
    }

    /// Zen's session, then its last clean backup.
    private static func sessionFiles(in folder: URL) -> [URL] {
        [folder.appending(path: "zen-sessions.jsonlz4"), folder.appending(path: "zen-sessions-backup/clean.jsonlz4")]
    }

    static func plan(for profile: Profile) throws -> ZenImportPlan {
        for file in sessionFiles(in: profile.folder) {
            guard let data = try? Data(contentsOf: file), let session = try? ZenSession.read(data), !session.spaces.isEmpty else {
                continue
            }
            return ZenImportPlan(session, containers: containerNames(in: profile.folder))
        }
        throw Trouble.unreadable
    }

    /// The names users gave their containers. Firefox's own ones carry a
    /// translation key instead of a name, and are left out.
    private static func containerNames(in folder: URL) -> [Int: String] {
        struct File: Decodable {
            struct Identity: Decodable {
                let userContextId: Int
                let name: String?
            }
            let identities: [Identity]
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "containers.json")),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return Dictionary(
            file.identities.compactMap { identity in identity.name.flatMap { $0.isEmpty ? nil : (identity.userContextId, $0) } },
            uniquingKeysWith: { first, _ in first })
    }
}

extension Browser {
    struct ZenBrought: Equatable {
        var spaces = 0
        var tabs = 0
        /// Spaces brought before, left as they are.
        var already = 0
    }

    /// Adds Zen's spaces after Mote's own, each with its tabs saved as a
    /// session, and turns spaces on. Tabs wait asleep until opened. A space
    /// brought before is left alone, so importing again adds nothing twice.
    @discardableResult
    func importZen(_ plan: ZenImportPlan) -> ZenBrought {
        var brought = ZenBrought()
        let known = Set(spaces.compactMap(\.origin))
        var list = SpaceList(saved: spaces)
        var made: [Space] = []
        for zen in plan.spaces {
            let origin = "zen:\(zen.zenID)"
            guard !known.contains(origin) else {
                brought.already += 1
                continue
            }
            let space = Space(
                id: UUID(), name: zen.name, icon: zen.icon ?? list.freeIcon, sharesSignIns: !zen.ownData, origin: origin)
            list.add(space)
            made.append(space)
            let entries = zen.tabs.map { tab in
                Session.Entry(
                    url: tab.url.absoluteString, title: tab.title, pin: tab.tier == .essential ? TabLabel.monogram(for: tab.url) : nil,
                    kept: tab.tier == .pinned ? true : nil, name: tab.name)
            }
            // In front: the first open tab, or the first of any.
            let front = zen.tabs.firstIndex { $0.tier == .loose } ?? 0
            Session.write(now: true, space: space.id, .init(tabs: entries, active: front))
            brought.spaces += 1
            brought.tabs += entries.count
        }
        guard !made.isEmpty else { return brought }
        addSpaces(made)
        // Turning spaces on builds their rows; when they're on already, the new ones are built here.
        if prefs.usesSpaces { preloadSpaces() } else { prefs.usesSpaces = true }
        return brought
    }
}

/// Settings › General › Import from Zen: which profile, what will come, and
/// what came.
struct ZenImportPanel: View {
    @ObservedObject var browser: Browser

    @State private var profiles: [ZenImporter.Profile] = []
    @State private var profile: ZenImporter.Profile?
    @State private var plan: ZenImportPlan?
    @State private var trouble: String?
    @State private var brought: Browser.ZenBrought?

    private func close() { browser.importingZen = false }

    var body: some View {
        Plate("Import from Zen", width: 520, close: close) {
            if profiles.count > 1, brought == nil {
                Segmented(
                    options: profiles.map { ($0, $0.name) },
                    selection: Binding(get: { profile ?? profiles[0] }, set: { pick($0) }))
            }
            if let brought {
                Card {
                    Line(summary(brought)) { EmptyView() }
                }
            } else if let plan, !plan.spaces.isEmpty {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(plan.spaces.enumerated()), id: \.element.zenID) { index, space in
                            if index > 0 { Rule() }
                            SpaceLine(space: space, already: browser.spaces.contains { $0.origin == "zen:\(space.zenID)" })
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 360)
            } else {
                Card { EmptyState(trouble ?? "No spaces found in this profile.") }
            }
        } foot: {
            HStack(spacing: 8) {
                Text(
                    brought == nil ? "Nothing in Zen changes. Sign-ins and history come in a later update." : "Tabs open as you click them."
                )
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if brought == nil {
                    Pill("Cancel", action: close)
                    Pill("Import", filled: true) {
                        if let plan { brought = browser.importZen(plan) }
                    }
                    .disabled(plan?.spaces.isEmpty != false)
                } else {
                    Pill("Done", filled: true, action: close)
                }
            }
        }
        .onAppear {
            profiles = ZenImporter.profiles()
            if let first = profiles.first { pick(first) } else { trouble = "Zen isn't on this Mac, or has nothing saved yet." }
        }
    }

    private func pick(_ chosen: ZenImporter.Profile) {
        profile = chosen
        do {
            plan = try ZenImporter.plan(for: chosen)
            trouble = nil
        } catch {
            plan = nil
            trouble = "Zen's saved tabs in “\(chosen.name)” couldn't be read."
        }
    }

    private func summary(_ brought: Browser.ZenBrought) -> String {
        var parts = [
            "\(brought.spaces) \(brought.spaces == 1 ? "space" : "spaces") and \(brought.tabs) \(brought.tabs == 1 ? "tab" : "tabs") brought over."
        ]
        if brought.already > 0 { parts.append("\(brought.already) already here, left as they were.") }
        return parts.joined(separator: " ")
    }

    private struct SpaceLine: View {
        let space: ZenImportPlan.Space
        let already: Bool

        var body: some View {
            HStack(spacing: 12) {
                SpaceGlyph(space.icon ?? "square.stack", size: 13).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .opacity(already ? 0.5 : 1)
        }

        private var detail: String {
            if already { return "Already brought over" }
            var parts: [String] = []
            for (tier, word) in [(TabTier.essential, "essential"), (.pinned, "pinned"), (.loose, "open")] {
                let count = space.count(tier)
                if count > 0 { parts.append("\(count) \(word)") }
            }
            parts.append(space.ownData ? "its own sign-ins" : "shared sign-ins")
            return parts.joined(separator: " · ")
        }
    }
}
