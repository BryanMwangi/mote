import AppKit
import MoteCore
import SwiftUI

/// A space's icon: its emoji, or its symbol. `icon` is either.
struct SpaceGlyph: View {
    let icon: String
    var size: CGFloat = 12

    init(_ icon: String, size: CGFloat = 12) {
        self.icon = icon
        self.size = size
    }

    init(space: Space, size: CGFloat = 12) {
        self.init(space.emoji ?? space.symbol, size: size)
    }

    var body: some View {
        if Space.isEmoji(icon) {
            Text(icon).font(.system(size: size + 1))
        } else {
            Image(systemName: icon).font(.system(size: size, weight: .medium))
        }
    }

    /// For menus: the emoji drawn as a picture, or the symbol.
    static func image(_ icon: String, name: String) -> NSImage? {
        guard Space.isEmoji(icon) else { return NSImage(systemSymbolName: icon, accessibilityDescription: name) }
        let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let size = text.size()
        return NSImage(size: size, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
    }
}

/// A space's icon and name, above its pinned tabs. A right-click opens its menu.
struct SpaceHeader: View {
    @ObservedObject var browser: Browser
    let space: Space

    static let height: CGFloat = 28

    /// A label, not a button: its menu is on right-click, as every space's is.
    var body: some View {
        HStack(spacing: 8) {
            SpaceGlyph(space: space, size: 11).frame(width: 16)
            Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.muted)
        .padding(.leading, 10)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onRightClick { SpaceMenu.show(for: browser, space: space, from: .header) }
        .iconPicker(browser: browser, space: space, from: .header)
    }
}

/// Every space at the foot of the sidebar, this one marked; a click goes to
/// that space. The others are icons, or dots (Settings, or when the icons
/// don't fit) that show their icon on hover. Too many even as dots, the row
/// scrolls sideways, and a right-click lists every space to jump to.
struct SpaceIcons: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The room the foot leaves the row.
    @State private var room: CGFloat = 0

    private static let gap: CGFloat = 2
    static let dot: CGFloat = 12

    var body: some View {
        let count = CGFloat(browser.spaces.count)
        let full = count * SpaceDot.width + (count - 1) * Self.gap
        let dotted = prefs.spaceMarks == .dots || full > room
        let width = dotted ? SpaceDot.width + (count - 1) * (Self.dot + Self.gap) : full
        let overflows = width > room + 0.5
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: 26)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            .overlay {
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: Self.gap) {
                            ForEach(browser.spaces) { space in
                                SpaceIcon(browser: browser, space: space, dot: dotted, listing: overflows).id(space.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(!overflows)
                    .frame(width: min(width, max(room, 0)))
                    .mask { Fades(on: overflows) }
                    .background { SpaceRowSpot(overflows: overflows) }
                    .onChange(of: browser.spaceID) { _, id in withAnimation(Motion.glide) { scroller.scrollTo(id) } }
                    .onAppear { scroller.scrollTo(browser.spaceID) }
                }
            }
            .animation(Motion.quick, value: dotted)
    }

    /// Soft edges where the row is cut off.
    private struct Fades: View {
        let on: Bool

        var body: some View {
            if on {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                }
            } else {
                Rectangle()
            }
        }
    }
}

/// Where the spaces' row is, for a sideways scroll over it to scroll it
/// rather than swipe between spaces, while it overflows (see SpaceSwipe).
@MainActor
enum SpaceRow {
    fileprivate static weak var view: NSView?
    fileprivate static var overflows = false

    /// Whether `event` is over the row, and the row scrolls.
    static func takes(_ event: NSEvent) -> Bool {
        guard overflows, let view, view.window === event.window else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}

private struct SpaceRowSpot: FillsRoom {
    let overflows: Bool

    func makeNSView(context: Context) -> NSView { Spot() }

