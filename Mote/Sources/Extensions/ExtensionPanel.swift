import AppKit
import MoteCore
import SwiftUI
import WebKit

// Extensions' side panels (chrome.sidePanel, Firefox's sidebar_action), in
// the window's side panels beside the page (Browser+Panels): one page per
// open panel per window, kept as the tabs change.

/// The open panels' pages.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPanels {
    static let shared = ExtensionPanels()

    private struct Key: Hashable {
        let window: ObjectIdentifier
        let panel: String
    }

    private var pages: [Key: PanelPage] = [:]

    /// The page for a panel open in `browser`, made on first asking.
    func web(for panel: SidePanel, in browser: Browser) -> WKWebView? {
        let key = Key(window: ObjectIdentifier(browser), panel: panel.id)
        if let known = pages[key]?.web { return known }
        guard let id = panel.extensionID, let context = Extensions.shared.contexts[id], let setup = context.webViewConfiguration,
            let path = ExtensionShims.panelPath(for: id, tab: panel.tab, context: context)
        else { return nil }
        let web = WKWebView(frame: .zero, configuration: setup)
        Web.name(web, "Extension panel · \(context.webExtension.displayName ?? "extension")")
        let page = PanelPage(web: web, browser: browser, panel: panel.id)
        web.uiDelegate = page
        web.navigationDelegate = page
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: Self.url(of: path, in: context)))
        pages[key] = page
        Extensions.shared.controller.didOpenTab(page)
        return web
    }

    /// Whether `browser` shows this page: for the bench.
    func web(of extensionID: String, in browser: Browser) -> WKWebView? {
        pages.first { $0.key.window == ObjectIdentifier(browser) && $0.key.panel == "ext:" + extensionID }?.value.web
    }

    /// A panel closed: its page goes.
    func drop(_ panel: String, in browser: Browser) {
        guard let page = pages.removeValue(forKey: Key(window: ObjectIdentifier(browser), panel: panel)) else { return }
        page.web?.removeFromSuperview()
        Extensions.shared.controller.didCloseTab(page, windowIsClosing: false)
    }

    /// A window closed: its panels' pages go with it, each told to the
    /// extension as a tab closing with its window.
    func drop(windowOf browser: Browser) {
        let window = ObjectIdentifier(browser)
        for (key, page) in pages where key.window == window {
            pages[key] = nil
            page.web?.removeFromSuperview()
            Extensions.shared.controller.didCloseTab(page, windowIsClosing: true)
        }
    }

    /// An extension switched off or removed: its panels close everywhere.
    func close(extension id: String) {
        for browser in Windows.shared.all { browser.closePanel(id: "ext:" + id) }
    }

    /// A panel's page from its manifest path, which may carry a query
    /// (`popup/index.html?uilocation=sidebar`).
    static func url(of path: String, in context: WKWebExtensionContext) -> URL {
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: relative, relativeTo: context.baseURL)?.absoluteURL ?? context.baseURL.appendingPathComponent(relative)
    }

    /// A new path for an open panel: shown at once.
    func reload(extension id: String, path: String) {
        guard let context = Extensions.shared.contexts[id] else { return }
        let url = Self.url(of: path, in: context)
        for (key, page) in pages where key.panel == "ext:" + id && page.web?.url != url { page.web?.load(URLRequest(url: url)) }
    }
}

/// A panel's page as WebKit sees it: in the browser window, not among its
/// tabs, so the panel's "current window" and active tab are the page's
/// beside it.
@available(macOS 15.4, *)
@MainActor
final class PanelPage: NSObject, WKWebExtensionTab, WKUIDelegate, WKNavigationDelegate {
    let web: WKWebView?
    weak var browser: Browser?
    let panel: String

    init(web: WKWebView, browser: Browser, panel: String) {
        self.web = web
        self.browser = browser
        self.panel = panel
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser.map(Extensions.shared.window(for:)) }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { web?.isLoading != true }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { browser?.closePanel(id: panel) }

    func webViewDidClose(_ webView: WKWebView) { browser?.closePanel(id: panel) }

    /// Its page's process went down: it loads again rather than stay blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    /// A new window opens as a tab beside it, as in Chrome; the panel stays.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url { browser?.open(url, foreground: true) }
        return nil
    }
}

/// What a side panel shows, by its kind. The chat has its own place in
/// ChromeDetail, kept in the tree as it slides; the others come and go.
struct PanelHost: View {
    @ObservedObject var browser: Browser
    let panel: SidePanel
    let toolbarTop: CGFloat
    let place: PanelPlace

    var body: some View {
        if #available(macOS 15.4, *), let id = panel.extensionID {
            ExtensionPanelView(browser: browser, panel: panel, extensionID: id, toolbarTop: toolbarTop, place: place)
        }
    }
}

/// An extension's panel: its name and icon over its page, as Chrome heads one.
@available(macOS 15.4, *)
private struct ExtensionPanelView: View {
    @ObservedObject var browser: Browser
    let panel: SidePanel
    let extensionID: String
    let toolbarTop: CGFloat
    let place: PanelPlace

    private var context: WKWebExtensionContext? { Extensions.shared.contexts[extensionID] }

    var body: some View {
        let other: PanelSide = browser.side(of: panel) == .left ? .right : .left
        PanelWeb(web: ExtensionPanels.shared.web(for: panel, in: browser))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                PanelHeader {
                    if let icon = context?.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(context?.webExtension.displayName ?? "Extension")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Door(
                        icon: other == .left ? "arrow.left.to.line" : "arrow.right.to.line",
                        help: other == .left ? "Move to Left" : "Move to Right"
                    ) {
                        browser.move(panel, to: other)
                    }
                    Door(icon: "xmark", help: "Close panel") { browser.closePanel(id: panel.id) }
                }
            }
            .panelCard(toolbarTop: toolbarTop, place: place)
    }
}

/// The panel's page, moved into whichever view shows it.
@available(macOS 15.4, *)
private struct PanelWeb: NSViewRepresentable {
    let web: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ holder: NSView, context: Context) {
        guard let web, web.superview !== holder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }
}
