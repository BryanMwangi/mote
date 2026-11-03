import MoteCore
import SwiftUI
import UniformTypeIdentifiers

/// The tabs down the left, on the window's frame: the traffic lights, the
/// pinned tabs in a grid, the rest in a list, and spaces and chats at
/// the foot. The page's own controls are in the toolbar beside it.
struct Sidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The sidebar on screen. The docked one stays built while folded; only
    /// the one showing opens the chats menu.
    var showing = true

    @State private var dropping = false
    @State private var chatsOpen = false
    /// A tab being dragged to a new place in the list.
    @State private var drag: ReorderDrag<Tab.ID>?
    @State private var keptDrag: ReorderDrag<Tab.ID>?

    /// A tab row's height and the gap between rows.
    private static let row = Metrics.row
    private static let gap: CGFloat = 2
    private static let pinGap: CGFloat = 6
    /// The line under the pinned tabs, with the room around it.
    private static let divider: CGFloat = 13
    /// The band at the top that holds the traffic lights.
    static let top: CGFloat = 50
    private static let footHeight: CGFloat = 50
    /// Under the address pill, when the toolbar is hidden.
    private static let pillGap: CGFloat = 10

    var body: some View {
        ZStack(alignment: .top) {
            // Under the rows, empty sidebar drags the window; not while the
            // new-space card is up, whose ground wouldn't take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd)
            // The band by the traffic lights works as a title bar.
            DragStrip().frame(height: Self.top)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.top)
                if browser.navInSidebar { AddressPill(browser: browser).padding(.bottom, Self.pillGap) }
                spaces
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Self.footHeight + (browser.playing == nil ? 0 : MediaStrip.height + MediaStrip.gap))

            VStack(spacing: 0) {
                Spacer()
                if let tab = browser.playing {
                    MediaStrip(browser: browser, tab: tab)
                        .padding(.horizontal, 10)
                        .padding(.bottom, MediaStrip.gap)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            TrafficLights(showing: showing, inset: browser.folded ? ChromeLayout.gap : 0)
                .frame(width: Metrics.lights, height: Self.top)
        }
        // With the toolbar hidden, its sidebar button and back, forward and
        // reload come here, beside the traffic lights.
        .overlay(alignment: .topTrailing) {
            if browser.navInSidebar {
                // Narrow sidebars keep clear of the traffic lights: smaller
                // buttons, and ⌘S alone for the sidebar.
                HStack(spacing: 2) {
                    if prefs.sideWidth >= 220 {
                        Door(icon: "sidebar.left", help: browser.folded ? "Show Sidebar   ⌘S" : "Hide Sidebar   ⌘S") {
                            browser.toggleFold()
                        }
                    }
                    Helm(browser: browser)
                }
                .controlSize(prefs.sideWidth >= 260 ? .large : .regular)
                .padding(.trailing, 8)
                .frame(height: Self.top)
            }
        }
        // Pages sliding in from other spaces stay inside.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // Nothing of its own behind: the window's frame shows through.
        .background(Palette.veil.opacity(dropping ? 1 : 0))
        .onDrop(of: [.url, .text], isTargeted: $dropping) { browser.take($0) }
        .animation(Motion.quick, value: dropping)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        .animation(Motion.settle, value: browser.keptCount)
        .animation(Motion.settle, value: browser.playing?.id)
    }

    // MARK: - Spaces, side by side

    /// This space's place; the spaces' count while the new-space card shows.
    private var spaceIndex: Int {
        browser.makingSpace ? browser.spaces.count : browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
    }

    /// Every space's page side by side, kept built, as Zen keeps a strip per
    /// workspace: switching only moves another into view and makes it the
    /// live one, rather than taking one list down and building another.
    private var spaces: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let here = spaceIndex
        let swiping = swipe != 0
        return ZStack(alignment: .topLeading) {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                let live = index == here && !browser.makingSpace
                SpacePage(browser: browser, prefs: prefs, space: space, live: live, drag: $drag, keptDrag: $keptDrag)
                    .padding(.horizontal, 10)
                    .frame(width: width, alignment: .topLeading)
                    .offset(x: CGFloat(index - here) * width + swipe)
                    // Built and laid out, but only drawn when it can be seen.
                    .opacity(live || (swiping && abs(index - here) == 1) ? 1 : 0)
                    .allowsHitTesting(live)
                    .accessibilityHidden(!live)
            }
            if browser.makingSpace || (swiping && here == browser.spaces.count - 1 && swipe < 0) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 10)
                .frame(width: width, alignment: .topLeading)
                .offset(x: CGFloat(browser.spaces.count - here) * width + swipe)
                .allowsHitTesting(browser.makingSpace)
            }
        }
        // Pages span the whole sidebar and keep their own margins.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Where the rows end and the window-dragging room starts. Worked out, not
    /// measured: a measurement is a frame late, and for that frame the whole
    /// sidebar would drag the window.
    private var rowsEnd: CGFloat {
        let pins = browser.essentialCount
        let grid = PinGrid(count: pins, width: prefs.sideWidth - 20, gap: Self.pinGap)
        let essentials = pins == 0 ? 0 : grid.height(pins) + 10
        let kept = browser.keptCount == 0 ? 0 : CGFloat(browser.keptCount) * (Self.row + Self.gap) - Self.gap + Self.divider
        let loose = CGFloat(browser.tabs.count - browser.pinnedCount) * (Self.row + Self.gap)
        let header = prefs.usesSpaces ? SpaceHeader.height + Self.gap : 0
        let pill = browser.navInSidebar ? AddressPill.height + Self.pillGap : 0
        return Self.top + pill + essentials + header + kept + loose + Self.row + 8
    }

    /// The chat archive, in a panel beside the sidebar.
    private func chats(titled: Bool) -> some View {
        Group {
            if titled {
                Quiet(icon: "bubble.left.and.bubble.right", title: "Chats", height: Self.footHeight - 10) { chatsOpen.toggle() }
            } else {
                FootIcon(symbol: "bubble.left.and.bubble.right", help: "Chats") { chatsOpen.toggle() }
            }
        }
        .menuPanel(isPresented: showing ? $chatsOpen : .constant(false), edge: .trailing) {
            ChatsPage(browser: browser, inPanel: true) { chatsOpen = false }
                .frame(width: 380, height: 440)
        }
    }

    /// The chat archive, every space, and a plus for a new tab or space.
    private var foot: some View {
        HStack(spacing: 2) {
            if browser.prefs.usesSpaces {
                chats(titled: false)
                Spacer(minLength: 4)
                SpaceIcons(browser: browser)
                Spacer(minLength: 4)
            } else {
                chats(titled: true)
            }
            AddMenuButton(browser: browser)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
    }
}

