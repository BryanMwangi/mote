import Foundation
import WebKit

/// Where Mote keeps things. A test run (a Debug build, or MOTE_PROBE set)
/// lives in a world of its own and never touches the real folder, settings
/// or WebKit stores.
enum Storage {
    /// Debug builds are always a test run, so real data never depends on
    /// remembering a flag.
    nonisolated static var testing: Bool {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["MOTE_PROBE"] != nil
        #endif
    }

    /// The test world's name: "test", or MOTE_PROBE's value cleaned up, so
    /// test sessions side by side don't share anything. Nil for the real one.
    static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["MOTE_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return ["", "1", "test"].contains(asked) ? "test" : asked
    }()

    /// A test run for measuring (MOTE_MEASURE too), which keeps the release
    /// build's background throttling and App Nap.
    static var measuring: Bool { testing && ProcessInfo.processInfo.environment["MOTE_MEASURE"] != nil }

    /// The profile this Mote runs (MOTE_PROFILE, set when one is opened from
    /// another): its id, or nil for the first, whose data is where it always was.
    static let profile: String? = {
        let asked = (ProcessInfo.processInfo.environment["MOTE_PROFILE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty ? nil : asked
    }()

    /// The world's folder, where the first profile's data lives and the list
    /// of profiles is kept.
    static let base = URL.applicationSupportDirectory.appending(path: world.map { "Mote (\($0))" } ?? "Mote", directoryHint: .isDirectory)

    /// This profile's folder in Application Support: another profile's is
    /// under Profiles/ in the first's.
    static let folder = profile.map { base.appending(path: "Profiles/\($0)", directoryHint: .isDirectory) } ?? base

    static func file(_ name: String) -> URL { folder.appending(path: name) }

    /// Sets aside a file that no longer reads, so the next save doesn't
    /// overwrite it. If that fails, nothing more is done: the read already
    /// came back empty.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let aside = file.deletingLastPathComponent()
            .appending(path: "\(file.deletingPathExtension().lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// The settings: the standard defaults, or the test world's own suite.
    static let settings: UserDefaults = {
        guard let suite = suite(for: profile) else { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// A profile's settings suite; nil for the real first profile's, the
    /// standard defaults.
    static func suite(for profile: String?) -> String? {
        let world = world.map { "io.github.mote-browser.mote.test" + ($0 == "test" ? "" : ".\($0)") }
        guard let profile else { return world }
        return (world ?? "io.github.mote-browser.mote") + ".profile.\(profile)"
    }

    // MARK: - WebKit

    /// The website data store. WebKit's default one belongs to the bundle, not
    /// the folder, so a test world uses one with a fixed identifier instead,
    /// and never shares cookies or sign-ins with the real browser.
    static var websites: WKWebsiteDataStore {
        if let profile { return WKWebsiteDataStore(forIdentifier: profileStore(1, profile)) }
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// A profile's fixed store identifier (kind 1 for websites, 2 for
    /// extensions), from a hash of its world and id, apart from the test
    /// worlds' (5E4C…) and from any space's.
    static func profileStore(_ kind: UInt32, _ profile: String) -> UUID {
        let hash = ((world ?? "") + "/" + profile).utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return UUID(uuidString: String(format: "5E4D%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind))!
    }

    /// Running under another bundle id, which has its own WebKit container
    /// and can use the default stores (they keep extension workers alive
    /// differently from identified ones).
    static var ownContainer: Bool { Bundle.main.bundleIdentifier != "io.github.mote-browser.mote" }

    /// A test world's fixed store identifier (kind 1 for websites, 2 for
    /// extensions): 5E4C0000-0000-4000-8000-00000000000k for "test", which
    /// `make fresh` wipes, and for named worlds a 32-bit FNV-1a hash of the
    /// name in the second and third groups.
    static func probeStore(_ kind: UInt32) -> UUID {
        let hash: UInt32 =
            world.flatMap { $0 == "test" ? nil : $0 }.map { name in
                name.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
            } ?? 0
        return UUID(uuidString: String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind))!
    }
}
