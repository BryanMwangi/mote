import AppKit
import MoteCore
import SwiftUI

/// Settings › Keyboard: every shortcut, grouped as the menus are, each one
/// changed by recording a new key (see Shortcuts in MoteCore). Below them,
/// the keys that stay as they are.
struct KeyboardSettings: View {
    @ObservedObject var prefs: Preferences

    /// Keys that aren't one command's, so they can't be changed.
    private static let fixed = [
        ("⌘1 – ⌘8", "A tab by its place"), ("⌘9", "The last tab"), ("⌃1 – ⌃9", "A space by its place"),
        ("⌃⇥  ⌃⇧⇥", "Next and previous tab"), ("⌘←  ⌘→", "Back and forward, outside text"), ("F12", "Web Inspector"),
        ("⌘Z", "Undo a hide, while picking elements"), ("Esc", "Close what's open over the page"),
    ]

    var body: some View {
        ForEach(ShortcutID.Group.allCases, id: \.self) { group in
            SettingsSection(group.rawValue) {
                let ids = ShortcutID.allCases.filter { $0.group == group }
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { RowRule() }
                    SettingRow(id.title, symbol: group.symbol, tint: group.tint, keywords: ["shortcut", "key"] + combos(id)) {
                        KeyRecorder(id: id, prefs: prefs)
                    }
                }
            }
        }

        SettingsSection("Always the same") {
            ForEach(Array(Self.fixed.enumerated()), id: \.offset) { index, key in
                if index > 0 { RowRule() }
                HStack {
                    Text(key.1).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(key.0).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .settingsSearch([key.1, key.0, "shortcut", "key"])
            }
        }

        HStack {
            Spacer()
            Pill("Restore Defaults") { prefs.shortcuts = Shortcuts() }.disabled(prefs.shortcuts.changed.isEmpty)
        }
        .settingsSearch(["Restore default shortcuts", "keys"])
    }

    private func combos(_ id: ShortcutID) -> [String] { prefs.shortcuts.combos(for: id).map(\.text) }
}

extension ShortcutID.Group {
    var symbol: String {
        switch self {
        case .tabs: "square.on.square"
        case .windows: "macwindow"
        case .page: "doc.text"
        case .view: "sidebar.left"
        case .spaces: "square.stack"
        case .split: "rectangle.split.2x1"
        case .library: "book"
        case .developer: "hammer"
        }
    }

    var tint: Color {
        switch self {
        case .tabs: Tint.blue
        case .windows: Tint.indigo
        case .page: Tint.teal
        case .view: Tint.gray
        case .spaces: Tint.purple
        case .split: Tint.green
        case .library: Tint.orange
        case .developer: Tint.pink
        }
    }
}

/// A command's key, as a pill: clicked, it records the next key pressed with
/// ⌘, ⌃ or ⌥. Escape stops, Delete leaves it without a key. A key the Mac
/// keeps is refused; one another command has is given over when the user says.
struct KeyRecorder: View {
    let id: ShortcutID
    @ObservedObject var prefs: Preferences

    /// The recorder listening, which Settings' window hands every key to.
    static var recording: ((NSEvent) -> Bool)?

    @State private var listening = false
    @State private var refusals = 0
    @State private var shake: CGFloat = 0
    @State private var note: String?

    private var combos: [KeyCombo] { prefs.shortcuts.combos(for: id) }
    private var changed: Bool { prefs.shortcuts.changed[id] != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                if changed, !listening {
                    Button {
                        prefs.shortcuts.reset(id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Back to \(id.defaults.first?.text ?? "none")")
                }
                Button(action: toggle) {
                    Text(listening ? "Type keys…" : combos.first?.text ?? "None")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(listening ? Color.accentColor : combos.isEmpty ? Palette.muted : Palette.ink)
                        .frame(minWidth: 64)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(listening ? Color.accentColor : Palette.hairline, lineWidth: listening ? 1.5 : 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(listening ? "Press the keys, Escape to stop, Delete for none" : "Click to record a new key")
                .shakesOnRefusal(refusals, while: true, travel: $shake)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .onDisappear(perform: stop)
        .animation(Motion.quick, value: listening)
    }

    private func toggle() {
        if listening { return stop() }
        note = nil
        listening = true
        KeyRecorder.recording = take
    }

    private func stop() {
        guard listening else { return }
        listening = false
        KeyRecorder.recording = nil
    }

    /// Every key while listening; true as it's always used.
    private func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == KeyMap.escape, plain {
            stop()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117, plain {
            prefs.shortcuts.set(id, to: nil)
            stop()
            return true
        }
        let combo = KeyCombo(
            event.charactersIgnoringModifiers ?? "", code: event.keyCode, command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control))
        guard Shortcuts.usable(combo) else {
            return refuse("Hold ⌘, ⌃ or ⌥ with the key")
        }
        guard !Shortcuts.reserved(combo) else {
            return refuse("\(combo.text) is the Mac's own")
        }
        if let other = prefs.shortcuts.owner(of: combo, except: id) {
            let ask = NSAlert()
            ask.messageText = "\(combo.text) is \(other.title)."
            ask.informativeText = "Use it for \(id.title) instead? \(other.title) will have no key until you give it one."
            ask.addButton(withTitle: "Use It")
            ask.addButton(withTitle: "Cancel")
            // Still listening while asked, so a No can be followed by another key.
            guard ask.runModal() == .alertFirstButtonReturn else { return true }
        }
        prefs.shortcuts.set(id, to: combo)
        stop()
        return true
    }

    private func refuse(_ why: String) -> Bool {
        note = why
        refusals += 1
        return true
    }
}
