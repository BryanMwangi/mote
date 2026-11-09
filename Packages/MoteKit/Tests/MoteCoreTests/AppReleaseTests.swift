import Foundation
import Testing

@testable import MoteCore

@Suite("AppRelease")
struct AppReleaseTests {
    private let feed = URL(string: "https://mote.example.com/appcast.json")!

    private func appcast(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    private var valid: [String: Any] {
        [
            "version": "1.2.0",
            "build": 202609270900,
            "url": "https://mote.example.com/Mote.zip",
            "dmg": "https://mote.example.com/Mote.dmg",
            "sha256": " ABCDEF ",
            "signature": "c2lnbmVk",
            "notes": "  ",
            "minimumSystemVersion": "14.0",
        ]
    }

    @Test("A valid feed is parsed")
    func parsesValidFeed() throws {
        let release = try #require(AppRelease(appcast: try appcast(valid), feed: feed, intel: false))
        #expect(release.version == "1.2.0")
        #expect(release.build == 202609270900)
        #expect(release.archive.lastPathComponent == "Mote.zip")
        #expect(release.sha256 == "abcdef")
        #expect(release.signature == "c2lnbmVk")
        #expect(release.notes == nil)
    }

    @Test("Each chip takes its own build: Apple Silicon's at the top, Intel's under intel; none for Intel in an older feed")
    func eachChip() throws {
        var fields = valid
        fields["intel"] = [
            "url": "https://mote.example.com/Mote-Intel.zip", "dmg": "https://mote.example.com/Mote-Intel.dmg",
            "sha256": "1234", "signature": "aW50ZWw=",
        ]
        let apple = try #require(AppRelease(appcast: try appcast(fields), feed: feed, intel: false))
        #expect(apple.archive.lastPathComponent == "Mote.zip")
        #expect(apple.signature == "c2lnbmVk")
        let intel = try #require(AppRelease(appcast: try appcast(fields), feed: feed, intel: true))
        #expect(intel.archive.lastPathComponent == "Mote-Intel.zip")
        #expect(intel.diskImage.lastPathComponent == "Mote-Intel.dmg")
        #expect(intel.sha256 == "1234" && intel.signature == "aW50ZWw=")
        #expect(intel.version == "1.2.0" && intel.notes == nil)
        #expect(AppRelease(appcast: try appcast(valid), feed: feed, intel: true) == nil)
    }

    @Test("The build number may be a string")
    func buildAsString() throws {
        var fields = valid
        fields["build"] = "42"
        #expect(AppRelease(appcast: try appcast(fields), feed: feed, intel: false)?.build == 42)
    }

    @Test("Links to another host are refused")
    func refusesOtherHost() throws {
        var fields = valid
        fields["dmg"] = "https://evil.example.net/Mote.dmg"
        #expect(AppRelease(appcast: try appcast(fields), feed: feed, intel: false) == nil)
    }

    @Test("Plain http is refused unless allowed")
    func refusesHTTP() throws {
        var fields = valid
        fields["url"] = "http://mote.example.com/Mote.zip"
        #expect(AppRelease(appcast: try appcast(fields), feed: feed, intel: false) == nil)
        #expect(AppRelease(appcast: try appcast(fields), feed: feed, allowsHTTP: true, intel: false) != nil)
    }

    @Test("Garbage is not a release")
    func refusesGarbage() {
        #expect(AppRelease(appcast: Data("not json".utf8), feed: feed, intel: false) == nil)
    }

    @Test(
        "Minimum system version",
        arguments: [
            ("14.0", OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0), true),
            ("14.2", OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 9), false),
            ("15", OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0), true),
            ("26.1.2", OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 1), false),
            ("26.1.2", OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2), true),
        ])
    func minimumSystem(required: String, system: OperatingSystemVersion, runs: Bool) {
        let release = AppRelease(version: "1", build: 1, archive: feed, diskImage: feed, minimumSystemVersion: required)
        #expect(release.runs(on: system) == runs)
    }
}
