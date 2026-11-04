/// A key with its modifiers, as a shortcut is written down.
public struct KeyCombo: Hashable, Codable, Sendable {
    /// The character without modifiers, lowercased ("t", "[", "=").
    public var key: String
    /// Where the key sits, for keys whose character the layout or ⌥ changes.
    public var code: UInt16
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, code: UInt16? = nil, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false)
    {
        self.key = key.lowercased()
        self.code = code ?? KeyCombo.codes[key.lowercased()] ?? 0
        (self.command, self.shift, self.option, self.control) = (command, shift, option, control)
    }

    /// ⌘ and a key, the most common kind.
    static func cmd(_ key: String, shift: Bool = false, option: Bool = false) -> KeyCombo {
        KeyCombo(key, command: true, shift: shift, option: option)
    }

    /// ⌃⌥ and a key, as Zen's view, space and split keys.
    static func ctrlOpt(_ key: String) -> KeyCombo { KeyCombo(key, option: true, control: true) }

    /// As the menus write it: ⌃⌥⇧⌘ then the key.
    public var text: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + KeyCombo.name(of: key)
    }

    /// Whether `press` is this key. With ⌥ or ⌃ held, or for a digit, by where
    /// the key sits, since ⌥ and some layouts (AZERTY's top row) change the
    /// character; otherwise by the character, so the shortcut follows the layout.
    public func matches(_ press: KeyMap.Press) -> Bool {
        guard press.command == command, press.shift == shift, press.option == option, press.control == control else { return false }
        if option || control || key.first?.isNumber == true { return press.code == code }
        return press.key == key
    }

    private static func name(of key: String) -> String {
        switch key {
        case "\t": "⇥"
        case " ": "Space"
        case "\u{7f}": "⌫"
        case "\r": "↩"
        default: key.uppercased()
        }
    }

    /// The US layout's key codes, for writing defaults by character.
    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "+": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "}": 30, "o": 31, "u": 32, "[": 33, "{": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
}

