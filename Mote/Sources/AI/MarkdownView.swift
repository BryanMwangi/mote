import AppKit
import MoteAI
import SwiftUI

/// A reply's Markdown, drawn in Mote's type: each block from `Markdown`,
/// and the words inside them through Foundation's inline Markdown.
struct MarkdownView: View, Equatable {
    let text: String
    /// Links to these pages (by `Source.key`) show as citation chips with
    /// the name given.
    var cites: [String: String] = [:]
    /// The reply the text is from, whose parse is kept and carried on as
    /// it streams in; nil for text parsed whole each time.
    var reply: UUID?
    /// While it streams in: its last words, fading in (see `Typewriter`).
    var tail: Tail?

    struct Tail: Equatable {
        var fresh: [Typewriter.Fresh]
    }

    var body: some View {
        Blocks(blocks: Self.blocks(of: text, reply: reply), cites: cites, tail: tail, key: reply?.uuidString)
    }

    /// Replies as they stream in, each parsed a piece at a time.
    @MainActor private static var streams: [UUID: Markdown.Stream] = [:]
    /// Other text parsed, so drawing it again doesn't parse it again.
    @MainActor private static var parsed: [String: [Markdown.Block]] = [:]

    @MainActor private static func blocks(of text: String, reply: UUID?) -> [Markdown.Block] {
        if let reply {
            var stream = streams[reply] ?? Markdown.Stream()
            stream.update(text)
            if streams.count > 400, streams[reply] == nil { streams.removeAll() }
            streams[reply] = stream
            return stream.blocks
        }
        if let blocks = parsed[text] { return blocks }
        let blocks = Markdown.parse(text)
        if parsed.count > 64 { parsed.removeAll() }
        parsed[text] = blocks
        return blocks
    }

    /// Body text in replies: a little larger than the chrome's, for reading.
    static let size: CGFloat = 14
    static let leading: CGFloat = 4.5

    /// Inline Markdown already styled, by text, with the cites it was styled for.
    @MainActor private static var styled: [String: (cites: [String: String], text: AttributedString)] = [:]

    /// Inline Markdown (emphasis, code, links) in a block's text. Code spans
    /// get the monospaced face on a faint wash.
    @MainActor static func inline(_ text: String, cites: [String: String] = [:]) -> AttributedString {
        if let kept = styled[text], kept.cites == cites { return kept.text }
        let made = style(text, cites: cites)
        if styled.count > 2_000 { styled.removeAll() }
        styled[text] = (cites, made)
        return made
    }

    private static func style(_ text: String, cites: [String: String]) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: size * 0.9, design: .monospaced)
            styled[run.range].backgroundColor = Palette.veil
        }
        // By link, so a link whose text mixes styles is one chip; from the end,
        // so replacing one never moves those still to come.
        for (link, range) in styled.runs[\.link].reversed() {
            guard let link else { continue }
            guard let name = cites[Source.key(for: link)] else {
                styled[range].underlineStyle = .single
                continue
            }
            // A citation: the site's name on a small chip, still a link. A link
            // worded as part of the answer keeps its words, with the chip after.
            var chip = AttributedString("\u{2009}\(name)\u{2009}")
            chip.link = link
            chip.font = .system(size: size * 0.76, weight: .medium)
            chip.foregroundColor = Palette.muted
            chip.backgroundColor = Palette.wash
            chip.baselineOffset = 1
            if Citations.namesSite(String(styled[range].characters), link) {
                styled.replaceSubrange(range, with: chip)
            } else {
                styled[range].link = nil
                styled.insert(AttributedString(" ") + chip, at: range.upperBound)
            }
        }
        return styled
    }
}

/// The blocks, as runs of text drawn by one text view each, and the
/// blocks that aren't text (code and tables scroll sideways; a quote has
/// its bar) each a view of its own.
private struct Blocks: View {
    let blocks: [Markdown.Block]
    let cites: [String: String]
    /// Goes to the last run only: the words streaming in are at the end.
    var tail: MarkdownView.Tail?
    /// The reply's, for keeping each run's layout (see `ReplyLayout.kept`).
    var key: String?

