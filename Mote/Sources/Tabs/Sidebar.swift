import MoteAI
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
    /// The media strips fanned out, with the tabs making room.
    @State private var mediaOpen = false
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
            .padding(.bottom, Self.footHeight + MediaStack.height(browser.players.count, open: mediaOpen))

            VStack(spacing: 0) {
                Spacer()
                if !browser.players.isEmpty {
                    MediaStack(browser: browser, players: browser.players, open: $mediaOpen)
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
        .animation(Motion.settle, value: browser.players.map(\.id))
        .animation(Motion.settle, value: mediaOpen)
        .environment(\.sidebarShowing, showing)
    }

    // MARK: - Spaces, side by side

    private var spaces: some View {
        SpacePages(
            browser: browser, prefs: prefs, shown: browser.swipeOffset.shown, drag: $drag, keptDrag: $keptDrag, dropping: $dropping)
    }

    /// Full-window chat tabs, which the Chats section holds when it shows.
    private var chatTabs: Int { prefs.chatsInSidebar ? browser.tabs.filter { $0.section == .loose && $0.chat != nil }.count : 0 }

    /// Where the rows end and the window-dragging room starts. Worked out, not
    /// measured: a measurement is a frame late, and for that frame the whole
    /// sidebar would drag the window.
    private var rowsEnd: CGFloat {
        let pill = browser.navInSidebar ? AddressPill.height + Self.pillGap : 0
        let rows = Self.rowsHeight(
            essentials: browser.essentialCount, kept: browser.keptCount, loose: browser.tabs.count - browser.pinnedCount - chatTabs,
            width: prefs.sideWidth, named: browser.usesSpaces, chats: ChatsSection.lines(prefs, tabs: chatTabs, selected: false))
        return Self.top + pill + rows + 8
    }

    /// How tall a space's page stands: its essentials, name, pinned tabs,
    /// the rest and "New tab".
    static func rowsHeight(essentials pins: Int, kept: Int, loose: Int, width: CGFloat, named: Bool, chats: Int = 0) -> CGFloat {
        let grid = PinGrid(count: pins, width: width - 20, gap: pinGap)
        let essentials = pins == 0 ? 0 : grid.height(pins) + 10
        let keptRows = kept == 0 ? 0 : CGFloat(kept) * (row + gap) - gap + divider
        let header = named ? SpaceHeader.height + gap : 0
        let chatRows = chats == 0 ? 0 : CGFloat(chats) * (row + gap) - gap + divider
        return essentials + header + chatRows + keptRows + CGFloat(loose) * (row + gap) + row
    }

    /// The user's buttons, every space, and a plus for a new tab or space.
    private var foot: some View {
        HStack(spacing: 2) {
            if browser.isPrivate {
                // Where the spaces would be: this window keeps nothing.
                Label("Private", systemImage: "eye.slash")
                    .font(TextStyle.secondary.font.weight(.medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 6)
                    .help("A private window: no history, and nothing kept once it closes")
            } else {
                FootButtons(browser: browser, prefs: prefs, showing: showing)
                if browser.usesSpaces {
                    SpaceIcons(browser: browser, prefs: prefs).padding(.horizontal, 4)
                } else {
                    Spacer(minLength: 4)
                }
            }
            if browser.isPrivate { Spacer(minLength: 4) }
            AddMenuButton(browser: browser)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
    }
}

/// Every space's page side by side, kept built switching only moves another
/// into view and makes it the live one, rather than taking one list down and
/// building another. A swipe moves
/// them by Core Animation (SwipeTrack); they're worked out again only as one
/// starts and ends, when the neighbouring pages show and hide.
private struct SpacePages: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var shown: SwipeShown
    @Binding var drag: ReorderDrag<Tab.ID>?
    @Binding var keptDrag: ReorderDrag<Tab.ID>?
    @Binding var dropping: Bool
    /// Passed into the pages' own hosting view, which starts without them:
    /// only what the rows read. The whole environment, new on every redraw
    /// of the sidebar, went through every row of every page each time.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.spaceTint) private var tint
    @Environment(\.sidebarShowing) private var showing

    /// This space's place; the spaces' count while the new-space card shows.
    private var spaceIndex: Int {
        browser.makingSpace ? browser.spaces.count : browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
    }

    var body: some View {
        let _ = SpaceSwipe.pagesDrawn += 1
        let content = pages.environment(\.colorScheme, scheme).environment(\.spaceTint, tint).environment(\.sidebarShowing, showing)
        SwipeTrack(swipe: browser.swipeOffset, content: AnyView(content), here: spaceIndex, count: browser.spaces.count + 1)
            // Pages span the whole sidebar and keep their own margins.
            .padding(.horizontal, -10)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swiping = shown.swiping
        let here = spaceIndex
        return GeometryReader { room in
            ZStack(alignment: .topLeading) {
                ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                    let live = index == here && !browser.makingSpace
                    // Its place from the page in front: the space a switch is
                    // leaving sits right beside it, as the one sliding out.
                    let coming = shown.coming[space.id]
                    // Each page keeps its place along the track, which moves
                    // whole (SwipeTrack): moved one by one, every row of every
                    // page was placed again on each switch. Only a space
                    // coming from afar sits beside this one (SpaceSwipe.go).
                    let place = coming.map { here + $0 } ?? index
                    let slot = place - here
                    // The pages either side are drawn all along, out of sight past
                    // the sidebar's edge, so a swipe starting draws nothing new;
                    // one coming from afar takes its neighbour's place.
                    let seen = live || coming != nil || (abs(slot) == 1 && !shown.coming.values.contains(slot))
                    SpacePage(
                        browser: browser, prefs: prefs, space: space, live: live, room: room.size.height, drag: $drag, keptDrag: $keptDrag
                    )
                    // Rows coming and going within a page; never the pages'
                    // places, which only a swipe or a switch's slide moves.
                    .animation(Motion.glide, value: browser.editingTab)
                    .animation(Motion.settle, value: rows(of: space, live: live))
                    .animation(Motion.settle, value: browser.players.map(\.id))
                    .padding(.horizontal, 10)
                    .frame(width: width, alignment: .topLeading)
                    .offset(x: CGFloat(place) * width)
                    // Built and laid out, but only drawn when it can be seen.
                    .opacity(seen ? 1 : 0)
                    .allowsHitTesting(live)
                    .accessibilityHidden(!live)
                }
                if browser.makingSpace || (swiping && here == browser.spaces.count - 1) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        NewSpaceCard(browser: browser)
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 10)
                    .frame(width: width, alignment: .topLeading)
                    .offset(x: CGFloat(browser.spaces.count) * width)
                    .allowsHitTesting(browser.makingSpace)
                }
            }
        }
        // The sidebar's own, which don't reach into another hosting view.
        .onDrop(of: [.url, .text], isTargeted: $dropping) { browser.take($0) }
    }

    /// A page's own rows and where each stands, which don't change when it
    /// becomes the space in front or leaves it.
    private func rows(of space: Space, live: Bool) -> [String] {
        (live ? browser.tabs : browser.parked[space.id]?.tabs ?? []).map { "\($0.id)\($0.section)" }
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
    /// A drag among one folder's tabs, by folder: each folder's rows make
    /// room only for their own.
    @State private var folderDrags: [UUID: ReorderDrag<Tab.ID>] = [:]
    /// Which way the selected tab is, scrolled out of sight; nil while it shows.
    @State private var activeAway: VerticalEdge?
    @State private var viewport: CGFloat = 0
    @ObservedObject private var folderStore = FolderStore.shared
    @ObservedObject private var feeds = LiveFeeds.shared

    private static let row = Metrics.row
    private static let gap: CGFloat = 2
    private static let divider: CGFloat = 13

    /// The docked and the floating sidebar are both built; only the one on
    /// screen edits a tab in place, or the two fields would take the keyboard
    /// from each other.
    @Environment(\.sidebarShowing) private var showing

    /// Its tabs are the window's own while it's the space showing, parked
    /// otherwise; read from the browser, not `live`, which comes from the
    /// pages around it and can be a draw behind as a switch is made.
    private var front: Bool { space.id == browser.spaceID }
    private var tabs: [Tab] { front ? browser.tabs : browser.parked[space.id]?.tabs ?? [] }
    private var active: Tab.ID? { front ? browser.activeID : browser.parked[space.id]?.active }

    var body: some View {
        let tabs = tabs
        let essentials = tabs.filter { $0.section == .essential }
        let kept = tabs.filter { $0.section == .pinned }
        // Full-window chat tabs sit in the Chats section, when it shows, not among the rest.
        let chatTabs = prefs.chatsInSidebar ? tabs.filter { $0.section == .loose && $0.chat != nil } : []
        // The chat open in the sidebar on the tab in front, to show as selected.
        let sideChat = front && browser.active?.chatOpen == true ? browser.active?.pageChat?.id : nil
        let loose = tabs.filter { tab in tab.section == .loose && !chatTabs.contains { $0 === tab } }
        let lines = keptLines(kept)
        VStack(alignment: .leading, spacing: 0) {
            if !essentials.isEmpty {
                PinnedTabs(browser: browser, prefs: prefs, tabs: essentials, active: active, live: live)
                    .padding(.bottom, 10)
            }
            if browser.usesSpaces { SpaceHeader(browser: browser, space: space).padding(.bottom, Self.gap) }
            // A plain stack until the tabs overflow, so the room below them
            // still drags the window. Worked out, not measured: ViewThatFits
            // lays the rows out twice, on every page, on every change.
            // Overflowing, the pinned tabs and folders scroll with the rest,
            // as Zen's: the essentials and the space's name stay put, and a
            // big open folder can't push the ones after it out of reach.
            let overflows =
                Sidebar.rowsHeight(
                    essentials: essentials.count, kept: lines.count, loose: loose.count, width: prefs.sideWidth, named: browser.usesSpaces,
                    chats: ChatsSection.lines(prefs, tabs: chatTabs.count, selected: chatTabs.contains { $0.id == active } || sideChat != nil))
                > room
            // Above the folders and pinned tabs, scrolling with them.
            let chats = prefs.chatsInSidebar ? ChatsSection(browser: browser, prefs: prefs, tabs: chatTabs, row: row, active: active, sideChat: sideChat).padding(.bottom, Self.divider) : nil
            if !overflows {
                chats
                if !lines.isEmpty { keptRows(kept, lines: lines) }
                listed(loose)
            } else {
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            chats
                            if !lines.isEmpty { keptRows(kept, lines: lines) }
                            listed(loose, scrolls: true)
                        }
                    }
                    .floatingScrollBar()
                    .coordinateSpace(name: Self.viewport)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        viewport = $0
                    }
                    // The selected tab scrolled out of sight: a way back to it.
                    .overlay(alignment: activeAway == .top ? .top : .bottom) {
                        if live, let away = activeAway, let id = active {
                            Button {
                                withAnimation(Motion.glide) { scroller.scrollTo(id, anchor: .center) }
                            } label: {
                                Image(systemName: away == .top ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 26, height: 26)
                                    .bubble(shadow: 0.1, radius: 8)
                            }
                            .buttonStyle(.plain)
                            .help("Back to the selected tab")
                            .padding(6)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .animation(Motion.quick, value: activeAway)
                    // Within the space only: a switch moves the page whole,
                    // and the page coming in is already where it was left.
                    .onChange(of: browser.activeID) { old, id in
                        guard live, let id, tabs.contains(where: { $0.id == old }) else { return }
                        withAnimation(Motion.glide) { scroller.scrollTo(id) }
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
        let renaming = live && showing && browser.editingTab == tab.id
        return SideRow(
            browser: browser, tab: tab, live: tab.id == active, renaming: renaming,
            draft: renaming ? browser.tabDraft : "", refusals: renaming ? browser.field.refusals : 0,
            icons: prefs.glyph == .icons, showsReading: prefs.showsReading,
            preview: browser.preview(of: tab.id), carded: live && showing && browser.siteCardRow == tab.id,
            picks: browser.picks)
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
        // A private window keeps nothing, folders included.
        let folders = browser.isPrivate ? [] : browser.folders(in: space.id)
        return Folder.outline(folders, tabs: kept.map { ($0.id, $0.folder) }, active: active).flatMap { line -> [KeptLine] in
            guard case .folder(let id, let depth) = line, let folder = folders.first(where: { $0.id == id }), folder.live != nil,
                !folder.collapsed
            else { return [.line(line)] }
            // The newest few: a feed can hold hundreds.
            return [.line(line)] + feeds.items(in: id).prefix(LiveFeeds.shown).map { .item($0, depth: depth + 1) }
        }
    }

    private func keptRows(_ kept: [Tab], lines: [KeptLine]) -> some View {
        let folders = browser.folders(in: space.id)
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
                                Group {
                                    if depth == 0, let index = unfiled.firstIndex(where: { $0.id == id }) {
                                        row(tab)
                                            .background { splitBox(at: index, in: unfiled) }
                                            // Places count among the pinned tabs, after the essentials.
                                            .modifier(
                                                Reorderable(
                                                    id: tab.id, index: index, places: 0..<unfiled.count,
                                                    lattice: .column(step: Self.row + Self.gap),
                                                    space: "kept", drag: $keptDrag, away: (browser, tab), filing: (browser, tab)
                                                ) { target in
                                                    // To where the tab now in that place sits among all the pinned ones.
                                                    let place = kept.firstIndex { $0.id == unfiled[target].id } ?? target
                                                    browser.move(tab, to: place + browser.essentialCount)
                                                })
                                    } else if let home = tab.folder, case let siblings = kept.filter({ $0.folder == home }),
                                        let index = siblings.firstIndex(where: { $0.id == id })
                                    {
                                        // Among its folder's own tabs, which sit together.
                                        row(tab)
                                            .background { splitBox(at: index, in: siblings) }
                                            .modifier(
                                                Reorderable(
                                                    id: tab.id, index: index, places: 0..<siblings.count,
                                                    lattice: .column(step: Self.row + Self.gap), space: "kept",
                                                    drag: Binding(get: { folderDrags[home] }, set: { folderDrags[home] = $0 }),
                                                    away: (browser, tab), filing: (browser, tab)
                                                ) { target in
                                                    let place = kept.firstIndex { $0.id == siblings[target].id } ?? target
                                                    browser.move(tab, to: place + browser.essentialCount)
                                                }
                                            )
                                            .padding(.leading, CGFloat(depth) * Self.indent)
                                    } else {
                                        row(tab).padding(.leading, CGFloat(depth) * Self.indent)
                                    }
                                }
                                // For scrolling to it, as to the open tabs.
                                .id(tab.id)
                            }
                        }
                    }
                }
            }
            .overlay { closing(lines.map { line in if case .line(.tab(let id, _)) = line { kept.first { $0.id == id } } else { nil } }) }
            // The pinned tabs in no folder come last: where a tab dragged out
            // of its folder lands still pinned, and where it would go.
            .overlay(alignment: .topLeading) {
                if live && showing {
                    let step = Self.row + Self.gap
                    let head = CGFloat(lines.count - unfiled.count) * step
                    ListSpot { [weak browser] in browser?.keptSpot = $0 }.frame(height: max(0, CGFloat(unfiled.count) * step - Self.gap))
                        .offset(y: head)
                    if case .kept(let place) = browser.folderExit {
                        DropLine().offset(y: head + CGFloat(min(place, unfiled.count)) * step - Self.gap / 2 - 1)
                    }
                }
            }
            .coordinateSpace(name: "kept")
            Self.rule
        }
    }

    /// The box around a split group's rows, for the row at `index` of `tabs`.
    @ViewBuilder private func splitBox(at index: Int, in tabs: [Tab]) -> some View {
        if let run = browser.splitRun(at: index, in: tabs) {
            // Hugging its rows, so it never runs under a selected or hovered
            // row beside it; its corners then are the rows' own (10).
            SplitRun(axis: .vertical, first: run.first, last: run.last, gap: Self.gap, bleed: 0)
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

    /// The scrolling list's own space, for the selected tab to say where it is.
    private static let viewport = "viewport"

    /// `scrolls`: in the scrolling list, where the selected tab says when it's out of sight.
    private func listed(_ loose: [Tab], scrolls: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: Self.gap) {
                ForEach(Array(loose.enumerated()), id: \.element.id) { index, tab in
                    row(tab)
                        .onGeometryChange(for: VerticalEdge?.self) { [viewport] proxy in
                            guard scrolls, tab.id == active else { return nil }
                            let frame = proxy.frame(in: .named(Self.viewport))
                            return frame.maxY < 0 ? .top : frame.minY > viewport ? .bottom : nil
                        } action: { away in
                            if tab.id == active, activeAway != away { activeAway = away }
                        }
                        .background { splitBox(at: index, in: loose) }
                        // Places count among the loose tabs, after the essentials and pinned ones.
                        .modifier(
                            Reorderable(
                                id: tab.id, index: index, places: 0..<loose.count, lattice: .column(step: Self.row + Self.gap),
                                space: "rows", drag: $drag, away: (browser, tab), filing: (browser, tab)
                            ) { browser.move(tab, to: $0 + browser.pinnedCount) })
                }
            }
            .overlay { closing(loose.map { $0 }) }
            // Where a tab dragged out of a folder would land.
            .background { if live && showing { ListSpot { [weak browser] in browser?.looseSpot = $0 } } }
            .overlay(alignment: .topLeading) {
                if live && showing, case .loose(let place) = browser.folderExit {
                    DropLine().offset(y: CGFloat(min(place, loose.count)) * (Self.row + Self.gap) - Self.gap / 2 - 1)
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
    @Environment(\.sidebarShowing) private var showing
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
                    browser: browser, tab: tab, live: tab.id == active, lettering: live && showing && browser.editingPin == tab.id,
                    icons: prefs.glyph == .icons, size: grid.frame(of: index).size, preview: browser.preview(of: tab.id)
                )
                .modifier(
                    Reorderable(
                        id: tab.id, index: index, places: 0..<tabs.count, lattice: grid.lattice,
                        space: "pins", drag: $drag
                    ) { browser.move(tab, to: $0) })
            }
        }
        // As ⌘W: a pinned tab lets its page go and stays pinned.
        .overlay {
            MiddleClick { at in
                if let index = grid.index(at: at), tabs.indices.contains(index) { browser.close(tabs[index]) }
            }
        }
        .coordinateSpace(name: "pins")
    }
}

