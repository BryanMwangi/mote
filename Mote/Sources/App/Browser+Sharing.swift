import AppKit

extension Browser {
    /// Where the last share menu pointed, for the bench: a row's frame in its
    /// window, or the page.
    static var sharedAt = ""

    /// A share menu is open from a tab's row: the floating tabs stay out
    /// under it, or it would point at nothing, or close with them.
    static var sharing: Bool { SharingDone.current != nil }

    /// Share…, from anywhere: the share menu beside the tab's row in the
    /// sidebar, or below it in the strip, as the site card opens; with the
    /// tabs out of sight, the page's corner.
    func share(beside tab: Tab) {
        let beside = !prefs.sidebar || !folded || peeking
        // The picker doesn't say when it's dismissed, so an earlier share can
        // have left this row marked; a mark counts only for its own tab.
        if beside { siteCardRow = tab.id }
        let edge: NSRectEdge = prefs.sidebar ? (prefs.sideRight ? .minX : .maxX) : .minY
        Task { @MainActor in
            // The picker is a menu, which can't open while the one Share… was
            // picked from (the tab's, the menu bar's) is still closing: it
            // waits for the run loop to be out of menu tracking.
            await withCheckedContinuation { done in RunLoop.main.perform(inModes: [.default]) { done.resume() } }
            guard beside, let address = tab.address else { return sharePage() }
            // A few frames for the row to mark itself (SiteCardAnchor).
            for _ in 0..<10 {
                if let row = SiteCardPanel.row(for: tab.id) {
                    let picker = NSSharingServicePicker(items: [address])
                    let done = SharingDone { [weak self] in if self?.siteCardRow == tab.id { self?.siteCardRow = nil } }
                    picker.delegate = done
                    SharingDone.current = done
                    let place = row.convert(row.bounds, to: nil)
                    Self.sharedAt = "row \(Int(place.minX)),\(Int(place.minY)) \(Int(place.width))×\(Int(place.height))"
                    return picker.show(relativeTo: row.bounds, of: row, preferredEdge: edge)
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            siteCardRow = nil
            sharePage()
        }
    }

    /// File › Share, the page panel's: beside the tab in front.
    func share() { active.map(share(beside:)) }

    /// The share menu pointing into the page's top right corner (or the
    /// window's, with no page showing).
    private func sharePage() {
        guard let address = active?.address, let window else { return }
        Self.sharedAt = "page"
        let page = active?.built.flatMap { $0.window === window ? $0 : nil }
        guard let view = page ?? window.contentView else { return }
        // A little in, so the arrow points at the page rather than its edge.
        let inset: CGFloat = 12
        let top = view.isFlipped ? inset : view.bounds.maxY - inset
        NSSharingServicePicker(items: [address])
            .show(
                relativeTo: NSRect(x: view.bounds.maxX - inset, y: top, width: 1, height: 1), of: view,
                preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}

/// Lets the tab row go once the share menu has closed: on a choice, or when
/// its popover closes, which the picker doesn't always say.
private final class SharingDone: NSObject, NSSharingServicePickerDelegate {
    static var current: SharingDone?
    let done: () -> Void
    private var closing: NSObjectProtocol?

    init(_ done: @escaping () -> Void) {
        self.done = done
        super.init()
        closing = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.finish() }
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated { finish() }
    }

    @MainActor private func finish() {
        guard Self.current === self else { return }
        closing.map(NotificationCenter.default.removeObserver)
        done()
        Self.current = nil
    }
}