/// One space's tabs: its essentials, name, pinned tabs and the rest. The
/// showing space's are live; another's are its parked row, drawn the same
/// way and kept built, so it can come into view at once.
private struct SpacePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let space: Space
    let live: Bool
    @Binding var drag: ReorderDrag<Tab.ID>?
    @Binding var keptDrag: ReorderDrag<Tab.ID>?

    /// Each page has its own, so the highlight under the tab in front never
    /// jumps between pages.
    @Namespace private var ground

    private static let row = Metrics.row
    private static let gap: CGFloat = 2
    private static let divider: CGFloat = 13

    private var tabs: [Tab] { live ? browser.tabs : browser.parked[space.id]?.tabs ?? [] }
    private var active: Tab.ID? { live ? browser.activeID : browser.parked[space.id]?.active }

    var body: some View {
        let tabs = tabs
        let essentials = tabs.filter { $0.section == .essential }
        let kept = tabs.filter { $0.section == .pinned }
        let loose = tabs.filter { $0.section == .loose }
        VStack(alignment: .leading, spacing: 0) {
            if !essentials.isEmpty {
                PinnedTabs(browser: browser, prefs: prefs, tabs: essentials, active: active, live: live, ground: ground)
                    .padding(.bottom, 10)
            }
            if prefs.usesSpaces { SpaceHeader(browser: browser, space: space).padding(.bottom, Self.gap) }
            if !kept.isEmpty { keptRows(kept) }
            // A plain stack until the tabs overflow, so the room below them still drags the window.
            ViewThatFits(in: .vertical) {
                listed(loose)
                ScrollViewReader { scroller in
                    // Into the trailing margin, so the scroller sits beside the
                    // close buttons rather than on them; the resize handle covers it.
                    ScrollView(.vertical) { listed(loose).padding(.trailing, 10).floatingScroller() }
                        .padding(.trailing, -10)
                        .onChange(of: browser.activeID) { _, id in
                            if live, let id { withAnimation(Motion.glide) { scroller.scrollTo(id) } }
                        }
                        .onChange(of: live) { _, now in
                            if now, let id = active { scroller.scrollTo(id, anchor: .center) }
                        }
                        .onAppear { if let id = active { scroller.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    /// The line between the pinned tabs and the others.
    private static var rule: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 6).padding(.vertical, (divider - 1) / 2)
    }

    /// Pinned tabs: rows that stay when closed, above the others.
    private func keptRows(_ kept: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Self.gap) {
                ForEach(Array(kept.enumerated()), id: \.element.id) { index, tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == active, ground: ground) {
                        browser.close(tab)
                    }
                    // Places count among the pinned tabs, after the essentials.
                    .modifier(
                        Reorderable(
                            id: tab.id, index: index, places: 0..<kept.count, lattice: .column(step: Self.row + Self.gap),
                            space: "kept", drag: $keptDrag
                        ) { browser.move(tab, to: $0 + browser.essentialCount) })
                }
            }
            .coordinateSpace(name: "kept")
            Self.rule
        }
    }

    private func listed(_ loose: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Self.gap) {
                ForEach(Array(loose.enumerated()), id: \.element.id) { index, tab in
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == active, ground: ground) {
                        browser.close(tab)
                    }
                    // Places count among the loose tabs, after the essentials and pinned ones.
                    .modifier(
                        Reorderable(
                            id: tab.id, index: index, places: 0..<loose.count, lattice: .column(step: Self.row + Self.gap),
                            space: "rows", drag: $drag
                        ) { browser.move(tab, to: $0 + browser.pinnedCount) })
                }
            }
            // Drags are measured in the list's space (see Reorderable).
            .coordinateSpace(name: "rows")
            Quiet(icon: "plus", title: "New tab", height: Self.row) { browser.newTab() }.padding(.top, Self.gap)
        }
    }
}