/// The essential in front its own icon blown up to twice the square and
/// blurred behind it, under a frosted panel inset by 2 points, so the
/// icon's colours ring the edge
/// and wash the middle. Drawn only for the one in front.
private struct IconGlow: View {
    let icon: NSImage
    let corner: CGFloat
    let dark: Bool
    var inverted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        GeometryReader { room in
            ZStack {
                Image(nsImage: icon)
                    .resizable()
                    .modifier(Inverted(on: inverted))
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

/// Fixed cells, row by row, a short last row sharing the width. Not a
/// LazyVGrid: that makes cells only once on screen, so they missed the
/// sidebar's slide in.
private struct PinCells: Layout {
    let grid: PinGrid

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: grid.width, height: grid.height(subviews.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, cell) in subviews.enumerated() {
            let frame = grid.frame(of: index)
            cell.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
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
    /// A link preview open over it: its site's mark sits on the square's corner, as Zen's.
    let preview: Tab?

    @State private var hovering = false
    @State private var overMinus = false
    @Environment(\.colorScheme) private var colorScheme

    /// Contents scale with the shorter side, so the mark stays its usual size.
    private var side: CGFloat { min(size.width, size.height) }
    private var corner: CGFloat { side * 10 / 36 }
    /// A white icon would vanish on the light tile: it's drawn dark instead.
    private var invertsIcon: Bool { colorScheme == .light && tab.icon?.isPale == true }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        mark
            .frame(width: side * 16 / 34, height: side * 16 / 34)
            .frame(width: size.width, height: size.height)
            .background {
                if live, let icon = tab.icon {
                    IconGlow(icon: icon, corner: corner, dark: colorScheme == .dark, inverted: invertsIcon)
                } else if live {
                    Lifted(corner: corner)
                } else {
                    Tinted(shape: shape, fill: Palette.veil.opacity(hovering ? 1.8 : 1))
                }
            }
            .contentShape(shape)
            .modifier(
                OneClick(live: live) {
                    browser.select(tab)
                } edit: {
                    browser.editLetter(tab)
                }
            )
            .rowHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                if let preview {
                    PreviewMark(tab: preview, size: side * 0.42) { browser.openPreview(of: tab) }
                        .padding(3)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // – lets the page go, keeping the essential; to the other corner past a preview's mark.
            .overlay(alignment: preview == nil ? .topTrailing : .topLeading) {
                if hovering || overMinus, !tab.asleep, !lettering {
                    // Small to look at, easy to hit: the press takes a square
                    // well past the circle.
                    Button {
                        browser.close(tab)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 14, height: 14)
                            .background(Palette.ground, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.hairline))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Past the square's edge it keeps itself showing.
                    .onHover { overMinus = $0 }
                    .help("Unload Tab, keeping it   ⌘W")
                    .offset(x: preview == nil ? 4 : -4, y: -4)
                    .transition(.opacity)
                }
            }
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
                .modifier(Inverted(on: invertsIcon))
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
    /// The link preview open over this tab, if any, and a click on it keeps the
    /// preview as a tab.
    let preview: Tab?
    /// The site card hangs beside it.
    let carded: Bool

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    /// Tabs picked together, this one among them or not.
    @ObservedObject var picks: TabPicks
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
                if tab.chat != nil, tab.isBlank {
                    // A chat's tab is marked as a chat, as the Chats section lists them.
                    Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(colour).frame(width: 16, height: 16)
                } else if !tab.isBlank || tab.isStart {
                    // Its site's icon, or with letters chosen (or no icon) its letter.
                    Mark(icon: icons ? tab.icon : nil, letter: tab.monogram, size: 16, dim: tab.asleep && tab.held, mote: tab.isStart)
                        // In another profile than its space's: that profile's colour, at the corner.
                        .overlay(alignment: .bottomTrailing) {
                            if let profile = tab.profileOverride(in: browser.home(of: tab)) {
                                Circle().fill(Color(hex: Profiles.shared.avatar(of: profile.isEmpty ? nil : profile).color) ?? .gray)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Palette.frame, lineWidth: 1.2))
                                    .offset(x: 3, y: 3)
                                    .help("In \(Profiles.shared.name(of: profile.isEmpty ? nil : profile))")
                            }
                        }
                }
                TabMarks(tab: tab, colour: colour)
                Text(tab.label).font(TextStyle.body.font).lineLimit(1).truncationMode(.tail).foregroundStyle(colour)
            }
            if status {
                Spacer(minLength: 2)
                ZStack {
                    if let preview {
                        PreviewMark(tab: preview) { browser.openPreview(of: tab) }.transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)
                // On hover the close button takes this place and the speaker moves left; a preview's mark stays.
                .opacity(hovering && !speaker && preview == nil ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 26 : 0)
            } else if let chat = tab.chat, tab.isBlank {
                // When the chat was last used, where the close button shows on hover.
                Spacer(minLength: 4)
                Text(ChatTime.text(chat.updated)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted)
                    .opacity(hovering ? 0 : 1)
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
        .modifier(
            // The speaker, ring or preview's mark, and the speaker moved aside on hover.
            OneClick(
                live: live, spare: status ? (hovering && speaker ? 60 : 34) : 0, pick: { browser.select(tab) },
                edit: { browser.beginTabRename(tab) }, together: { browser.pick(tab, with: $0) })
        )
        // Over the row, not inside it: inside, its click would wait out the
        // double-click interval of the tab you're on before closing it.
        .overlay(alignment: .trailing) {
            if !renaming {
                // An essential's or pinned tab's – lets its page go (back to its
                // pinned page, if it went elsewhere); Back to Pinned Page is in its menu.
                let home = tab.wandered && !tab.held
                Shut(shown: hovering, home: home, rests: tab.held, act: home ? { browser.goHome(tab) } : close)
                    .padding(.trailing, preview == nil ? 7 : 30)
            }
        }
        .rowHover { over in
            hovering = over
            if over { fading = true }
        }
        // A row going while hovered (closed, moved) hears no hover end: its card goes with it.
        .onDisappear { if hovering { TabPreview.leave() } }
        // Rested on a moment: a picture of its page beside it.
        .task(id: hovering) {
            guard hovering, !live, !renaming, NSEvent.pressedMouseButtons == 0 else { return TabPreview.leave() }
            try? await Task.sleep(for: .seconds(TabPreview.wait))
            if !Task.isCancelled { TabPreview.show(tab, in: browser) }
        }
        // A tab the pointer rests on is likely the next: it warms (see Browser.warm).
        .task(id: hovering) {
            guard hovering, !live else { return }
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { browser.warm(tab) }
        }
        .task(id: hovering) {
            guard !hovering, fading else { return }
            try? await Task.sleep(for: .seconds(0.15))
            if !Task.isCancelled { fading = false }
        }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .background { if carded { SiteCardAnchor(row: tab.id) } }
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
        } else if picks.ids.contains(tab.id) {
            shape.fill(Palette.hover).overlay(shape.strokeBorder(Palette.ink.opacity(0.18)))
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
    /// Its tile's side: the row's small mark, or a badge on an essential.
    var size: CGFloat = 16
    let keep: () -> Void

    private var tile: RoundedRectangle { RoundedRectangle(cornerRadius: size / 4, style: .continuous) }

    var body: some View {
        Mark(icon: tab.icon, letter: tab.monogram, size: size > 16 ? size * 0.62 : 14)
            .frame(width: size, height: size)
            .background(size > 16 ? Palette.ground : Palette.veil, in: tile)
            .overlay { if size > 16 { tile.strokeBorder(Palette.hairline) } }
            .contentShape(Rectangle())
            .onTapGesture(perform: keep)
            .help("Previewing “\(tab.label)” — click to keep it as a tab")
    }
}

/// A folder among the pinned tabs; a click opens or closes it, and
/// its menu renames, nests, unloads, unpacks or deletes it.
private struct FolderRow: View {
    /// A line of the list a closed folder shows: one PopoverLine.
    private static let previewLine: CGFloat = 28
    let browser: Browser
    let folder: Folder
    /// The showing space's; another's, during a swipe, is only drawn.
    let live: Bool
    /// A dragged tab is over it, and would drop in.
    let dropping: Bool
    /// Only the sidebar on screen says where its rows are: the docked and
    /// the sliding one are both built.
    @Environment(\.sidebarShowing) private var showing

    @State private var hovering = false
    /// Its tabs listed beside it, and the pointer on that list.
    @State private var listing = false
    @State private var overList = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 10)
            Group {
                if let icon = folder.icon {
                    SpaceGlyph(icon, size: 12).foregroundStyle(Palette.ink.opacity(0.7))
                } else {
                    Image(systemName: folder.live != nil ? "dot.radiowaves.left.and.right" : folder.collapsed ? "folder" : "folder.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink.opacity(0.7))
                }
            }
            .frame(width: 16)
            Text(folder.name).font(TextStyle.body.font).foregroundStyle(Palette.ink.opacity(0.8)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .background { if live && showing { FolderIconPick(browser: browser, folder: folder) } }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
        .background { if hovering || dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.veil) } }
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5) }
        }
        .animation(Motion.quick, value: dropping)
        // Where it is, for a tab dragged onto it; only in the space showing.
        .background { if live && showing && folder.live == nil { FolderSpot(browser: browser, id: folder.id) } }
        .contentShape(Rectangle())
        .onTapGesture { if live { withAnimation(Motion.settle) { browser.toggleFolder(folder.id) } } }
        // Dragged onto another folder, it goes before it, beside it.
        .draggable("folder:" + folder.id.uuidString)
        .dropDestination(for: String.self) { dropped, at in
            guard live, let text = dropped.first, text.hasPrefix("folder:"), let id = UUID(uuidString: String(text.dropFirst(7))) else {
                return false
            }
            withAnimation(Motion.settle) { browser.moveFolder(id, before: folder.id, after: at.y > Metrics.row / 2) }
            return true
        }
        .rowHover { hovering = $0 }
        // A closed folder rested on a moment lists its tabs.
        .task(id: hovering || overList) {
            guard hovering || overList else {
                // A moment to reach the list.
                try? await Task.sleep(for: .seconds(0.3))
                if !Task.isCancelled { listing = false }
                return
            }
            guard !listing, folder.collapsed, folder.live == nil, live else { return }
            try? await Task.sleep(for: .seconds(0.5))
            if !Task.isCancelled { listing = true }
        }
        .menuPanel(isPresented: $listing, edge: .trailing, keyboard: false, plain: true) {
            // Its subfolders' tabs too, a line each. Past a height (a dozen
            // lines, or less of a short screen) it scrolls, with no bar.
            let family = Folder.family(of: folder.id, in: browser.folders)
            let inside = browser.tabs.filter { $0.folder.map(family.contains) ?? false }
            let lines = VStack(alignment: .leading, spacing: 0) {
                ForEach(inside) { tab in
                    // As the rows mark them: the site's icon, or its letter (Settings › Tabs › Beside each title).
                    PopoverLine(tab.label, mark: (browser.prefs.glyph == .icons ? tab.icon : nil, tab.monogram)) {
                        listing = false
                        browser.select(tab)
                    }
                }
            }
            .lineLimit(1)
            .padding(6)
            let tallest = min(Self.previewLine * 12, (NSScreen.main?.visibleFrame.height ?? 800) * 0.6) + 12
            Group {
                if CGFloat(inside.count) * Self.previewLine + 12 > tallest {
                    ScrollView(showsIndicators: false) { lines }.scrollIndicators(.never).frame(height: tallest)
                } else {
                    lines
                }
            }
            .frame(width: 240)
            .onHover { overList = $0 }
        }
        .contextMenu {
            Button("Rename Folder…") { browser.renameFolder(folder.id) }
            Button("Change Icon…") { browser.changeFolderIcon(folder.id) }
            if folder.live != nil { Button("Refresh Now") { LiveFeeds.shared.refresh(folder) } }
            Button("New Subfolder…") { browser.newFolder(in: folder.id) }
            Divider()
            Button("Unload All Tabs") { browser.unloadFolder(folder.id) }
            Button("Unpack Folder") { browser.unpackFolder(folder.id) }
            Button("Delete Folder…") {
                // Its tabs close with it: asked first, as Zen asks.
                let count = browser.tabs(inFolder: folder.id).count
                guard
                    count == 0
                        || Dialogs.confirm(
                            "Delete “\(folder.name)”?", "Its \(count) tab\(count == 1 ? "" : "s") close with it.", button: "Delete Folder")
                else { return }
                browser.deleteFolder(folder.id)
            }
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
        .rowHover { hovering = $0 }
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

private struct Inverted: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.colorInvert() } else { content }
    }
}

