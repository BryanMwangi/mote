import Foundation
import Testing

@testable import MoteCore

/// Zen's files as Zen writes them: the old file's entries in the shape of
/// Zen's own tests (`src/zen/tests/kbs`, public domain) and a Mac profile's,
/// and `customKeys.json` as Firefox's CustomKeys writes it.
@Suite("ZenKeys")
struct ZenKeysTests {
    private static func entry(
        _ id: String, key: String? = nil, keycode: String? = nil, _ modifiers: [String] = [], disabled: Bool = false
    )
        -> String
    {
        let all = ["control", "alt", "shift", "meta", "accel"].map { "\"\($0)\": \(modifiers.contains($0))" }.joined(separator: ", ")
        let key = key.map { "\"\($0)\"" } ?? "null", code = keycode.map { "\"\($0)\"" } ?? "null"
        return """
            {"id": "\(id)", "key": \(key), "keycode": \(code), "group": "other", "l10nId": null, "modifiers": {\(all)}, \
            "action": null, "disabled": \(disabled), "reserved": false, "internal": false}
            """
    }

    @Test("The old file: each mapped key, first entry for a command wins; arrows; Back stays Mote's; a disabled key is none")
    func legacy() throws {
        let file = """
            {"shortcuts": [
            \(Self.entry("key_hideOtherAppsCmdMac", key: "h", ["alt", "accel"])),
            \(Self.entry("key_gotoHistory", key: "y", ["accel", "shift"])),
            \(Self.entry("zen-workspace-forward", keycode: "VK_RIGHT", ["accel", "alt"])),
            \(Self.entry("key_find", key: "f", ["accel"])),
            \(Self.entry("key_find", key: "q", ["accel"])),
            \(Self.entry("goBackKb", keycode: "VK_LEFT", ["accel"])),
            \(Self.entry("zen-split-view-grid", disabled: true)),
            \(Self.entry("unknownKb", key: "k", ["accel"]))
            ]}
            """
        let keys = try #require(ZenKeys.shortcuts(legacy: Data(file.utf8)))
        #expect(keys.combos(for: .history) == [KeyCombo("y", command: true, shift: true)])
        #expect(keys.combos(for: .nextSpace) == [KeyCombo(KeyCombo.rightArrow, command: true, option: true)])
        #expect(keys.combos(for: .find) == [KeyCombo("f", command: true)])
        #expect(keys.combos(for: .back) == ShortcutID.back.defaults)
        #expect(keys.combos(for: .splitGrid).isEmpty)
    }

    @Test("customKeys.json: Zen's keys with the changes over them; an empty entry clears a key")
    func customKeys() throws {
        let file =
            #"{"key_gotoHistory": {"modifiers": "accel,shift", "key": "H"}, "zen-split-view-grid": {}, "zen-workspace-backward": {"modifiers": "accel,alt", "keycode": "VK_LEFT"}}"#
        let keys = try #require(ZenKeys.shortcuts(customKeys: Data(file.utf8)))
        #expect(keys.combos(for: .history) == [KeyCombo("h", command: true, shift: true)])
        #expect(keys.combos(for: .splitGrid).isEmpty)
        #expect(keys.combos(for: .previousSpace) == [KeyCombo(KeyCombo.leftArrow, command: true, option: true)])
        // Not mentioned: Zen's own.
        #expect(keys.combos(for: .compactMode) == Shortcuts.zen.combos(for: .compactMode))
    }

    @Test("Not Zen's files: nothing")
    func garbage() {
        #expect(ZenKeys.shortcuts(legacy: Data("[]".utf8)) == nil)
        #expect(ZenKeys.shortcuts(customKeys: Data("nope".utf8)) == nil)
    }
}
