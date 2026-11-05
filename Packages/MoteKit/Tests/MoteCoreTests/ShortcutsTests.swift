import Foundation
import Testing

@testable import MoteCore

@Suite("Shortcuts")
struct ShortcutsTests {
    private func press(_ combo: KeyCombo) -> KeyMap.Press {
        KeyMap.Press(
            key: combo.key, code: combo.code, command: combo.command, shift: combo.shift, option: combo.option, control: combo.control)
    }

    @Test("No two commands share a default key")
    func noClashes() {
        var seen: [KeyCombo: ShortcutID] = [:]
        for id in ShortcutID.allCases {
            for combo in id.defaults {
                #expect(seen[combo] == nil, "\(combo.text) is both \(seen[combo]?.title ?? "") and \(id.title)")
                seen[combo] = id
            }
        }
    }

    @Test("Every default works: its own press finds its command")
    func defaultsMatch() {
        let shortcuts = Shortcuts()
        for id in ShortcutID.allCases {
            for combo in id.defaults { #expect(shortcuts.id(matching: press(combo)) == id, "\(combo.text)") }
        }
    }

    @Test("A changed key moves the command: ⌘E reloads, and ⌘R then does nothing")
    func changed() {
        var shortcuts = Shortcuts()
        shortcuts.set(.reload, to: .cmd("e"))
        #expect(KeyMap.command(for: press(.cmd("e")), spaces: false, picking: false, inText: false, shortcuts: shortcuts) == .reload)
        #expect(KeyMap.command(for: press(.cmd("r")), spaces: false, picking: false, inText: false, shortcuts: shortcuts) == nil)
        shortcuts.reset(.reload)
        #expect(shortcuts.changed.isEmpty)
    }

    @Test("A key another command has is taken from it, which is left without one")
    func taking() {
        var shortcuts = Shortcuts()
        #expect(shortcuts.owner(of: .cmd("d"), except: .reload) == .duplicateTab)
        shortcuts.set(.reload, to: .cmd("d"))
        #expect(shortcuts.combos(for: .reload) == [.cmd("d")])
        #expect(shortcuts.combos(for: .duplicateTab).isEmpty)
        #expect(shortcuts.id(matching: press(.cmd("d"))) == .reload)
    }

    @Test("No key at all, and back to the default is no change")
    func none() {
        var shortcuts = Shortcuts()
        shortcuts.set(.print, to: nil)
        #expect(shortcuts.combos(for: .print).isEmpty)
        #expect(shortcuts.id(matching: press(.cmd("p"))) == nil)
        shortcuts.set(.print, to: .cmd("p"))
        #expect(shortcuts.changed.isEmpty)
    }

    @Test("The Mac's own keys are refused; a key needs ⌘, ⌃ or ⌥")
    func reserved() {
        #expect(Shortcuts.reserved(.cmd("q")))
        #expect(Shortcuts.reserved(.cmd("c")))
        #expect(Shortcuts.reserved(.cmd("h", option: true)))
        #expect(!Shortcuts.reserved(.cmd("e")))
        #expect(!Shortcuts.usable(KeyCombo("e")))
        #expect(Shortcuts.usable(.ctrlOpt("e")))
    }

    @Test("Written as the menus write it")
    func text() {
        #expect(KeyCombo.cmd("s", shift: true, option: true).text == "⌥⇧⌘S")
        #expect(KeyCombo.ctrlOpt("g").text == "⌃⌥G")
        #expect(KeyCombo.cmd(",").text == "⌘,")
    }

    @Test("Zen's keys: no two commands share one, and the ones Zen moves work")
    func zenKeys() {
        let zen = Shortcuts.zen
        var seen: [KeyCombo: ShortcutID] = [:]
        for id in ShortcutID.allCases {
            for combo in zen.combos(for: id) {
                #expect(seen[combo] == nil, "\(combo.text) is both \(seen[combo]?.title ?? "") and \(id.title)")
                seen[combo] = id
            }
        }
        #expect(zen.id(matching: press(.cmd("s"))) == .compactMode)
        #expect(zen.id(matching: press(.cmd("g", option: true))) == .splitGrid)
        #expect(zen.id(matching: press(.cmd(KeyCombo.rightArrow, option: true))) == .nextSpace)
        #expect(zen.combos(for: .foldTabs) == [.ctrlOpt("s")])
        #expect(KeyCombo.cmd(KeyCombo.leftArrow, option: true).text == "⌥⌘←")
    }

    @Test("Saved and read back")
    func codable() throws {
        var shortcuts = Shortcuts()
        shortcuts.set(.reload, to: .cmd("e"))
        shortcuts.set(.print, to: nil)
        let back = try JSONDecoder().decode(Shortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(back == shortcuts)
    }
}