/// The essentials' grid, where cells drag in two directions.
private struct PinnedTabs: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let tabs: [Tab]
    let active: Tab.ID?
    let live: Bool
    let ground: Namespace.ID

    @State private var drag: ReorderDrag<Tab.ID>?

    private static let gap: CGFloat = 6

    var body: some View {
        let grid = PinGrid(count: tabs.count, width: prefs.sideWidth - 20, gap: Self.gap)
        // Drags are measured in the grid's space (see Reorderable).
        PinCells(grid: grid) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == active, ground: ground, size: grid.cell)
                    .modifier(
                        Reorderable(
                            id: tab.id, index: index, places: 0..<tabs.count, lattice: Lattice(columns: grid.columns, step: grid.step),
                            space: "pins", drag: $drag
                        ) { browser.move(tab, to: $0) })
            }
        }
        .coordinateSpace(name: "pins")
    }
}

/// Fixed cells, row by row, a short last row keeping to the left. Not a
/// LazyVGrid: that makes cells only once on screen, so they missed the
/// sidebar's slide in.
private struct PinCells: Layout {
    let grid: PinGrid

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: CGFloat(grid.columns) * grid.step.width - grid.gap, height: grid.height(subviews.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, cell) in subviews.enumerated() {
            let place = CGPoint(
                x: bounds.minX + CGFloat(index % grid.columns) * grid.step.width,
                y: bounds.minY + CGFloat(index / grid.columns) * grid.step.height)
            cell.place(at: place, proposal: ProposedViewSize(grid.cell))
        }
    }
}

