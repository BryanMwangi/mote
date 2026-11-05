import CryptoKit
import Foundation
import Testing

@testable import MoteCore

@Suite("AMO")
struct AMOTests {
    /// Mozilla's reply for uBlock Origin, trimmed.
    private let reply = Data(
        """
        {"guid": "uBlock0@raymondhill.net", "slug": "ublock-origin", "default_locale": "en-US",
         "name": {"de": "uBlock Origin", "en-US": "uBlock Origin"},
         "current_version": {"version": "1.75.4", "file": {
           "url": "https://addons.mozilla.org/firefox/downloads/file/5203014/ublock_origin-1.75.4.xpi",
           "hash": "sha256:E2DF503CCE7CF5069130618C349695F62BDDDB9EB8C189156D027269AE4AE267"}}}
        """.utf8)

    @Test("An add-on's page, in any language, or amo:slug, names it; other addresses don't")
    func slugs() {
        #expect(AMO.slug(in: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/") == "ublock-origin")
        #expect(
            AMO.slug(in: "https://addons.mozilla.org/firefox/addon/bitwarden-password-manager/reviews/") == "bitwarden-password-manager")
        #expect(AMO.slug(in: "amo:darkreader") == "darkreader")
        #expect(AMO.slug(in: "https://chromewebstore.google.com/detail/x/abc") == nil)
        #expect(AMO.slug(in: "https://addons.mozilla.org/en-US/firefox/") == nil)
        #expect(AMO.slug(in: "amo:../etc") == nil)
    }

    @Test("The API's reply gives the latest file and its hash")
    func addon() throws {
        let addon = try #require(AMO.addon(in: reply))
        #expect(addon.slug == "ublock-origin" && addon.guid == "uBlock0@raymondhill.net" && addon.name == "uBlock Origin")
        #expect(addon.version == "1.75.4" && addon.file.lastPathComponent == "ublock_origin-1.75.4.xpi")
        #expect(addon.sha256 == "e2df503cce7cf5069130618c349695f62bdddb9eb8c189156d027269ae4ae267")
        #expect(AMO.addon(in: Data("{}".utf8)) == nil)
    }

    @Test("A file is only taken when its hash is what the API said")
    func verify() throws {
        let file = Data("an add-on".utf8)
        let hash = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        let addon = AMO.Addon(slug: "a", guid: "a@b", name: "A", version: "1", file: URL(string: "https://x/a.xpi")!, sha256: hash)
        #expect(AMO.verified(file, as: addon))
        #expect(!AMO.verified(Data("something else".utf8), as: addon))
    }

    @Test("Firefox manifests are known by their gecko id; what WebKit lacks is named")
    func manifests() {
        #expect(AMO.isFirefox(manifest: ["browser_specific_settings": ["gecko": ["id": "a@b"]]]))
        #expect(AMO.isFirefox(manifest: ["applications": ["gecko": ["id": "a@b"]]]))
        #expect(!AMO.isFirefox(manifest: ["name": "Chrome one"]))
        let missing = AMO.unsupported(manifest: ["permissions": ["storage", "contextualIdentities", "dns"], "sidebar_action": [:]])
        #expect(missing.count == 3)
        #expect(AMO.unsupported(manifest: ["permissions": ["storage", "tabs"]]).isEmpty)
    }
}
