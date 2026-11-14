import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Pen and signatures on a PDF in Mote's reader: strokes kept as PDFKit ink,
/// with a pen or a highlighter, a width, a colour, solid or dashed, smoothed
/// as they're drawn, rubbed out by dragging over them; and saved signatures
/// (drawn, typed or a picture) placed as stamps that can be moved and resized.
@MainActor
final class PDFInk: ObservableObject {
    enum Brush: String, CaseIterable { case pen = "Pen", highlighter = "Highlighter" }

    @Published var brush: Brush = .pen
    @Published var color: Color = .red
    @Published var thickness: CGFloat = 3
    @Published var opacity: Double = 1
    @Published var dashed = false
    @Published var smooth = true
    @Published var erasing = false
    /// The signature the next click places.
    @Published var placing: Signature?

    static let widths: [CGFloat] = [1, 2, 3, 5, 8, 12]
    static let swatches: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple]

    /// The stroke's width on the page: a highlighter is a broad nib.
    var width: CGFloat { brush == .highlighter ? max(8, thickness * 4) : thickness }

    /// The stroke's colour: a highlighter lets the text through.
    var stroke: NSColor { NSColor(color).withAlphaComponent(brush == .highlighter ? 0.35 : opacity) }

    var dashes: [CGFloat]? { dashed ? [width * 3, width * 2] : nil }
}

/// A drawn line through `points`: as drawn, or smoothed, close points thinned
/// and the rest joined by curves through their midpoints.
enum Stroke {
    static func path(_ points: [CGPoint], smooth: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard smooth, points.count > 2 else {
            points.dropFirst().forEach(path.line(to:))
            return path
        }
        var kept = [first]
        for point in points.dropFirst() where hypot(point.x - kept[kept.count - 1].x, point.y - kept[kept.count - 1].y) > 1.5 {
            kept.append(point)
        }
        guard kept.count > 2 else {
            if let last = points.last { path.line(to: last) }
            return path
        }
        var from = kept[0]
        for index in 1..<kept.count - 1 {
            let control = kept[index], next = kept[index + 1]
            let mid = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            // A quadratic curve, as the cubic NSBezierPath draws.
            path.curve(
                to: mid,
                controlPoint1: CGPoint(x: from.x + 2 / 3 * (control.x - from.x), y: from.y + 2 / 3 * (control.y - from.y)),
                controlPoint2: CGPoint(x: mid.x + 2 / 3 * (control.x - mid.x), y: mid.y + 2 / 3 * (control.y - mid.y)))
            from = mid
        }
        path.line(to: kept[kept.count - 1])
        return path
    }

    /// How near `point` comes to the line, both in the same space.
    static func distance(from point: CGPoint, to path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var nearest = CGFloat.infinity
        var last: CGPoint?
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<flat.elementCount {
            let kind = flat.element(at: index, associatedPoints: &points)
            let here = points[0]
            if kind == .lineTo, let from = last { nearest = min(nearest, segment(point, from, here)) }
            if kind == .moveTo { nearest = min(nearest, hypot(point.x - here.x, point.y - here.y)) }
            last = here
        }
        return nearest
    }

    private static func segment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// A signature saved for signing PDFs: a picture with a name, kept in Mote's
/// folder (a picture, not a secret).
struct Signature: Identifiable, Equatable {
    let id: String
    var name: String
    let image: NSImage

    static func == (a: Signature, b: Signature) -> Bool { a.id == b.id }
}

@MainActor
final class Signatures: ObservableObject {
    static let shared = Signatures()
    @Published private(set) var all: [Signature] = []
    private let folder = Storage.file("Signatures")

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        all = files.filter { $0.pathExtension == "png" }.compactMap { file in
            NSImage(contentsOf: file).map { Signature(id: file.lastPathComponent, name: file.deletingPathExtension().lastPathComponent, image: $0) }
        }
        .sorted { $0.name < $1.name }
    }

    func add(_ image: NSImage, named name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.isEmpty ? "Signature" : name.replacingOccurrences(of: "/", with: "-")
        var file = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
            (try? png.write(to: file)) != nil
        else { return }
        all.append(Signature(id: file.lastPathComponent, name: file.deletingPathExtension().lastPathComponent, image: image))
    }

    func remove(_ signature: Signature) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(signature.id))
        all.removeAll { $0 == signature }
    }
}