    var body: some View {
        // A table still arriving shows once whole: when what follows it
        // starts, or the reply ends, rather than a row at a time.
        let runs = Run.of(tail != nil && Self.isTable(blocks.last) ? Array(blocks.dropLast()) : blocks)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                let tail = index == runs.count - 1 ? tail : nil
                switch run {
                case .text(let blocks):
                    // Equatable, so as a reply streams in only its last run is touched.
                    MarkdownText(
                        blocks: blocks, cites: cites, streaming: tail != nil, fresh: tail?.fresh ?? [], key: key.map { "\($0)-\(index)" }
                    )
                    .equatable()
                case .block(.code(let language, let text, _)):
                    CodeBlock(language: language, code: text)
                case .block(.table(let table)):
                    TableBlock(table: table, cites: cites)
                case .block(.quote(let blocks)):
                    HStack(alignment: .top, spacing: 12) {
                        Capsule().fill(Palette.faint).frame(width: 3)
                        Blocks(blocks: blocks, cites: cites, tail: tail).opacity(0.75)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .block:
                    Palette.hairline.frame(height: 1).padding(.vertical, 4)
                }
            }
        }
    }

    private static func isTable(_ block: Markdown.Block?) -> Bool {
        if case .table? = block { true } else { false }
    }

    enum Run {
        case text([Markdown.Block])
        case block(Markdown.Block)

        static func of(_ blocks: [Markdown.Block]) -> [Run] {
            var runs: [Run] = []
            for block in blocks {
                switch block {
                case .paragraph, .heading, .list:
                    if case .text(let run) = runs.last {
                        runs[runs.count - 1] = .text(run + [block])
                    } else {
                        runs.append(.text([block]))
                    }
                default: runs.append(.block(block))
                }
            }
            return runs
        }
    }
}

/// Paragraphs, headings and lists in one AppKit text view: laid out by
/// TextKit once and again only where they change, selectable across them,
/// one place for the pointer. As SwiftUI `Text`s, each was a view measured
/// and hit-tested on its own, and a long reply was hundreds.
private struct MarkdownText: NSViewRepresentable, Equatable {
    let blocks: [Markdown.Block]
    let cites: [String: String]
    /// Its end still arriving: half-written marks there are healed.
    let streaming: Bool
    /// The words shown lately, fading in.
    let fresh: [Typewriter.Fresh]
    /// Which reply's run this is.
    let key: String?

    /// Measures apart from the view: SwiftUI asks the size of this text and
    /// of the one before it in no set order, so sizing never touches what
    /// shows. Kept by reply, so a row the list builds again as it scrolls
    /// back into view has its height at once.
    final class Coordinator {
        let measure: ReplyLayout
        init(key: String?) { measure = ReplyLayout.kept(key) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(key: key) }
    /// Its own layout: SwiftUI asks the size of versions other than the one
    /// showing, which would change what shows if the two were one.
    func makeNSView(context: Context) -> ReplyTextView { ReplyTextView(reply: ReplyLayout()) }

