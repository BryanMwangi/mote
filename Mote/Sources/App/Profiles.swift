import AppKit
import Combine
import WebKit

/// Profiles, as Firefox's (and so Zen's): Motes that share nothing. Each
/// runs as its own Mote, with its own folder, settings, website data,
/// passwords and extensions (see Storage); the first is the data Mote
/// always had. The list is kept in the first's folder, for every profile
/// to read.
@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    nonisolated struct Profile: Codable, Identifiable, Equatable, Sendable {
        let id: String
        var name: String
    }

    /// The profiles besides the first.
    @Published private(set) var list: [Profile]
    private let file = JSONFile<[Profile]>(at: Storage.base.appending(path: "profiles.json"))

    private init() { list = file.load() ?? [] }

    /// This Mote's profile's name; the first is "Default".
    var current: String { Storage.profile.flatMap { id in list.first { $0.id == id }?.name } ?? "Default" }

    /// A new profile, opened at once.
    func add(named name: String) {
        let profile = Profile(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name.isEmpty ? "Profile" : name)
        list.append(profile)
        file.save(list)
        open(profile.id)
    }

    func rename(_ id: String, to name: String) {
        guard !name.isEmpty, let at = list.firstIndex(where: { $0.id == id }) else { return }
        list[at].name = name
        file.save(list)
    }

    /// A profile as its own Mote, as Firefox's -P does: nil for the first.
    func open(_ id: String?) {
        let setup = NSWorkspace.OpenConfiguration()
        setup.createsNewApplicationInstance = true
        var environment = ProcessInfo.processInfo.environment.filter { $0.key == "MOTE_PROBE" }
        if let id { environment["MOTE_PROFILE"] = id }
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
}
