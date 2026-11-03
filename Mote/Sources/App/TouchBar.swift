import AppKit
import Combine

/// On a Mac with a Touch Bar: back, forward, the address and a new tab, laid
/// out as Safari's. The window shows it, and so do pages, which would
/// otherwise show WebKit's own.
@MainActor
final class BrowserTouchBar: NSObject, NSTouchBarDelegate {
    private weak var browser: Browser?
    private weak var back: NSButton?
    private weak var forward: NSButton?
    private var watches: [AnyCancellable] = []

    private static let backID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.back")
    private static let forwardID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.forward")
    private static let addressID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.address")
    private static let newTabID = NSTouchBarItem.Identifier("io.github.mote-browser.mote.new-tab")

    init(browser: Browser) {
        self.browser = browser
        super.init()
        // Back and forward follow the tab in front.
        watches.append(
            browser.$activeID.sink { [weak self] _ in
                Task { @MainActor in self?.followActive() }
            })
    }

    func make() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.backID, Self.forwardID, .fixedSpaceSmall, Self.addressID, .fixedSpaceSmall, Self.newTabID]
        bar.principalItemIdentifier = Self.addressID
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case Self.backID:
            let button = Self.button(symbol: "chevron.left", label: "Back") { [weak self] in self?.browser?.back() }
            back = button
            item.view = button
        case Self.forwardID:
            let button = Self.button(symbol: "chevron.right", label: "Forward") { [weak self] in self?.browser?.forward() }
            forward = button
            item.view = button
        case Self.addressID:
            let button = Self.button(symbol: "magnifyingglass", label: "Search or enter website name") { [weak self] in
                self?.browser?.edit()
            }
            button.title = "Search or enter website name"
            button.imagePosition = .imageLeading
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
            item.view = button
        case Self.newTabID:
            item.view = Self.button(symbol: "plus.square.on.square", label: "New Tab") { [weak self] in self?.browser?.newTab() }
        default:
            return nil
        }
        item.customizationLabel = (item.view as? NSButton)?.accessibilityLabel() ?? ""
        followActive()
        return item
    }

    /// Back and forward greyed out when there's nowhere to go.
    private func followActive() {
        watches.removeSubrange(1...)
        guard let tab = browser?.active else {
            back?.isEnabled = false
            forward?.isEnabled = false
            return
        }
        watches.append(tab.$canGoBack.sink { [weak self] can in self?.back?.isEnabled = can })
        watches.append(tab.$canGoForward.sink { [weak self] can in self?.forward?.isEnabled = can })
        // Media starting or stopping, or full screen, swaps the page's bar
        // between this one and WebKit's playback controls: asked for again.
        let swap = Publishers.Merge3(
            tab.$media.map { $0?.playing }.removeDuplicates().map { _ in () },
            tab.$noisy.removeDuplicates().map { _ in () },
            tab.$immersed.removeDuplicates().map { _ in () }
        )
        watches.append(
            swap.dropFirst().receive(on: DispatchQueue.main).sink { [weak tab] in
                tab?.built?.touchBar = nil
            })
    }

    private static func button(symbol: String, label: String, _ act: @escaping () -> Void) -> NSButton {
        let button = ActionButton(act)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.setAccessibilityLabel(label)
        button.bezelStyle = .rounded
        return button
    }

    /// A button that runs a block, its own target.
    private final class ActionButton: NSButton {
        private let act: () -> Void

        init(_ act: @escaping () -> Void) {
            self.act = act
            super.init(frame: .zero)
            title = ""
            target = self
            action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { act() }
    }
}