/// Every command with a shortcut the user can see, and change where it's
/// editable (Settings › Keyboard). Menus and KeyMap both read their keys
/// from here, so a change shows and works everywhere.
public enum ShortcutID: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    // Tabs
    case newTab, reopenTab, closeTab, duplicateTab, nextTab, previousTab, switcher, editAddress, copyAddress, pasteAndGo, openFile
    // Windows
    case newWindow, newPrivateWindow, newPrivateTab
    // Page
    case back, forward, reload, reloadFromOrigin, reader, find, findNext, findPrevious, print, savePage, screenshot
    case floatVideo, pauseSound, pageChat, hideElements, hiddenElements, zoomIn, zoomOut, actualSize
    // View
    case toggleSidebar, foldTabs, compactMode, toggleToolbar
    // Spaces
    case previousSpace, nextSpace
    // Split view
    case splitGrid, splitVertical, splitHorizontal, unsplit
    // Bookmarks, history and the rest
    case bookmark, history, downloads, passwords, settings
    // Developer
    case inspector, console, inspectElement, viewSource, responsive

    public enum Group: String, CaseIterable, Sendable {
        case tabs = "Tabs", windows = "Windows", page = "Page", view = "View", spaces = "Spaces", split = "Split View"
        case library = "Bookmarks and History", developer = "Developer"
    }

    public var group: Group {
        switch self {
        case .newTab, .reopenTab, .closeTab, .duplicateTab, .nextTab, .previousTab, .switcher, .editAddress, .copyAddress,
            .pasteAndGo, .openFile:
            .tabs
        case .newWindow, .newPrivateWindow, .newPrivateTab: .windows
        case .back, .forward, .reload, .reloadFromOrigin, .reader, .find, .findNext, .findPrevious, .print, .savePage, .screenshot,
            .floatVideo, .pauseSound, .pageChat, .hideElements, .hiddenElements, .zoomIn, .zoomOut, .actualSize:
            .page
        case .toggleSidebar, .foldTabs, .compactMode, .toggleToolbar: .view
        case .previousSpace, .nextSpace: .spaces
        case .splitGrid, .splitVertical, .splitHorizontal, .unsplit: .split
        case .bookmark, .history, .downloads, .passwords, .settings: .library
        case .inspector, .console, .inspectElement, .viewSource, .responsive: .developer
        }
    }

    /// As the menus call it.
    public var title: String {
        switch self {
        case .newTab: "New Tab"
        case .reopenTab: "Reopen Closed Tab"
        case .closeTab: "Close Tab"
        case .duplicateTab: "Duplicate Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .switcher: "Search Tabs"
        case .editAddress: "Open Address"
        case .copyAddress: "Copy Address"
        case .pasteAndGo: "Paste and Go"
        case .openFile: "Open File"
        case .newWindow: "New Window"
        case .newPrivateWindow: "New Private Window"
        case .newPrivateTab: "New Private Tab"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload Page"
        case .reloadFromOrigin: "Reload Skipping Cache"
        case .reader: "Reading Mode"
        case .find: "Find on Page"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .print: "Print"
        case .savePage: "Save Page As"
        case .screenshot: "Take Screenshot"
        case .floatVideo: "Float Video"
        case .pauseSound: "Stop Sound in Tab"
        case .pageChat: "Chat about This Page"
        case .hideElements: "Hide Elements"
        case .hiddenElements: "Hidden on This Site"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .toggleSidebar: "Tabs in Sidebar or on Top"
        case .foldTabs: "Hide or Show Tabs"
        case .compactMode: "Compact Mode"
        case .toggleToolbar: "Toolbar on Hover"
        case .previousSpace: "Previous Space"
        case .nextSpace: "Next Space"
        case .splitGrid: "Split View: Grid"
        case .splitVertical: "Split View: Vertical"
        case .splitHorizontal: "Split View: Horizontal"
        case .unsplit: "Unsplit"
        case .bookmark: "Add Bookmark"
        case .history: "Show History"
        case .downloads: "Downloads"
        case .passwords: "Passwords"
        case .settings: "Settings"
        case .inspector: "Web Inspector"
        case .console: "JavaScript Console"
        case .inspectElement: "Inspect Element"
        case .viewSource: "View Page Source"
        case .responsive: "Responsive Design Mode"
        }
    }

    /// Mote's keys out of the box. The first is the one menus show.
    public var defaults: [KeyCombo] {
        switch self {
        case .newTab: [.cmd("t")]
        case .reopenTab: [.cmd("t", shift: true)]
        case .closeTab: [.cmd("w")]
        case .duplicateTab: [.cmd("d")]
        // The layout sends ⇧] as "]" or "}".
        case .nextTab: [.cmd("]", shift: true), .cmd("}", shift: true)]
        case .previousTab: [.cmd("[", shift: true), .cmd("{", shift: true)]
        case .switcher: [.cmd("k")]
        case .editAddress: [.cmd("l")]
        case .copyAddress: [.cmd("c", shift: true)]
        case .pasteAndGo: [.cmd("v", shift: true)]
        case .openFile: [.cmd("o")]
        case .newWindow: [.cmd("n")]
        case .newPrivateWindow: [.cmd("n", shift: true)]
        case .newPrivateTab: [.cmd("n", shift: true, option: true)]
        case .back: [.cmd("[")]
        case .forward: [.cmd("]")]
        case .reload: [.cmd("r")]
        case .reloadFromOrigin: [.cmd("r", option: true)]
        case .reader: [.cmd("r", shift: true)]
        case .find: [.cmd("f")]
        case .findNext: [.cmd("g")]
        case .findPrevious: [.cmd("g", shift: true)]
        case .print: [.cmd("p")]
        case .savePage: [.cmd("s", option: true)]
        case .screenshot: [.cmd("s", shift: true, option: true)]
        case .floatVideo: [.cmd("p", shift: true)]
        case .pauseSound: [.cmd("m", shift: true)]
        case .pageChat: [.cmd("a", shift: true)]
        case .hideElements: [.cmd("h", shift: true)]
        case .hiddenElements: [.cmd("u", shift: true)]
        // ⌘+ comes as "=" or "+", with or without shift, depending on the layout.
        case .zoomIn: [.cmd("+"), .cmd("="), .cmd("=", shift: true), .cmd("+", shift: true)]
        case .zoomOut: [.cmd("-")]
        case .actualSize: [.cmd("0")]
        case .toggleSidebar: [.cmd("s", shift: true)]
        case .foldTabs: [.cmd("s"), .ctrlOpt("s")]
        case .compactMode: [.ctrlOpt("c")]
        case .toggleToolbar: [.ctrlOpt("t")]
        case .previousSpace: [.ctrlOpt("q")]
        case .nextSpace: [.ctrlOpt("e")]
        case .splitGrid: [.ctrlOpt("g")]
        case .splitVertical: [.ctrlOpt("v")]
        case .splitHorizontal: [.ctrlOpt("h")]
        case .unsplit: [.ctrlOpt("u")]
        case .bookmark: [.cmd("b", shift: true)]
        case .history: [.cmd("y")]
        case .downloads: [.cmd("j", shift: true)]
        case .passwords: [.cmd("l", option: true)]
        case .settings: [.cmd(",")]
        case .inspector: [.cmd("i", option: true)]
        case .console: [.cmd("j", option: true)]
        case .inspectElement: [.cmd("c", option: true)]
        case .viewSource: [.cmd("u", option: true)]
        case .responsive: [KeyCombo("r", command: true, control: true)]
        }
    }

    /// What KeyMap does for it, or nil when only its menu item does: the menus
    /// get keys the page lets through, and these don't need to go first.
    public var command: KeyMap.Command? {
        switch self {
        case .newTab: .newTab
        case .reopenTab: .reopenTab
        case .closeTab: .closeTab
        case .duplicateTab: .duplicateTab
        case .nextTab: .nextTab
        case .previousTab: .previousTab
        case .switcher: .switcher
        case .editAddress: .editAddress
        case .copyAddress: .copyAddress
        case .pasteAndGo: .pasteAndGo
        case .newPrivateWindow: .newPrivateWindow
        case .back: .back
        case .forward: .forward
        case .reload: .reload
        case .reader: .reader
        case .find: .find
        case .findNext: .findAgain(backwards: false)
        case .findPrevious: .findAgain(backwards: true)
        case .print: .print
        case .floatVideo: .floatVideo
        case .pauseSound: .pauseSound
        case .pageChat: .pageChat
        case .hideElements: .hideElements
        case .hiddenElements: .hiddenElements
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .actualSize: .actualSize
        case .toggleSidebar: .toggleSidebar
        case .foldTabs: .foldTabs
        case .compactMode: .compactMode
        case .toggleToolbar: .toggleToolbar
        case .previousSpace: .stepSpace(-1)
        case .nextSpace: .stepSpace(1)
        case .splitGrid: .split(.grid)
        case .splitVertical: .split(.across)
        case .splitHorizontal: .split(.down)
        case .unsplit: .unsplit
        case .bookmark: .bookmark
        case .history: .history
        case .downloads: .downloads
        case .settings: .settings
        case .openFile, .newWindow, .newPrivateTab, .reloadFromOrigin, .savePage, .screenshot, .passwords, .inspector, .console,
            .inspectElement, .viewSource, .responsive:
            nil
        }
    }

}

