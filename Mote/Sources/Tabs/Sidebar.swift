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
            // On the right, the lights stay at the window's top left (see ChromeDetail).
            TrafficLights(showing: showing && !prefs.sideRight, inset: browser.folded ? ChromeLayout.gap : 0)
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
                    AppMenuButton(browser: browser)
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
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        .animation(Motion.settle, value: browser.keptCount)
        .animation(Motion.settle, value: browser.playing?.id)
    }

    // MARK: - Spaces, side by side

    private var spaces: some View {
        SpacePages(browser: browser, prefs: prefs, swipe: browser.swipeOffset, drag: $drag, keptDrag: $keptDrag)
    }

    /// Where the rows end and the window-dragging room starts. Worked out, not
    /// measured: a measurement is a frame late, and for that frame the whole
    /// sidebar would drag the window.
    private var rowsEnd: CGFloat {
        let pill = browser.navInSidebar ? AddressPill.height + Self.pillGap : 0
        let rows = Self.rowsHeight(
            essentials: browser.essentialCount, kept: browser.keptCount, loose: browser.tabs.count - browser.pinnedCount,
            width: prefs.sideWidth, named: browser.usesSpaces)
        return Self.top + pill + rows + 8
    }

    /// How tall a space's page stands: its essentials, name, pinned tabs,
    /// the rest and "New tab".
    static func rowsHeight(essentials pins: Int, kept: Int, loose: Int, width: CGFloat, named: Bool) -> CGFloat {
        let grid = PinGrid(count: pins, width: width - 20, gap: pinGap)
        let essentials = pins == 0 ? 0 : grid.height(pins) + 10
        let keptRows = kept == 0 ? 0 : CGFloat(kept) * (row + gap) - gap + divider
        let header = named ? SpaceHeader.height + gap : 0
        return essentials + header + keptRows + CGFloat(loose) * (row + gap) + row
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
            if browser.isPrivate {
                // Where the spaces would be: this window keeps nothing.
                Label("Private", systemImage: "eye.slash")
                    .font(TextStyle.secondary.font.weight(.medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 6)
                    .help("A private window: no history, and nothing kept once it closes")
                Spacer(minLength: 4)
            } else if browser.usesSpaces {
                chats(titled: false)
                Spacer(minLength: 4)
                SpaceIcons(browser: browser)
                Spacer(minLength: 4)
            } else {
                chats(titled: true)
            }
            FootIcon(symbol: "books.vertical", help: "Library   ⌥⇧L") { browser.toggleLibrary() }
            AddMenuButton(browser: browser)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
    }
}

