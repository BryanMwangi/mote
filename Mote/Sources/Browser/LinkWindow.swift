import MoteCore
import SwiftUI
import WebKit

// Links from other apps can open in a small window of their own, with the
// site's name and an Open in Mote button (Settings › General). The page is an
// ordinary tab that moves into the browser when kept.
//
// A page's pop-up (`window.open` with a size, or without toolbars: sign-ins,
// verifications) opens in one too, as browsers give pop-ups a window with
// nothing but the page and its site: no tabs, sidebar or address field.

/// Where links from other apps open (Settings › General).
enum LinkSpace {
    static let current = ""
    /// A tab that keeps nothing, as a private window's.
    static let none = "private"
}

@MainActor
final class LinkWindow: NSObject, NSWindowDelegate {
    /// Every one open, oldest first, until closed or kept.
    private(set) static var all: [LinkWindow] = []

    let tab: Tab
    private weak var browser: Browser?
    private let window: NSWindow
    private var kept = false
    /// The space it opens in when kept; nil for the one showing.
    private var space: UUID?
    /// A page's pop-up: it stays a window, closed by the page or ⌘W.
    let popup: Bool
    /// Told as it closes: an extension's window goes from WebKit's list.
    var closed: (() -> Void)?
    /// For an extension's window: its frame and focus.
    var nsWindow: NSWindow { window }

    /// `front: false` makes it without showing it, for the bench.
    static func show(_ url: URL, for browser: Browser, front: Bool = true) {
        let chosen = browser.prefs.linksSpace
        // A space that's gone counts as the one showing.
        let space = browser.usesSpaces ? browser.spaces.first { $0.id.uuidString == chosen }?.id : nil
        let tab =
            chosen == LinkSpace.none
            ? Tab(shy: true) : space.map { Tab(configuration: Web.configuration(space: $0)) } ?? Tab()
        browser.prepare(tab)
        tab.go(to: url)
        let little = LinkWindow(tab: tab, browser: browser)
        little.space = space
        all.append(little)
        little.window.center()
        guard front else { return }
        little.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// A pop-up's window for `tab`, whose page WebKit is about to load: the
    /// size the page asked for, where it asked, else over the window it came
    /// from.
    static func popUp(_ tab: Tab, for browser: Browser, features: WKWindowFeatures, over opener: NSWindow?) {
        let size = NSSize(
            width: features.width.map { CGFloat($0.doubleValue) } ?? 500,
            height: features.height.map { CGFloat($0.doubleValue) } ?? 600)
        let spot = features.x.flatMap { x in features.y.map { NSPoint(x: x.doubleValue, y: $0.doubleValue) } }
        popUp(tab, for: browser, size: size, at: spot, over: opener)
    }

    /// A pop-up's window at `size`, its top left at `spot` (from the
    /// screen's top left) if given, else over `opener`: a page's, or an
    /// extension's (chrome.windows.create with type popup).
    @discardableResult
    static func popUp(
        _ tab: Tab, for browser: Browser, size: NSSize, at spot: NSPoint?, over opener: NSWindow?, front: Bool = true
    )
        -> LinkWindow
    {
        browser.prepare(tab)
        let little = LinkWindow(tab: tab, browser: browser, popup: true, size: size)
        all.append(little)
        let window = little.window
        if let screen = opener?.screen ?? NSScreen.main, let spot {
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + spot.x, y: screen.frame.maxY - spot.y))
        } else if let opener {
            window.setFrameOrigin(NSPoint(x: opener.frame.midX - window.frame.width / 2, y: opener.frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        if front { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        return little
    }

    static func owning(_ window: NSWindow?) -> LinkWindow? {
        all.first { $0.window === window }
    }

    /// The pop-up showing `webView`, if one does.
    static func showing(_ webView: WKWebView) -> LinkWindow? {
        all.first { $0.tab.built === webView }
    }

    private init(tab: Tab, browser: Browser, popup: Bool = false, size: NSSize = NSSize(width: 900, height: 640)) {
        self.tab = tab
        self.browser = browser
        self.popup = popup
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + LinkWindowView.barHeight)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = popup ? NSSize(width: 240, height: 200) : NSSize(width: 420, height: 320)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: LinkWindowView(tab: tab, keep: popup ? nil : { [weak self] in self?.keep() }))
    }

    /// As the close button does.
    func close() { window.performClose(nil) }

    /// Its own keys, before the browser's; false leaves the key to the page.
    func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let press = KeyMap.Press(
            key: event.charactersIgnoringModifiers ?? "", code: event.keyCode, command: flags.contains(.command),
            shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
        switch KeyMap.linkWindow(press) {
        // A pop-up's page may want Escape, and isn't a tab to keep.
        case .keep where !popup: keep()
        case .close where !popup || press.command: close()
        default: return false
        }
        return true
    }

    /// Moves the page into the browser after the current tab and brings the
    /// browser forward.
    func keep() {
        guard let browser else { return }
        kept = true
        window.close()
        // One that keeps nothing goes to a private window.
        if tab.shy, !browser.isPrivate {
            let hidden = Windows.shared.open(private: true)
            let blank = hidden.active
            hidden.adopt(tab)
            hidden.activeID = tab.id
            if let blank, blank.isBlank { hidden.close(blank) }
            return
        }
        if let space, space != browser.spaceID { browser.switchSpace(to: space) }
        browser.insert(tab, at: browser.placeForNew())
        browser.select(tab)
        let main = AppDelegate.window ?? NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) && $0 !== window }
        main?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !kept { tab.close() }
        Self.all.removeAll { $0 === self }
        closed?()
    }
}

/// The site's bar over the page.
private struct LinkWindowView: View {
    @ObservedObject var tab: Tab
    /// None for a pop-up.
    let keep: (() -> Void)?

    static let barHeight: CGFloat = 34

    /// The traffic lights sit on the bar.
    private static let lightsRoom: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: Self.lightsRoom)
                Spacer(minLength: 0)
                // A pop-up's opener names it, so the site shows instead: where
                // a password is being typed.
                if keep == nil, tab.address?.scheme == "https" {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                Text(tab.address.map { keep == nil ? $0.host() ?? "" : Address.siteName(for: $0) } ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let keep {
                    Pill("Open in Mote", action: keep).help("Open in Mote   ⌘O")
                } else {
                    Color.clear.frame(width: Self.lightsRoom)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.barHeight)
            WebStage(page: tab.built ?? tab.web)
        }
        .background(Palette.ground)
        .ignoresSafeArea()
    }
}
