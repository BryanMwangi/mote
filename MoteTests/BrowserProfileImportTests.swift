import Foundation
import MoteCore
import Testing

@testable import Mote

/// Other browsers' profiles, as Mote finds and brings them: Chrome's and
/// Brave's by Local State's names, Opera's from its own folder and
/// _side_profiles, Zen's from profiles.ini; and each brought into a profile
/// of its own here, its history and Zen's spaces living in it. On a made-up
/// Application Support, from Chromium's own test files (Fixtures/README.md).
@Suite("Importing other browsers' profiles", .serialized)
@MainActor
struct BrowserProfileImportTests {
    private static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/chromium")

    /// Zen's session for its Work profile: one space with a pinned tab and an open one.
    private static let zenSession = """
        {"spaces":[{"uuid":"z-work","name":"Zen Work"}],
         "tabs":[{"entries":[{"url":"https://pinned.example/","title":"Pinned"}],"pinned":true,"zenWorkspace":"z-work"},
                 {"entries":[{"url":"https://open.example/","title":"Open"}],"zenWorkspace":"z-work"}]}
        """

    /// A Chromium profile folder: Chromium's own History, and a Login Data file,
    /// which is what marks a folder as a profile.
    private func chromiumProfile(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appending(path: "History"), to: folder.appending(path: "History"))
        FileManager.default.createFile(atPath: folder.appending(path: "Login Data").path, contents: Data())
    }

    /// Application Support with Chrome, Brave, Opera and Zen as each keeps its profiles.
    private func library() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "mote-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        // Chrome and Brave: Default and Profile 1 beside Local State, which names them.
        for folder in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            let root = base.appending(path: folder, directoryHint: .isDirectory)
            try chromiumProfile(at: root.appending(path: "Default"))
            try chromiumProfile(at: root.appending(path: "Profile 1"))
            let data = try Data(contentsOf: Self.fixtures.appending(path: "Local State"))
            var state = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var profile = try #require(state["profile"] as? [String: Any])
            var names = try #require(profile["info_cache"] as? [String: Any])
            names["Profile 1"] = ["name": "Work"]
            profile["info_cache"] = names
            state["profile"] = profile
            try JSONSerialization.data(withJSONObject: state).write(to: root.appending(path: "Local State"))
        }
        // Opera: its first profile in its folder itself, the others under _side_profiles.
        let opera = base.appending(path: "com.operasoftware.Opera", directoryHint: .isDirectory)
        try chromiumProfile(at: opera)
        try chromiumProfile(at: opera.appending(path: "_side_profiles/side1"))
        // Zen: profiles.ini, and a profile with a session (compressed as Zen writes it).
        let zen = base.appending(path: "zen", directoryHint: .isDirectory)
        let work = zen.appending(path: "Profiles/abc.Work", directoryHint: .isDirectory)
        let main = zen.appending(path: "Profiles/def.Default (release)", directoryHint: .isDirectory)
        for folder in [work, main] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MozLZ4.encode(Data(Self.zenSession.utf8)).write(to: folder.appending(path: "zen-sessions.jsonlz4"))
            FileManager.default.createFile(atPath: folder.appending(path: "places.sqlite").path, contents: Data())
        }
        try """
        [Profile0]
        Name=Default (release)
        IsRelative=1
        Path=Profiles/def.Default (release)
        Default=1

        [Profile1]
        Name=Work
        IsRelative=1
        Path=Profiles/abc.Work
        """.write(to: zen.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
        return base
    }

    @Test("Chrome's and Brave's profiles are found, by the names their Local State gives them")
    func chromiumNames() throws {
        let base = try library()
        defer { try? FileManager.default.removeItem(at: base) }
        let names = Set(ImportSource.found(in: base).map(\.name))
        for browser in ["Chrome", "Brave"] {
            #expect(names.contains("\(browser) — First user"))
            #expect(names.contains("\(browser) — Work"))
        }
    }

    @Test("Opera's first profile is its folder itself; the others are under _side_profiles")
    func opera() throws {
        let base = try library()
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = Set(ImportSource.found(in: base).filter { $0.browser == "Opera" }.map(\.id))
        #expect(ids == ["chromium:Opera:Default", "chromium:Opera:_side_profiles/side1"])
    }

    @Test("Zen's profiles come from profiles.ini, each with its session")
    func zen() throws {
        let base = try library()
        defer { try? FileManager.default.removeItem(at: base) }
        let zens = ImportSource.found(in: base).filter { $0.browser == "Zen" }
        #expect(Set(zens.map(\.profileName)) == ["Default (release)", "Work"])
        #expect(zens.allSatisfy { $0.zen != nil })
    }

    @Test("A Chromium profile's history comes from its own database, its hidden and non-web pages left out")
    func history() throws {
        let base = try library()
        defer { try? FileManager.default.removeItem(at: base) }
        for source in ChromiumImporter.installed(in: base) {
            let places = ChromiumImporter.places(in: source.only(source.name == "Opera" ? "Default" : "Profile 1"))
            #expect(places.count == 11, "\(source.name)")
            #expect(places.first?.url.absoluteString == "http://www.google.com/")
            #expect(!places.contains { $0.url.scheme == "about" })
        }
    }

    @Test("Another browser's profile comes into a profile of its own here: its history, not the default's")
    func historyIntoProfile() async throws {
        let base = try library()
        let profile = "test-" + UUID().uuidString.prefix(8).lowercased()
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: Profiles.shared.folder(of: profile))
        }
        let browser = Browser()
        let source = try #require(ImportSource.found(in: base).first { $0.id == "chromium:Brave:Profile 1" })
        let before = AppState.shared.history.entries(matching: "bleep").count
        let tally = try await browser.bring([.history], from: source, into: profile)
        #expect(tally.history == 11)
        #expect(!Profiles.shared.history(for: profile).entries(matching: "bleep").isEmpty)
        #expect(AppState.shared.history.entries(matching: "bleep").count == before)
        #expect(browser.importingInto == nil)
    }

    @Test("Zen's spaces brought into a profile live in it, with their tabs")
    func zenSpacesIntoProfile() async throws {
        let base = try library()
        let profile = "test-" + UUID().uuidString.prefix(8).lowercased()
        let browser = Browser()
        let before = Set(browser.spaces.map(\.id))
        defer {
            for space in browser.spaces where !before.contains(space.id) { browser.deleteSpace(space.id) }
            try? FileManager.default.removeItem(at: base)
        }
        let source = try #require(ImportSource.found(in: base).first { $0.browser == "Zen" && $0.profileName == "Work" })
        let tally = try await browser.bring([.spaces, .shortcuts], from: source, into: profile)
        #expect(tally.spaces == 1)
        #expect(tally.tabs == 2)
        // A profile's import leaves this Mote's own keys alone.
        #expect(!tally.shortcuts)
        let made = browser.spaces.filter { !before.contains($0.id) }
        #expect(made.map(\.name) == ["Zen Work"])
        #expect(made.allSatisfy { $0.profile == profile })
    }
}