    func updateNSView(_ view: ReplyTextView, context: Context) {
        let open = context.environment.openURL
        view.open = { open($0) }
        // SwiftUI keeps the size it was given until told it changed.
        if view.reply.show(blocks, cites: cites, streaming: streaming, like: context.coordinator.measure) { view.invalidateIntrinsicContentSize() }
        view.fade(fresh)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReplyTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ChatView<EmptyView, EmptyView>.column
        let measure = context.coordinator.measure
        measure.show(blocks, cites: cites, streaming: streaming)
        return CGSize(width: width, height: measure.height(for: width))
    }
}

/// A reply's text laid out: each block a piece of it kept apart, so as a
/// reply streams in, only the pieces from the first changed block on are
/// made and laid out again.
@MainActor
final class ReplyLayout {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: ChatView<EmptyView, EmptyView>.column, height: .greatestFiniteMagnitude))
    private var blocks: [Markdown.Block] = []
    private var cites: [String: String] = [:]
    private var streaming = false
    private var pieces: [NSAttributedString] = []
    private var measured: (width: CGFloat, height: CGFloat)?

    /// The width replies were last laid out at, for those made ahead.
    static var width = ChatView<EmptyView, EmptyView>.column

    /// Measuring layouts by reply and run, a few hundred at most.
    private static var measuring: [String: ReplyLayout] = [:]

    static func kept(_ key: String?) -> ReplyLayout {
        guard let key else { return ReplyLayout() }
        if let kept = measuring[key] { return kept }
        if measuring.count > 300 { measuring.removeAll() }
        let made = ReplyLayout()
        measuring[key] = made
        return made
    }

    init() {
        // Laid out when it's measured or drawn, not again in idle time.
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
    }

    /// How tall the text is at `width`, kept until it or the text changes.
    func height(for width: CGFloat) -> CGFloat {
        Self.width = width
        if let measured, measured.width == width { return measured.height }
        if container.size.width != width { container.size = CGSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        measured = (width, height)
        return height
    }

    /// Whether the text changed. Taken whole from `other` when it holds the
    /// same, rather than made again.
    @discardableResult
    func show(_ blocks: [Markdown.Block], cites: [String: String], streaming: Bool, like other: ReplyLayout? = nil) -> Bool {
        guard blocks != self.blocks || cites != self.cites || streaming != self.streaming else { return false }
        if let other, other !== self, other.blocks == blocks, other.cites == cites, other.streaming == streaming, self.blocks.isEmpty {
            storage.setAttributedString(other.storage)
            pieces = other.pieces
            (self.blocks, self.cites, self.streaming) = (blocks, cites, streaming)
            measured = nil
            return true
        }
        // The first block that changed; the last one's healing goes with whether it streams.
        var first = 0
        if cites == self.cites {
            while first < min(blocks.count, self.blocks.count), blocks[first] == self.blocks[first] { first += 1 }
            if streaming != self.streaming { first = min(first, max(0, self.blocks.count - 1), max(0, blocks.count - 1)) }
        }
        let made = blocks.indices.dropFirst(first).map { index in
            Styled.piece(blocks[index], first: index == 0, cites: cites, healed: streaming && index == blocks.count - 1)
        }
        let kept = pieces.prefix(first)
        let from = kept.reduce(0) { $0 + $1.length }
        let added = NSMutableAttributedString()
        made.forEach(added.append)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: added)
        storage.endEditing()
        pieces = Array(kept) + made
        (self.blocks, self.cites, self.streaming) = (blocks, cites, streaming)
        measured = nil
        return true
    }
}

/// A reply's text shown, read only and selectable.
final class ReplyTextView: NSTextView, NSTextViewDelegate {
    var open: (URL) -> Void = { _ in }
    /// What it shows, laid out.
    let reply: ReplyLayout

    init(reply: ReplyLayout) {
        self.reply = reply
        super.init(frame: .zero, textContainer: reply.container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        delegate = self
        // Links keep their own look: plain ones underlined, citations as chips.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        selectedTextAttributes = [.backgroundColor: Palette.NS.ink.withAlphaComponent(0.12)]
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if let container = textContainer, container.size.width != size.width {
            container.size = CGSize(width: size.width, height: .greatestFiniteMagnitude)
        }
    }

    // MARK: Words fading in

    private var fresh: [Typewriter.Fresh] = []
    private var ticking: CADisplayLink?

    /// Draws the newest words fainter the newer they are, easing in: a
    /// drawing attribute, so a fade never lays the text out again.
    func fade(_ fresh: [Typewriter.Fresh]) {
        guard fresh != self.fresh else { return }
        self.fresh = fresh
        if fresh.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return stopFading() }
        if ticking == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            ticking = link
        }
        tick()
    }

    @objc private func tick() {
        guard let layout = layoutManager, let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let now = Date.timeIntervalSinceReferenceDate
        let string = storage.string
        var end = string.endIndex
        var fading = false
        for piece in fresh.reversed() {
            let start = string.index(end, offsetBy: -piece.count, limitedBy: string.startIndex) ?? string.startIndex
            let progress = min(1, max(0, (now - piece.at) / Typewriter.fade))
            if progress < 1 {
                fading = true
                // Ease out: quick to show, gentle to settle.
                let alpha = 1 - pow(1 - progress, 3)
                layout.addTemporaryAttribute(
                    .foregroundColor, value: Palette.NS.ink.withAlphaComponent(alpha), forCharacterRange: NSRange(start..<end, in: string))
            }
            end = start
            if start == string.startIndex { break }
        }
        if !fading { stopFading() }
    }

    private func stopFading() {
        ticking?.invalidate()
        ticking = nil
        if let storage = textStorage {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopFading() }
    }

    // MARK: The pointer

    /// The text scrolls under what's drawn over the chat (the composer, the
    /// way down): there, that shows its own pointer, not the text's I-beam.
    private func covered(_ event: NSEvent) -> Bool {
        guard let frame = window?.contentView?.superview, let hit = frame.hitTest(event.locationInWindow) else { return false }
        return hit !== self && !hit.isDescendant(of: self)
    }

    override func cursorUpdate(with event: NSEvent) {
        if covered(event) { return NSCursor.arrow.set() }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if covered(event) { return NSCursor.arrow.set() }
        super.mouseMoved(with: event)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        open(url)
        return true
    }
}

