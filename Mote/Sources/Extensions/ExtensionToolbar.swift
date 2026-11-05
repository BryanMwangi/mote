import AppKit
import MoteCore
import SwiftUI
import WebKit

// What the page panel (PagePanel.swift) shows of each extension: its icon
// and badge, its right-click actions, and the view its popup hangs from.

/// Tells Extensions which view a popup hangs from.
@available(macOS 15.4, *)
struct PopupAnchor: FillsRoom {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Extensions.shared.register(view, for: id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Extensions.shared.register(view, for: id)
    }
}

/// Its icon with its badge; without an icon, its initial, so it isn't
/// taken for the puzzle button.
@available(macOS 15.4, *)
struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            picture
                .frame(width: size + 4, height: size + 4)
                .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }

    @ViewBuilder private var picture: some View {
        if let icon = button.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Text(button.name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: size, height: size)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

/// An extension's context menu.
@available(macOS 15.4, *)
struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        if extensions.contexts[id]?.optionsPageURL != nil { Button("Options…") { extensions.openOptions(id) } }
        Button("Reload") { extensions.reload(id) }
        Divider()
        Button("Remove “\(name)”…") {
            let alert = Dialogs.alert("Remove “\(name)”?", "Its settings and data go with it.", buttons: ["Remove", "Cancel"])
            if alert.runModal() == .alertFirstButtonReturn { extensions.remove(id) }
        }
    }
}
