import AppKit
import Combine
import SwiftUI
import WebKit

/// Profiles, as Firefox's (and so Zen's): Motes that share nothing. Each
/// runs as its own Mote, with its own folder, settings, website data,
/// passwords and extensions (see Storage); the first is the data Mote
/// always had. The list is kept in the first's folder, for every profile
/// to read. A new profile starts from the first's settings, so it opens
/// straight to the browser.
@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    /// What a profile wears: a symbol (or its initial) on a colour, or a
    /// picture, already cropped round.
    nonisolated struct Avatar: Codable, Equatable, Sendable {
        var symbol: String?
        var color = "#6cbad9"
        /// A PNG in the profile's folder.
        var image: String?
        /// Worn on the Dock icon while this profile runs (not the first's).
        var inDock = true

        init(symbol: String? = nil, color: String = "#6cbad9") {
            self.symbol = symbol
            self.color = color
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? color
            image = try c.decodeIfPresent(String.self, forKey: .image)
            inDock = try c.decodeIfPresent(Bool.self, forKey: .inDock) ?? true
        }
    }

    nonisolated struct Profile: Codable, Identifiable, Equatable, Sendable {
        let id: String
        var name: String
        var avatar: Avatar

        init(id: String, name: String, avatar: Avatar) {
            self.id = id
            self.name = name
            self.avatar = avatar
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            avatar = try c.decodeIfPresent(Avatar.self, forKey: .avatar) ?? Avatar()
        }
    }

    /// The profiles besides the first.
    @Published private(set) var list: [Profile]
    /// The first profile's avatar, kept beside the list.
    @Published private(set) var base: Avatar
    private let file = JSONFile<[Profile]>(at: Storage.base.appending(path: "profiles.json"))
    private let baseFile = JSONFile<Avatar>(at: Storage.base.appending(path: "profile.json"))

    private init() {
        list = file.load() ?? []
        base = baseFile.load() ?? Avatar(symbol: "person.fill", color: "#ff8558")
    }

    /// This Mote's profile's name; the first is "Default".
    var current: String { name(of: Storage.profile) }

    func name(of id: String?) -> String { id.flatMap { id in list.first { $0.id == id }?.name } ?? "Default" }

    func avatar(of id: String?) -> Avatar { id.flatMap { id in list.first { $0.id == id }?.avatar } ?? base }

    /// Where a profile keeps its things: the world's folder for the first.
    func folder(of id: String?) -> URL { id.map { Storage.base.appending(path: "Profiles/\($0)") } ?? Storage.base }

    func picture(of id: String?) -> NSImage? {
        avatar(of: id).image.flatMap { NSImage(contentsOf: folder(of: id).appending(path: $0)) }
    }

    /// A new profile, with the first's settings, opened at once.
    /// `importing`: another browser's things for it to bring once it opens (see importOnLaunch).
    func add(named name: String, avatar: Avatar, picture: NSImage? = nil, importing: String? = nil) {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        list.append(Profile(id: id, name: name.isEmpty ? "Profile" : name, avatar: avatar))
        if let picture { keep(picture, for: id) }
        file.save(list)
        copySettings(to: id)
        open(id, importing: importing)
    }

    func rename(_ id: String, to name: String) {
        guard !name.isEmpty, let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].name = name
        file.save(list)
    }

    /// A new avatar, with a new picture when there is one.
    func dress(_ id: String?, as avatar: Avatar, picture: NSImage? = nil) {
        set(avatar, for: id)
        if let picture { keep(picture, for: id) }
        dressDock()
    }

    func showInDock(_ id: String, _ on: Bool) {
        var avatar = avatar(of: id)
        avatar.inDock = on
        set(avatar, for: id)
        dressDock()
    }

    private func set(_ avatar: Avatar, for id: String?) {
        if let id, let at = list.firstIndex(where: { $0.id == id }) {
            list[at].avatar = avatar
            file.save(list)
        } else if id == nil {
            base = avatar
            baseFile.save(base)
        }
    }

    /// Saves the picture as the avatar's, under a new name so menus and
    /// the Dock don't keep the old one, and drops the old file.
    private func keep(_ picture: NSImage, for id: String?) {
        let folder = folder(of: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let name = "avatar-\(UUID().uuidString.prefix(6)).png"
        guard (try? png.write(to: folder.appending(path: name))) != nil else { return }
        var avatar = avatar(of: id)
        if let old = avatar.image { try? FileManager.default.removeItem(at: folder.appending(path: old)) }
        avatar.image = name
        set(avatar, for: id)
    }

    /// The first profile's settings as the new one's start: its look, layout,
    /// engine, keys, ad blocking, AI and having been welcomed; not what AppKit
    /// keeps (window frames), nor which space was in front, nor the bench.
    private func copySettings(to id: String) {
        let from = Storage.suite(for: nil) ?? Bundle.main.bundleIdentifier ?? ""
        guard let to = Storage.suite(for: id), var settings = UserDefaults.standard.persistentDomain(forName: from) else { return }
        settings = settings.filter { key, _ in
            !["NS", "Apple", "com.apple", "space.current", "bench", "Sparkle"].contains { key.hasPrefix($0) }
        }
        UserDefaults.standard.setPersistentDomain(settings, forName: to)
    }

    /// A profile as its own Mote, as Firefox's -P does: nil for the first.
    func open(_ id: String?, importing: String? = nil) {
        let setup = NSWorkspace.OpenConfiguration()
        setup.createsNewApplicationInstance = true
        var environment = ProcessInfo.processInfo.environment.filter { $0.key == "MOTE_PROBE" }
        if let id { environment["MOTE_PROFILE"] = id }
        if let importing { environment["MOTE_IMPORT"] = importing }
        setup.environment = environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: setup)
    }

    /// Deletes a profile and everything it kept: its folder, its settings and
    /// its website and extension data. Not the one running here.
    func delete(_ id: String) {
        guard id != Storage.profile else { return }
        list.removeAll { $0.id == id }
        file.save(list)
        try? FileManager.default.removeItem(at: Storage.base.appending(path: "Profiles/\(id)"))
        if let suite = Storage.suite(for: id) { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for kind: UInt32 in [1, 2] {
            WKWebsiteDataStore.remove(forIdentifier: Storage.profileStore(kind, id)) { _ in }
        }
    }

    // MARK: - Pictures of it

    /// The avatar drawn to an image, for menus and the Dock.
    func image(of id: String?, size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: ProfileAvatar(id: id, size: size, profiles: self))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }

    /// The Dock icon wears this profile's avatar, as Chrome's does, while
    /// there is more than one profile and this isn't the first; round, at
    /// the bottom right.
    func dressDock() {
        let worn = Storage.profile.flatMap { id in avatar(of: id).inDock ? dockIcon(for: id) : nil }
        NSApp.applicationIconImage = worn
    }

    /// Mote's icon with a profile's avatar on it; nil for the first, or an
    /// unknown one.
    func dockIcon(for id: String) -> NSImage? {
        guard list.contains(where: { $0.id == id }), let icon = NSImage(named: NSImage.applicationIconName)?.copy() as? NSImage
        else { return nil }
        let side: CGFloat = 512
        let badge = image(of: id, size: 200)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: rect)
            badge.draw(in: NSRect(x: side - 222, y: 22, width: 200, height: 200))
            return true
        }
    }
}
