import AppKit
import MoteAI
import SwiftUI

/// The conversation in an AppKit table: each message a row with its height
/// known before it shows, so scrolling only moves what's already drawn, the
/// end is always where it is, and SwiftUI lays nothing out for a scroll.
/// The rows are the chat's SwiftUI views, one hosting view each, kept as
/// they scroll away. A long chat opens with its latest messages and takes
/// up older ones in batches as it's scrolled toward them.
struct ChatTable: NSViewRepresentable {
    let browser: Browser
    let conversation: Conversation
    let rows: ChatRows
    /// What the rows show; read here, so only this follows the conversation.
    let messages: [Message]
    let busy: Bool
    let summarised: Int
    let summary: String?
    /// The message whose larger look is up, drawn over the rows after it.
    let raised: UUID?
    /// Room under the last row for what sits over the end (the composer).
    let endRoom: CGFloat
    @Binding var distance: ScrollDistance
    /// Bumped by the way down.
    let jumps: Int
    let openURL: OpenURLAction
    let retry: () -> Void

    /// Messages a chat opens with; the rest are taken up after.
    static let opening = 2
    /// Between messages.
    static let spacing: CGFloat = 26

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.parent = self
        return context.coordinator.make()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let jumped = coordinator.parent?.jumps != jumps
        coordinator.parent = self
        coordinator.update()
        if jumped { coordinator.jumpDown() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        coordinator.letGo()
    }

    // MARK: - Rows

    enum Key: Hashable {
        case message(UUID)
        /// Where the chat was summarised: before this message, or at the end (nil).
        case summary(UUID?)
        case status
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ChatTable?
        private let scroll = ChatScrollView()
        private let table = NSTableView()
        /// The rows shown, in order.
        private var keys: [Key] = []
        /// The first message taken up.
        private var from = 0
        private var hosts: [Key: NSHostingController<AnyView>] = [:]
        private var heights: [Key: (height: CGFloat, width: CGFloat)] = [:]
        /// The messages as their rows last showed them.
        private var shown: [UUID: Message] = [:]
        private var shownBusy = false
        private var conversation: ObjectIdentifier?
        /// Keeping to the end as the reply grows; scrolling up by hand lets go.
        private var pinned = true
        private var live = false
        private var lastY: CGFloat = 0
        private var watching: [NSObjectProtocol] = []