/// Every space's page side by side, kept built, as Zen keeps a strip per
/// workspace: switching only moves another into view and makes it the live
/// one, rather than taking one list down and building another. Its own view,
/// so a swipe's every frame moves the pages and redraws nothing else.
private struct SpacePages: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var swipe: SwipeOffset
    @Binding var drag: ReorderDrag<Tab.ID>?
    @Binding var keptDrag: ReorderDrag<Tab.ID>?

    /// This space's place; the spaces' count while the new-space card shows.
    private var spaceIndex: Int {
        browser.makingSpace ? browser.spaces.count : browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
    }

    var body: some View {
        let width = prefs.sideWidth
        let swipe = swipe.value
        let swiping = swipe != 0
        let here = spaceIndex
        GeometryReader { room in
            ZStack(alignment: .topLeading) {
                ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                    let live = index == here && !browser.makingSpace
                    SpacePage(
                        browser: browser, prefs: prefs, space: space, live: live, room: room.size.height, drag: $drag, keptDrag: $keptDrag
                    )
                    .padding(.horizontal, 10)
                    .frame(width: width, alignment: .topLeading)
                    .offset(x: CGFloat(index - here) * width + swipe)
                    // Built and laid out, but only drawn when it can be seen.
                    .opacity(live || (swiping && abs(index - here) == 1) ? 1 : 0)
                    .allowsHitTesting(live)
                    .accessibilityHidden(!live)
                }
                if browser.makingSpace || (swipe < 0 && here == browser.spaces.count - 1) {
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
        }
        // Pages span the whole sidebar and keep their own margins.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One space's tabs: its essentials, name, pinned tabs and the rest. The
/// showing space's are live; another's, sliding in during a swipe, are its
/// parked row, drawn the same way but not to be touched.
private struct SpacePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let space: Space
    let live: Bool
    /// The height the page has.
    let room: CGFloat
    @Binding var drag: ReorderDrag<Tab.ID>?
    @Binding var keptDrag: ReorderDrag<Tab.ID>?
    @ObservedObject private var folderStore = FolderStore.shared
    @ObservedObject private var feeds = LiveFeeds.shared

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
        let lines = keptLines(kept)
        VStack(alignment: .leading, spacing: 0) {
            if !essentials.isEmpty {
                PinnedTabs(browser: browser, prefs: prefs, tabs: essentials, active: active, live: live)
                    .padding(.bottom, 10)
            }
            if browser.usesSpaces { SpaceHeader(browser: browser, space: space).padding(.bottom, Self.gap) }
            if !lines.isEmpty { keptRows(kept, lines: lines) }
            // A plain stack until the tabs overflow, so the room below them
            // still drags the window. Worked out, not measured: ViewThatFits
            // lays the rows out twice, on every page, on every change.
            let overflows =
                Sidebar.rowsHeight(
                    essentials: essentials.count, kept: lines.count, loose: loose.count, width: prefs.sideWidth, named: browser.usesSpaces)
                > room
            if !overflows {
                listed(loose)
            } else {
                ScrollViewReader { scroller in
                    // No scroll bar, as in Zen: one over the rows would cover their close buttons.
                    ScrollView(.vertical) { listed(loose) }
                        .scrollIndicators(.never)
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

    /// A row, told only what it draws, so it redraws when that or its tab
    /// changes, not on every change to the browser.
    private func row(_ tab: Tab) -> SideRow {
        let renaming = live && browser.editingTab == tab.id
        return SideRow(
            browser: browser, tab: tab, live: tab.id == active, renaming: renaming,
            draft: renaming ? browser.tabDraft : "", refusals: renaming ? browser.field.refusals : 0,
            icons: prefs.glyph == .icons, showsReading: prefs.showsReading,
            preview: live && tab.id == active ? browser.peekTab : nil, carded: live && browser.siteCardRow == tab.id)
    }

    /// The line between the pinned tabs and the others.
    private static var rule: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 6).padding(.vertical, (divider - 1) / 2)
    }

    /// Pinned tabs, rows that stay when closed, above the others: folders
    /// first, each with its folders and tabs a step in, then the tabs in none.
    /// Those last reorder by dragging; a tab goes into a folder from its menu.
    /// One line of the pinned section: a folder's or a tab's, or an item of
    /// a live folder (a feed's post, a pull request), under its folder.
    private enum KeptLine: Hashable {
        case line(Folder.Line<Tab.ID>)
        case item(LiveItem, depth: Int)
    }

    /// The pinned section's lines, an open live folder's items after it.
    private func keptLines(_ kept: [Tab]) -> [KeptLine] {
        let folders = folderStore.folders(in: space.id)
        return Folder.outline(folders, tabs: kept.map { ($0.id, $0.folder) }, active: active).flatMap { line -> [KeptLine] in
            guard case .folder(let id, let depth) = line, let folder = folders.first(where: { $0.id == id }), folder.live != nil,
                !folder.collapsed
            else { return [.line(line)] }
            // The newest few: a feed can hold hundreds.
            return [.line(line)] + feeds.items(in: id).prefix(LiveFeeds.shown).map { .item($0, depth: depth + 1) }
        }
    }

    private func keptRows(_ kept: [Tab], lines: [KeptLine]) -> some View {
        let folders = folderStore.folders(in: space.id)
        let unfiled = lines.compactMap { line -> Tab? in
            guard case .line(.tab(let id, 0)) = line else { return nil }
            return kept.first { $0.id == id }
        }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Self.gap) {
                ForEach(lines, id: \.self) { entry in
                    switch entry {
                    case .item(let item, let depth):
                        LiveItemRow(browser: browser, item: item, read: feeds.isRead(item)).padding(.leading, CGFloat(depth) * Self.indent)
                    case .line(let line):
                        switch line {
                        case .folder(let id, let depth):
                            if let folder = folders.first(where: { $0.id == id }) {
                                FolderRow(browser: browser, folder: folder, live: live, dropping: browser.folderHover == folder.id)
                                    .padding(.leading, CGFloat(depth) * Self.indent)
                            }
                        case .tab(let id, let depth):
                            if let tab = kept.first(where: { $0.id == id }) {
                                if depth == 0, let index = unfiled.firstIndex(where: { $0.id == id }) {
                                    row(tab)
                                        // Places count among the pinned tabs, after the essentials.
                                        .modifier(
                                            Reorderable(
                                                id: tab.id, index: index, places: 0..<unfiled.count,
                                                lattice: .column(step: Self.row + Self.gap),
                                                space: "kept", drag: $keptDrag, filing: (browser, tab)
                                            ) { target in
                                                // To where the tab now in that place sits among all the pinned ones.
                                                let place = kept.firstIndex { $0.id == unfiled[target].id } ?? target
                                                browser.move(tab, to: place + browser.essentialCount)
                                            })
                                } else {
                                    row(tab).padding(.leading, CGFloat(depth) * Self.indent)
                                }
                            }
                        }
                    }
                }
            }
            .overlay { closing(lines.map { line in if case .line(.tab(let id, _)) = line { kept.first { $0.id == id } } else { nil } }) }
            .coordinateSpace(name: "kept")
            Self.rule
        }
    }

    /// How far each level of folders steps in.
    private static let indent: CGFloat = 14

    /// A middle click on a row closes its tab, as ⌘W does.
    /// `tabs` line by line; nil for a line that isn't a tab (a folder).
    private func closing(_ tabs: [Tab?]) -> some View {
        MiddleClick { at in
            let index = Int(at.y / (Self.row + Self.gap))
            if tabs.indices.contains(index), let tab = tabs[index] { browser.close(tab) }
        }
    }

    private func listed(_ loose: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Self.gap) {
                ForEach(Array(loose.enumerated()), id: \.element.id) { index, tab in
                    row(tab)
                        .background {
                            if let run = browser.splitRun(at: index, in: loose) {
                                SplitRun(axis: .vertical, first: run.first, last: run.last, gap: Self.gap)
                            }
                        }
                        // Places count among the loose tabs, after the essentials and pinned ones.
                        .modifier(
                            Reorderable(
                                id: tab.id, index: index, places: 0..<loose.count, lattice: .column(step: Self.row + Self.gap),
                                space: "rows", drag: $drag, away: (browser, tab), filing: (browser, tab)
                            ) { browser.move(tab, to: $0 + browser.pinnedCount) })
                }
            }
            .overlay { closing(loose.map { $0 }) }
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

    @State private var drag: ReorderDrag<Tab.ID>?

    private static let gap: CGFloat = 6

    var body: some View {
        let grid = PinGrid(count: tabs.count, width: prefs.sideWidth - 20, gap: Self.gap)
        // Drags are measured in the grid's space (see Reorderable).
        PinCells(grid: grid) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PinSquare(
                    browser: browser, tab: tab, live: tab.id == active, lettering: live && browser.editingPin == tab.id,
                    icons: prefs.glyph == .icons, size: grid.cell
                )
                .modifier(
                    Reorderable(
                        id: tab.id, index: index, places: 0..<tabs.count, lattice: Lattice(columns: grid.columns, step: grid.step),
                        space: "pins", drag: $drag
                    ) { browser.move(tab, to: $0) })
            }
        }
        // As ⌘W: a pinned tab lets its page go and stays pinned.
        .overlay {
            MiddleClick { at in
                let index = Int(at.y / grid.step.height) * grid.columns + Int(at.x / grid.step.width)
                if tabs.indices.contains(index) { browser.close(tabs[index]) }
            }
        }
        .coordinateSpace(name: "pins")
    }
}

