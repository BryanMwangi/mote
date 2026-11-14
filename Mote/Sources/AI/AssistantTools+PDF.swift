import AppKit
import MoteAI
import MoteCore
import PDFKit

/// PDFs: their text, page by page, and their form fields, what kind each is
/// and what it holds; and filling those fields in, in Mote's reader, where
/// the person sees them and can save the PDF.
extension AssistantTools {
    var pdfTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        return [
            Tool(
                name: "pdf_fields",
                description:
                    "A PDF tab's form fields: each one's number, name, kind (text, check box, radio, list, signature), page, what it holds, and whether it can be filled. Says so when the PDF has none (a flat or scanned form).",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
            Tool(
                name: "fill_pdf_fields",
                description:
                    "Fills a PDF tab's form fields, by number or name from pdf_fields: text for text fields, \"on\" or \"off\" for check boxes, an option for lists and radios. Shown in Mote's reader; save: true saves the filled PDF to Downloads. Asks first, per site.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"values\":{\"type\":\"object\",\"description\":\"Field number or name to value\"},\"save\":{\"type\":\"boolean\"}},\"required\":[\"tab\",\"values\"]}"),
        ]
    }

    func runPDF(_ call: ToolCall) async -> String? {
        switch call.name {
        case "pdf_fields":
            guard let found = find(call.input) else { return Self.noTab }
            guard let document = await found.tab.pdfDocument() else { return "\(Self.line(found.tab)) isn't a PDF, or it couldn't be read." }
            return Self.fields(of: document)
        case "fill_pdf_fields":
            return await fillFields(call.input)
        default:
            return nil
        }
    }

    // MARK: Text

    /// A PDF tab's text, page by page, for read_tab; nil when the tab isn't a PDF.
    func pdfText(of tab: Tab) async -> String? {
        guard tab.pdf != nil || tab.pdfAt != nil || tab.address?.pathExtension.lowercased() == "pdf",
            let document = await tab.pdfDocument()
        else { return nil }
        let fields = Self.widgets(in: document).count
        let head = "\(tab.label)\n\(tab.address?.absoluteString ?? "")\nA PDF of \(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
            + (fields > 0 ? ", with \(fields) form fields (list them with pdf_fields)." : ", with no form fields.")
        return head + "\n\n" + Self.text(of: document)
    }

    static func text(of document: PDFDocument) -> String {
        var text = ""
        for index in 0..<document.pageCount {
            let page = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text += "— Page \(index + 1) —\n" + (page.isEmpty ? "(no text: a picture or a scan)" : page) + "\n\n"
            if text.count > most { return String(text.prefix(most)) + "\n…the rest is cut off." }
        }
        return text
    }

    // MARK: Fields

    /// Every form field, in page order: one widget per field (a radio group's
    /// buttons count once).
    static func widgets(in document: PDFDocument) -> [(page: Int, widget: PDFAnnotation)] {
        var seen = Set<String>()
        var found: [(Int, PDFAnnotation)] = []
        for index in 0..<document.pageCount {
            for widget in document.page(at: index)?.annotations ?? [] where widget.type == "Widget" {
                let name = widget.fieldName ?? "field \(found.count + 1)"
                if widget.widgetControlType == .radioButtonControl, !seen.insert(name).inserted { continue }
                found.append((index, widget))
            }
        }
        return found
    }

    private static func kind(_ widget: PDFAnnotation) -> String {
        switch widget.widgetFieldType {
        case .text: "text"
        case .choice: "list"
        case .signature: "signature"
        case .button:
            switch widget.widgetControlType {
            case .checkBoxControl: "check box"
            case .radioButtonControl: "radio"
            default: "button"
            }
        default: "field"
        }
    }

    private static func value(_ widget: PDFAnnotation) -> String {
        switch widget.widgetFieldType {
        case .button where widget.widgetControlType != .pushButtonControl: widget.buttonWidgetState == .onState ? "on" : "off"
        default: widget.widgetStringValue ?? ""
        }
    }

