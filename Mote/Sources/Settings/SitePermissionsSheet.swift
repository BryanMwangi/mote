import SwiftUI

/// The sites that asked for one permission, and what each was told: changed
/// or removed here, saved together. New requests can be turned down without
/// asking.
struct SitePermissionsSheet: View {
    let kind: SitePermissions.Kind
    @Environment(\.dismiss) private var dismiss

    /// The list as edited, saved only with Save Changes.
    @State private var sites: [(host: String, allowed: Bool)] = []
    @State private var blocksNew = false
    @State private var query = ""
    @State private var picked: String?
    /// macOS keeps this from Mote: no site gets it, whatever it's told here.
    @State private var systemOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(kind.title) Permissions").font(.headline).frame(maxWidth: .infinity)
            Text(
                "These websites have asked to \(kind.what). Choose which may, and which may not. You can also turn down new requests without being asked."
            )
            .fixedSize(horizontal: false, vertical: true)
            if systemOff {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("macOS doesn't let Mote use \(kind.title.lowercased()), so no website can, whatever it's allowed here.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open System Settings") { SystemAccess.open(kind) }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            TextField("Search Website", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $picked) {
                ForEach(shown, id: \.host) { site in
                    HStack {
                        Text(site.host).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: answer(for: site.host)) {
                            Text("Allow").tag(true)
                            Text("Block").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .tag(site.host)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if shown.isEmpty { Text(query.isEmpty ? "No website has asked yet." : "No website matches.").foregroundStyle(.secondary) }
            }
            .frame(minHeight: 200)
            HStack {
                Button("Remove Website") { sites.removeAll { $0.host == picked } }.disabled(picked == nil)
                Button("Remove All Websites…") {
                    guard Dialogs.confirm("Remove all websites?", "Each asks again next time.", button: "Remove All") else { return }
                    sites.removeAll()
                }
                .disabled(sites.isEmpty)
            }
            Toggle("Block new requests asking to \(kind.what)", isOn: $blocksNew)
            Text("Websites not listed above won't be able to ask. Some may not work as they should.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Changes", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .onAppear {
            sites = SitePermissions.sites(kind)
            blocksNew = SitePermissions.blocksNew(kind)
        }
        // Looked at again on coming back from System Settings.
        .task(id: kind) { systemOff = await SystemAccess.withheld(kind) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { systemOff = await SystemAccess.withheld(kind) }
        }
    }

    private var shown: [(host: String, allowed: Bool)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? sites : sites.filter { $0.host.contains(needle) }
    }

    private func answer(for host: String) -> Binding<Bool> {
        Binding(
            get: { sites.first { $0.host == host }?.allowed ?? false },
            set: { allowed in if let index = sites.firstIndex(where: { $0.host == host }) { sites[index].allowed = allowed } })
    }

    private func save() {
        let kept = Set(sites.map(\.host))
        for old in SitePermissions.sites(kind) where !kept.contains(old.host) { SitePermissions.remember(old.host, kind, nil) }
        for site in sites { SitePermissions.remember(site.host, kind, site.allowed) }
        SitePermissions.blockNew(kind, blocksNew)
        dismiss()
    }
}