        func make() -> NSScrollView {
            let column = NSTableColumn(identifier: .init("chat"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.intercellSpacing = NSSize(width: 0, height: ChatTable.spacing)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.usesAutomaticRowHeights = false
            table.focusRingType = .none
            table.allowsColumnSelection = false
            table.style = .plain
            table.wantsLayer = true
            table.dataSource = self
            table.delegate = self

            scroll.byHand = { [weak self] up in self?.scrolledByHand(up: up) }
            scroll.documentView = table
            scroll.drawsBackground = false
            scroll.verticalScroller = ThinScroller()
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            watching = [
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScroll(true) }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScroll(false) }
                },
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resized() }
                },
            ]
            scroll.postsFrameChangedNotifications = true
            return scroll
        }

        /// A chat's rows let go of a few at a time once it's put away, rather
        /// than all at once while the next one opens.
        func letGo() {
            var left = Array(hosts.values)
            hosts = [:]
            func next() {
                guard !left.isEmpty else { return }
                left.removeLast(min(8, left.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
        }

        func stop() {
            taking?.cancel()
            settling?.cancel()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            if live { ScrollHover.moving = false }
        }

        // MARK: What shows

        /// Brings the rows up to the conversation: new messages added, the one
        /// that changed shown again, everything again for another chat.
        func update() {
            guard let parent else { return }
            let inset = NSEdgeInsets(top: 32, left: 0, bottom: parent.endRoom, right: 0)
            if scroll.contentInsets.bottom != inset.bottom || scroll.contentInsets.top != inset.top {
                scroll.contentInsets = inset
                if pinned, parent.busy { toEnd() }
            }
            let messages = parent.messages
            if conversation != ObjectIdentifier(parent.conversation) {
                conversation = ObjectIdentifier(parent.conversation)
                letGo()
                taking?.cancel()
                taking = nil
                (heights, shown, keys) = ([:], [:], [])
                // The last few at once; older ones as the chat is scrolled up to them.
                from = max(0, messages.count - ChatTable.opening)
                pinned = true
            }
            from = min(from, max(0, messages.count - 1))
            let next = Self.keys(messages, from: from, summarised: parent.summarised, summary: parent.summary)
            let before = keys
            let busyChanged = shownBusy != parent.busy
            shownBusy = parent.busy
            // What each row shows, again where it changed: the streaming reply,
            // the one that was last (its buttons), the status line.
            var changed: [Key] = [.status]
            for message in messages[from...] where shown[message.id] != message {
                changed.append(.message(message.id))
                shown[message.id] = message
            }
            if busyChanged, let last = messages.last { changed.append(.message(last.id)) }
            if before.isEmpty {
                keys = next
                table.reloadData()
            } else if next.count > before.count, next.starts(with: before.dropLast()) {
                // Sent or answered: what's new goes in at the end, the status row moving down.
                if before.count > 1, let old = before.dropLast().last { changed.append(old) }
                keys = next
                let added = IndexSet(integersIn: max(0, before.count - 1)..<(next.count - 1))
                for key in changed { refresh(key) }
                table.insertRows(at: added, withAnimation: .effectFade)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<keys.count))
                pinned = true
            } else if next != before {
                keys = next
                for key in changed { refresh(key) }
                table.reloadData()
            } else {
                for key in changed { refresh(key) }
            }
            raise(parent.raised)
            if pinned { toEnd() }
            publish()
        }

        /// The rows for the messages from `from`: each message, the summary's
        /// place, and the status line last.
        static func keys(_ messages: [Message], from: Int, summarised: Int, summary: String?) -> [Key] {
            var keys: [Key] = []
            for index in messages.indices where index >= from {
                if summary != nil, summarised > 0, index == summarised { keys.append(.summary(messages[index].id)) }
                keys.append(.message(messages[index].id))
            }
            keys.append(.status)
            if summary != nil, summarised > 0, summarised == messages.count { keys.append(.summary(nil)) }
            return keys
        }

        /// The row's view shown again with what it now holds.
        private func refresh(_ key: Key) {
            guard let host = hosts[key], let view = content(key) else { return }
            host.rootView = view
        }

        private func content(_ key: Key) -> AnyView? {
            guard let parent else { return nil }
            let body: AnyView
            switch key {
            case .message(let id):
                guard let index = parent.messages.lastIndex(where: { $0.id == id }) else { return nil }
                let last = index == parent.messages.count - 1
                body = AnyView(
                    MessageRow(
                        message: parent.messages[index], last: last, streaming: last && parent.busy, folder: parent.conversation.folder, tiles: nil
                    )
                    .equatable()
                    .environment(\.message, id))
            case .summary:
                guard let summary = parent.summary else { return nil }
                body = AnyView(SummaryDivider(summary: summary))
            case .status:
                body = AnyView(Status(browser: parent.browser, conversation: parent.conversation, retry: parent.retry))
            }
            let report = { [weak self] (height: CGFloat) in self?.measured(key, height) }
            return AnyView(
                body
                    .environment(\.chatRows, parent.rows)
                    .environment(\.openURL, parent.openURL)
                    .frame(maxWidth: ChatView<EmptyView, EmptyView>.column, alignment: .leading)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    // A row tells its own height as it changes: a reply growing,
                    // its steps or thoughts opened, the status line.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) })
        }

        /// The row's hosting controller, made (and measured) the first time it's asked for.
        private func host(_ key: Key) -> NSHostingController<AnyView>? {
            if let host = hosts[key] { return host }
            guard let view = content(key) else { return nil }
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            host.view.wantsLayer = true
            host.view.layer?.masksToBounds = false
            if hosts.count > 400 { hosts.removeAll() }
            hosts[key] = host
            return host
        }

        private var width: CGFloat { max(table.bounds.width, scroll.contentView.bounds.width) }

        /// How tall a row is: kept, or measured now when it never was. Kept at
        /// another width (the chat being resized, the panel sliding open), it
        /// stays until the width settles: measuring every row on every frame of
        /// a resize is what made opening a long chat take seconds.
        private func height(_ key: Key) -> CGFloat {
            let width = width
            if let kept = heights[key] {
                if kept.width != width { settleSoon() }
                return kept.height
            }
            // Not laid out yet: measured once it has a width.
            guard width > 100 else { return 120 }
            return measure(key)
        }

        @discardableResult
        private func measure(_ key: Key) -> CGFloat {
            let width = width
            guard let host = host(key) else { return 1 }
            let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = max(1, ceil(size.height))
            heights[key] = (height, width)
            return height
        }

        /// A row's own report of its height, once laid out.
        private func measured(_ key: Key, _ height: CGFloat) {
            let height = max(1, ceil(height))
            guard let row = keys.firstIndex(of: key), width > 100 else { return }
            let old = heights[key]?.height
            if let old, abs(old - height) < 0.5 { heights[key] = (height, width); return }
            heights[key] = (height, width)
            changed(row, by: height - (old ?? height))
        }

        /// A row grown or shrunk: one above what shows holds the view where it
        /// was, so nothing seen moves; at the end, it's followed.
        private func changed(_ row: Int, by delta: CGFloat) {
            let clip = scroll.contentView
            let above = table.rect(ofRow: row).maxY <= clip.bounds.minY
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
            if pinned {
                toEnd()
            } else if above, delta != 0 {
                move(to: clip.bounds.origin.y + delta)
            }
            publish()
        }

        // MARK: Width

        private var settling: Task<Void, Never>?

        /// Once the width has held still a moment, rows kept at another one
        /// measured again a few at a time, those in view first; a person
        /// scrolling comes first.
        private func settleSoon() {
            settling?.cancel()
            settling = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                let visible = self.table.rows(in: self.scroll.contentView.bounds)
                let order = Array(visible.lowerBound..<visible.upperBound) + Array(0..<self.keys.count).filter { !visible.contains($0) }
                for row in order where self.keys.indices.contains(row) {
                    let key = self.keys[row]
                    guard let kept = self.heights[key], kept.width != self.width else { continue }
                    while !self.still, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    guard !Task.isCancelled, let at = self.keys.firstIndex(of: key) else { return }
                    let height = self.measure(key)
                    self.changed(at, by: height - kept.height)
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { keys.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            keys.indices.contains(row) ? height(keys[row]) : 1
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            keys.indices.contains(row) ? host(keys[row])?.view : nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = ChatRowView()
            view.wantsLayer = true
            view.layer?.masksToBounds = false
            return view
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        /// The raised message's row over the rows after it.
        private func raise(_ id: UUID?) {
            table.enumerateAvailableRowViews { view, row in
                let up = id.map { keys.indices.contains(row) && keys[row] == .message($0) } ?? false
                view.layer?.zPosition = up ? 1 : 0
            }
        }

        // MARK: Scrolling

        private var endY: CGFloat {
            let clip = scroll.contentView
            return max(-scroll.contentInsets.top, table.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        }

        private func toEnd() {
            let clip = scroll.contentView
            guard abs(clip.bounds.origin.y - endY) > 0.5 else { return }
            move(to: endY)
        }

        private func liveScroll(_ on: Bool) {
            live = on
            ScrollHover.moving = on
            lastY = scroll.contentView.bounds.origin.y
            // A scroll by hand that ends at the end takes following up again.
            if !on, endY - scroll.contentView.bounds.origin.y < 24 { pinned = true }
        }

        /// A person's scroll, by wheel or trackpad: up lets go of the end;
        /// down to the end takes it up again.
        private func scrolledByHand(up: Bool) {
            if up { pinned = false } else if endY - scroll.contentView.bounds.origin.y < 24 { pinned = true }
        }

        /// Scrolling the chat does itself: following, holding the view as rows
        /// above it change, the way down.
        private var ours = false
        /// Gliding down to the end, which is the chat's own scrolling too.
        private var jumping = false

        private func move(to y: CGFloat) {
            let clip = scroll.contentView
            ours = true
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            ours = false
            lastY = clip.bounds.origin.y
        }

        /// When the chat last moved, however it was scrolled.
        private var moved = Date.distantPast

        /// Nothing scrolling it lately: work that holds the main thread a while
        /// (measuring a row) waits for this, so it never lands mid-scroll.
        private var still: Bool { !live && Date.now.timeIntervalSince(moved) > 0.4 }

        private func scrolled() {
            moved = .now
            let y = scroll.contentView.bounds.origin.y
            // Only a person counts: a live scroll (a trackpad, dragging the scroll
            // bar) going up lets go of the end, and back at the end takes it up
            // again. The chat moving because what it holds changed size (a reply
            // settling, the working line) never lets go; nor does its own scrolling.
            if live, !ours, !jumping {
                if y < lastY - 0.5 { pinned = false } else if endY - y < 24 { pinned = true }
            }
            lastY = y
            publish()
            // Near the first message taken up: the ones before it, once the chat is still.
            if from > 0, taking == nil, y + scroll.contentInsets.top < scroll.contentView.bounds.height * 3 { takeOlderSoon() }
            // Near the first message taken up, the ones before it.
            if let window = scroll.window {
                let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
                parent?.rows.visible = CGRect(
                    x: visible.minX, y: (window.contentView?.bounds.height ?? 0) - visible.maxY, width: visible.width, height: visible.height)
            }
        }

        private func resized() {
            // Rows shown before there was a width, on a guess until now.
            let guessed = IndexSet(keys.indices.filter { heights[keys[$0]] == nil })
            if width > 100, !guessed.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: guessed)
                }
            }
            settleSoon()
            if pinned { toEnd() }
        }

        /// The zone of how far up from the end, to the chat, when it changes.
        private func publish() {
            guard let parent else { return }
            let clip = scroll.contentView
            let zone = ScrollDistance(below: endY - clip.bounds.origin.y, view: clip.bounds.height)
            if zone != parent.distance { DispatchQueue.main.async { parent.distance = zone } }
        }

        private var taking: Task<Void, Never>?

        /// A few older messages, near the top of what's taken up: each
        /// measured once the chat is still (measuring holds the main thread a
        /// while), then put in above with the view held where it was.
        private func takeOlderSoon() {
            taking = Task { @MainActor [weak self] in
                for _ in 0..<ChatTable.opening * 2 {
                    guard let self, self.from > 0, !Task.isCancelled else { break }
                    while !self.still || self.width <= 100, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    guard !Task.isCancelled else { break }
                    self.takeOne()
                    try? await Task.sleep(for: .milliseconds(16))
                }
                self?.taking = nil
            }
        }

        private func takeOne() {
            guard let parent else { return }
            let older = from - 1
            let next = Self.keys(parent.messages, from: older, summarised: parent.summarised, summary: parent.summary)
            let added = Array(next.prefix(max(0, next.count - keys.count)))
            let rise = added.reduce(0) { $0 + measure($1) + ChatTable.spacing }
            for key in added { if case .message(let id) = key, let message = parent.messages.first(where: { $0.id == id }) { shown[id] = message } }
            from = older
            keys = next
            let clip = scroll.contentView
            let y = clip.bounds.origin.y
            table.insertRows(at: IndexSet(integersIn: 0..<added.count), withAnimation: [])
            if !pinned {
                move(to: y + rise)
            } else {
                toEnd()
            }
        }

        /// The way down: from far up, straight to two screens above the end,
        /// unseen, then a glide the rest; it lands on the end, as every row's
        /// height is known.
        func jumpDown() {
            pinned = true
            let clip = scroll.contentView
            let screen = clip.bounds.height
            if endY - clip.bounds.origin.y > screen * 2 {
                move(to: endY - screen * 2)
            }
            jumping = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: endY))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.jumping = false
                    self.scroll.reflectScrolledClipView(clip)
                    self.toEnd()
                }
            }
        }
    }
}