/// The user's keys: Mote's defaults, with their changes over them.
public struct Shortcuts: Codable, Equatable, Sendable {
    /// A command's keys as the user set them; an empty list is no key.
    public var changed: [ShortcutID: [KeyCombo]] = [:]

    public init(changed: [ShortcutID: [KeyCombo]] = [:]) { self.changed = changed }

    public func combos(for id: ShortcutID) -> [KeyCombo] { changed[id] ?? id.defaults }

    /// The command `press` is, if any.
    public func id(matching press: KeyMap.Press) -> ShortcutID? {
        ShortcutID.allCases.first { id in combos(for: id).contains { $0.matches(press) } }
    }

    /// The command that has `combo` now, other than `except`.
    public func owner(of combo: KeyCombo, except: ShortcutID? = nil) -> ShortcutID? {
        ShortcutID.allCases.first { $0 != except && combos(for: $0).contains(combo) }
    }

    /// Gives `id` the key `combo` (nil for none), taking it from any command
    /// that had it, which is left without a key.
    public mutating func set(_ id: ShortcutID, to combo: KeyCombo?) {
        if let combo, let other = owner(of: combo, except: id) { changed[other] = combos(for: other).filter { $0 != combo } }
        changed[id] = combo.map { [$0] } ?? []
        // Back to a default is no change at all.
        for (key, value) in changed where value == key.defaults { changed[key] = nil }
    }

    public mutating func reset(_ id: ShortcutID) { changed[id] = nil }

    /// Keys macOS and text editing keep: recording refuses them.
    public static func reserved(_ combo: KeyCombo) -> Bool {
        let plainCommand = combo.command && !combo.shift && !combo.option && !combo.control
        if plainCommand, ["q", "h", "m", "`", "\t", "c", "v", "x", "a", "z"].contains(combo.key) { return true }
        if combo.command, combo.option, !combo.shift, !combo.control, combo.key == "h" { return true }
        if combo.command, combo.shift, !combo.option, !combo.control, combo.key == "z" { return true }
        return false
    }

    /// Whether a key may be a shortcut at all: it needs ⌘, ⌃ or ⌥.
    public static func usable(_ combo: KeyCombo) -> Bool { combo.command || combo.control || combo.option }
}
