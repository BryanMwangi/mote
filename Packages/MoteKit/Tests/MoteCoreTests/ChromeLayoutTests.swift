import CoreGraphics
import Testing

@testable import MoteCore

@Suite("ChromeLayout")
struct ChromeLayoutTests {
    private let window = CGSize(width: 1200, height: 800)
    private let gap = ChromeLayout.gap

    private func layout(
        _ tabs: ChromeLayout.Tabs, folded: Bool = false, immersed: Bool = false, bookmarked: Bool = false, side: CGFloat = 240,
        chatting: Bool = false, panel: CGFloat = ChromeLayout.panel
    ) -> ChromeLayout {
        ChromeLayout(
            window: window, tabs: tabs, sideWidth: side, folded: folded, immersed: immersed, bookmarked: bookmarked,
            panels: chatting ? [chat(panel)] : [])
    }

    private func chat(_ width: CGFloat = ChromeLayout.panel, on side: PanelSide = .right) -> PanelSlot {
        PanelSlot(id: "chat", side: side, width: width, placement: .edgeAlways)
    }

    @Test("Beside a sidebar the card starts where the sidebar ends and keeps a gap on the other sides")
    func sidebarCard() {
        let chrome = layout(.sidebar)
        #expect(chrome.sidebar == CGRect(x: 0, y: 0, width: 240, height: 800))
        #expect(chrome.card == CGRect(x: 240, y: gap, width: 1200 - 240 - gap, height: 800 - 2 * gap))
        #expect(chrome.strip == nil)
        #expect(chrome.corner == ChromeLayout.corner)
    }

