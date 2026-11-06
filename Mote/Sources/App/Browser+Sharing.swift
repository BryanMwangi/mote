import AppKit

extension Browser {
    /// Share… from a tab's menu: the share menu beside that tab's row in the
    /// sidebar, as the site card opens; elsewhere, the page's corner.
    func share(beside tab: Tab) {
        guard prefs.sidebar, let address = tab.address else { return share() }
        siteCardRow = tab.id
        Task { @MainActor in
            // A few frames for the row to mark itself (SiteCardAnchor).
            for _ in 0..<10 {
                if let row = SiteCardPanel.row, row.window != nil {
                    let picker = NSSharingServicePicker(items: [address])
                    let done = SharingDone { [weak self] in if self?.siteCardRow == tab.id { self?.siteCardRow = nil } }
                    picker.delegate = done
                    SharingDone.current = done
                    return picker.show(relativeTo: row.bounds, of: row, preferredEdge: prefs.sideRight ? .minX : .maxX)
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            siteCardRow = nil
            share()
        }
    }

    /// File › Share: the system's share menu, pointing into the page's top
    /// right corner (or the window's, with no page showing).
    func share() {
        guard let address = active?.address, let window = AppDelegate.window else { return }
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

/// Lets the tab row go once the share menu has closed.
private final class SharingDone: NSObject, NSSharingServicePickerDelegate {
    static var current: SharingDone?
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            done()
            Self.current = nil
        }
    }
}
