import Foundation
import Testing

@testable import MoteCore

@Suite("Add-ons from other browsers")
struct AddOnsTests {
    @Test("Firefox: the user's own extensions that are on; not themes, built-in ones or those turned off")
    func firefox() {
        let json = """
            {"addons": [
              {"id": "uBlock0@raymondhill.net", "type": "extension", "active": true, "location": "app-profile",
               "defaultLocale": {"name": "uBlock Origin"}},
              {"id": "{446900e4-71c2-419f-a6a7-df9c091e268b}", "type": "extension", "active": true, "location": "app-profile",
               "defaultLocale": {"name": "Bitwarden Password Manager"}},
              {"id": "off@example", "type": "extension", "active": false, "location": "app-profile", "defaultLocale": {"name": "Off"}},
              {"id": "theme@example", "type": "theme", "active": true, "location": "app-profile", "defaultLocale": {"name": "Dark"}},
              {"id": "screenshots@mozilla.org", "type": "extension", "active": true, "location": "app-system-defaults",
               "defaultLocale": {"name": "Screenshots"}}
            ]}
            """
        let found = AddOns.firefox(json: Data(json.utf8))
        #expect(found.map(\.name) == ["uBlock Origin", "Bitwarden Password Manager"])
        #expect(found.allSatisfy { $0.store == .firefox })
    }

    @Test("uBlock Origin for Firefox comes as its Lite version, which WebKit can run; others as they are")
    func forWebKit() {
        let ubo = AddOns.Found(name: "uBlock Origin", id: "uBlock0@raymondhill.net", store: .firefox).forWebKit
        #expect(ubo == AddOns.Found(name: "uBlock Origin Lite", id: "ddkjiahejlhfcafbddmgiahcphecmpfh", store: .chrome))
        let other = AddOns.Found(name: "Bitwarden", id: "{446900e4}", store: .firefox)
        #expect(other.forWebKit == other)
    }

    @Test("Chromium: Web Store extensions that are on, named from the file or the folder")
    func chromium() {
        let json = """
            {"extensions": {"settings": {
              "aaaa": {"location": 1, "from_webstore": true, "state": 1, "manifest": {"name": "Dark Reader"}},
              "bbbb": {"location": 1, "from_webstore": true, "disable_reasons": []},
              "cccc": {"location": 5, "manifest": {"name": "Built in"}},
              "dddd": {"location": 1, "state": 0, "manifest": {"name": "Turned off"}},
              "eeee": {"location": 1, "disable_reasons": [1], "manifest": {"name": "Disabled"}}
            }}}
            """
        let found = AddOns.chromium(preferences: Data(json.utf8)) { $0 == "bbbb" ? "Bitwarden" : nil }
        #expect(found.map(\.name) == ["Bitwarden", "Dark Reader"])
        #expect(found.map(\.id) == ["bbbb", "aaaa"])
    }

    @Test("A manifest's name, or its default locale's message")
    func names() {
        #expect(AddOns.name(manifest: Data(#"{"name": "Plain"}"#.utf8)) { _ in nil } == "Plain")
        let manifest = Data(#"{"name": "__MSG_extName__", "default_locale": "en"}"#.utf8)
        let messages = Data(#"{"extName": {"message": "From Messages"}}"#.utf8)
        #expect(AddOns.name(manifest: manifest) { $0 == "en" ? messages : nil } == "From Messages")
    }
}
