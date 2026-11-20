import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › General › Files and applications: one list, searchable, of
/// every kind of file Mote downloads or opens and every kind of link it hands
/// to another app (mailto:, and any a site has tried to open), each with what
/// Mote does with it; and what it does with every other file.
struct FilesAndAppsSheet: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Looked at again after a change made outside the menus (a default app).
    @State private var looked = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files and Applications").font(.headline).frame(maxWidth: .infinity)
            Text("Choose how Mote handles links, downloaded files and content.").fixedSize(horizontal: false, vertical: true)
            TextField("Search file types, links or applications", text: $query).textFieldStyle(.roundedBorder)
            List {
                HStack {
                    Text("Content Type").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("Action").font(.system(size: 12, weight: .semibold)).frame(width: 230, alignment: .leading)
                }
                .foregroundStyle(.secondary)
                ForEach(shownFiles) { kind in
                    FileRow(kind: kind, looked: $looked)
                }
                ForEach(shownLinks, id: \.self) { scheme in
                    LinkRow(scheme: scheme, looked: $looked)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if shownFiles.isEmpty && shownLinks.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary) }
            }
            .frame(minHeight: 260)
            .id(looked)
            Text("What should Mote do with other files?").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
            Picker("", selection: $prefs.asksWhereToSave) {
                Text("Save them to the downloads folder").tag(false)
                Text("Ask where to save each one").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 600)
    }

    private func matches(_ words: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || words.contains { $0.lowercased().contains(needle) }
    }

    private var shownFiles: [OpenFiles] {
        OpenFiles.allCases.filter { kind in matches([kind.title, kind.action.title(kind)] + kind.types.compactMap(\.preferredFilenameExtension)) }
    }

    private var shownLinks: [String] {
        LinkHandlers.schemes.filter { scheme in
            matches([scheme, LinkRow.title(LinkHandlers.handler(for: scheme), scheme), LinkHandlers.askedBy(scheme) ?? ""])
        }
    }
}

extension OpenFiles {
    /// What a finished download of this kind does, as the list says it.
    var action: After { after }

    var afterTitle: String { action.title(self) }
}

extension OpenFiles.After {
    func title(_ kind: OpenFiles) -> String {
        switch self {
        case .nothing: "Save File"
        case .mote: "Open in Mote"
        case .app: kind.opensInMote ? "Open in Mote" : "Open in \(kind.openerName ?? "Its App")"
        }
    }
}

/// A kind of file: what a download of it does, and which app opens it from Finder.
private struct FileRow: View {
    let kind: OpenFiles
    @Binding var looked: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.opensInMote ? "Opens in Mote from Finder" : "Opens in \(kind.openerName ?? "no app") from Finder")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(kind.afterTitle) {
                choice(.mote)
                choice(.nothing)
                if !kind.opensInMote, kind.openerName != nil { choice(.app) }
                if !kind.opensInMote {
                    Divider()
                    Button("Open These from Finder in Mote") {
                        Task {
                            await kind.makeMoteDefault()
                            looked += 1
                        }
                    }
                }
            }
            .frame(width: 230)
        }
        .padding(.vertical, 3)
    }

    private func choice(_ after: OpenFiles.After) -> some View {
        Button {
            Storage.settings.set(after.rawValue, forKey: kind.afterKey)
            looked += 1
        } label: {
            if kind.action == after { Label(after.title(kind), systemImage: "checkmark") } else { Text(after.title(kind)) }
        }
    }
}

/// A kind of link: which app or site opens it.
private struct LinkRow: View {
    let scheme: String
    @Binding var looked: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(scheme)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(scheme)
                if let host = LinkHandlers.askedBy(scheme) {
                    Text("Last asked for by \(host)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(Self.title(handler, scheme)) {
                choice(.system, Self.title(.system, scheme))
                choice(.ask, "Always Ask")
                let services = LinkHandlers.services(for: scheme)
                if !services.isEmpty {
                    Divider()
                    ForEach(services, id: \.template) { choice(.web($0.template), "Use \($0.name)") }
                }
                if case .app = handler {
                    Divider()
                    choice(handler, Self.title(handler, scheme))
                }
                Divider()
                Button("Use Other…", action: pickApp)
                if scheme == "mailto", !LinkHandlers.moteTakesMail {
                    Divider()
                    Button("Send Mail Links from Other Apps to Mote") {
                        Task {
                            await LinkHandlers.takeMail()
                            looked += 1
                        }
                    }
                }
            }
            .frame(width: 230)
        }
        .padding(.vertical, 3)
    }

    private var handler: LinkHandler { LinkHandlers.handler(for: scheme) }

    private func choice(_ choice: LinkHandler, _ title: String) -> some View {
        Button {
            LinkHandlers.set(choice, for: scheme)
            looked += 1
        } label: {
            if handler == choice { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    static func title(_ handler: LinkHandler, _ scheme: String) -> String {
        switch handler {
        case .system: LinkHandlers.systemApp(for: scheme).map { "Use \($0) (default)" } ?? "No App"
        case .ask: "Always Ask"
        case .app(let id): "Use \(LinkHandlers.appName(id) ?? id)"
        case .web(let template):
            "Use " + (LinkHandlers.services(for: scheme).first { $0.template == template }?.name ?? URL(string: template)?.host() ?? "a website")
        }
    }

    static func symbol(_ scheme: String) -> String {
        switch scheme {
        case "mailto": "envelope"
        case "tel", "facetime": "phone"
        case "sms": "message"
        case "webcal": "calendar"
        default: "link"
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url, let id = Bundle(url: app)?.bundleIdentifier else { return }
        LinkHandlers.set(.app(id), for: scheme)
        looked += 1
    }
}
