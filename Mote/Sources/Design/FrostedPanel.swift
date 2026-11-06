import AppKit
import SwiftUI

/// A floating editor over the window, frosted as Zen's theme picker and
/// boost editor are: it stays on top while the page changes under it, moves
/// by its background, and closes with Esc or its owner. One per name.
@MainActor
enum FrostedPanel {
    private static var open: [String: Panel] = [:]

    /// Shows `content` beside `window`'s sidebar edge (or at `origin`, on
    /// screen, its top left); `closed` runs however it closes.
    static func show(
        _ name: String, _ content: some View, over window: NSWindow, at origin: NSPoint, closed: @escaping () -> Void
    ) {
        if let panel = open[name] { return panel.orderFront(nil) }
        let host = NSHostingView(rootView: AnyView(content))
        let size = host.fittingSize
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        // Shaped by a mask image only: the blur ignores the layer's rounded
        // corners and the window would show square around it.
        material.maskImage = .roundedMask(radius: 16)
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)

        let panel = Panel(contentRect: material.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = material
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // By its top bar only (see DragHandle), so what's inside can be dragged.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.appearance = window.effectiveAppearance
        panel.closed = {
            open[name] = nil
            closed()
        }
        var frame = NSRect(origin: NSPoint(x: origin.x, y: origin.y - size.height), size: size)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - size.width - 8)
            frame.origin.y = max(frame.minY, screen.minY + 8)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        open[name] = panel
    }

    static func close(_ name: String) { open[name]?.close() }

    private final class Panel: NSPanel {
        var closed: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
        override func close() {
            parent?.removeChildWindow(self)
            super.close()
            let closed = closed
            self.closed = {}
            closed()
        }
    }
}

/// The top bar of a frosted panel, which moves it as a title bar would.
struct DragHandle: FillsRoom {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Handle: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

extension NSImage {
    /// A rounded rectangle that stretches to any size, keeping its corners:
    /// the shape of a frosted panel's blur.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Frosted glass behind SwiftUI content, rounded by a mask image (the blur
/// ignores rounded layers): the menu panels' ground.
struct Frost: FillsRoom {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = .roundedMask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
