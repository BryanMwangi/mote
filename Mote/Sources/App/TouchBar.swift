import AppKit
import Combine

/// On a Mac with a Touch Bar: back and forward, the address and a new tab,
/// laid out as Safari's. The window shows it, and so do pages, except while
/// a page plays video, when WebKit's own playback bar shows (see PageView).
@MainActor
final class BrowserTouchBar: NSObject, NSTouchBarDelegate {
    private weak var browser: Browser?
    private weak var arrows: NSSegmentedControl?
    /// The browser's own, kept for as long as it lives.
    private var following: AnyCancellable?
    /// The tab in front's: replaced only when another tab comes to the front.
    private var watches: [AnyCancellable] = []

    private static let navigationID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.navigation")
    private static let reloadID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.reload")
    private static let fullScreenID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.full-screen")
    private static let playbackID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.playback")
    /// WebKit's playback controls, for the playback bar being made.
    private var playback: NSTouchBar?
    private static let addressID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.address")
    private static let newTabID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.new-tab")

    init(browser: Browser) {
        self.browser = browser
        super.init()
        following = browser.$activeID.removeDuplicates().sink { [weak self] _ in
            // After the change has landed: `@Published` tells before it stores.
            Task { @MainActor in self?.followActive() }
        }
    }

    func make() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        // No spacers: the address button stretches to fill the room left.
        bar.defaultItemIdentifiers = [Self.navigationID, Self.reloadID, Self.addressID, Self.newTabID]
        return bar
    }

    /// While a page plays video: reload and full screen, then WebKit's own
    /// playback controls (play or pause, time, scrubber) as a group.
    func makePlayback(around controls: NSTouchBar) -> NSTouchBar {
        playback = controls
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.reloadID, Self.fullScreenID, Self.playbackID]
        return bar
    }

    /// Only builds the item from what's known now; it never subscribes, as
    /// making the bar must not lead to asking for it again.
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case Self.navigationID:
            let arrows = NSSegmentedControl(
                images: [Self.symbol("chevron.left", "Back"), Self.symbol("chevron.right", "Forward")], trackingMode: .momentary,
                target: self, action: #selector(navigate(_:)))
            arrows.segmentStyle = .separated
            arrows.setWidth(56, forSegment: 0)
            arrows.setWidth(56, forSegment: 1)
            self.arrows = arrows
            showWhereToGo()
            item.view = arrows
            item.customizationLabel = "Back and Forward"
        case Self.addressID:
            let button = ActionButton(title: "Search or enter website name", symbol: "magnifyingglass") { [weak self] in
                self?.browser?.edit()
            }
            button.imageHugsTitle = true
            // Sized by the bar, not by a number: as wide as the room left
            // allows, and no narrower than its text needs to stay readable.
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            item.view = button
            item.visibilityPriority = .high
            item.customizationLabel = "Address"
        case Self.reloadID:
            item.view = ActionButton(title: "", symbol: "arrow.clockwise", label: "Reload") { [weak self] in self?.browser?.reload() }
            // The first to go when the bar is short of room.
            item.visibilityPriority = .low
            item.customizationLabel = "Reload"
        case Self.fullScreenID:
            let full = browser?.active?.immersed == true
            item.view = ActionButton(
                title: "", symbol: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: full ? "Exit Full Screen" : "Full Screen"
            ) { [weak self] in
                (self?.browser?.active?.built as? PageView)?.toggleVideoFullScreen()
            }
            item.customizationLabel = "Full Screen"
        case Self.playbackID:
            guard let controls = playback else { return nil }
            let group = NSGroupTouchBarItem(identifier: identifier, items: [])
            group.groupTouchBar = controls
            return group
        case Self.newTabID:
            item.view = ActionButton(title: "", symbol: "plus.square.on.square", label: "New Tab") { [weak self] in
                self?.browser?.newTab()
            }
            item.visibilityPriority = .high
            item.customizationLabel = "New Tab"
        default:
            return nil
        }
        return item
    }

    @objc private func navigate(_ arrows: NSSegmentedControl) {
        if arrows.selectedSegment == 0 { browser?.back() } else { browser?.forward() }
    }

    private func showWhereToGo() {
        let tab = browser?.active
        arrows?.setEnabled(tab?.canGoBack == true, forSegment: 0)
        arrows?.setEnabled(tab?.canGoForward == true, forSegment: 1)
    }

    /// Follows the tab in front: where it can go, and whether its page's bar
    /// should be WebKit's playback controls.
    private func followActive() {
        watches = []
        showWhereToGo()
        guard let tab = browser?.active else { return }
        watches.append(tab.$canGoBack.merge(with: tab.$canGoForward).sink { [weak self] _ in Task { @MainActor in self?.showWhereToGo() } })
        // As Firefox's Touch Bar: no polling, only events. Video starting or
        // stopping, or full screen: the page checks whether its bar should
        // change, and asks for it again only if so.
        let refresh = { [weak tab] in
            guard let tab, let page = tab.built as? PageView else { return }
            page.refreshTouchBar(immersed: tab.immersed)
        }
        let media = Publishers.Merge3(tab.$media.map { _ in () }, tab.$noisy.map { _ in () }, tab.$immersed.map { _ in () })
        watches.append(media.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink(receiveValue: refresh))
        // WebKit brings its playback controls back a moment after full screen
        // ends, without telling anyone: look once more then.
        watches.append(
            tab.$immersed.dropFirst().filter { !$0 }.delay(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { _ in refresh() })
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    /// A button that runs a block, its own target.
    private final class ActionButton: NSButton {
        private let act: () -> Void

        init(title: String, symbol: String, label: String? = nil, _ act: @escaping () -> Void) {
            self.act = act
            super.init(frame: .zero)
            self.title = title
            image = BrowserTouchBar.symbol(symbol, label ?? title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            bezelStyle = .rounded
            setAccessibilityLabel(label ?? title)
            target = self
            action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { act() }
    }
}