/// The essential in front, as Zen's (`zen.theme.essentials-favicon-bg`):
/// its own icon blown up to twice the square and blurred behind it, under
/// a frosted panel inset by 2 points, so the icon's colours ring the edge
/// and wash the middle. Drawn only for the one in front.
private struct IconGlow: View {
    let icon: NSImage
    let corner: CGFloat
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        GeometryReader { room in
            ZStack {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: room.size.width * 2, height: room.size.height * 2)
                    .blur(radius: 20)
                RoundedRectangle(cornerRadius: corner - 2, style: .continuous)
                    .fill(dark ? Color(red: 68 / 255, green: 64 / 255, blue: 64 / 255).opacity(0.85) : .white.opacity(0.85))
                    .padding(2)
            }
            .frame(width: room.size.width, height: room.size.height)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
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
    /// For what it does; it watches only its tab (see `SpacePage.row`).
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    /// Its letter is being changed.
    let lettering: Bool
    let icons: Bool
    let size: CGSize

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// Contents scale with the shorter side, so the mark stays its usual size.
    private var side: CGFloat { min(size.width, size.height) }
    private var corner: CGFloat { side * 10 / 36 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        mark
            .frame(width: side * 16 / 34, height: side * 16 / 34)
            .frame(width: size.width, height: size.height)
            .background {
                if live, let icon = tab.icon {
                    IconGlow(icon: icon, corner: corner, dark: colorScheme == .dark)
                } else if live {
                    Lifted(corner: corner)
                } else {
                    shape.fill(Palette.veil.opacity(hovering ? 1.8 : 1))
                }
            }
            .contentShape(shape)
            .modifier(OneClick(double: live) { live ? browser.editLetter(tab) : browser.select(tab) })
            .onHover { hovering = $0 }
            .contextMenu { TabMenu(browser: browser, tab: tab) { browser.close(tab) } }
            .help(tab.label)
            .animation(Motion.hover, value: hovering)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    @ViewBuilder
    private var mark: some View {
        if lettering {
            InlineField.letter(of: tab, in: browser)
        } else if icons, let icon = tab.icon {
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
    /// For what it does; it watches only its tab (see `SpacePage.row`).
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let renaming: Bool
    /// The new name so far, while renaming: the field redraws as it changes.
    let draft: String
    let refusals: Int
    let icons: Bool
    let showsReading: Bool
    /// The link preview open over this tab, if any: its icon ends the row, as
    /// Zen's Glance does, and a click on it keeps the preview as a tab.
    let preview: Tab?
    /// The site card hangs beside it.
    let carded: Bool

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    /// The title's end is faded, or fading back: masked only then, as a mask
    /// costs every row a drawing pass of its own.
    @State private var fading = false

    /// The speaker; clickable, so on hover it moves aside for the close button.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    /// The loading ring or speaker holds the end of the row. The close button
    /// only comes on hover and holds no room of its own.
    private var status: Bool { !renaming && (tab.loading || speaker || preview != nil) }
    private var colour: Color { live ? Palette.ink : Palette.ink.opacity(hovering ? 0.8 : 0.62) }
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 8) {
            if renaming {
                InlineField.rename(browser).frame(height: 16)
            } else {
                if icons, !tab.isBlank || tab.isStart {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 16, mote: tab.isStart)
                }
                TabMarks(tab: tab, colour: colour)
                Text(tab.label).font(TextStyle.body.font).lineLimit(1).truncationMode(.tail).foregroundStyle(colour)
            }
            if status {
                Spacer(minLength: 2)
                ZStack {
                    if let preview {
                        PreviewMark(tab: preview) { browser.keepPeek() }.transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
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
        .modifier(TitleFade(on: fading && !renaming && !status, faded: hovering))
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .background { backdrop }
        .shakesOnRefusal(refusals, while: renaming, travel: $shake)
        .contentShape(shape)
        // A double click renames the tab you're on; a click goes to any other.
        .modifier(OneClick(double: live) { live ? browser.beginTabRename(tab) : browser.select(tab) })
        // Over the row, not inside it: inside, its click would wait out the
        // double-click interval of the tab you're on before closing it.
        .overlay(alignment: .trailing) {
            if !renaming {
                let home = tab.wandered
                Shut(shown: hovering, home: home, act: home ? { browser.goHome(tab) } : close)
                    .padding(.trailing, preview == nil ? 7 : 30)
            }
        }
        .onHover { over in
            hovering = over
            if over { fading = true }
        }
        .task(id: hovering) {
            guard !hovering, fading else { return }
            try? await Task.sleep(for: .seconds(0.15))
            if !Task.isCancelled { fading = false }
        }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .background { if carded { SiteCardAnchor(row: true) } }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.glide, value: renaming)
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    private func close() { browser.close(tab) }

    @ViewBuilder
    private var backdrop: some View {
        if live {
            Lifted(corner: 10) {
                if showsReading {
                    // How far the page is read, as a faint fill across the row.
                    ReadFill(reading: tab.reading)
                }
            }
        } else if hovering {
            shape.fill(Palette.veil)
        }
    }
}

/// A row's title fading out under its close button.
private struct TitleFade: ViewModifier {
    let on: Bool
    /// Faded, rather than fading back.
    let faded: Bool

    /// Put on, so a mask that has just come fades from the full title.
    @State private var settled = false

    func body(content: Content) -> some View {
        if on {
            content.mask {
                ZStack {
                    Rectangle().opacity(faded && settled ? 0 : 1)
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        Color.clear.frame(width: 30)
                    }
                }
                .onAppear { withAnimation(Motion.hover) { settled = true } }
                .onDisappear { settled = false }
            }
        } else {
            content
        }
    }
}

/// The site a link preview shows, at the end of the row of the tab it's open
/// over; a click keeps it as a tab.
private struct PreviewMark: View {
    @ObservedObject var tab: Tab
    let keep: () -> Void

    var body: some View {
        Mark(icon: tab.icon, letter: tab.monogram, size: 14)
            .padding(1)
            .background(Palette.veil, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: keep)
            .help("Previewing “\(tab.label)” — click to keep it as a tab")
    }
}

/// A folder among the pinned tabs, as Zen's: a click opens or closes it, and
/// its menu renames, nests, unloads, unpacks or deletes it.
private struct FolderRow: View {
    let browser: Browser
    let folder: Folder
    /// The showing space's; another's, during a swipe, is only drawn.
    let live: Bool
    /// A dragged tab is over it, and would drop in.
    let dropping: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 10)
            Group {
                if let icon = folder.icon {
                    Text(icon).font(.system(size: 13))
                } else {
                    Image(systemName: folder.live != nil ? "dot.radiowaves.left.and.right" : folder.collapsed ? "folder" : "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink.opacity(0.7))
                }
            }
            .frame(width: 16)
            Text(folder.name).font(TextStyle.body.font).foregroundStyle(Palette.ink.opacity(0.8)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
        .background { if hovering || dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.veil) } }
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5) }
        }
        .animation(Motion.quick, value: dropping)
        // Where it is, for a tab dragged onto it; only in the space showing.
        .background { if live && folder.live == nil { FolderSpot(browser: browser, id: folder.id) } }
        .contentShape(Rectangle())
        .onTapGesture { if live { withAnimation(Motion.settle) { browser.toggleFolder(folder.id) } } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Folder…") { browser.renameFolder(folder.id) }
            Button("Change Icon…") { browser.changeFolderIcon(folder.id) }
            if folder.live != nil { Button("Refresh Now") { LiveFeeds.shared.refresh(folder) } }
            Button("New Subfolder…") { browser.newFolder(in: folder.id) }
            Divider()
            Button("Unload All Tabs") { browser.unloadFolder(folder.id) }
            Button("Unpack Folder") { browser.unpackFolder(folder.id) }
            Button("Delete Folder") { browser.deleteFolder(folder.id) }
        }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("Folder \(folder.name), \(folder.collapsed ? "closed" : "open")")
    }
}

