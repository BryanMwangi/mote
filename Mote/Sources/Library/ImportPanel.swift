import AppKit
import MoteCore
import SwiftUI
import UniformTypeIdentifiers

/// Bringing your things from another browser: which browser (the Mac's
/// default first) or file, what comes, and what came. In a panel from
/// Settings, and inside the welcome's first step.
struct ImportForm: View {
    @ObservedObject var browser: Browser
    /// Called once it's done, or turned down; nil inside the welcome, which
    /// moves on itself.
    var close: (() -> Void)?

    @State private var sources: [ImportSource] = []
    @State private var source: ImportSource?
    @State private var kinds: Set<ImportKind> = []
    @State private var ownProfile = false
    @State private var asking = false
    @State private var primaryPassword = ""
    @State private var working = false
    @State private var tally: ImportTally?
    @State private var trouble: String?
    /// What each source brought, by its id: one imported can't be again,
    /// which would bring its history twice; another can be picked after it.
    @State private var imported: [String: ImportTally] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            picker
            if let source {
                if source.family == .safari {
                    note("In Safari, choose File › Export Browsing Data to File…, then pick what it saved.")
                }
                Card {
                    ForEach(Array(source.kinds.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Rule() }
                        Line(kind.title, detail(kind, of: source)) {
                            Switch(
                                on: Binding(
                                    get: { kinds.contains(kind) },
                                    set: { on in
                                        if on { kinds.insert(kind) } else { kinds.remove(kind) }
                                    }))
                        }
                    }
                }
                if source.isBrowser, close != nil {
                    Card {
                        Line("Into a new profile", "A Mote of its own for \(source.name), apart from this one") { Switch(on: $ownProfile) }
                    }
                }
                if asking {
                    SecureField("\(source.browser)'s primary password", text: $primaryPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(run)
                }
            }
            if let tally {
                note(
                    close == nil && sources.contains(where: { $0.isBrowser && imported[$0.id] == nil })
                        ? "\(tally.summary) Another browser can come along too: pick it above." : tally.summary, strong: true)
            }
            if let trouble { note(trouble, strong: true) }
            HStack(spacing: 8) {
                note(source.map { $0.isBrowser ? "Nothing in \($0.browser) changes." : "The file is read, not kept." } ?? "")
                Spacer()
                if let close, tally == nil { Pill("Cancel", action: close) }
                if tally != nil, let close {
                    Pill("Done", filled: true, action: close)
                } else if tally != nil {
                    Pill("Imported") {}.disabled(true)
                } else {
                    Pill(working ? "Importing…" : needsFile ? "Choose File…" : "Import", filled: true, action: run)
                        .disabled(working || source == nil || kinds.isEmpty)
                }
            }
        }
        .onAppear {
            guard sources.isEmpty else { return }
            sources = ImportSource.found()
            pick(sources.first)
        }
    }

    /// The source, as a wide field with its browser's icon.
    private var picker: some View {
        Menu {
            let browsers = sources.filter(\.isBrowser), files = sources.filter { !$0.isBrowser }
            ForEach(browsers) { item in button(for: item) }
            Divider()
            ForEach(files) { item in button(for: item) }
        } label: {
            HStack(spacing: 10) {
                if let source { Image(nsImage: source.icon).resizable().frame(width: 24, height: 24) }
                Text(source?.name ?? "No browsers found").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func button(for item: ImportSource) -> some View {
        Button {
            pick(item)
        } label: {
            Label {
                Text(imported[item.id] == nil ? item.name : "\(item.name) — imported")
            } icon: {
                Image(nsImage: Self.small(item.icon))
            }
        }
    }

    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func note(_ text: String, strong: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(strong ? Palette.ink : Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var needsFile: Bool {
        switch source?.family {
        case .safari, .passwordsFile, .bookmarksFile: true
        default: false
        }
    }

    private func detail(_ kind: ImportKind, of source: ImportSource) -> String? {
        // Listed, as switching it on is saying yes to installing each.
        if kind == .addOns {
            let names = source.addOns.map(\.name)
            guard !names.isEmpty else { return "None from a store" }
            let shown = names.count > 4 ? Array(names.prefix(3)) + ["\(names.count - 3) more"] : names
            return ListFormatter.localizedString(byJoining: shown) + ", from their stores"
        }
        guard kind == .spaces, let zen = source.zen, let plan = try? ZenImporter.plan(for: zen) else { return nil }
        let spaces = plan.spaces.count
        return "\(spaces) \(spaces == 1 ? "space" : "spaces"), \(plan.tabCount) tabs, with their split views and colours"
    }

    private func pick(_ chosen: ImportSource?) {
        source = chosen
        kinds = Set(chosen?.kinds ?? [])
        tally = chosen.flatMap { imported[$0.id] }
        trouble = nil
        asking = false
        primaryPassword = ""
        ownProfile = false
    }

    private func run() {
        guard let source else { return }
        if ownProfile {
            Profiles.shared.add(
                named: source.name, avatar: .init(symbol: "person.fill", color: "#6cbad9"),
                importing: "\(source.id)|\(kinds.map(\.rawValue).joined(separator: ","))")
            tally = ImportTally()
            trouble = "\(source.name) opens as a profile of its own, bringing its things there."
            return
        }
        var file: URL?
        if needsFile {
            let panel = NSOpenPanel()
            switch source.family {
            case .safari:
                panel.allowedContentTypes = [.zip, .folder]
                panel.canChooseDirectories = true
                panel.message = "Choose what Safari's File › Export Browsing Data to File… saved"
            case .passwordsFile: panel.allowedContentTypes = [.commaSeparatedText, .plainText]
            default: panel.allowedContentTypes = [.html]
            }
            curtainMakesWay(true)
            defer { curtainMakesWay(false) }
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            file = chosen
        }
        working = true
        trouble = nil
        Task {
            defer { working = false }
            do {
                let brought = try await browser.bring(kinds, from: source, file: file, primaryPassword: primaryPassword)
                imported[source.id] = brought
                tally = brought
                asking = false
            } catch ImportTrouble.primaryPassword {
                asking = true
                trouble = primaryPassword.isEmpty ? "\(source.browser) keeps its passwords behind a primary password." : "That isn't it."
            } catch ImportTrouble.locked {
                trouble = "macOS didn't hand over \(source.browser)'s password key. Try again, and allow it."
            } catch {
                trouble = "Nothing readable there."
            }
        }
    }
}

/// Settings › Import Browser Data.
struct ImportPanel: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Plate("Import Browser Data", width: 460, close: { browser.importing = false }) {
            ImportForm(browser: browser) { browser.importing = false }
        }
    }
}

extension Browser {
    /// A profile made from another browser's (see ImportForm) brings its
    /// things in once it opens: MOTE_IMPORT is the source's id and the kinds.
    func importOnLaunch() {
        guard let asked = ProcessInfo.processInfo.environment["MOTE_IMPORT"], Storage.profile != nil,
            !Storage.settings.bool(forKey: "import.launched")
        else { return }
        Storage.settings.set(true, forKey: "import.launched")
        let parts = asked.split(separator: "|", maxSplits: 1).map(String.init)
        guard let source = ImportSource.found().first(where: { $0.id == parts.first }) else { return }
        let kinds = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { ImportKind(rawValue: String($0)) })
        Task {
            let tally = try? await bring(kinds, from: source)
            announce("From \(source.name): \(tally?.summary ?? "nothing readable")")
        }
    }
}