/// A signature on a page, drawn from its picture.
nonisolated final class SignatureStamp: PDFAnnotation {
    let picture: NSImage

    init(picture: NSImage, bounds: CGRect) {
        self.picture = picture
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

extension PDFAnnotation {
    /// A sticky note's, a stroke's or a signature's: what the reader lets you
    /// pick up, move and delete.
    var movable: Bool { self is SignatureStamp || isNote || isInk }
    var isNote: Bool { type == "Text" }
    var isInk: Bool { type == "Ink" }
}

/// Over the pages: draws strokes as they go and keeps them on the page,
/// rubs them out, places, moves and resizes signatures; and in Select, picks
/// up notes, strokes and signatures to move, edit or delete them. Elsewhere
/// the pointer goes through to the pages, for selecting text.
final class InkLayer: NSView {
    weak var pdfView: PDFView?
    weak var reader: PDFReader?
    var tool: PDFReader.Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            preview.isHidden = true
        }
    }
    private let stroke = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let preview = CALayer()
    private var points: [CGPoint] = []
    /// What's being moved or resized, and from where.
    private var handling: (annotation: PDFAnnotation, page: PDFPage, start: CGPoint, bounds: CGRect, resizing: Bool, moved: Bool)?
    private var watching: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineJoin = .round
        outline.fillColor = nil
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [4, 3]
        preview.opacity = 0.5
        preview.isHidden = true
        preview.contentsGravity = .resizeAspect
        for part in [stroke, outline, preview] { layer?.addSublayer(part) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows the pages as they scroll and zoom, so a picked note's outline stays on it.
    func watch(_ view: PDFView) {
        pdfView = view
        let center = NotificationCenter.default
        let clip = view.documentView?.enclosingScrollView?.contentView
        clip?.postsBoundsChangedNotifications = true
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.refreshOutline() } }
        watching = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: refresh),
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main, using: refresh),
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    // MARK: Where the pointer is

    private func onPage(_ event: NSEvent) -> (page: PDFPage, at: CGPoint)? {
        onPage(window: event.locationInWindow)
    }

    private func onPage(window point: NSPoint) -> (page: PDFPage, at: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(point, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true) else { return nil }
        return (page, pdfView.convert(inView, to: page))
    }

    /// The note, stroke or signature at a point, topmost first.
    private func movable(at found: (page: PDFPage, at: CGPoint)) -> PDFAnnotation? {
        found.page.annotations.reversed().first { annotation in
            guard annotation.movable, annotation.bounds.insetBy(dx: -4, dy: -4).contains(found.at) else { return false }
            // A stroke only where it's drawn, not across its whole box.
            return !annotation.isInk || hit(annotation, at: found.at, within: 6)
        }
    }

    private func hit(_ ink: PDFAnnotation, at point: CGPoint, within reach: CGFloat) -> Bool {
        let local = CGPoint(x: point.x - ink.bounds.minX, y: point.y - ink.bounds.minY)
        let half = (ink.border?.lineWidth ?? 1) / 2
        return (ink.paths ?? []).contains { Stroke.distance(from: local, to: $0) <= half + reach }
    }

    /// Drawing and signing take the pointer; in Select, only over a note,
    /// stroke or signature, so text selection still works elsewhere.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, frame.contains(point) else { return nil }
        if tool != .select { return self }
        guard let found = onPage(window: superview.convert(point, to: nil)), movable(at: found) != nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        switch tool {
        case .select: addCursorRect(bounds, cursor: .openHand)
        case .draw: addCursorRect(bounds, cursor: reader?.ink.erasing == true ? Self.eraser(diameter: eraserReach * 2 * scale) : .crosshair)
        case .sign: addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    /// The eraser's reach on the page, either side of the pointer.
    private let eraserReach: CGFloat = 6
    private var scale: CGFloat { pdfView?.scaleFactor ?? 1 }

    /// A circle the eraser's size.
    private static func eraser(diameter: CGFloat) -> NSCursor {
        let side = max(8, min(diameter, 64)) + 2
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor.white.withAlphaComponent(0.5).setFill()
            ring.fill()
            NSColor.black.withAlphaComponent(0.7).setStroke()
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
    }

    // MARK: The picked one

    func refreshOutline() {
        guard let picked = reader?.picked, let pdfView, picked.page.annotations.contains(picked.annotation) else {
            outline.path = nil
            return
        }
        let rect = convert(pdfView.convert(picked.annotation.bounds, from: picked.page), from: pdfView).insetBy(dx: -3, dy: -3)
        let path = CGMutablePath()
        path.addRect(rect)
        // A signature's corner, to resize it by.
        if picked.annotation is SignatureStamp { path.addRect(CGRect(x: rect.maxX - 5, y: rect.minY - 5, width: 10, height: 10)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = path
        CATransaction.commit()
    }

    // MARK: Pressing, dragging, letting go

    override func mouseDown(with event: NSEvent) {
        // Undo and the keys go to the pages.
        if let pdfView { window?.makeFirstResponder(pdfView) }
        guard let reader, let found = onPage(event) else { return }
        let ink = reader.ink
        switch tool {
        case .draw where ink.erasing:
            erase(at: found)
        case .draw:
            points = [convert(event.locationInWindow, from: nil)]
            stroke.strokeColor = ink.stroke.cgColor
            stroke.lineWidth = ink.width * scale
            stroke.lineCap = ink.brush == .highlighter ? .square : .round
            stroke.lineDashPattern = ink.dashes?.map { NSNumber(value: Double($0 * scale)) }
        case .sign, .select:
            if let annotation = movable(at: found), tool == .select || annotation is SignatureStamp {
                reader.pick(annotation, on: found.page)
                let corner = CGPoint(x: annotation.bounds.maxX, y: annotation.bounds.minY)
                let resizing = annotation is SignatureStamp && hypot(found.at.x - corner.x, found.at.y - corner.y) < 14 / scale + 4
                handling = (annotation, found.page, found.at, annotation.bounds, resizing, false)
                if tool == .select { NSCursor.closedHand.set() }
            } else if tool == .sign, let signature = ink.placing {
                let ratio = signature.image.size.height / max(signature.image.size.width, 1)
                let size = CGSize(width: 160, height: 160 * ratio)
                let stamp = SignatureStamp(
                    picture: signature.image,
                    bounds: CGRect(x: found.at.x - size.width / 2, y: found.at.y - size.height / 2, width: size.width, height: size.height))
                reader.add(stamp, to: found.page)
                reader.pick(stamp, on: found.page)
            } else {
                reader.pick(nil, on: nil)
            }
        }
        refreshOutline()
    }

    override func mouseDragged(with event: NSEvent) {
        if let held = handling, let found = onPage(event), found.page == held.page {
            let dx = found.at.x - held.start.x, dy = found.at.y - held.start.y
            guard held.moved || hypot(dx, dy) > 2 / scale else { return }
            handling?.moved = true
            if held.resizing {
                // Wider to the right keeps its shape, anchored at the top left.
                let width = max(40, held.bounds.width + dx)
                let height = width * held.bounds.height / held.bounds.width
                held.annotation.bounds = CGRect(x: held.bounds.minX, y: held.bounds.maxY - height, width: width, height: height)
            } else {
                held.annotation.bounds = held.bounds.offsetBy(dx: dx, dy: dy)
            }
            pdfView?.annotationsChanged(on: held.page)
            refreshOutline()
            return
        }
        if tool == .draw, reader?.ink.erasing == true {
            if let found = onPage(event) { erase(at: found) }
            return
        }
        guard tool == .draw, !points.isEmpty else { return }
        points.append(convert(event.locationInWindow, from: nil))
        stroke.path = Stroke.path(points, smooth: reader?.ink.smooth ?? true).cgPathCompat
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            handling = nil
            points = []
            stroke.path = nil
        }
        if let held = handling {
            if held.moved {
                reader?.moved(held.annotation, on: held.page, from: held.bounds)
            } else if tool == .select, held.annotation.isNote {
                editNote(held.annotation, on: held.page)
            }
            if tool == .select { NSCursor.openHand.set() }
            return
        }
        guard tool == .draw, let reader, let pdfView, points.count > 1, !reader.ink.erasing else { return }
        let ink = reader.ink
        let inView = points.map { convert($0, to: pdfView) }
        guard let page = pdfView.page(for: inView[0], nearest: true) else { return }
        let onPage = inView.map { pdfView.convert($0, to: page) }
        let xs = onPage.map(\.x), ys = onPage.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -ink.width, dy: -ink.width)
        let local = onPage.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.add(Stroke.path(local, smooth: ink.smooth))
        annotation.color = ink.stroke
        let border = PDFBorder()
        border.lineWidth = ink.width
        if let dashes = ink.dashes {
            border.style = .dashed
            border.dashPattern = dashes
        }
        annotation.border = border
        reader.add(annotation, to: page)
    }

    /// Strokes under the eraser go; one rub is one undo.
    private func erase(at found: (page: PDFPage, at: CGPoint)) {
        guard let reader else { return }
        for annotation in found.page.annotations where annotation.isInk {
            guard annotation.bounds.insetBy(dx: -eraserReach, dy: -eraserReach).contains(found.at),
                hit(annotation, at: found.at, within: eraserReach)
            else { continue }
            reader.remove(annotation, from: found.page)
        }
    }

    // MARK: A signature following the pointer before it's placed

    override func mouseMoved(with event: NSEvent) {
        guard tool == .sign, let signature = reader?.ink.placing else {
            if !preview.isHidden { preview.isHidden = true }
            return
        }
        let at = convert(event.locationInWindow, from: nil)
        let width = 160 * scale
        let height = width * signature.image.size.height / max(signature.image.size.width, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.contents = signature.image
        preview.frame = CGRect(x: at.x - width / 2, y: at.y - height / 2, width: width, height: height)
        preview.isHidden = false
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) { preview.isHidden = true }

    // MARK: Notes

    private var notePopover: NSPopover?

    /// A note's words in a popover beside it, to change, or to delete it.
    func editNote(_ note: PDFAnnotation, on page: PDFPage) {
        guard let pdfView, let reader else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NoteEditor(text: note.contents ?? "") { [weak self, weak reader] text in
                if let text {
                    reader?.setText(text, of: note)
                } else {
                    reader?.remove(note, from: page)
                    reader?.pick(nil, on: nil)
                    self?.refreshOutline()
                }
                self?.notePopover?.performClose(nil)
            })
        let rect = convert(pdfView.convert(note.bounds, from: page), from: pdfView)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxX)
        notePopover = popover
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let found = onPage(event), let annotation = movable(at: found) else { return nil }
        reader?.pick(annotation, on: found.page)
        refreshOutline()
        let menu = NSMenu()
        if annotation.isNote {
            menu.addItem(ActionItem("Edit Note…") { [weak self] in self?.editNote(annotation, on: found.page) })
        }
        let what = annotation.isNote ? "Note" : annotation.isInk ? "Drawing" : "Signature"
        menu.addItem(ActionItem("Delete \(what)") { [weak self] in
            self?.reader?.remove(annotation, from: found.page)
            self?.reader?.pick(nil, on: nil)
            self?.refreshOutline()
        })
        return menu
    }
}

