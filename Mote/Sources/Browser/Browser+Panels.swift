import MoteCore
import SwiftUI

/// A side panel: docked on a window edge beside the page card, as the chat
/// is. What it shows is up to its kind; the layout only knows its id, side,
/// width and placement (ChromeLayout, PanelSlot).
struct SidePanel: Identifiable, Equatable {
    enum Kind: Equatable {
        case chat
        /// An extension's side panel (chrome.sidePanel, Firefox's sidebar).
        case `extension`(String)
    }

    let kind: Kind
    /// The tab it belongs to; nil for the whole window, as Chrome keeps an
    /// extension's panel while the tabs change.
    var tab: Tab.ID?

    static let chat = SidePanel(kind: .chat)

    var id: String {
        switch kind {
        case .chat: "chat"
        case .extension(let extensionID): "ext:" + extensionID
        }
    }

    var extensionID: String? {
        if case .extension(let id) = kind { id } else { nil }
    }
}

extension Browser {
    /// The panels showing for the tab in front: the window's, the tab's own,
    /// and the chat when it's open there.
    var shownPanels: [SidePanel] {
        sidePanels.filter { $0.tab == nil || $0.tab == activeID } + (chatting ? [.chat] : [])
    }

    /// What the layout places.
    var panelSlots: [PanelSlot] {
        shownPanels.map {
            PanelSlot(id: $0.id, side: side(of: $0), width: width(of: $0), placement: $0.kind == .chat ? .edgeAlways : .normal)
        }
    }

    func side(of panel: SidePanel) -> PanelSide {
        panel.kind == .chat ? prefs.chatSide : prefs.panelSides[panel.id] ?? prefs.chatSide
    }

    func width(of panel: SidePanel) -> CGFloat {
        panel.kind == .chat ? prefs.chatWidth : prefs.panelWidths[panel.id] ?? Metrics.chat
    }

    func panel(id: String) -> SidePanel? {
        id == SidePanel.chat.id ? (chatting ? .chat : nil) : sidePanels.first { $0.id == id }
    }

    func isOpen(_ panel: SidePanel) -> Bool { shownPanels.contains { $0.id == panel.id } }

    /// Opens a panel, or moves an open one to `tab`'s scope (nil: the window's).
    func open(_ panel: SidePanel) {
        guard panel.kind != .chat else { return chatting ? () : togglePageChat() }
        if let index = sidePanels.firstIndex(where: { $0.id == panel.id }) {
            guard sidePanels[index].tab != panel.tab else { return }
            return slidingFold { sidePanels[index].tab = panel.tab }
        }
        slidingFold { sidePanels.append(panel) }
    }

    func closePanel(id: String) {
        if id == SidePanel.chat.id { return chatting ? togglePageChat() : () }
        guard sidePanels.contains(where: { $0.id == id }) else { return }
        slidingFold { sidePanels.removeAll { $0.id == id } }
        if #available(macOS 15.4, *) { ExtensionPanels.shared.drop(id, in: self) }
    }

    func toggle(_ panel: SidePanel) {
        isOpen(panel) ? closePanel(id: panel.id) : open(panel)
    }

    /// Docks a panel on the other side; the chat stays at its side's edge.
    func move(_ panel: SidePanel, to side: PanelSide) {
        slidingFold {
            if panel.kind == .chat { prefs.chatSide = side } else { prefs.panelSides[panel.id] = side }
        }
    }

    /// Panels kept for a tab go with it.
    func dropPanels(of tab: Tab.ID) {
        for panel in sidePanels where panel.tab == tab { closePanel(id: panel.id) }
    }
}

/// A side panel's top bar: frosted and square, so whatever scrolls under it
/// doesn't run into its buttons; the card it sits on does the rounding.
struct PanelHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .controlSize(.large)
            .padding(.horizontal, 6)
            .frame(height: ChromeLayout.toolbar)
            .background(.ultraThinMaterial, in: Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Where a panel sits among its side's: which side, and whether it's the
/// outermost, against the window's edge (or the sidebar).
struct PanelPlace: Equatable {
    var side: PanelSide
    var outermost: Bool
}

extension View {
    /// A side panel's surface: a card a little in from the edges, its top
    /// level with the page's, so the space's colours ring it and come through
    /// faintly while the words stay readable. Only the card is rounded.
    ///
    /// The gap goes on the side towards the page, and on the outer side only
    /// for the outermost panel: side by side, every seam is one gap wide, as
    /// between the page and the panel beside it.
    func panelCard(toolbarTop: CGFloat, place: PanelPlace) -> some View {
        let card = RoundedRectangle(cornerRadius: ChromeLayout.corner, style: .continuous)
        let inner: Edge.Set = place.side == .right ? .leading : .trailing
        let outer: Edge.Set = place.side == .right ? .trailing : .leading
        return background(PageChatPanel.scrim, in: card)
            .clipShape(card)
            .padding([.bottom, inner], ChromeLayout.gap)
            .padding(outer, place.outermost ? ChromeLayout.gap : 0)
            .padding(.top, max(toolbarTop, ChromeLayout.gap))
    }
}

extension ChromeLayout {
    /// Where the panel `id` sits, for its card (PanelPlace).
    func place(of id: String, side: PanelSide) -> PanelPlace {
        PanelPlace(side: side, outermost: panels.first { $0.side == side }.map { $0.id == id } ?? true)
    }
}