/// A pinned tab in the sidebar's grid.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let ground: Namespace.ID
    let size: CGSize

    @State private var hovering = false

    /// Contents scale with the shorter side, so the mark stays its usual size.
    private var side: CGFloat { min(size.width, size.height) }
    private var corner: CGFloat { side * 10 / 36 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        mark
            .frame(width: side * 16 / 34, height: side * 16 / 34)
            .frame(width: size.width, height: size.height)
            .background {
                if live {
                    Lifted(corner: corner).matchedGeometryEffect(id: "live", in: ground)
                } else {
                    shape.fill(Palette.veil.opacity(hovering ? 1.8 : 1))
                }
            }
            .contentShape(shape)
            .modifier(OneClick(double: live) { live ? browser.editLetter(tab) : browser.select(tab) })
            // As ⌘W: a pinned tab lets its page go and stays pinned.
            .overlay { MiddleClick { browser.close(tab) } }
            .onHover { hovering = $0 }
            .contextMenu { TabMenu(browser: browser, tab: tab) { browser.close(tab) } }
            .help(tab.label)
            .animation(Motion.hover, value: hovering)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    @ViewBuilder
    private var mark: some View {
        if browser.editingPin == tab.id {
            InlineField.letter(of: tab, in: browser)
        } else if prefs.glyph == .icons, let icon = tab.icon {
            Mark(icon: icon, letter: tab.pin ?? "", size: side * 16 / 34, dim: tab.asleep)
        } else {
            Text(tab.pin ?? "")
                .font(.system(size: side * 12 / 34, weight: .medium))
                .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
        }
    }
}

/// A tab in the sidebar's list.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let ground: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var renaming: Bool { browser.editingTab == tab.id }
    /// The speaker; clickable, so on hover it moves aside for the close button.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    /// The loading ring or speaker holds the end of the row. The close button
    /// only comes on hover and holds no room of its own.
    private var status: Bool { !renaming && (tab.loading || speaker) }
    private var colour: Color { live ? Palette.ink : Palette.ink.opacity(hovering ? 0.8 : 0.62) }
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 8) {
            if renaming {
                InlineField.rename(browser).frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank || tab.isStart {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 16, mote: tab.isStart)
                }
                TabMarks(tab: tab, colour: colour)
                Text(tab.label).font(TextStyle.body.font).lineLimit(1).truncationMode(.tail).foregroundStyle(colour)
            }
            if status {
                Spacer(minLength: 2)
                ZStack {
                    if tab.loading { Ring().transition(.opacity) } else { Speaker(tab: tab).transition(.opacity) }
                }
                .frame(width: 16, height: 16)
                // On hover the close button takes this place and the speaker moves left.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 26 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, status ? 8 : 10)
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
        // The title fades out under the close button rather than being cut
        // short, so it doesn't move on hover.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !renaming && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                    Color.clear.frame(width: 30)
                }
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .background { backdrop }
        .shakesOnRefusal(browser.field.refusals, while: renaming, travel: $shake)
        .contentShape(shape)
        // A double click renames the tab you're on; a click goes to any other.
        .modifier(OneClick(double: live) { live ? browser.beginTabRename(tab) : browser.select(tab) })
        // Over the row, not inside it: inside, its click would wait out the
        // double-click interval of the tab you're on before closing it.
        .overlay(alignment: .trailing) {
            if !renaming { Shut(shown: hovering, act: close).padding(.trailing, 7) }
        }
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.glide, value: renaming)
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var backdrop: some View {
        if live {
            Lifted(corner: 10) {
                if prefs.showsReading {
                    // How far the page is read, as a faint fill across the row.
                    ReadFill(reading: tab.reading)
                }
            }
            .matchedGeometryEffect(id: "live", in: ground)
        } else if hovering {
            shape.fill(Palette.veil)
        }
    }
}
