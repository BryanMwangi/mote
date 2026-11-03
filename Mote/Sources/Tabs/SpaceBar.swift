import AppKit
import MoteCore
import SwiftUI

/// A space's icon and name, above its pinned tabs. A click opens the spaces
/// menu.
struct SpaceHeader: View {
    @ObservedObject var browser: Browser
    let space: Space

    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        Button {
            SpaceMenu.show(for: browser)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: space.symbol).font(.system(size: 11, weight: .medium)).frame(width: 16)
                Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .padding(.leading, 10)
            .frame(height: Self.height)
            .background(hovering ? Palette.veil : .clear, in: Rounded.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// Every space's icon at the foot of the sidebar, this one marked; a click
/// goes to that space. Falls back to the single `SpaceDot` when they don't fit.
struct SpaceIcons: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(browser.spaces) { space in
                    SpaceIcon(browser: browser, space: space)
                }
            }
            SpaceDot(browser: browser)
        }
    }
}

private struct SpaceIcon: View {
    @ObservedObject var browser: Browser
    let space: Space

    @State private var hovering = false

    private var here: Bool { space.id == browser.spaceID && !browser.makingSpace }

    var body: some View {
        Button {
            if here { SpaceMenu.show(for: browser) } else { browser.switchSpace(to: space.id) }
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(here || hovering ? Palette.ink : Palette.muted.opacity(0.8))
                .frame(width: SpaceDot.width, height: 26)
                .background(here ? Palette.wash : hovering ? Palette.hover : .clear, in: Rounded.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(space.name)
        .contextMenu {
            Button("Switch to “\(space.name)”") { browser.switchSpace(to: space.id) }.disabled(here)
        }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.quick, value: here)
    }
}

/// The plus at the foot: a new tab, or a new space.
struct AddMenuButton: View {
    @ObservedObject var browser: Browser

    var body: some View {
        FootIcon(symbol: "plus", help: "New tab or space") {
            let menu = NSMenu()
            menu.addItem(item("New Tab", symbol: "plus") { browser.newTab() })
            if browser.prefs.usesSpaces {
                menu.addItem(item("Create Space…", symbol: "square.on.square") { browser.askForSpace() })
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func item(_ title: String, symbol: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title, key: "", run)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// A small icon button at the foot of the sidebar.
struct FootIcon: View {
    let symbol: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 26, height: 26)
                .background(hovering ? Palette.hover : .clear, in: Rounded.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.hover, value: hovering)
    }
}
