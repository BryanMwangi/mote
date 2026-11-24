import AppKit
import Combine
import MoteCore
import SwiftUI
import WebKit

/// What sites keep in Mote, every space's and profile's stores together:
/// by site, with how much, and the two ways to clear it.
@MainActor
final class WebsiteData: ObservableObject {
    struct Site: Identifiable {
        let name: String
        var size: UInt64
        var cache: UInt64
        var records: [(store: WKWebsiteDataStore, record: WKWebsiteDataRecord)]
        var id: String { name }
    }

    @Published private(set) var sites: [Site] = []
    @Published private(set) var loaded = false
    /// WebKit told sizes (an unpublished option); without them sites are listed by name.
    @Published private(set) var sized = false

    var total: UInt64 { sites.reduce(0) { $0 + $1.size } }
    var cache: UInt64 { sites.reduce(0) { $0 + $1.cache } }

    static let caches: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    /// Every store sites keep data in: each space's, profiles' included.
    private var stores: [WKWebsiteDataStore] {
        var seen = Set<ObjectIdentifier>()
        return Windows.shared.all.flatMap { $0.spaces.map { Spaces.store(for: $0.id) } }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func load() async {
        var bySite: [String: Site] = [:]
        var sized = false
        for store in stores {
            for (record, size, cache) in await Self.records(in: store) {
                sized = sized || size != nil
                var site = bySite[record.displayName] ?? Site(name: record.displayName, size: 0, cache: 0, records: [])
                site.size += size ?? 0
                site.cache += cache ?? 0
                site.records.append((store, record))
                bySite[record.displayName] = site
            }
        }
        sites = bySite.values.sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        self.sized = sized
        loaded = true
    }

    /// Caches only: pages load again as needed, and sign-ins stay.
    func freeUpSpace() async {
        for store in stores { await store.removeData(ofTypes: Self.caches, modifiedSince: .distantPast) }
        await load()
    }

    /// Everything, every site: cookies too, so sites sign out.
    func clearAll() async {
        for store in stores { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
        await load()
    }

    func clear(_ site: Site) async {
        for (store, record) in site.records { await store.removeData(ofTypes: record.dataTypes, for: [record]) }
        sites.removeAll { $0.name == site.name }
    }

    /// A store's records, with each one's size and the size of its caches
    /// when WebKit will tell (`_fetchDataRecordsOfTypes:withOptions:`, the
    /// sizes option); else the plain records, without.
    private static func records(in store: WKWebsiteDataStore) async -> [(WKWebsiteDataRecord, UInt64?, UInt64?)] {
        let types = WKWebsiteDataStore.allWebsiteDataTypes() as NSSet
        let selector = NSSelectorFromString("_fetchDataRecordsOfTypes:withOptions:completionHandler:")
        guard store.responds(to: selector) else {
            return await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).map { ($0, nil, nil) }
        }
        typealias Fetch = @convention(c) (AnyObject, Selector, NSSet, UInt, @escaping @convention(block) (NSArray) -> Void) -> Void
        let fetch = unsafeBitCast(store.method(for: selector), to: Fetch.self)
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { done in
            // 1: compute sizes.
            fetch(store, selector, types, 1) { found in done.resume(returning: found as? [WKWebsiteDataRecord] ?? []) }
        }
        return records.map { record in
            guard let size = record.unpublishedObject("_dataSize") else { return (record, nil, nil) }
            let total = (size.value(forKey: "totalSize") as? NSNumber)?.uint64Value
            let ofTypes = NSSelectorFromString("sizeOfDataTypes:")
            var cache: UInt64?
            if size.responds(to: ofTypes) {
                typealias Of = @convention(c) (AnyObject, Selector, NSSet) -> UInt64
                cache = unsafeBitCast(size.method(for: ofTypes), to: Of.self)(size, ofTypes, Self.caches as NSSet)
            }
            return (record, total, cache)
        }
    }
}

/// Settings › Privacy › Website data › Manage: how much sites keep, freeing
/// space without signing out, clearing it all, or one site.
struct WebsiteDataSheet: View {
    @StateObject private var data = WebsiteData()
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    /// Languages downloaded to translate pages (MozillaTranslation).
    @State private var languages: [(language: String, bytes: Int)] = []