    func updateNSView(_ view: NSView, context: Context) {
        SpaceRow.view = view
        SpaceRow.overflows = overflows
    }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct SpaceIcon: View {
    @ObservedObject var browser: Browser
    let space: Space
    /// Other spaces are dots, until hovered.
    let dot: Bool
    /// The row overflows: a right-click lists every space.
    let listing: Bool

    @State private var hovering = false
    @State private var warming: Task<Void, Never>?

    private var here: Bool { space.id == browser.spaceID && !browser.makingSpace }
    private var small: Bool { dot && !here && !hovering }

    var body: some View {
        Button {
            // The menu is on right-click only, for every space's icon.
            if !here { browser.switchSpace(to: space.id) }
        } label: {
            ZStack {
                Circle()
                    .fill(Palette.muted.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .opacity(small ? 1 : 0)
                SpaceGlyph(space: space)
                    .foregroundStyle(here || hovering ? Palette.ink : Palette.muted.opacity(0.8))
                    .scaleEffect(small ? 0.4 : 1)
                    .opacity(small ? 0 : 1)
            }
            .frame(width: small ? SpaceIcons.dot : SpaceDot.width, height: 26)
            // The space's own wash, as the tab in front has.
            .background { if here || hovering { Tinted(shape: Rounded.row, fill: here ? Palette.wash : Palette.hover) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over
            warming?.cancel()
            // Resting on another space's icon readies it, so the click is instant.
            guard over, !here else { return }
            warming = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { browser.warmSpace(space.id) }
            }
        }
        .help(space.name)
        .background { SpaceDropSpot(space: space.id) }
        .onRightClick { SpaceMenu.show(for: browser, space: space, from: .foot, listing: listing) }
        .iconPicker(browser: browser, space: space, from: .foot)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.quick, value: here)
    }
}

/// The plus at the foot a space or folder, then a split
/// or a tab.
struct AddMenuButton: View {
    @ObservedObject var browser: Browser

    var body: some View {
        FootIcon(symbol: "plus", help: "New tab, split or space") {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if browser.usesSpaces {
                menu.addItem(item("Create Space…", symbol: "square.on.square") { browser.askForSpace() })
            }
            menu.addItem(item("Create Folder", symbol: "folder.badge.plus") { browser.newFolder() })
            let live = NSMenuItem(title: "Create Live Folder", action: nil, keyEquivalent: "")
            live.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
            live.submenu = NSMenu()
            live.submenu?.items = [
                item("RSS or Atom Feed…", symbol: "dot.radiowaves.up.forward") { browser.newLiveFolder("feed") },
                item("GitHub Pull Requests…", symbol: "arrow.triangle.pull") { browser.newLiveFolder("pulls") },
                item("GitHub Issues…", symbol: "smallcircle.filled.circle") { browser.newLiveFolder("issues") },
            ]
            menu.addItem(live)
            // Buttons for the foot, beside the spaces.
            let missing = FootButton.allCases.filter { !browser.prefs.foot.contains($0) }
            if !missing.isEmpty {
                let add = NSMenuItem(title: "Add to Sidebar", action: nil, keyEquivalent: "")
                add.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
                add.submenu = NSMenu()
                add.submenu?.items = missing.map { button in
                    item(button.title, symbol: button.symbol) { browser.prefs.foot.append(button) }
                }
                menu.addItem(add)
            }
            menu.addItem(.separator())
            let split = item("New Split", symbol: "rectangle.split.2x1") { browser.newSplit() }
            split.isEnabled = browser.active.map(browser.splittable) == true
            menu.addItem(split)
            menu.addItem(item("New Tab", symbol: "plus") { browser.newTab() })
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
    /// Off while something else takes the symbol's place (a download's progress).
    var showsSymbol = true
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .opacity(showsSymbol ? 1 : 0)
                .frame(width: 26, height: 26)
                .background { if hovering { Tinted(shape: Rounded.row, fill: Palette.hover) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.hover, value: hovering)
    }
}

/// The page's address at the top of the sidebar while the toolbar is hidden:
/// the host, with copying the link and the extensions beside it. A click
/// brings out the toolbar with the address ready to edit, as ⌘L does.
struct AddressPill: View {
    @ObservedObject var browser: Browser

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    static let height: CGFloat = 32

    private var host: String {
        guard let tab = browser.active, !tab.isBlank, let url = tab.shownAddress else { return "Search or enter an address" }
        return url.host().map { $0.replacingOccurrences(of: "www.", with: "", options: .anchored) } ?? url.absoluteString
    }

    private var editing: Bool { browser.editingInPill }

    var body: some View {
        HStack(spacing: 2) {
            if editing {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    AddressField(browser: browser, size: 12, placeholder: "Search or enter address") { browser.dismiss() }
                        .frame(height: 18)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(KeepZone())
            } else {
                shown
            }
            if !editing {
                // Packed close, as in Zen's address bar: the address keeps the room.
                HStack(spacing: 0) {
                    if browser.active?.isBlank == false {
                        Door(icon: "link", help: "Copy Address   ⇧⌘C", act: browser.copyAddress)
                    }
                    if let tab = browser.active { TranslateButton(browser: browser, tab: tab) }
                    if browser.prefs.showsPageActions, #available(macOS 15.4, *) { PageActionButton(extensions: .shared) }
                    PageButton(browser: browser, asks: browser.navInSidebar)
                }
                .environment(\.packedButtons, true)
            }
        }
        .padding(.trailing, 2)
        .frame(height: Self.height)
        .background {
            Tinted(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), fill: editing || hovering ? Palette.hover : Palette.wash)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ink.opacity(editing ? 0.14 : 0))
                .allowsHitTesting(false)
        }
        .shakesOnRefusal(browser.field.refusals, while: editing, travel: $shake)
        .onHover { hovering = $0 }
        // Suggestions in a panel of their own: the sidebar is too narrow and
        // clipped, and the field keeps the keyboard.
        .menuPanel(
            isPresented: Binding(
                get: { editing && !browser.field.offers.isEmpty },
                set: { if !$0 { browser.dismiss() } }),
            edge: .bottom, keyboard: false
        ) {
            SuggestionList(browser: browser).frame(width: 440)
        }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.quick, value: editing)
    }

    private var shown: some View {
        HStack(spacing: 0) {
            // The site card hangs from it, as from the toolbar's.
            if let tab = browser.active, !tab.isBlank { SiteButton(browser: browser, tab: tab, compact: true).padding(.leading, 4) }
            address
        }
    }

    private var address: some View {
        Button(action: browser.edit) {
            HStack(spacing: 6) {
                Text(host)
                    .font(.system(size: 12))
                    .foregroundStyle(browser.active?.isBlank == false ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, browser.active?.isBlank == false ? 2 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit the address   ⌘L")
    }
}

extension View {
    /// Runs `act` on a right-click (or a control-click), leaving every other
    /// click to the view underneath.
    func onRightClick(_ act: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(act: act))
    }
}

private struct RightClickCatcher: FillsRoom {
    let act: () -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.act = act }

    final class Catcher: NSView {
        var act: (() -> Void)?

        private static func isRightClick(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        /// Only right-clicks land here; the rest go through to the view below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.isRightClick(NSApp.currentEvent) ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { act?() }
        override func mouseDown(with event: NSEvent) { act?() }
    }
}

/// Which view a space's icon picker hangs from.
enum IconAnchor { case foot, header, dot }

/// The icon picker open now: for which space, from which view.
struct IconPick: Equatable {
    let space: UUID
    let from: IconAnchor
}

extension View {
    /// The icon picker for `space`, hanging from this view while it's the one
    /// asked for. It goes with the view, as when the sidebar tucks away.
    func iconPicker(browser: Browser, space: Space, from anchor: IconAnchor) -> some View {
        modifier(IconPickerHost(browser: browser, space: space, anchor: anchor))
    }
}

private struct IconPickerHost: ViewModifier {
    @ObservedObject var browser: Browser
    let space: Space
    let anchor: IconAnchor

    private var mine: Bool { browser.pickingIcon == IconPick(space: space.id, from: anchor) }

    func body(content: Content) -> some View {
        content
            .popover(
                isPresented: Binding(get: { mine }, set: { if !$0, mine { browser.pickingIcon = nil } }), arrowEdge: .top
            ) {
                IconPicker(current: space.emoji ?? space.symbol) { icon in
                    browser.setSpaceIcon(space.id, to: icon)
                    browser.pickingIcon = nil
                }
            }
            .onDisappear { if mine { browser.pickingIcon = nil } }
    }
}
