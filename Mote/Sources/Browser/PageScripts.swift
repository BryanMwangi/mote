import MoteCore
import WebKit

/// The scripts Mote puts in each document a tab loads, in order.
enum PageScripts {
    /// Everything for the next document: scroll reports, the element picker,
    /// sign-in forms, swipes, image menus, the Web Store bridge, link hovers,
    /// middle-clicks, passkeys, and this site's hidden elements (at document
    /// start, so they never show).
    @MainActor
    /// `dev`: the page is a developer site the assistant may test, which gets
    /// the console and network hook (Scripts/src/dev-hooks.ts) in its own world.
    static func all(hiding: ElementHidingStyle.Config, boost: String = "", ads: Bool = false, dev: Bool = false) -> [WKUserScript] {
        var scripts = [
            mote(ScrollRelay.script, at: .atDocumentEnd),
            mote(ElementPicker.picker, at: .atDocumentStart),
            mote(FormRelay.script, at: .atDocumentEnd),
        ]
        if AutoScroll.on { scripts.append(mote(AutoScroll.script, at: .atDocumentEnd)) }
        // YouTube's ads come inside its player's data, out of a block list's reach.
        if ads { scripts.append(YouTubeAds.userScript) }
        // Every frame: only a frame's own document knows whether it takes a
        // swipe (a map) or holds the image under the pointer.
        scripts += [
            mote(Swipe.watch, at: .atDocumentStart, everyFrame: true),
            mote(ImageRelay.watch, at: .atDocumentStart, everyFrame: true),
        ]
        if #available(macOS 15.4, *) { scripts.append(mote(WebStoreBridge.script, at: .atDocumentEnd)) }
        if HoveredLink.on {
            scripts.append(
                WKUserScript(source: HoveredLink.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        // Main frame only: a middle-click in a frame (an ad) isn't the tab's.
        scripts.append(mote(MiddleRelay.watch, at: .atDocumentStart))
        // The passkey patch replaces the page's own functions, so it runs in the
        // page's world and reaches Mote through a bridge in Mote's. It goes in
        // either way, since extension scripts can carry it too (see Passkeys.swift).
        let passkeys = FormRelay.passkeysOffered ? PasskeyRelay.page : FormRelay.withoutPasskeys
        scripts += [
            WKUserScript(source: passkeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            mote(PasskeyRelay.bridge, at: .atDocumentStart, everyFrame: true),
        ]
        // Which site it's loading from, until it has loaded.
        scripts.append(mote(LoadRelay.script, at: .atDocumentStart))
        // In the page's world, the only one that sees the site's media session.
        scripts.append(WKUserScript(source: MediaRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // Notifications, which WebKit shows apps no way to give the page.
        scripts.append(WKUserScript(source: NotificationRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if dev { scripts.append(WKUserScript(source: Self.devHooks, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)) }
        // An image on its own (a file dropped in, a download opened): on a
        // dark ground, as Firefox shows one, rather than the page's white.
        scripts.append(mote(Self.imageGround, at: .atDocumentEnd))
        if !hiding.selectors.isEmpty { scripts.append(mote(ElementPicker.hiding(hiding), at: .atDocumentStart)) }
        // The site's boost (see Boosts.swift), from the first paint.
        if !boost.isEmpty { scripts.append(mote(boost, at: .atDocumentStart)) }
        return scripts
    }

    private static let devHooks = InjectedScript.source("dev-hooks")

    /// Whether a page at `url` gets the developer hook: one of the developer
    /// sites, with Developer mode on or coding agents let in.
    static func wantsDevHooks(_ url: URL?) -> Bool {
        let store = Storage.settings
        guard store.string(forKey: "ai.actMode") == AIMode.developer.rawValue || store.bool(forKey: "ai.agents") else { return false }
        return SiteList.contains(store.string(forKey: "ai.devSites") ?? "localhost:*, 127.0.0.1:*", url)
    }

    private static let imageGround = """
        if (document.contentType.startsWith('image/') && document.images.length === 1 && document.body.children.length === 1) {
          document.documentElement.style.background = '#1c1c1e';
          document.body.style.background = '#1c1c1e';
        }
        """

    @MainActor
    private static func mote(_ source: String, at time: WKUserScriptInjectionTime, everyFrame: Bool = false) -> WKUserScript {
        WKUserScript(source: source, injectionTime: time, forMainFrameOnly: !everyFrame, in: Web.world)
    }
}