    var body: some View {
        VStack(spacing: 0) {
            // All of it in one scroll, at the sheet's height: the languages and
            // the sites below them can be any length.
            ScrollView { content.padding(20) }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 620)
        .disabled(working)
        .task { await data.load() }
        .task { languages = await MozillaTranslation.shared.downloaded() }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive").font(.system(size: 24, weight: .regular)).foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: 52, height: 52).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Website Data").font(.title3.weight(.semibold))
            Text("Websites keep copies of pages and their own data in Mote, so they load faster and remember you.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                action("Free Up Space", size: data.sized ? data.cache : nil, tint: Palette.ink) {
                    guard
                        Dialogs.confirm(
                            "Free up space?", "Saved copies of pages are removed, and load again when needed. You stay signed in.",
                            button: "Free Up Space")
                    else { return }
                    await data.freeUpSpace()
                }
                Divider().padding(.leading, 12)
                action("Clear Website Data", size: data.sized ? data.total : nil, tint: .red) {
                    guard
                        Dialogs.confirm(
                            "Clear all website data?", "Websites may sign you out, and lose what they kept on this Mac.",
                            button: "Clear Website Data")
                    else { return }
                    await data.clearAll()
                }
            }
            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(
                "Free Up Space removes saved copies of pages, which load again when needed; you stay signed in. Clear Website Data also removes cookies and site storage, so you may be signed out of websites."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !languages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloaded Languages").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(languages, id: \.language) { kept in
                            LanguageRow(name: Browser.languageName(kept.language), bytes: kept.bytes) { remove(kept.language) }
                            if kept.language != languages.last?.language { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            // The sites, as rows of the same scroll.
            LazyVStack(spacing: 0) {
                ForEach(data.sites) { site in
                    SiteRow(site: site, sized: data.sized) { Task { await data.clear(site) } }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                    if site.id != data.sites.last?.id { Divider().padding(.leading, 38) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .overlay {
                if !data.loaded { ProgressView().controlSize(.small) }
                else if data.sites.isEmpty { Text("No website keeps anything.").foregroundStyle(.secondary) }
            }
            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func action(_ title: String, size: UInt64?, tint: Color, _ act: @escaping () async -> Void) -> some View {
        Button {
            run(act)
        } label: {
            HStack {
                Text(title).foregroundStyle(tint)
                Spacer()
                if let size { Text(Self.bytes(size)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func remove(_ language: String) {
        let name = Browser.languageName(language)
        guard
            Dialogs.confirm(
                "Remove \(name)?", "Pages in \(name) download it again the next time you translate one.", button: "Remove")
        else { return }
        run {
            await MozillaTranslation.shared.remove(language)
            languages = await MozillaTranslation.shared.downloaded()
        }
    }

    private func run(_ act: @escaping () async -> Void) {
        working = true
        Task {
            await act()
            working = false
        }
    }

    static func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
}

/// A language kept to translate pages: its name and size, Remove on hover.
private struct LanguageRow: View {
    let name: String
    let bytes: Int
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            if hovering {
                Button("Remove", action: remove).buttonStyle(.borderless).controlSize(.small)
            } else {
                Text(WebsiteDataSheet.bytes(UInt64(bytes))).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SiteRow: View {
    let site: WebsiteData.Site
    let sized: Bool
    let clear: () -> Void
    @State private var icon: NSImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "globe").foregroundStyle(.secondary) }
            }
            .frame(width: 16, height: 16)
            Text(site.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if hovering {
                Button("Clear", action: clear).buttonStyle(.borderless).controlSize(.small)
            } else if sized {
                Text(WebsiteDataSheet.bytes(site.size)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .onHover { hovering = $0 }
        .task(id: site.name) { icon = await Favicons.shared.icon(for: site.name) }
    }
}