/// A live folder's item: a post or a pull request, opening in a tab; a dot
/// until it's been opened.
private struct LiveItemRow: View {
    let browser: Browser
    let item: LiveItem
    let read: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(read ? Color.clear : Color.accentColor).frame(width: 6, height: 6).frame(width: 16)
            Text(item.title).font(TextStyle.body.font).foregroundStyle(Palette.ink.opacity(read ? 0.55 : 0.85)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
        .background { if hovering { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.veil) } }
        .contentShape(Rectangle())
        .onTapGesture { browser.open(item, foreground: true) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { browser.open(item, foreground: true) }
            Button("Open in Background") { browser.open(item, foreground: false) }
            Button("Mark as Read") { LiveFeeds.shared.markRead(item) }.disabled(read)
        }
        .help(item.url.absoluteString)
        .animation(Motion.hover, value: hovering)
    }
}

/// Marks a folder's row for a dragged tab to find (Browser.hoverFolder): an
/// AppKit view, as the sidebar's rows are hosted apart from the window's.
private struct FolderSpot: FillsRoom {
    let browser: Browser
    let id: UUID

    func makeNSView(context: Context) -> NSView {
        let spot = Spot()
        browser.folderSpots[id] = WeakView(spot)
        return spot
    }

    func updateNSView(_ view: NSView, context: Context) { browser.folderSpots[id] = WeakView(view) }

    private final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
