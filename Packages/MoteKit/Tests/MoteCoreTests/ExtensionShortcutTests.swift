import Testing

@testable import MoteCore

@Suite("ExtensionShortcut")
struct ExtensionShortcutTests {
    @Test("Ctrl is Command on a Mac, MacCtrl is Control, Alt is Option")
    func reads() throws {
        let key = try #require(ExtensionShortcut("Ctrl+Shift+U"))
        #expect(key.matches(key: "u", command: true, shift: true, option: false, control: false))
        #expect(!key.matches(key: "u", command: false, shift: true, option: false, control: true))
        let mac = try #require(ExtensionShortcut("MacCtrl+Alt+Y"))
        #expect(mac.matches(key: "Y", command: false, shift: false, option: true, control: true))
    }

    @Test("A key with no modifier, or two keys, isn't one")
    func refuses() {
        #expect(ExtensionShortcut("Shift+U") == nil)
        #expect(ExtensionShortcut("Ctrl+U+Y") == nil)
        #expect(ExtensionShortcut("") == nil)
    }

    @Test("The Mac key wins over the default")
    func suggested() {
        let manifest: [String: Any] = [
            "commands": ["_execute_sidebar_action": ["suggested_key": ["default": "Ctrl+Shift+Y", "mac": "Command+Shift+U"]]]
        ]
        #expect(ExtensionShortcut.suggested(for: "_execute_sidebar_action", in: manifest)?.key == "u")
        #expect(ExtensionShortcut.suggested(for: "other", in: manifest) == nil)
    }
}
