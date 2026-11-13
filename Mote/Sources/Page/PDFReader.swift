import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A tab's PDF, read with macOS's own PDFKit in Mote's reader: pages and their
/// outline, zoom, find, marking text up, notes, turning pages, page layouts,
/// presentation, printing and saving. Made once a PDF has loaded, from the
/// bytes WebKit already holds; let go when the tab goes elsewhere.
@MainActor
final class PDFReader: ObservableObject {
    let document: PDFDocument
    let url: URL
    @Published var page = 0
    @Published var sidebar: Sidebar? = .pages
    @Published var found: [PDFSelection] = []
    @Published var foundAt = 0
    @Published var tool: Tool = .select
    /// The ink drawn and stamps placed since opening, for Save to say so.
    @Published var edited = false
    weak var view: PDFView?

    enum Sidebar: String { case pages, outline }
    enum Tool: Equatable { case select, draw, sign }

    init(document: PDFDocument, url: URL) {
        self.document = document
        self.url = url
    }

    var pages: Int { document.pageCount }

    func go(to index: Int) {
        guard let view, let page = document.page(at: min(max(index, 0), pages - 1)) else { return }
        view.go(to: page)
    }

    // MARK: Zoom

    enum Zoom: Hashable {
        case automatic, actual, pageFit, pageWidth, percent(Int)
        static let all: [Zoom] = [.automatic, .actual, .pageFit, .pageWidth] + [50, 75, 100, 125, 150, 200, 300, 400].map(Zoom.percent)
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .actual: "Actual Size"
            case .pageFit: "Page Fit"
            case .pageWidth: "Page Width"
            case .percent(let n): "\(n)%"
            }
        }
    }

    func zoom(_ zoom: Zoom) {
        guard let view else { return }
        switch zoom {
        case .automatic:
            view.autoScales = true
        case .actual:
            view.autoScales = false
            view.scaleFactor = 1
        case .pageFit, .pageWidth:
            guard let page = view.currentPage else { return }
            let box = page.bounds(for: view.displayBox)
            let room = view.bounds.insetBy(dx: 20, dy: 20)
            view.autoScales = false
            view.scaleFactor = zoom == .pageWidth ? room.width / box.width : min(room.width / box.width, room.height / box.height)
        case .percent(let n):
            view.autoScales = false
            view.scaleFactor = CGFloat(n) / 100
        }
    }

    // MARK: Find

    func find(_ text: String, matchCase: Bool, wholeWords: Bool) {
        found = []
        foundAt = 0
        guard !text.isEmpty else {
            view?.highlightedSelections = nil
            return
        }
        var options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        options.insert(.diacriticInsensitive)
        var results = document.findString(text, withOptions: options)
        if wholeWords {
            results = results.filter { selection in
                guard let page = selection.pages.first, let whole = page.string,
                    let range = selection.range(at: 0, on: page).toOptional, let found = Range(range, in: whole)
                else { return true }
                let before = found.lowerBound > whole.startIndex ? whole[whole.index(before: found.lowerBound)] : " "
                let after = found.upperBound < whole.endIndex ? whole[found.upperBound] : " "
                return !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber
            }
        }
        for result in results { result.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        found = results
        view?.highlightedSelections = results
        show(0)
    }

    func show(_ index: Int) {
        guard !found.isEmpty else { return }
        foundAt = (index + found.count) % found.count
        view?.setCurrentSelection(found[foundAt], animate: true)
        view?.scrollSelectionToVisible(nil)
    }

    // MARK: Marking up

    /// Highlights, underlines or strikes through the selected text, line by line.
    func mark(_ kind: PDFAnnotationSubtype) {
        guard let selection = view?.currentSelection else { return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: kind, withProperties: nil)
                mark.color = kind == .highlight ? NSColor.systemYellow.withAlphaComponent(0.5) : NSColor.systemRed
                page.addAnnotation(mark)
            }
        }
        view?.clearSelection()
        edited = true
    }

    /// A note at the selection, or the middle of the page.
    func note() {
        guard let view, let page = view.currentSelection?.pages.first ?? view.currentPage else { return }
        let at = view.currentSelection?.bounds(for: page).origin ?? CGPoint(x: page.bounds(for: .cropBox).midX, y: page.bounds(for: .cropBox).midY)
        let note = PDFAnnotation(bounds: CGRect(x: at.x, y: at.y, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Note"
        note.color = .systemYellow
        page.addAnnotation(note)
        edited = true
    }

    func rotate() {
        guard let page = view?.currentPage else { return }
        page.rotation = (page.rotation + 90) % 360
        edited = true
    }

    func layout(_ mode: PDFDisplayMode) {
        view?.displayMode = mode
        view?.displaysAsBook = mode == .twoUpContinuous || mode == .twoUp
    }

    // MARK: Out

    func print() {
        view?.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    /// With what was marked, drawn and signed, where the person says.
    func save(in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.lastPathComponent.isEmpty ? "Document.pdf" : url.lastPathComponent
        let write: (NSApplication.ModalResponse) -> Void = { [document] answer in
            guard answer == .OK, let to = panel.url else { return }
            document.write(to: to)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    var properties: [(String, String)] {
        let info = document.documentAttributes ?? [:]
        let when = { (key: PDFDocumentAttribute) in (info[key] as? Date).map { $0.formatted(date: .abbreviated, time: .shortened) } }
        let size = document.page(at: 0).map { $0.bounds(for: .mediaBox).size }
        return [
            ("File", url.lastPathComponent),
            ("Title", info[PDFDocumentAttribute.titleAttribute] as? String),
            ("Author", info[PDFDocumentAttribute.authorAttribute] as? String),
            ("Subject", info[PDFDocumentAttribute.subjectAttribute] as? String),
            ("Keywords", (info[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ")),
            ("Created", when(.creationDateAttribute)),
            ("Changed", when(.modificationDateAttribute)),
            ("Made with", info[PDFDocumentAttribute.creatorAttribute] as? String),
            ("PDF producer", info[PDFDocumentAttribute.producerAttribute] as? String),
            ("Version", "\(document.majorVersion).\(document.minorVersion)"),
            ("Pages", "\(pages)"),
            ("Page size", size.map { "\(Int($0.width)) × \(Int($0.height)) pt" }),
        ].compactMap { name, value in value.flatMap { $0.isEmpty ? nil : (name, $0) } }
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}

extension Tab {
    /// Once a page has loaded: a PDF gets Mote's reader, made from what
    /// WebKit already has (a file, or the PDF WebKit shows); anything else lets it go.
    func readPDFIfShown() {
        guard let web = built, !web.isLoading, let url = address else { return }
        let shows = pdfExpected || web.unpublishedFlag("_isDisplayingPDF") == true || (url.isFileURL && url.pathExtension.lowercased() == "pdf")
        guard shows else {
            if pdf != nil { pdf = nil }
            return
        }
        guard pdf?.url != url, !readingPDF else { return }
        readingPDF = true
        Task { [weak self] in
            defer { self?.readingPDF = false }
            guard let data = await self?.pdfData(of: url, in: web), let document = PDFDocument(data: data), self?.address == url else { return }
            self?.pdf = PDFReader(document: document, url: url)
        }
    }

    /// The PDF's bytes: WebKit's own, once its viewer has them (it can say the
    /// page loaded a moment before); a file's; else fetched again with the
    /// tab's cookies.
    private func pdfData(of url: URL, in web: WKWebView) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        for _ in 0..<6 {
            if let data = web.unpublishedObject("_dataForDisplayedPDF") as? Data, !data.isEmpty { return data }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        var request = URLRequest(url: url)
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { url.host()?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try? await URLSession.shared.data(for: request).0
    }
}

/// The reader over the page: its toolbar, a sidebar of pages or the outline,
/// and the document.
struct PDFReaderView: View {
    @ObservedObject var reader: PDFReader
    @State private var findText = ""
    @State private var matchCase = false
    @State private var wholeWords = false
    @State private var pageField = "1"
    @State private var showsProperties = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                if let sidebar = reader.sidebar {
                    Group {
                        if sidebar == .pages { PDFThumbnails(reader: reader) } else { PDFOutlineList(reader: reader) }
                    }
                    .frame(width: 180)
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                }
                PDFPages(reader: reader)
            }
        }
        .background(Palette.frame)
        .onChange(of: reader.page) { _, page in pageField = "\(page + 1)" }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Door(icon: "sidebar.left", on: reader.sidebar != nil, help: "Pages and outline") {
                reader.sidebar = reader.sidebar == nil ? .pages : nil
            }
            if reader.sidebar != nil {
                Menu(reader.sidebar == .outline ? "Outline" : "Pages") {
                    Button("Pages") { reader.sidebar = .pages }
                    Button("Outline") { reader.sidebar = .outline }.disabled(reader.document.outlineRoot == nil)
                }
                .fixedSize()
            }
            divider
            Door(icon: "chevron.up", help: "Previous page") { reader.go(to: reader.page - 1) }
            Door(icon: "chevron.down", help: "Next page") { reader.go(to: reader.page + 1) }
            TextField("", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onSubmit { reader.go(to: (Int(pageField) ?? 1) - 1) }
            Text("of \(reader.pages)").foregroundStyle(Palette.muted)
            divider
            Door(icon: "minus", help: "Zoom out") { reader.view.map { $0.autoScales = false; $0.scaleFactor = max($0.scaleFactor / 1.2, 0.1) } }
            Door(icon: "plus", help: "Zoom in") { reader.view.map { $0.autoScales = false; $0.scaleFactor = min($0.scaleFactor * 1.2, 8) } }
            Menu("Zoom") {
                ForEach(PDFReader.Zoom.all, id: \.self) { zoom in Button(zoom.title) { reader.zoom(zoom) } }
            }
            .fixedSize()
            Spacer(minLength: 8)
            findBar
            Spacer(minLength: 8)
            Door(icon: "highlighter", help: "Highlight the selected text") { reader.mark(.highlight) }
            Door(icon: "underline", help: "Underline the selected text") { reader.mark(.underline) }
            Door(icon: "strikethrough", help: "Strike through the selected text") { reader.mark(.strikeOut) }
            Door(icon: "note.text", help: "Add a note") { reader.note() }
            divider
            Menu {
                Button("Rotate Page") { reader.rotate() }
                Divider()
                Button("Single Page") { reader.layout(.singlePage) }
                Button("Continuous") { reader.layout(.singlePageContinuous) }
                Button("Two Pages") { reader.layout(.twoUpContinuous) }
                Divider()
                Button("Presentation") { present() }
                Divider()
                Button("Print…") { reader.print() }
                Button(reader.edited ? "Save with Changes…" : "Save…") { reader.save(in: reader.view?.window) }
                Button("Document Properties…") { showsProperties = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .popover(isPresented: $showsProperties) { properties }
        }
        .font(TextStyle.secondary.font)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var findBar: some View {
        HStack(spacing: 4) {
            TextField("Find in document", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .onSubmit { reader.found.isEmpty ? reader.find(findText, matchCase: matchCase, wholeWords: wholeWords) : reader.show(reader.foundAt + 1) }
                .onChange(of: findText) { _, text in reader.find(text, matchCase: matchCase, wholeWords: wholeWords) }
            if !reader.found.isEmpty {
                Text("\(reader.foundAt + 1)/\(reader.found.count)").foregroundStyle(Palette.muted).monospacedDigit()
                Door(icon: "chevron.left", help: "Previous") { reader.show(reader.foundAt - 1) }
                Door(icon: "chevron.right", help: "Next") { reader.show(reader.foundAt + 1) }
            }
            Toggle("Aa", isOn: $matchCase).toggleStyle(.button).help("Match case")
                .onChange(of: matchCase) { reader.find(findText, matchCase: matchCase, wholeWords: wholeWords) }
            Toggle("W", isOn: $wholeWords).toggleStyle(.button).help("Whole words")
                .onChange(of: wholeWords) { reader.find(findText, matchCase: matchCase, wholeWords: wholeWords) }
        }
    }

    private var properties: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(reader.properties, id: \.0) { name, value in
                GridRow {
                    Text(name).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(maxWidth: 420)
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(width: 1, height: 16) }

    /// Full screen, a page at a time, as a slide show; Escape leaves it.
    private func present() {
        reader.layout(.singlePage)
        reader.zoom(.pageFit)
        reader.view?.window?.toggleFullScreen(nil)
    }
}

/// The pages, in PDFKit's own view.
private struct PDFPages: NSViewRepresentable {
    let reader: PDFReader

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = reader.document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        reader.view = view
        context.coordinator.watch(view, reader)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var watching: AnyCancellable?

        @MainActor func watch(_ view: PDFView, _ reader: PDFReader) {
            watching = NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: view).sink { [weak reader, weak view] _ in
                MainActor.assumeIsolated {
                    guard let reader, let page = view?.currentPage else { return }
                    let index = reader.document.index(for: page)
                    if reader.page != index { reader.page = index }
                }
            }
        }
    }
}

/// The pages small, for going to one.
private struct PDFThumbnails: NSViewRepresentable {
    let reader: PDFReader

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.thumbnailSize = CGSize(width: 120, height: 150)
        thumbnails.backgroundColor = .clear
        thumbnails.pdfView = reader.view
        return thumbnails
    }

    func updateNSView(_ thumbnails: PDFThumbnailView, context: Context) {
        if thumbnails.pdfView !== reader.view { thumbnails.pdfView = reader.view }
    }
}

/// The document's outline, for going to a part.
private struct PDFOutlineList: View {
    @ObservedObject var reader: PDFReader

    var body: some View {
        List {
            if let root = reader.document.outlineRoot {
                OutlineLevel(outline: root, reader: reader)
            }
        }
        .listStyle(.sidebar)
    }

    private struct OutlineLevel: View {
        let outline: PDFOutline
        let reader: PDFReader

        var body: some View {
            ForEach(0..<outline.numberOfChildren, id: \.self) { index in
                if let child = outline.child(at: index) {
                    if child.numberOfChildren > 0 {
                        DisclosureGroup {
                            OutlineLevel(outline: child, reader: reader)
                        } label: {
                            line(child)
                        }
                    } else {
                        line(child)
                    }
                }
            }
        }

        private func line(_ item: PDFOutline) -> some View {
            Button(item.label ?? "Untitled") { if let destination = item.destination { reader.view?.go(to: destination) } }
                .buttonStyle(.plain)
                .lineLimit(1)
        }
    }
}