/// A note's words, to change; Delete takes the note away.
private struct NoteEditor: View {
    @State var text: String
    /// The new words, or nil to delete the note.
    let done: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(width: 240, height: 110)
                .scrollContentBackground(.hidden)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Delete Note", role: .destructive) { done(nil) }
                Spacer()
                Button("Done") { done(text) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

/// The pen's and the signatures' row under the reader's toolbar.
struct PDFInkBar: View {
    @ObservedObject var reader: PDFReader
    @ObservedObject var ink: PDFInk
    @ObservedObject private var signatures = Signatures.shared
    @State private var adding = false

    var body: some View {
        HStack(spacing: 10) {
            if reader.tool == .draw { pen } else { signing }
            Spacer(minLength: 0)
            Door(icon: "arrow.uturn.backward", help: "Undo   ⌘Z") { reader.undo.undo() }
            Door(icon: "checkmark", help: "Done   Esc") { reader.tool = .select }
        }
        .font(TextStyle.secondary.font)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Palette.frame)
        .sheet(isPresented: $adding) {
            NewSignature { image, name in
                if let image { Signatures.shared.add(image, named: name) }
                adding = false
            }
        }
        // The cursor shows the eraser's ring, or the pen's cross.
        .onChange(of: ink.erasing) { reader.inkLayer.map { $0.window?.invalidateCursorRects(for: $0) } }
    }

    @ViewBuilder
    private var pen: some View {
        Picker("", selection: $ink.brush) {
            ForEach(PDFInk.Brush.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        HStack(spacing: 4) {
            ForEach(PDFInk.swatches, id: \.self) { swatch in
                Circle().fill(swatch).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Palette.ink.opacity(ink.color == swatch ? 0.9 : 0.15), lineWidth: ink.color == swatch ? 2 : 1))
                    .contentShape(Circle())
                    .onTapGesture {
                        ink.color = swatch
                        ink.erasing = false
                    }
            }
            ColorPicker("", selection: $ink.color).labelsHidden()
        }
        Menu {
            Picker("Width", selection: $ink.thickness) {
                ForEach(PDFInk.widths, id: \.self) { width in
                    Label { Text("\(Int(width)) pt") } icon: { Image(nsImage: Self.line(width: width, dashed: false)) }.tag(width)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Line", selection: $ink.dashed) {
                Label { Text("Solid") } icon: { Image(nsImage: Self.line(width: 2, dashed: false)) }.tag(false)
                Label { Text("Dashed") } icon: { Image(nsImage: Self.line(width: 2, dashed: true)) }.tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Smooth Lines", isOn: $ink.smooth)
        } label: {
            Image(nsImage: Self.line(width: min(ink.thickness, 8), dashed: ink.dashed))
        }
        .fixedSize()
        .help("Line width and style")
        if ink.brush == .pen {
            Text("Opacity").foregroundStyle(Palette.muted)
            Slider(value: $ink.opacity, in: 0.2...1).frame(width: 80)
        }
        Toggle(isOn: $ink.erasing) { Label("Erase", systemImage: "eraser") }
            .toggleStyle(.button)
            .help("Drag over strokes to rub them out")
    }

    @ViewBuilder
    private var signing: some View {
        Text(ink.placing == nil ? "Pick a signature" : "Click where it goes").foregroundStyle(Palette.muted)
        ForEach(signatures.all) { signature in
            Button {
                ink.placing = ink.placing == signature ? nil : signature
            } label: {
                // On white, as on a page: dark ink would vanish on the dark bar.
                Image(nsImage: signature.image).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 22)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(ink.placing == signature ? Color.accentColor : .clear, lineWidth: 2)
                    }
            }
            .buttonStyle(.plain)
            .help(signature.name)
            .contextMenu {
                Button("Remove Signature") {
                    if ink.placing == signature { ink.placing = nil }
                    signatures.remove(signature)
                }
            }
        }
        Pill("Add Signature…") { adding = true }
    }

    /// A sample stroke for the line menu.
    private static func line(width: CGFloat, dashed: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 36, height: 14), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 3 + width / 2, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 3 - width / 2, y: rect.midY))
            path.lineWidth = width
            path.lineCapStyle = .round
            if dashed { path.setLineDash([width * 2 + 2, width + 2], count: 2, phase: 0) }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Making a signature: drawn with the pointer, typed in a handwriting face,
