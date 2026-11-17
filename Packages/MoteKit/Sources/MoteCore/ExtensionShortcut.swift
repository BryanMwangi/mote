import Foundation

/// An extension command's key, as its manifest suggests it ("Ctrl+Shift+U"),
/// read as Chrome and Firefox read it on a Mac: Ctrl and Command are ⌘,
/// MacCtrl is ⌃, Alt and Option are ⌥.
public struct ExtensionShortcut: Equatable, Sendable {
    public let key: String
    public let command, shift, option, control: Bool

    public init?(_ text: String) {
        var (command, shift, option, control) = (false, false, false, false)
        var key: String?
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "ctrl", "command": command = true
            case "macctrl": control = true
            case "alt", "option": option = true
            case "shift": shift = true
            default:
                guard key == nil, !part.isEmpty else { return nil }
                key = part
            }
        }
        guard let key, command || option || control else { return nil }
        (self.key, self.command, self.shift, self.option, self.control) = (key, command, shift, option, control)
    }

    /// The manifest's key for `command`: the Mac one, else the default.
    public static func suggested(for command: String, in manifest: [String: Any]) -> ExtensionShortcut? {
        let commands = manifest["commands"] as? [String: Any]
        let keys = (commands?[command] as? [String: Any])?["suggested_key"] as? [String: Any]
        return ((keys?["mac"] ?? keys?["default"]) as? String).flatMap(ExtensionShortcut.init)
    }

    /// Whether a press is this key: `key` as typed without modifiers.
    public func matches(key typed: String, command: Bool, shift: Bool, option: Bool, control: Bool) -> Bool {
        typed.lowercased() == key && command == self.command && shift == self.shift && option == self.option && control == self.control
    }
}
