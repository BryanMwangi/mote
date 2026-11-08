import AppKit
import MoteCore
import WebKit

// WebKit's questions about navigation, new windows, permissions and load
// results. The decisions themselves are NavigationPolicy's; this connects
// them to tabs.
extension Browser: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Context-menu downloads and `download` links. Allowing them would make
        // WebKit try to show them and fail silently.
        guard !action.shouldPerformDownload else { return decisionHandler(.download) }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let from = tab(for: webView)

        // An extension's sign-in redirect goes to the extension, not the page.
        if ExtensionAuth.intercept(url, browser: self, from: webView) { return decisionHandler(.cancel) }
        // An extension page sending its own tab to a website (see replace(_:going:)).
        if #available(macOS 15.4, *), scheme == "http" || scheme == "https", mainFrame,
            webView.url?.scheme == Extensions.scheme, let from
        {
            decisionHandler(.cancel)
            Task { self.replace(from, going: url) }
            return
        }

        let request = NavigationPolicy.Request(
            scheme: scheme,
            clicked: action.navigationType == .linkActivated,
            button: action.buttonNumber,
            keys: Self.keys(action.modifierFlags),
            // Only tabs in the row preview; links inside a preview just navigate.
            peekKeys: prefs.peeksLinks && from != nil && peekTab == nil ? prefs.peekClick.keys : nil)

        switch NavigationPolicy.decide(request) {
        case .ignore:
            decisionHandler(.cancel)
        case .peek:
            decisionHandler(.cancel)
            if let from { Task { self.peek(url, from: from) } }
        case .openTab(let foreground):
            open(url, foreground: foreground, from: from)
            decisionHandler(.cancel)
        case .handOff:
            decisionHandler(.cancel)
            handOff(url, clicked: request.clicked, mainFrame: mainFrame, from: webView)
        case .load:
            // A site a rule gives to another space opens there (Browser+Routing.swift).
            if mainFrame, action.navigationType != .reload, let from, let space = routedSpace(for: url, from: from) {
                decisionHandler(.cancel)
                let fresh = webView.backForwardList.currentItem == nil
                Task { self.route(url, to: space, from: from, fresh: fresh) }
                return
            }
            // The destination site's hidden elements and blocking rules go in
            // before its document loads.
            if mainFrame, let from {
                let host = Address.siteHost(of: url)
                from.boostScript = Boosts.script(for: Boosts.shared.boost(for: host))
                from.arm(hiding: elementHider.hiding(on: host))
                AdBlocker.shared.tune(webView.configuration.userContentController, for: host)
            }
            decisionHandler(.allow)
        }
    }

    private static func keys(_ flags: NSEvent.ModifierFlags) -> NavigationPolicy.Keys {
        var keys: NavigationPolicy.Keys = []
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.command) { keys.insert(.command) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.control) { keys.insert(.control) }
        return keys
    }

    /// Opens a URL with the app that owns its scheme, asking first as Safari
    /// does, except for clicked mail and phone links.
    private func handOff(_ url: URL, clicked: Bool, mainFrame: Bool, from webView: WKWebView) {
        guard NavigationPolicy.mayHandOff(mainFrame: mainFrame, clicked: clicked),
            let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return }
        if NavigationPolicy.handsOffQuietly(scheme: url.scheme ?? "", clicked: clicked) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = Dialogs.alert(
            "Open \u{201C}\(name)\u{201D}?", "\(webView.url?.host() ?? "This page") wants to open \(name).", buttons: ["Open", "Cancel"])
        Dialogs.ask(alert, over: webView) { opens in
            if opens { NSWorkspace.shared.open(url) }
        }
    }

    /// `window.open` and target=_blank links become tabs. The new page must use
    /// the configuration WebKit hands over, or it can't talk to its opener.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let opener = tab(for: webView)
        // A link from Mote's own menu items, to open somewhere else (Browser+Links.swift).
        if let opening = linkOpening, let url = action.request.url {
            linkOpening = nil
            guard case .tab(let background) = opening else {
                open(url, as: opening, from: opener)
                return nil
            }
            // A tab here, as below, left behind when asked.
            configuration.userContentController = WKUserContentController()
            let tab = Tab(shy: opener?.shy ?? isPrivate, configuration: configuration)
            adopt(tab)
            tab.opener = opener?.id ?? activeID
            if !background { activeID = tab.id }
            tab.setAddressOptimistically(url)
            return tab.web
        }
        // WebKit's copy still points at the opener's content controller; sharing it
        // would let the new tab remove the opener's message handlers when it closes.
        configuration.userContentController = WKUserContentController()
        let tab = Tab(shy: opener?.shy ?? false, configuration: configuration)
        tab.popup =
            windowFeatures.width != nil || windowFeatures.height != nil || windowFeatures.toolbarsVisibility?.boolValue == false
        adopt(tab)
        tab.opener = opener?.id ?? activeID
        activeID = tab.id
        editing = false
        // Returning the view makes it the target; WebKit loads the request into it.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Responses the page can't show are downloaded (see NavigationPolicy.downloads).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let http = response.response as? HTTPURLResponse
        let downloads = NavigationPolicy.downloads(
            status: http?.statusCode, disposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
            canShow: response.canShowMIMEType)
        decisionHandler(downloads ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        keep(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        keep(download)
    }

    /// Camera and microphone. Without this WebKit denies every request.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        capture.request(host: host, type: type, answer: decisionHandler)
    }

    /// `window.close()`. Sign-in pop-ups close themselves when done; the tab
    /// goes and its opener, where the sign-in started, comes back.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if let home = tab.opener.flatMap(self.tab) { select(home) }
        tab.pin = nil
        tab.kept = false
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        if tab.id == activeID { linkStatus.dismiss() }
        tab.failure = nil
        tab.typing = false
        // The site's zoom before the first frame.
        tab.applyRememberedZoom()
        // A tab waking from sleep drops its snapshot shortly after the new document.
        tab.uncover(after: 0.45)
    }

    /// The first frame with content: a page held back to avoid a white flash
    /// fades in (only pages that asked, via `PageView.holdForFirstFrame()`).
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // An empty page never reports a first frame.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = tab(for: webView), let url = tab.address else { return }
        tab.uncover()
        tellStore(tab)
        tab.settleSignIn()
        // The icon is fetched even when icons are hidden; they may be turned on later.
        Favicons.shared.fetch(for: tab)
        if !tab.shy, !tab.bench { history.record(url, title: tab.title) }
        noteLanguage(of: tab)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        let tab = tab(for: webView)
        tab?.uncover()
        let error = error as NSError
        let url =
            error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let failure = LoadFailure(domain: error.domain, code: error.code, url: url) { tab?.failure = failure }
    }
}