/// The chat's scroll view, telling which way a person scrolls it: a mouse
/// wheel, unlike a trackpad, sends no live-scroll notices to go by.
final class ChatScrollView: NSScrollView {
    var byHand: ((_ up: Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 { byHand?(true) }
        super.scrollWheel(with: event)
        if event.scrollingDeltaY < 0 { byHand?(false) }
    }
}

/// A message's row. Code, tables and the sources scroll sideways inside it;
/// a scroll mostly up or down that starts over one is the chat's, as a
/// nested scroll passes on what it doesn't take. AppKit picks a gesture's
/// target by hit-testing as it starts, so the row answers for those.
final class ChatRowView: NSTableRowView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, let event = NSApp.currentEvent, event.type == .scrollWheel,
            abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        else { return hit }
        var view: NSView? = hit
        while let at = view, at !== self {
            if at is NSScrollView { return self }
            view = at.superview
        }
        return hit
    }
}

/// The chat's scroll bar as the lists': a thin thumb with no track or
/// border, there while the chat moves (the system's overlay style shows and
/// hides it) and while the pointer is over its strip, a little wider then.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    private var over = false
    /// Keeps it showing while the pointer is over the strip.
    private var showing: Timer?

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        // Held inside its strip, a few points in from either end: grown to its
        // least height near the end, it ran past it and was cut off.
        let slot = rect(for: .knobSlot).insetBy(dx: 0, dy: 4)
        let knob = rect(for: .knob).insetBy(dx: 0, dy: 3)
        let width: CGFloat = over ? 7 : 4
        let height = min(max(24, knob.height), slot.height)
        let y = min(max(knob.midY - height / 2, slot.minY), slot.maxY - height)
        let thumb = NSRect(x: knob.maxX - width - 1, y: y, width: width, height: height)
        Palette.NS.ink.withAlphaComponent(over ? 0.45 : 0.32).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        over = true
        needsDisplay = true
        enclosingScrollView?.flashScrollers()
        showing?.invalidate()
        showing = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.enclosingScrollView?.flashScrollers() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        over = false
        needsDisplay = true
        showing?.invalidate()
        showing = nil
    }
}