    static func fields(of document: PDFDocument) -> String {
        let widgets = widgets(in: document)
        guard !widgets.isEmpty else {
            return "This PDF has no form fields: it's flat (or scanned), so it can't be filled in as a form. Read its text with read_tab."
        }
        return "\(widgets.count) fields:\n" + widgets.enumerated().map { number, item in
            let widget = item.widget
            var line = "\(number + 1)\t\(widget.fieldName ?? "unnamed")\t\(kind(widget))\tpage \(item.page + 1)\tholds “\(value(widget))”"
            if widget.isReadOnly { line += "\tread-only" }
            if let choices = widget.choices, !choices.isEmpty { line += "\toptions: " + choices.joined(separator: ", ") }
            if let tip = widget.toolTip, !tip.isEmpty, tip != widget.fieldName { line += "\t“\(tip.prefix(120))”" }
            return line
        }.joined(separator: "\n")
    }

    private func fillFields(_ input: JSON) async -> String {
        guard let found = find(input) else { return Self.noTab }
        guard let reader = found.tab.pdf, let address = found.tab.address else {
            return "\(Self.line(found.tab)) isn't open in Mote's PDF reader; select it, or open the PDF in a tab."
        }
        guard let values = input["values"]?.fields, !values.isEmpty else { return "Give the fields to fill, by number or name." }
        guard await permit(.inPage(address), "Fill \(values.count) field\(values.count == 1 ? "" : "s") in “\(found.tab.label)”?") else { return refused }
        let widgets = Self.widgets(in: reader.document)
        var filled: [String] = []
        var missed: [String] = []
        var before: [(PDFAnnotation, String?, PDFWidgetCellState)] = []
        for (key, value) in values {
            let text = value.string ?? value.int.map(String.init) ?? value.bool.map { $0 ? "on" : "off" } ?? ""
            let match = Int(key).flatMap { widgets.indices.contains($0 - 1) ? widgets[$0 - 1] : nil }
                ?? widgets.first { $0.widget.fieldName?.localizedCaseInsensitiveCompare(key) == .orderedSame }
            guard let widget = match?.widget, !widget.isReadOnly else {
                missed.append(key)
                continue
            }
            before.append((widget, widget.widgetStringValue, widget.buttonWidgetState))
            reader.setField(widget, to: text)
            filled.append("\(widget.fieldName ?? key): “\(Self.value(widget))”")
        }
        var said = filled.isEmpty ? "Nothing was filled." : "Filled in Mote's reader:\n" + filled.map { "- " + $0 }.joined(separator: "\n")
        if !missed.isEmpty { said += "\nNo such field, or read-only: \(missed.joined(separator: ", ")); list them with pdf_fields." }
        if input["save"]?.bool == true, !filled.isEmpty {
            let to = reader.saveCopy(in: browser.downloadsFolder)
            said += to.map { "\nSaved as \($0.lastPathComponent) in Downloads." } ?? "\nIt couldn't be saved."
        }
        let was = before
        return said + record("Filled \(filled.count) PDF fields in “\(found.tab.label)”") { [weak reader] in
            for (widget, text, state) in was {
                widget.widgetStringValue = text
                widget.buttonWidgetState = state
            }
            reader?.view?.setNeedsDisplay(reader?.view?.bounds ?? .zero)
            return "Emptied them again."
        }
    }
}

extension Tab {
    /// The tab's PDF: the reader's, else the bytes read again.
    func pdfDocument() async -> PDFDocument? {
        if let pdf { return pdf.document }
        guard let url = pdfAt ?? address else { return nil }
        if url.isFileURL { return PDFDocument(url: url) }
        if let built { return await pdfData(of: url, in: built).flatMap(PDFDocument.init(data:)) }
        // Asleep: fetched as it is.
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return PDFDocument(data: data)
    }
}
