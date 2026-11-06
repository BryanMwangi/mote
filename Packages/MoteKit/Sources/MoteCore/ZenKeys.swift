import Foundation

/// Zen's keyboard shortcuts as Mote's: the old `zen-keyboard-shortcuts.json`
/// (every key, as Zen up to 1.17 kept them) or Firefox's `customKeys.json`
/// (only the changed ones, as Zen keeps them since), both in the profile.
/// Commands Mote doesn't have are left out.
public enum ZenKeys {
    /// Firefox's and Zen's key ids, by Mote's command. Not Back and Forward:
    /// Firefox's ⌘← and ⌘→ would take moving along a line in text fields.
    static let ids: [String: ShortcutID] = [
        "key_newNavigatorTab": .newTab, "key_close": .closeTab, "key_undoCloseTab": .reopenTab,
        "key_restoreLastClosedTabOrWindowOrSession": .reopenTab, "zen-duplicate-tab": .duplicateTab, "focusURLBar": .editAddress,
        "zen-copy-url": .copyAddress, "openFileKb": .openFile, "key_newNavigator": .newWindow, "key_privatebrowsing": .newPrivateWindow,
        "key_reload": .reload, "key_reload_skip_cache": .reloadFromOrigin,
        "key_toggleReaderMode": .reader, "key_find": .find, "key_findAgain": .findNext, "key_findPrevious": .findPrevious,
        "printKb": .print, "key_savePage": .savePage, "key_screenshot": .screenshot, "key_togglePictureInPicture": .floatVideo,
        "key_toggleMute": .pauseSound, "key_fullZoomEnlarge": .zoomIn, "key_fullZoomReduce": .zoomOut, "key_fullZoomReset": .actualSize,
        "zen-toggle-sidebar": .foldTabs, "zen-compact-mode-toggle": .compactMode, "zen-workspace-forward": .nextSpace,
        "zen-workspace-backward": .previousSpace, "zen-split-view-grid": .splitGrid, "zen-split-view-vertical": .splitVertical,
        "zen-split-view-horizontal": .splitHorizontal, "zen-split-view-unsplit": .unsplit, "addBookmarkAsKb": .bookmark,
        "key_gotoHistory": .history, "key_openDownloads": .downloads, "zen-library-toggle": .library, "key_viewSource": .viewSource,
        "key_aboutProcesses": .processes, "key_switchTextDirection": .textDirection, "key_toggleToolbox": .inspector,
        "key_inspector": .inspectElement, "key_responsiveDesignMode": .responsive,
    ]

    /// Keys Firefox names, as AppKit's characters.
    private static let codes: [String: String] = [
        "VK_LEFT": KeyCombo.leftArrow, "VK_RIGHT": KeyCombo.rightArrow, "VK_UP": "\u{F700}", "VK_DOWN": "\u{F701}", "VK_TAB": "\t",
        "VK_RETURN": "\r", "VK_BACK": "\u{7f}", "VK_DELETE": "\u{F728}",
    ]

    /// From the old file: every key there is the user's.
    public static func shortcuts(legacy data: Data) -> Shortcuts? {
        struct File: Decodable {
            struct Entry: Decodable {
                let id: String?
                let key: String?
                let keycode: String?
                let modifiers: [String: Bool]?
                let disabled: Bool?
            }
            let shortcuts: [Entry]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var keys = Shortcuts.zen
        var done = Set<ShortcutID>()
        for entry in file.shortcuts {
            guard let id = entry.id.flatMap({ ids[$0] }), done.insert(id).inserted else { continue }
            let names = (entry.modifiers ?? [:]).filter(\.value).map(\.key)
            keys.set(id, to: entry.disabled == true ? nil : combo(key: entry.key, keycode: entry.keycode, modifiers: names))
        }
        return keys
    }

    /// From `customKeys.json`: Zen's own keys, with these changes over them.
    public static func shortcuts(customKeys data: Data) -> Shortcuts? {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: String]] else { return nil }
        var keys = Shortcuts.zen
        for (name, entry) in entries {
            guard let id = ids[name] else { continue }
            let names = (entry["modifiers"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            keys.set(id, to: combo(key: entry["key"], keycode: entry["keycode"], modifiers: names))
        }
        return keys
    }

    /// One key: accel (or meta) is ⌘ on a Mac, alt is ⌥. Nil when there's none.
    static func combo(key: String?, keycode: String?, modifiers: [String]) -> KeyCombo? {
        let names = Set(modifiers.map { $0.lowercased() })
        let character: String
        if let key, !key.isEmpty {
            character = key.lowercased()
        } else if let keycode, let mapped = codes[keycode] {
            character = mapped
        } else {
            return nil
        }
        return KeyCombo(
            character, command: names.contains("accel") || names.contains("meta"), shift: names.contains("shift"),
            option: names.contains("alt"), control: names.contains("control") || names.contains("ctrl"))
    }
}
