/// Which window command a key press means.
public enum KeyMap {
    /// A key as pressed.
    public struct Press: Equatable, Sendable {
        /// The character without modifiers, lowercased.
        public var key: String
        public var code: UInt16
        public var command = false
        public var shift = false
        public var option = false
        public var control = false

        public init(key: String, code: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
            self.key = key.lowercased()
            self.code = code
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }
    }

    public enum Command: Equatable, Sendable {
        case newTab, newPrivateWindow, reopenTab, closeTab, duplicateTab
        case nextTab, previousTab
        /// A tab by position; `last` for ⌘9.
        case tab(Int), lastTab
        case space(Int)
        case back, forward, reload, reader
        case editAddress, switcher, pasteAndGo, copyAddress
        case find, findAgain(backwards: Bool)
        case print, pauseSound, floatVideo
        case pageChat
        case toggleSidebar, foldTabs
        case bookmark, history, downloads, settings
        case hideElements, hiddenElements, undoHiding
        case zoomIn, zoomOut, actualSize
        case inspector
        /// Split view, as Zen's keys: the tab in front with the one before it,
        /// or its group, laid out so; or the group undone.
        case split(SplitGrid), unsplit
        /// Zen's ⌃⌥ keys: the space before or after, compact mode, the toolbar.
        case stepSpace(Int), compactMode, toggleToolbar
    }

    public static let escape: UInt16 = 53
    public static let tabKey: UInt16 = 48
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let returnKey: UInt16 = 36
    public static let enterKey: UInt16 = 76

    /// F12, as macOS sends it with fn held or from the Touch Bar's F-keys.
    public static let f12: UInt16 = 111

    /// The J key, by position.
    public static let jKey: UInt16 = 38

    /// ⌘J in a new tab's composer: Return asks the assistant instead of
    /// searching, or searches again.
    public static func switchesAsking(_ press: Press, inComposer: Bool) -> Bool {
        inComposer && press.command && !press.shift && !press.option && !press.control && press.code == jKey
    }

    /// The top row's digits by key code, so shortcuts don't depend on the
    /// layout (AZERTY types other characters there).
    public static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]

    /// What `press` means. `spaces`: spaces are on (⌃1–⌃9 switch them).
    /// `picking`: elements are being picked (⌘Z undoes a hide). `inText`:
    /// the keyboard is in something editable (⌘← and ⌘→ belong to it).
    public static func command(
        for press: Press, spaces: Bool, picking: Bool, inText: Bool, shortcuts: Shortcuts = Shortcuts()
    ) -> Command? {
        // ⌃⇥ and ⌃⇧⇥ step through the tabs.
        if press.code == tabKey, press.control, !press.command, !press.option { return press.shift ? .previousTab : .nextTab }
        if spaces, press.control, !press.command, !press.option, !press.shift, let number = digits[press.code], number > 0 {
            return .space(number - 1)
        }
        // F12 opens and closes the Web Inspector, as in Chrome, Firefox and Zen.
        if press.code == f12, !press.command, !press.option, !press.control, !press.shift { return .inspector }
        // The user's keys (Settings › Keyboard); a menu-only command is left to its menu.
        if let id = shortcuts.id(matching: press) {
            if case .stepSpace = id.command, !spaces { return nil }
            return id.command
        }
        guard press.command, !press.option, !press.control else { return nil }
        if !press.shift, let number = digits[press.code], number > 0 { return number == 9 ? .lastTab : .tab(number - 1) }
        if press.key == "z", !press.shift, picking { return .undoHiding }
        guard !press.shift, !inText else { return nil }
        return press.code == leftArrow ? .back : press.code == rightArrow ? .forward : nil
    }

    /// Shortcuts the page gets to see first, as in Chrome: if it doesn't use
    /// one, WebKit sends it back and Mote takes it then. Opening, closing and
    /// switching tabs are always Mote's, and so is ⌘Z while picking.
    public static func pageGoesFirst(_ press: Press, picking: Bool, shortcuts: Shortcuts = Shortcuts()) -> Bool {
        if press.key == "z", picking { return false }
        let mote: Set<ShortcutID> = [.newTab, .reopenTab, .closeTab, .newPrivateWindow, .nextTab, .previousTab]
        return shortcuts.id(matching: press).map { !mote.contains($0) } ?? true
    }

    /// What a key does in the small window for links from other apps: ⌘O
    /// keeps the page as a tab, Escape and ⌘W close the window, and the rest
    /// go to the page.
    public enum LinkWindowKey: Equatable, Sendable { case keep, close }

    public static func linkWindow(_ press: Press) -> LinkWindowKey? {
        let plain = !press.command && !press.shift && !press.option && !press.control
        let commandOnly = press.command && !press.shift && !press.option && !press.control
        if press.code == escape, plain { return .close }
        guard commandOnly else { return nil }
        switch press.key {
        case "w": return .close
        case "o": return .keep
        default: return nil
        }
    }
}