/// or a picture of one.
private struct NewSignature: View {
    let done: (NSImage?, String) -> Void
    @State private var way = 0
    @State private var name = ""
    @State private var typed = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var picture: NSImage?
    private static let size = CGSize(width: 420, height: 150)
    private static let face = "Snell Roundhand"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Signature").font(TextStyle.title.font)
            Picker("", selection: $way) {
                Text("Draw").tag(0)
                Text("Type").tag(1)
                Text("Picture").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch way {
                case 0: canvas
                case 1:
                    TextField("Your name", text: $typed).textFieldStyle(.roundedBorder)
                    Text(typed.isEmpty ? " " : typed).font(.custom(Self.face, size: 40)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                default:
                    HStack {
                        if let picture { Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit).frame(height: 100) }
                        Pill("Choose Picture…") { choose() }
                    }
                    .frame(minHeight: 100)
                }
            }
            TextField("Name it (optional)", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { done(nil, "") }.keyboardShortcut(.cancelAction)
                Button("Save") { done(made(), name) }.keyboardShortcut(.defaultAction).disabled(made() == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// White, as a page is, with dark ink: what you draw is what's placed.
    private var canvas: some View {
        Canvas { context, _ in
            for line in strokes where line.count > 1 {
                context.stroke(
                    Path(Stroke.path(line, smooth: true).cgPathCompat), with: .color(.black),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if !strokes.isEmpty { Button("Clear") { strokes = [] }.buttonStyle(.link).padding(8) }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if drag.translation == .zero || strokes.isEmpty { strokes.append([drag.location]) } else { strokes[strokes.count - 1].append(drag.location) }
                })
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { picture = NSImage(contentsOf: url) }
    }

    /// The signature as a picture, dark ink on nothing.
    private func made() -> NSImage? {
        switch way {
        case 0:
            guard strokes.contains(where: { $0.count > 1 }) else { return nil }
            return NSImage(size: Self.size, flipped: true) { _ in
                NSColor.black.setStroke()
                for line in strokes where line.count > 1 {
                    let path = Stroke.path(line, smooth: true)
                    path.lineWidth = 2.5
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    path.stroke()
                }
                return true
            }
        case 1:
            guard !typed.isEmpty else { return nil }
            let words = NSAttributedString(
                string: typed, attributes: [.font: NSFont(name: Self.face, size: 48) ?? .systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            let size = words.size()
            return NSImage(size: CGSize(width: size.width + 16, height: size.height + 8), flipped: false) { _ in
                words.draw(at: CGPoint(x: 8, y: 4))
                return true
            }
        default:
            return picture
        }
    }
}

extension NSBezierPath {
    /// As a CGPath, for SwiftUI and Core Animation.
    var cgPathCompat: CGPath {
        let made = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo: made.move(to: points[0])
            case .lineTo: made.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: made.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: made.addQuadCurve(to: points[1], control: points[0])
            case .closePath: made.closeSubpath()
            @unknown default: break
            }
        }
        return made
    }
}