    @Test("With the sidebar on the right the card keeps its gap on the left and ends where the sidebar starts")
    func sidebarOnRight() {
        let chrome = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: false, immersed: false, bookmarked: false, sideRight: true)
        #expect(chrome.sidebar == CGRect(x: 1200 - 240, y: 0, width: 240, height: 800))
        #expect(chrome.card == CGRect(x: gap, y: gap, width: 1200 - 240 - gap, height: 800 - 2 * gap))
        // Beside the native sidebar, which takes its own width: flush on the right.
        let native = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 0, folded: false, immersed: false, bookmarked: false, panels: [chat()],
            sideRight: true
        )
        #expect(native.card.minX == gap)
        #expect(native.frame(of: "chat")?.maxX == 1200)
    }

    @Test("A folded sidebar leaves the card inset evenly on every side")
    func foldedSidebar() {
        let chrome = layout(.sidebar, folded: true)
        #expect(chrome.sidebar == nil)
        #expect(chrome.card == CGRect(x: gap, y: gap, width: 1200 - 2 * gap, height: 800 - 2 * gap))
    }

    @Test("Under a strip the card meets the strip with no gap, so the active tab runs into it")
    func stripCard() {
        let chrome = layout(.strip)
        #expect(chrome.strip == CGRect(x: 0, y: 0, width: 1200, height: ChromeLayout.strip))
        #expect(chrome.card.minY == ChromeLayout.strip)
        #expect(chrome.card.minX == gap)
        #expect(chrome.card.maxX == 1200 - gap)
        #expect(chrome.card.maxY == 800 - gap)
    }

    @Test("Without the toolbar on the card, the page takes its room, under the bookmarks bar if any")
    func noToolbar() {
        for tabs in [ChromeLayout.Tabs.sidebar, .strip] {
            let bare = ChromeLayout(
                window: window, tabs: tabs, sideWidth: 240, folded: false, immersed: false, bookmarked: false, toolbar: false)
            #expect(bare.toolbar == 0)
            #expect(bare.page == bare.card)
            let marked = ChromeLayout(
                window: window, tabs: tabs, sideWidth: 240, folded: false, immersed: false, bookmarked: true, toolbar: false)
            #expect(marked.page.minY == marked.card.minY + ChromeLayout.bookmarks)
        }
    }

    @Test("The page sits under the toolbar, and under the bookmarks bar when it shows")
    func pageUnderBars() {
        let plain = layout(.sidebar)
        #expect(plain.page.minY == plain.card.minY + ChromeLayout.toolbar)
        #expect(plain.page.maxY == plain.card.maxY)
        #expect(plain.page.width == plain.card.width)

        let marked = layout(.sidebar, bookmarked: true)
        #expect(marked.bookmarks == ChromeLayout.bookmarks)
        #expect(marked.page.minY == marked.card.minY + ChromeLayout.toolbar + ChromeLayout.bookmarks)
    }

    @Test("A chat panel docks full height on the window's trailing edge, the mirror of the sidebar, and takes its width off the card")
    func chatPanel() throws {
        let chrome = layout(.sidebar, chatting: true)
        let panel = try #require(chrome.frame(of: "chat"))
        #expect(panel.width == ChromeLayout.panel)
        #expect(panel.minX == chrome.card.maxX)
        #expect(panel.maxX == window.width)
        #expect(panel.minY == 0)
        #expect(panel.maxY == window.height)
        // The card gives the panel its width; the page keeps the whole card.
        #expect(chrome.card.width == 1200 - 240 - ChromeLayout.panel)
        #expect(chrome.page.width == chrome.card.width)
        #expect(chrome.page.maxX == panel.minX)
    }

    @Test("The chat panel runs the window's full height even when the card carries the bars")
    func chatPanelBars() throws {
        let chrome = layout(.sidebar, bookmarked: true, chatting: true)
        let panel = try #require(chrome.frame(of: "chat"))
        #expect(panel.minY == 0)
        #expect(panel.maxY == window.height)
        #expect(chrome.page.minY == chrome.card.minY + ChromeLayout.toolbar + ChromeLayout.bookmarks)
        #expect(chrome.page.maxY == chrome.card.maxY)
    }

    @Test("The chat panel's width comes from the caller, not a fixed size")
    func chatPanelWidth() throws {
        let width: CGFloat = 300
        let chrome = layout(.sidebar, chatting: true, panel: width)
        let panel = try #require(chrome.frame(of: "chat"))
        #expect(panel.width == width)
        #expect(chrome.card.width == 1200 - 240 - width)
    }

    @Test("No chat panel leaves the page across the whole card")
    func noChatPanel() {
        let chrome = layout(.sidebar)
        #expect(chrome.frame(of: "chat") == nil)
        #expect(chrome.page.width == chrome.card.width)
    }

    @Test("Full-screen video leaves no room for a chat panel, however it was asked for", arguments: [true, false])
    func chatPanelImmersed(chatting: Bool) {
        let chrome = layout(.sidebar, immersed: true, chatting: chatting)
        #expect(chrome.frame(of: "chat") == nil)
        #expect(chrome.page == chrome.card)
    }

    @Test("A window too small for the panel keeps a non-negative page")
    func chatPanelTiny() {
        let chrome = ChromeLayout(
            window: CGSize(width: 100, height: 20), tabs: .sidebar, sideWidth: 240, folded: false, immersed: false, bookmarked: true,
            panels: [chat()])
        #expect(chrome.page.width >= 0)
        #expect((chrome.frame(of: "chat")?.width ?? 0) >= 0)
    }

    @Test("Panels on the left dock from the window's edge and the card starts after them")
    func leftPanels() throws {
        let chrome = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: true, immersed: false, bookmarked: false,
            panels: [PanelSlot(id: "a", side: .left, width: 300)])
        let a = try #require(chrome.frame(of: "a"))
        #expect(a == CGRect(x: 0, y: 0, width: 300, height: 800))
        #expect(chrome.card.minX == 300)
        #expect(chrome.card.maxX == 1200 - gap)
    }

    @Test("Beside a sidebar on the same side, panels sit against it")
    func panelsBesideSidebar() throws {
        let left = layout(.sidebar, side: 240)
        let withPanel = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: false, immersed: false, bookmarked: false,
            panels: [PanelSlot(id: "a", side: .left, width: 300)])
        #expect(withPanel.frame(of: "a")?.minX == left.sidebar?.maxX)
        #expect(withPanel.card.minX == CGFloat(240 + 300))
        let right = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: false, immersed: false, bookmarked: false,
            panels: [PanelSlot(id: "a", side: .right, width: 300)], sideRight: true)
        #expect(right.frame(of: "a")?.maxX == CGFloat(1200 - 240))
        #expect(right.card.maxX == CGFloat(1200 - 240 - 300))
    }

    @Test("The chat stays at the edge; others open beside the page, the newest nearest it")
    func panelOrder() throws {
        let slots = [
            PanelSlot(id: "first", side: .right, width: 200), chat(300), PanelSlot(id: "second", side: .right, width: 250),
        ]
        let laid = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: true, immersed: false, bookmarked: false, panels: slots)
        let edge = try #require(laid.frame(of: "chat"))
        let first = try #require(laid.frame(of: "first"))
        let second = try #require(laid.frame(of: "second"))
        #expect(edge.maxX == 1200)
        #expect(first.maxX == edge.minX)
        #expect(second.maxX == first.minX)
        #expect(laid.card.maxX == second.minX)
        #expect(laid.card.width == 1200 - gap - 300 - 200 - 250)
    }

    @Test("Panels on both sides each take their width off their own side of the card")
    func bothSides() {
        let laid = ChromeLayout(
            window: window, tabs: .sidebar, sideWidth: 240, folded: true, immersed: false, bookmarked: false,
            panels: [PanelSlot(id: "l", side: .left, width: 200), chat(300)])
        #expect(laid.card.minX == 200)
        #expect(laid.card.maxX == 900)
        #expect(laid.panels.count == 2)
    }

    @Test("Full-screen video fills the window with a bare page", arguments: [ChromeLayout.Tabs.sidebar, .strip])
    func immersed(tabs: ChromeLayout.Tabs) {
        let chrome = layout(tabs, immersed: true, bookmarked: true)
        #expect(chrome.card == CGRect(origin: .zero, size: window))
        #expect(chrome.page == chrome.card)
        #expect(chrome.corner == 0)
        #expect(chrome.toolbar == 0)
        #expect(chrome.bookmarks == 0)
        #expect(chrome.sidebar == nil)
        #expect(chrome.strip == nil)
    }

    @Test("A window too small for the chrome never gets a negative card")
    func tinyWindow() {
        let chrome = ChromeLayout(
            window: CGSize(width: 100, height: 20), tabs: .sidebar, sideWidth: 240, folded: false, immersed: false, bookmarked: true)
        #expect(chrome.card.width == 0)
        #expect(chrome.page.height >= 0)
    }

    @Test("The traffic lights line up with the toolbar beside a sidebar and sit in the strip above tabs")
    func lights() {
        let side = ChromeLayout.lights(for: .sidebar)
        #expect(side.y == ChromeLayout.gap + ChromeLayout.toolbar / 2)
        #expect(ChromeLayout.band(for: .sidebar) == 2 * side.y)

        let strip = ChromeLayout.lights(for: .strip)
        #expect(strip.y == ChromeLayout.strip / 2)
        #expect(ChromeLayout.band(for: .strip) == ChromeLayout.strip)
    }

    @Test("A peeking sidebar floats inset like the card")
    func floating() {
        let frame = ChromeLayout.floatingSidebar(window: window, sideWidth: 240)
        #expect(frame == CGRect(x: gap, y: gap, width: 240, height: 800 - 2 * gap))
    }
}
