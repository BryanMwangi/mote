import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Pen and signatures on a PDF in Mote's reader: strokes kept as PDFKit ink,
/// with a colour, thickness and opacity, undone or rubbed out; and saved
/// signatures (drawn, typed or a picture) placed as stamps that can be moved
/// and resized.
@MainActor
final class PDFInk: ObservableObject {
    @Published var color: Color = .red
    @Published var thickness: CGFloat = 3
    @Published var opacity: Double = 1
    @Published var erasing = false
    /// The signature the next click places.
    @Published var placing: Signature?
    /// Strokes and stamps added, newest last, for Undo.
    private var added: [(PDFPage, PDFAnnotation)] = []

    func keep(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.addAnnotation(annotation)
        added.append((page, annotation))
    }

    func undo() {
        guard let (page, annotation) = added.popLast() else { return }
        page.removeAnnotation(annotation)
    }

    var canUndo: Bool { !added.isEmpty }
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

/// Over the pages while drawing or signing: takes the pointer, draws the
/// stroke as it goes, and keeps it on the page when let go; places, moves and
/// resizes signatures.
final class InkLayer: NSView {
    weak var pdfView: PDFView?
    var ink: PDFInk?
    var tool: PDFReader.Tool = .select {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private let stroke = CAShapeLayer()
    private var points: [CGPoint] = []
    /// A signature being moved or resized, and from where.
    private var handling: (stamp: SignatureStamp, page: PDFPage, start: CGPoint, bounds: CGRect, resizing: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineCap = .round
        stroke.lineJoin = .round
        layer?.addSublayer(stroke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Only drawing and signing take the pointer; reading goes to the pages.
    override func hitTest(_ point: NSPoint) -> NSView? { tool == .select ? nil : super.hitTest(point) }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(bounds, cursor: tool == .draw ? .crosshair : .pointingHand) }
    }

    private func onPage(_ event: NSEvent) -> (page: PDFPage, at: CGPoint)? {
        guard let pdfView else { return nil }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        return (page, pdfView.convert(point, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        guard let ink, let found = onPage(event) else { return }
        if tool == .draw, ink.erasing {
            if let hit = found.page.annotation(at: found.at), hit.type == PDFAnnotationSubtype.ink.rawValue { found.page.removeAnnotation(hit) }
            return
        }
        if tool == .sign {
            if let stamp = found.page.annotation(at: found.at) as? SignatureStamp {
                let corner = CGPoint(x: stamp.bounds.maxX, y: stamp.bounds.minY)
                let resizing = hypot(found.at.x - corner.x, found.at.y - corner.y) < 14
                handling = (stamp, found.page, found.at, stamp.bounds, resizing)
            } else if let signature = ink.placing {
                let ratio = signature.image.size.height / max(signature.image.size.width, 1)
                let size = CGSize(width: 160, height: 160 * ratio)
                let stamp = SignatureStamp(
                    picture: signature.image, bounds: CGRect(x: found.at.x - size.width / 2, y: found.at.y - size.height / 2, width: size.width, height: size.height))
                ink.keep(stamp, on: found.page)
            }
            return
        }
        points = [convert(event.locationInWindow, from: nil)]
        let color = NSColor(ink.color).withAlphaComponent(ink.opacity)
        stroke.strokeColor = color.cgColor
        stroke.lineWidth = ink.thickness * (pdfView?.scaleFactor ?? 1)
    }

    override func mouseDragged(with event: NSEvent) {
        if let handling, let found = onPage(event), found.page == handling.page {
            let dx = found.at.x - handling.start.x, dy = found.at.y - handling.start.y
            var next = handling.bounds
            if handling.resizing {
                // Wider to the right keeps its shape, anchored at the top left.
                let width = max(40, handling.bounds.width + dx)
                let height = width * handling.bounds.height / handling.bounds.width
                next = CGRect(x: handling.bounds.minX, y: handling.bounds.maxY - height, width: width, height: height)
            } else {
                next = handling.bounds.offsetBy(dx: dx, dy: dy)
            }
            handling.stamp.bounds = next
            pdfView?.annotationsChanged(on: handling.page)
            return
        }
        guard tool == .draw, !points.isEmpty else { return }
        points.append(convert(event.locationInWindow, from: nil))
        let path = CGMutablePath()
        path.addLines(between: points)
        stroke.path = path
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            handling = nil
            points = []
            stroke.path = nil
        }
        guard tool == .draw, let ink, let pdfView, points.count > 1 else { return }
        let inView = points.map { convert($0, to: pdfView) }
        guard let page = pdfView.page(for: inView[0], nearest: true) else { return }
        let onPage = inView.map { pdfView.convert($0, to: page) }
        let xs = onPage.map(\.x), ys = onPage.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -ink.thickness, dy: -ink.thickness)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: onPage[0].x - bounds.minX, y: onPage[0].y - bounds.minY))
        for point in onPage.dropFirst() { path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.add(path)
        annotation.color = NSColor(ink.color).withAlphaComponent(ink.opacity)
        let border = PDFBorder()
        border.lineWidth = ink.thickness
        annotation.border = border
        ink.keep(annotation, on: page)
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
            if reader.tool == .draw {
                ColorPicker("", selection: $ink.color).labelsHidden()
                Text("Size").foregroundStyle(Palette.muted)
                Slider(value: $ink.thickness, in: 1...12).frame(width: 90)
                Text("Opacity").foregroundStyle(Palette.muted)
                Slider(value: $ink.opacity, in: 0.2...1).frame(width: 90)
                Toggle("Erase", isOn: $ink.erasing).toggleStyle(.button)
            } else {
                Text(ink.placing == nil ? "Pick a signature, then click where it goes. Drag one to move it, its corner to resize it." : "Click where it goes")
                    .foregroundStyle(Palette.muted)
                ForEach(signatures.all) { signature in
                    Button {
                        ink.placing = signature
                    } label: {
                        Image(nsImage: signature.image).resizable().aspectRatio(contentMode: .fit).frame(height: 22)
                            .padding(.horizontal, 6)
                            .background(ink.placing == signature ? Palette.hover : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(signature.name)
                    .contextMenu { Button("Remove Signature") { signatures.remove(signature) } }
                }
                Pill("Add Signature…") { adding = true }
            }
            Spacer(minLength: 0)
            Door(icon: "arrow.uturn.backward", help: "Undo") { ink.undo() }
            Door(icon: "checkmark", help: "Done") { reader.tool = .select }
        }
        .font(TextStyle.secondary.font)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Palette.frame)
        .sheet(isPresented: $adding) { NewSignature { image, name in
            if let image { Signatures.shared.add(image, named: name) }
            adding = false
        } }
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
                    Text(typed.isEmpty ? " " : typed).font(.custom(Self.face, size: 40)).frame(maxWidth: .infinity, minHeight: 80)
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

    private var canvas: some View {
        Canvas { context, _ in
            for line in strokes where line.count > 1 {
                var path = Path()
                path.addLines(line)
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) { if !strokes.isEmpty { Button("Clear") { strokes = [] }.buttonStyle(.link).padding(8) } }
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
                    let path = NSBezierPath()
                    path.lineWidth = 2.5
                    path.lineCapStyle = .round
                    path.move(to: line[0])
                    line.dropFirst().forEach(path.line(to:))
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
