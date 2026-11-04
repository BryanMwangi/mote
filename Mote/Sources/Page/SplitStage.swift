import MoteCore
import SwiftUI

/// The page area: the active tab's page, or its split view's pages side by
/// side, with dividers to drag between them. A tab dragged over it shows
/// where it would split in. A lone page fills it as before.
struct SplitStage<Pane: View>: View {
    @ObservedObject var browser: Browser
    let layout: SplitLayout<Tab.ID>
    @ViewBuilder let pane: (Tab) -> Pane

    /// The pane under the pointer, which shows its tools; one being dragged keeps them.
    @State private var hovered: Tab.ID?
    @State private var moving: Tab.ID?

    private var split: Bool { layout.count > 1 }
    private static var corner: CGFloat { 10 }

    var body: some View {
        GeometryReader { proxy in
            let area = CGRect(origin: .zero, size: proxy.size)
            let frames = layout.frames(in: area, gap: Browser.splitGap)
            ZStack(alignment: .topLeading) {
                // As Zen's: each page its own card, on the window's frame between them.
                if split { Palette.frame }
                ForEach(layout.ids, id: \.self) { id in
                    if let tab = browser.tab(id), let frame = frames[id] {
                        let shape = RoundedRectangle(cornerRadius: split ? Self.corner : 0, style: .continuous)
                        pane(tab)
                            .frame(width: frame.width, height: frame.height)
                            .clipShape(shape)
                            .overlay {
                                if split {
                                    shape.strokeBorder(
                                        id == browser.activeID ? Palette.ink.opacity(0.35) : Palette.edge,
                                        lineWidth: id == browser.activeID ? 1.5 : 1
                                    )
                                    .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .top) {
                                if split, hovered == id || moving == id { tools(for: tab) }
                            }
                            .onHover { over in hovered = over ? id : hovered == id ? nil : hovered }
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                if split, let group = layout.ids.first.flatMap(browser.group(of:)) {
                    ForEach(Array(layout.dividers(in: area, gap: Browser.splitGap).enumerated()), id: \.offset) { _, divider in
                        SplitHandle(axis: divider.axis) { travel in
                            let line = divider.axis == .across ? divider.rect.midX : divider.rect.midY
                            browser.resize(group, divider, to: line + travel)
                        }
                        .frame(width: divider.rect.width, height: divider.rect.height)
                        .offset(x: divider.rect.minX, y: divider.rect.minY)
                    }
                }
                if let hover = browser.splitHover, let target = frames[hover.target] {
                    let shown = SplitLayout<Tab.ID>.preview(of: target, side: hover.side).insetBy(dx: 4, dy: 4)
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: shown.minX, y: shown.minY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: browser.splitHover)
        }
        .background(StageAnchor(browser: browser))
        .animation(Motion.hover, value: hovered)
    }

    /// Over a pane's top, as Zen's: a handle to drag it beside another pane,
    /// and a button to take it out of the split, showing on its own.
    private func tools(for tab: Tab) -> some View {
        HStack(spacing: 0) {
            Grip()
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
                .help("Drag beside another page")
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            moving = tab.id
                            let pointer = NSEvent.mouseLocation
                            _ = browser.zone(dragging: tab, at: pointer)
                            TabGhost.show(tab.label, at: pointer)
                        }
                        .onEnded { _ in
                            moving = nil
                            TabGhost.hide()
                            if browser.zone(dragging: tab, at: NSEvent.mouseLocation) == .page {
                                browser.dropOnPage(tab)
                            } else {
                                browser.splitHover = nil
                            }
                        })
            Button {
                browser.unsplit(tab: tab.id)
                browser.select(tab)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Take out of the split")
        }
        .foregroundStyle(.white.opacity(0.9))
        .background(.black.opacity(0.45), in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6, style: .continuous))
        .transition(.opacity)
    }
}

/// Six dots, two rows of three: something to take hold of.
private struct Grip: View {
    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 2.5, height: 2.5) } }
            }
        }
    }
}

/// Tells the browser where the page area is, so a dragged tab can be placed over it.
private struct StageAnchor: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) { browser.stageView = anchor }

    /// Measured from the top left, as the layout's frames are.
    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The line between two panes. AppKit, so its cursor wins over the pages'
/// and the drag keeps tracking past it. Reports how far it was dragged,
/// rightward or downward, from where it was pressed.
private struct SplitHandle: NSViewRepresentable {
    let axis: SplitAxis
    let drag: (CGFloat) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ handle: Handle, context: Context) {
        handle.axis = axis
        handle.drag = drag
        handle.window?.invalidateCursorRects(for: handle)
    }

    final class Handle: NSView {
        var axis = SplitAxis.across
        var drag: (CGFloat) -> Void = { _ in }
        private var start: NSPoint?
        /// The line's place when pressed: `drag` is from there, and the layout
        /// it reads moves under it.
        private var pressed: ((CGFloat) -> Void)?

        private var cursor: NSCursor { axis == .across ? .resizeLeftRight : .resizeUpDown }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            pressed = drag
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let pressed else { return }
            cursor.set()
            // Windows count up from the bottom; the page, down from the top.
            let travel = axis == .across ? event.locationInWindow.x - start.x : start.y - event.locationInWindow.y
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { pressed(travel) }
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            pressed = nil
        }
    }
}

/// A split group's box in the sidebar or strip, drawn a part behind each of
/// its tabs: rounded at the group's ends, reaching over the gaps between.
struct SplitRun: View {
    let axis: Axis
    let first: Bool
    let last: Bool
    /// Between the tabs.
    let gap: CGFloat
    /// How far it reaches past the tabs, across the run.
    var bleed: CGFloat = 4

    var body: some View {
        let r: CGFloat = 10
        let down = axis == .vertical
        UnevenRoundedRectangle(
            topLeadingRadius: first ? r : 0, bottomLeadingRadius: (down ? last : first) ? r : 0, bottomTrailingRadius: last ? r : 0,
            topTrailingRadius: (down ? first : last) ? r : 0, style: .continuous
        )
        // Stronger than a row's hover, as Zen's group, so the split reads as one.
        .fill(Palette.ink.opacity(0.09))
        .padding(down ? .top : .leading, first ? -bleed : -gap / 2)
        .padding(down ? .bottom : .trailing, last ? -bleed : -gap / 2)
        .padding(down ? .horizontal : .vertical, -bleed)
        .allowsHitTesting(false)
    }
}