/// Markdown blocks as AppKit text in Mote's type, matching the reply's
/// SwiftUI look: body at `MarkdownView.size`, headings larger, lists with
/// their markers in a column of their own.
@MainActor
private enum Styled {
    static let body = NSFont.systemFont(ofSize: MarkdownView.size)
    /// Between blocks, as the column of views had.
    static let gap: CGFloat = 12

    /// A block's text, opening with the line break from the block before.
    static func piece(_ block: Markdown.Block, first: Bool, cites: [String: String], healed: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        append(block, to: out, indent: 0, before: first ? 0 : gap, cites: cites, healed: healed)
        if !first { out.insert(NSAttributedString(string: "\n"), at: 0) }
        return out
    }

    private static func append(
        _ block: Markdown.Block, to out: NSMutableAttributedString, indent: CGFloat, before: CGFloat, cites: [String: String], healed: Bool
    ) {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 19 : level == 2 ? 16.5 : 15
            let style = paragraph(indent: indent, before: before + (level <= 2 ? 6 : 2), spacing: 3)
            out.append(inline(text, cites: cites, font: .systemFont(ofSize: size, weight: .semibold), style: style, healed: healed))
        case .list(let list):
            for (index, item) in list.items.enumerated() {
                let gap = index == 0 ? before : 6
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
                appendItem(item, of: list, at: index, to: out, indent: indent + (indent == 0 ? 4 : 0), before: gap, cites: cites,
                    healed: healed && index == list.items.count - 1)
            }
        case .paragraph(let text):
            out.append(inline(text, cites: cites, font: body, style: paragraph(indent: indent, before: before), healed: healed))
        // At the top, code, tables, quotes and rules are views of their own
        // (see `Blocks.Run`); inside a list item, they're drawn plainly.
        case .code(_, let text, _):
            let code = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            out.append(
                NSAttributedString(
                    string: text,
                    attributes: [.font: code, .foregroundColor: Palette.NS.ink, .paragraphStyle: paragraph(indent: indent, before: before, spacing: 3)]))
        case .quote(let blocks):
            for (index, block) in blocks.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n")) }
                append(block, to: out, indent: indent + 15, before: index == 0 ? before : gap, cites: cites, healed: healed && index == blocks.count - 1)
            }
        case .table(let table):
            let rows = [table.header] + table.rows
            out.append(
                inline(rows.map { $0.joined(separator: "  ·  ") }.joined(separator: "\n"), cites: cites, font: body,
                    style: paragraph(indent: indent, before: before), healed: healed))
        case .rule:
            break
        }
    }

    private static func appendItem(
        _ item: Markdown.Item, of list: Markdown.List, at index: Int, to out: NSMutableAttributedString, indent: CGFloat, before: CGFloat,
        cites: [String: String], healed: Bool
    ) {
        let width = list.ordered ? CGFloat(String(list.start + list.items.count - 1).count) * 8.5 + 6 : 14
        let text = indent + width + 8
        let style = paragraph(indent: text, before: before)
        style.firstLineHeadIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .right, location: indent + width), NSTextTab(textAlignment: .left, location: text)]
        let line = NSMutableAttributedString(string: "\t", attributes: [.paragraphStyle: style, .font: body])
        line.append(marker(for: item, of: list, at: index, style: style))
        line.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: style, .font: body]))
        var rest = item.blocks[...]
        // The item's first paragraph on the marker's line; what follows under it.
        if case .paragraph(let words)? = rest.first {
            line.append(inline(words, cites: cites, font: body, style: style, healed: healed && rest.count == 1))
            rest = rest.dropFirst()
        }
        out.append(line)
        for (offset, block) in rest.enumerated() {
            out.append(NSAttributedString(string: "\n"))
            append(block, to: out, indent: text, before: 6, cites: cites, healed: healed && offset == rest.count - 1)
        }
    }

    private static func marker(for item: Markdown.Item, of list: Markdown.List, at index: Int, style: NSParagraphStyle) -> NSAttributedString {
        let muted: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .foregroundColor: Palette.NS.muted]
        if let checked = item.checked {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: checked ? "Done" : "To do")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            let mark = NSMutableAttributedString(attachment: attachment)
            mark.addAttributes(muted, range: NSRange(location: 0, length: mark.length))
            return mark
        }
        if list.ordered {
            let font = NSFont.monospacedDigitSystemFont(ofSize: MarkdownView.size, weight: .regular)
            return NSAttributedString(string: "\(list.start + index).", attributes: muted.merging([.font: font]) { $1 })
        }
        return NSAttributedString(string: "•", attributes: muted.merging([.font: NSFont.systemFont(ofSize: MarkdownView.size, weight: .bold)]) { $1 })
    }

    private static func paragraph(indent: CGFloat, before: CGFloat, spacing: CGFloat = MarkdownView.leading) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    /// Inline Markdown: emphasis, code spans on a faint wash, links, and
    /// links to cited pages as chips with the site's name.
    static func inline(_ text: String, cites: [String: String], font: NSFont, style: NSParagraphStyle, healed: Bool) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let source = healed ? Markdown.healed(text) : text
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var face = font
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .foregroundColor: Palette.NS.ink]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                face = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attributes[.backgroundColor] = Palette.NS.veil
            }
            if intent.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributes[.font] = face
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        guard !cites.isEmpty else { return out }
        // From the end, so replacing one never moves those still to come.
        var links: [(URL, NSRange)] = []
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if let url = value as? URL { links.append((url, range)) }
        }
        for (link, range) in links.reversed() {
            guard let name = cites[Source.key(for: link)] else { continue }
            // A citation: the site's name on a small chip, still a link. A link
            // worded as part of the answer keeps its words, with the chip after.
            let chip = NSAttributedString(
                string: "\u{2009}\(name)\u{2009}",
                attributes: [
                    .link: link, .font: NSFont.systemFont(ofSize: MarkdownView.size * 0.76, weight: .medium),
                    .foregroundColor: Palette.NS.muted, .backgroundColor: Palette.NS.wash, .baselineOffset: 1, .paragraphStyle: style,
                ])
            if Citations.namesSite(out.attributedSubstring(from: range).string, link) {
                out.replaceCharacters(in: range, with: chip)
            } else {
                out.removeAttribute(.link, range: range)
                out.removeAttribute(.underlineStyle, range: range)
                let spaced = NSMutableAttributedString(string: " ", attributes: [.paragraphStyle: style, .font: font])
                spaced.append(chip)
                out.insert(spaced, at: range.upperBound)
            }
        }
        return out
    }
}