// MARK: - Downloads

extension Browser: WKDownloadDelegate {
    /// Follows a download; tabs with one running don't sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
        downloads.began(download)
    }

    /// Pauses, or goes on with, a download from the Downloads list or popover.
    func resume(_ transfer: Transfer) {
        // In a page of this window, for its sign-ins; any page will do.
        guard let page = active?.built ?? tabs.lazy.compactMap(\.built).first else { return announce("Open a tab to go on") }
        downloads.resume(transfer, in: page) { [weak self] download in
            download.delegate = self
            self?.downloading.append(download)
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)
        let folder = downloadsFolder

        let transfer = downloads.transfer(for: download)
        guard prefs.asksWhereToSave else {
            let free = Clippings.freeName(name) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let file = folder.appendingPathComponent(free)
            transfer?.file = file
            completionHandler(file)
            announce("Downloading \(free)")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            transfer.map(downloads.cancel)
            return completionHandler(nil)
        }
        transfer?.file = url
        completionHandler(url)
        announce("Downloading \(url.lastPathComponent)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        guard let record = downloads.finished(download) else { return announce("Download finished") }
        announce("Saved \(record.name)")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloading.removeAll { $0 === download }
        // A pause stops it too, and says so itself.
        guard downloads.transfer(for: download)?.state == .running else { return }
        downloads.failed(download, resumeData: resumeData)
        announce(resumeData == nil ? "Download failed" : "Download stopped; it can go on from the Downloads list")
    }
}
