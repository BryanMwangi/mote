import Combine
import MoteCore
import SwiftUI
import WebKit

// The address of the link under the pointer, at the bottom of the page
// (Settings › General). Pages only get the script that reports it while
// that's on.

/// Hears the hovered link from the page. WebKit holds on to it, so the tab
/// is weak.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let name = "link"
    /// Whether new pages get the script.
    @MainActor static var on = false

    /// Quiets the script in pages that already have it.
    static let off = "if (window.__moteLinks) window.__moteLinks.on = false;"

    /// Reports the hovered link each time it changes, in every frame.
    /// See Scripts/src/status-line.ts.
    static let script = InjectedScript.source("status-line")

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.linkHovered(address.isEmpty ? nil : address)
        }
    }
}

/// Hears which site the page is loading from while it loads (see
/// Scripts/src/load-hosts.ts). WebKit holds on to it, so the tab is weak.
final class LoadRelay: NSObject, WKScriptMessageHandler, TabRelay {
    static let name = "loading"
    private struct Config: Encodable { let handler: String }
    static let script = InjectedScript.source("load-hosts", config: Config(handler: name))

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = message.body as? String, host.count < 256 else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built, tab.loading else { return }
            tab.loadingFrom = host.isEmpty ? nil : host
        }
    }
}

/// The address showing, if any, and which side it's on. It changes only when
/// the page says so, never as the pointer moves.
@MainActor
final class LinkStatus: ObservableObject {
    @Published private(set) var destination: String?
    @Published private(set) var onRight = false
    private var hiding: Task<Void, Never>?

    /// Leaving a link hides the address after a moment, so moving between
    /// two links doesn't flicker.
    private static let linger: Duration = .milliseconds(120)

    func show(_ address: String?, over page: NSView?) {
        hiding?.cancel()
        guard let address else {
            hiding = Task { [weak self] in
                try? await Task.sleep(for: Self.linger)
                if !Task.isCancelled { self?.dismiss() }
            }
            return
        }
        if destination != address { destination = address }
        if let page { place(over: page) }
    }

    /// At once: another tab, another page.
    func dismiss() {
        hiding?.cancel()
        hiding = nil
        if destination != nil { destination = nil }
    }

    private func place(over page: NSView) {
        guard let window = page.window else { return }
        let pointer = page.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let height = page.bounds.height
        let right = LinkBubblePlace.onRight(
            pointerX: pointer.x, fromBottom: page.isFlipped ? height - pointer.y : pointer.y, page: page.bounds.width)
        if onRight != right { onRight = right }
    }
}

/// The address in a capsule at the page's bottom edge; clicks pass through.
struct LinkBubble: View {
    @ObservedObject var status: LinkStatus
    @ObservedObject var tab: Tab
    /// Settings › General: the address of the link under the pointer.
    let showsLinks: Bool

    /// The link under the pointer, or what the page is loading from.
    private var text: String? {
        if showsLinks, let address = status.destination { return address }
        guard tab.loading else { return nil }
        if let host = tab.loadingFrom { return "Loading from \(host)…" }
        return tab.address?.host().map { "Loading \($0)…" } ?? "Loading…"
    }

    /// Links can sit on the right, out of the pointer's way; loading stays left.
    private var onRight: Bool { showsLinks && status.destination != nil && status.onRight }

    var body: some View {
        GeometryReader { room in
            if let address = text {
                Text(address)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Palette.ground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
                    .frame(maxWidth: LinkBubblePlace.width(page: room.size.width), alignment: onRight ? .trailing : .leading)
                    .padding([.horizontal, .bottom], 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .bottomTrailing : .bottomLeading)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: text == nil)
    }
}