private struct SidebarShowing: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this sidebar is the one on screen (see `Sidebar.showing`).
    fileprivate var sidebarShowing: Bool {
        get { self[SidebarShowing.self] }
        set { self[SidebarShowing.self] = newValue }
    }
}

/// Where a dragged tab would go in a list: a line between rows.
private struct DropLine: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6).allowsHitTesting(false)
    }
}

/// Marks a list in the sidebar for a tab dragged out of a folder: the open
/// tabs (Browser.loosePlace) or the pinned ones in no folder (keptPlace).
/// It says where it is as it joins a window, as well as when redrawn: a list
/// rebuilt (its tabs came to overflow) may not be redrawn again before a drag.
private struct ListSpot: FillsRoom {
    let mark: (WeakView) -> Void

    func makeNSView(context: Context) -> NSView { Spot(mark: mark) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Spot)?.mark = mark
        if view.window != nil { mark(WeakView(view)) }
    }

    private final class Spot: NSView {
        var mark: (WeakView) -> Void

        init(mark: @escaping (WeakView) -> Void) {
            self.mark = mark
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            if window != nil { mark(WeakView(self)) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The icon picker over a folder's row, while Change Icon… is open for it.
/// Apart from the row, so only this watches the browser.
private struct FolderIconPick: View {
    @ObservedObject var browser: Browser
    let folder: Folder

    var body: some View {
        Color.clear.popover(
            isPresented: Binding(
                get: { browser.pickingFolderIcon == folder.id }, set: { if !$0, browser.pickingFolderIcon == folder.id { browser.pickingFolderIcon = nil } }),
            arrowEdge: .trailing
        ) {
            IconPicker(current: folder.icon, reset: { browser.setFolderIcon(folder.id, to: nil) }) { browser.setFolderIcon(folder.id, to: $0) }
        }
    }
}

/// The newest chats, as a folder at the top of the sidebar (Settings › Tabs ›
/// Chats in the sidebar): folds like one, a click opens a chat, and Show All
/// opens every chat.
private struct ChatsSection: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    /// The full-window chat tabs: drawn here as the tabs they are.
    let tabs: [Tab]
    let row: (Tab) -> SideRow
    /// The selected tab, and the chat open in the sidebar on it, if any.
    let active: Tab.ID?
    let sideChat: UUID?
    @State private var hovering = false
    @State private var showingAll = false

    private static let shown = 5

    /// The newest chats without a tab, to fill the section to five.
    private static func newest(besides tabs: Int, open: Set<UUID>) -> [ChatArchive.Entry] {
        Array(Assistant.shared.chats.entries.filter { $0.archived != true && !open.contains($0.id) }.prefix(max(0, shown - tabs)))
    }

    /// How many rows it stands: its header, and unfolded its chat tabs, chats
    /// and Show All; folded, the selected chat under it if there is one.
    static func lines(_ prefs: Preferences, tabs: Int, selected: Bool) -> Int {
        guard prefs.chatsInSidebar else { return 0 }
        return prefs.chatsFolded ? 1 + (selected ? 1 : 0) : 2 + tabs + newest(besides: tabs, open: []).count
    }

    var body: some View {
        // The chat open in the sidebar follows the tab in front as it changes
        // there, not only when the browser does.
        if let tab = browser.active {
            FrontChat(tab: tab) { open in content(sideChat: open) }
        } else {
            content(sideChat: sideChat)
        }
    }

    @ViewBuilder private func content(sideChat: UUID?) -> some View {
        let entries = Self.newest(besides: tabs.count, open: Set(tabs.compactMap { $0.chat?.id }))
        VStack(alignment: .leading, spacing: 2) {
            header
            if !prefs.chatsFolded {
                // Indented under the header, as a folder's tabs are.
                ForEach(tabs) { row($0).padding(.leading, 14) }
                // Opened, a chat becomes its tab, here where it was.
                ForEach(entries) { line($0, sideChat: sideChat) }
                // Every chat, in the footer's own Chats popup.
                ChatLine(symbol: "ellipsis", title: "Show All", time: nil, selected: false) { showingAll = true }
                    .menuPanel(isPresented: $showingAll, edge: .trailing) {
                        ChatsPage(browser: browser, inPanel: true) { showingAll = false }.frame(width: 380, height: 440)
                    }
            } else if let tab = tabs.first(where: { $0.id == active }) {
                // Folded, the chat you're in still shows, as a closed folder's selected tab does.
                row(tab).padding(.leading, 14)
            } else if let open = entries.first(where: { $0.id == sideChat }) {
                line(open, sideChat: sideChat)
            }
        }
    }

    /// Watches the tab in front for the chat it has open in the sidebar.
    private struct FrontChat<Content: View>: View {
        @ObservedObject var tab: Tab
        let content: (UUID?) -> Content
        var body: some View { content(tab.chatOpen ? tab.pageChat?.id : nil) }
    }

    /// The header, as a folder's row: folds on a click, washed on hover.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(prefs.chatsFolded ? 0 : 90))
                .frame(width: 10)
            Text("Chats").font(TextStyle.body.font).foregroundStyle(Palette.ink.opacity(0.8))
            Spacer(minLength: 0)
            if hovering {
                Button(action: browser.newAskingTab) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("New Chat")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
        .background { if hovering { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.veil) } }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.settle) { prefs.chatsFolded.toggle() } }
        .onHover { over in withAnimation(Motion.hover) { hovering = over } }
    }

    /// A chat without a tab: selected while it's the one open in the sidebar.
    private func line(_ entry: ChatArchive.Entry, sideChat: UUID?) -> some View {
        ChatLine(
            symbol: "bubble.left", title: entry.title.isEmpty ? "New chat" : entry.title, time: ChatTime.text(entry.updated),
            selected: entry.id == sideChat
        ) { browser.open(chat: entry.id) }
    }

    /// A line as a tab's row: muted until hovered or selected, the
    /// selected tab's lift when it's the chat in front.
    private struct ChatLine: View {
        let symbol: String
        let title: String
        let time: String?
        let selected: Bool
        let open: () -> Void
        @State private var hovering = false

        private var colour: Color { selected ? Palette.ink : Palette.ink.opacity(hovering ? 0.8 : 0.62) }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(colour).frame(width: 16)
                Text(title).font(TextStyle.body.font).foregroundStyle(colour).lineLimit(1)
                Spacer(minLength: 4)
                if let time { Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted) }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: Metrics.row, maxHeight: Metrics.row, alignment: .leading)
            .background {
                if selected {
                    Lifted(corner: 10) {}
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.veil)
                }
            }
            .contentShape(Rectangle())
            // Indented as the chat tabs above it are, the same width.
            .padding(.leading, 14)
            .onTapGesture(perform: open)
            .onHover { over in withAnimation(Motion.hover) { hovering = over } }
        }
    }
}

/// When a chat was last used, as the sidebar shows it: today's time, as
/// "10:43"; else the day, as "21 Nov".
private enum ChatTime {
    static func text(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
