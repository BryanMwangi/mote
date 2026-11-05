import AppKit
import MoteAI
import MoteCore
import SwiftUI

/// The window's keyboard shortcuts. The page's web view takes most keys as
/// first responder, so a local monitor sees them first. Which command a key
/// means is KeyMap's; this carries it out.
@MainActor
final class KeyRouter {
    private weak var browser: Browser?
    private var monitor: Any?
    /// The last key left to the page first (see KeyMap.pageGoesFirst).
    private var leftToPage: NSEvent?

    func start(for browser: Browser) {
        self.browser = browser
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard event.type == .keyDown else {
                // Letting go of ⌘ goes to the tab picked with ⌘K.
                if !event.modifierFlags.contains(.command) { self?.browser?.landSummon() }
                return event
            }
            // nil means the key was used; only a router that's gone lets it through.
            guard let self else { return event }
            return self.route(event)
        }
    }

    /// nil when the key was used.
    func route(_ event: NSEvent) -> NSEvent? {
        take(event) ? nil : event
    }

    private func take(_ event: NSEvent) -> Bool {
        // Every window has a router, and each takes its own window's keys; the
        // main window's also takes those of the small windows below.
        let owner = Windows.shared.browser(for: event.window)
        if let owner, owner !== browser { return false }
        if owner == nil, browser?.extra == true { return false }
        // The small link window and Settings have keys of their own.
        if let little = LinkWindow.owning(event.window) { return little.take(event) }
        // Settings takes its own keys (see SettingsWindow), whichever windows are open.
        if SettingsWindow.owning(event.window) != nil { return false }
        guard let browser else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let press = KeyMap.Press(
            key: event.charactersIgnoringModifiers ?? "", code: event.keyCode, command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control))

        if press.code == KeyMap.escape { return escape(in: browser) }
        // ⌘J in a new tab's composer or the floating search: Return asks the
        // assistant, or searches again.
        if KeyMap.switchesAsking(press, inComposer: browser.composing) {
            withAnimation(Motion.settle) { browser.field.asksAssistant.toggle() }
            if browser.field.asksAssistant { Assistant.shared.prepare() }
            browser.field.askFocus()
            return true
        }
        // Tab (without ⌘, ⌥ or ⌃) walks the suggestions while the field is open,
        // is swallowed while renaming a tab, and otherwise goes to the page.
        if press.code == KeyMap.tabKey, !press.command, !press.option, !press.control {
            if browser.editingTab != nil { return true }
            guard browser.fieldShowing, !browser.field.offers.isEmpty else { return false }
            browser.field.walk(press.shift ? -1 : 1)
            return true
        }
        // A menu-only command on a key without ⌘ (⌥⇧L for the Library, or one
        // recorded in Settings › Keyboard): AppKit only offers keys with ⌘ or ⌃
        // to the menus, so it's run here.
        if !press.command, let id = browser.prefs.shortcuts.id(matching: press), id.command == nil {
            browser.perform(id)
            return true
        }
        let inText = browser.active?.typing == true || event.window?.firstResponder is NSTextView
        let command = KeyMap.command(
            for: press, spaces: browser.usesSpaces, picking: browser.pickingElement, inText: inText, shortcuts: browser.prefs.shortcuts)
        // ⌃ shortcuts of Mote's own (spaces, ⌃⇥) come before extensions'.
        if let command, !press.command {
            run(command, in: browser, event: event)
            return true
        }
        // Extensions get the rest of the shortcuts first.
        if #available(macOS 15.4, *), press.command || press.option || press.control, Extensions.shared.take(event) { return true }
        guard let command else { return false }
        if !isDigit(press), leavesToPage(event, press, picking: browser.pickingElement) { return false }
        run(command, in: browser, event: event)
        return true
    }

    private func isDigit(_ press: KeyMap.Press) -> Bool { !press.shift && KeyMap.digits[press.code] != nil }

    /// Lets the page have a shortcut first, as Chrome does, when the page has
    /// the keyboard. If it doesn't use it, WebKit sends the same key again,
    /// and this time Mote takes it.
    private func leavesToPage(_ event: NSEvent, _ press: KeyMap.Press, picking: Bool) -> Bool {
        guard KeyMap.pageGoesFirst(press, picking: picking, shortcuts: browser?.prefs.shortcuts ?? Shortcuts()),
            event.window?.firstResponder is PageView
        else { return false }
        if let earlier = leftToPage, PageView.same(earlier, event) {
            leftToPage = nil
            return false
        }
        leftToPage = event
        return true
    }

    /// Escape closes whatever is on top, one thing at a time.
    private func escape(in browser: Browser) -> Bool {
        let steps: [(Bool, () -> Void)] = [
            (browser.welcoming, browser.finishWelcome),
            (browser.editingTab != nil, browser.cancelTabEdit),
            (browser.peekTab != nil, browser.closePeek),
            (browser.makingSpace, { withAnimation(Motion.glide) { browser.makingSpace = false } }),
            (browser.bookmarking, { browser.bookmarking = false }),
            (browser.logins.managing, { browser.logins.managing = false }),
            (browser.recalling, { browser.recalling = false }),
            (browser.showingDownloads, { browser.showingDownloads = false }),
            (browser.showingProcesses, { browser.showingProcesses = false }),
            (browser.themingSpace != nil, { browser.themingSpace = nil }),
            (browser.boosting != nil, { browser.boosting = nil }),
            (browser.logins.choices != nil, browser.logins.dropChoices),
            (browser.pickingElement, browser.toggleHiding),
            (browser.reviewing, { browser.reviewing = false }),
            (browser.finder.showing, browser.finder.hide),
            // The pick goes before the field does.
            (browser.field.picked != nil, { browser.field.picked = nil }),
            (browser.editing && browser.active?.isStart == false, browser.dismiss),
            // Last, so Escape first closes whatever is over the chat.
            (browser.active?.chat?.busy == true, { browser.active?.chat?.stop() }),
            // The chat about the page: Escape stops its answer first, then the
            // panel itself. It sits above the page but under the sheets and
            // overlays earlier in the list, so those close first.
            (browser.active?.pageChat?.busy == true, { browser.active?.pageChat?.stop() }),
            (browser.chatting, browser.togglePageChat),
        ]
        guard let step = steps.first(where: \.0) else { return false }
        step.1()
        return true
    }

    private func run(_ command: KeyMap.Command, in browser: Browser, event: NSEvent) {
        if case .pasteAndGo = command { return pasteAndGo(in: browser, event: event) }
        browser.run(command)
    }

    /// ⇧⌘V: pastes plain text in anything editable, otherwise Paste and Go.
    /// WebKit gives ⇧⌘V back unused, so the plain paste is done here.
    /// `inputContext` is set whenever the caret is in something editable, in
    /// any frame, other sites' included.
    private func pasteAndGo(in browser: Browser, event: NSEvent) {
        let editable =
            browser.active?.typing == true || browser.active?.built?.inputContext != nil || browser.editing
            || event.window?.firstResponder is NSTextView
        if editable {
            _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
        } else {
            browser.pasteAndGo()
        }
    }
}
