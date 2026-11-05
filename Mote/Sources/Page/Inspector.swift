import WebKit

// The Web Inspector for the tab in front. WebKit only offers it through
// selectors it doesn't publish; without them these do nothing.

/// The inspector's panels Mote opens by name, as WebKit's front end calls them.
enum InspectorPanel: String {
    case network = "Network", sources = "Sources", storage = "Storage", timelines = "Timeline"
}

extension Browser {
    /// ⌥⌘I.
    func toggleInspector() {
        guard let inspector = inspector() else { return }
        inspector.unpublished(Self.inspectorShows(inspector) ? "close" : "show")
    }

    /// ⌥⌘J: the inspector at its console.
    func showConsole() {
        inspector()?.unpublished("showConsole")
    }

    /// ⌥⌘C: the inspector, picking an element on the page.
    func inspectElement() {
        guard let inspector = inspector() else { return }
        if !Self.inspectorShows(inspector) { inspector.unpublished("show") }
        inspector.unpublished("toggleElementSelection")
    }

    /// The inspector at one of its panels (Network ⌥⌘E, Sources ⌥⌘Z, Storage),
    /// as Firefox's keys open them. WebKit's own front end knows how
    /// (`WI.showNetworkTab()` and the like); it's asked once it has loaded.
    func showInspector(_ panel: InspectorPanel) {
        guard let inspector = inspector() else { return }
        if !Self.inspectorShows(inspector) { inspector.unpublished("show") }
        Self.show(panel, in: inspector, tries: 30)
    }

    private static func show(_ panel: InspectorPanel, in inspector: NSObject, tries: Int) {
        let again = {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { show(panel, in: inspector, tries: tries - 1) }
        }
        guard let front = inspector.unpublishedObject("inspectorWebView") as? WKWebView else { return again() }
        let call = "WI.show\(panel.rawValue)Tab"
        front.evaluateJavaScript("typeof \(call) === 'function' ? (\(call)(), true) : false") { shown, _ in
            MainActor.assumeIsolated { if shown as? Bool != true { again() } }
        }
    }

    /// ⇧⌘X, as Firefox: the text being typed runs the other way (right to
    /// left, or back); with nothing being typed, the whole page does.
    func switchTextDirection() {
        guard let web = active?.built else { return }
        web.evaluateInAppWorld(
            """
            (() => {
              const field = document.activeElement;
              const target = field && (field.isContentEditable || /^(INPUT|TEXTAREA)$/.test(field.tagName)) ? field : document.documentElement;
              const now = getComputedStyle(target).direction;
              target.dir = now === "rtl" ? "ltr" : "rtl";
            })()
            """)
    }

    private func inspector() -> NSObject? {
        guard let tab = active, !tab.isBlank else { return nil }
        return tab.web.unpublishedObject("_inspector")
    }

    private static func inspectorShows(_ inspector: NSObject) -> Bool {
        inspector.unpublishedFlag("isVisible") ?? false
    }
}