/// Code in its own well: the language and a copy button along the top, and
/// long lines scrolling sideways rather than wrapping.
private struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                CopyButton(text: code, label: "Copy")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 30)
            Palette.hairline.frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
        }
        .background(Palette.wash.opacity(0.5), in: Rounded.field)
        .overlay(Rounded.field.strokeBorder(Palette.hairline))
    }
}

private struct TableBlock: View {
    let table: Markdown.Table
    let cites: [String: String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column).font(.system(size: 13, weight: .semibold))
                    }
                }
                .background(Palette.wash.opacity(0.6))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Palette.hairline.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column).font(.system(size: 13))
                        }
                    }
                }
            }
            .overlay(Rounded.row.strokeBorder(Palette.hairline))
            .clipShape(Rounded.row)
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment =
            switch table.alignments.indices.contains(column) ? table.alignments[column] : .none {
            case .center: .center
            case .trailing: .trailing
            default: .leading
            }
        return Text(MarkdownView.inline(text, cites: cites))
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: alignment)
            .gridColumnAlignment(alignment.horizontal)
    }
}

/// Copies text, and says so for a moment.
struct CopyButton: View {
    let text: String
    var label: String?

    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .medium))
                if let label { Text(copied ? "Copied" : label).font(.system(size: 11)) }
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.8) : Palette.muted)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(hovering ? Palette.veil : .clear, in: Rounded.row)
            .contentShape(Rounded.row)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .animation(Motion.hover, value: hovering)
        .animation(Motion.quick, value: copied)
    }
}
