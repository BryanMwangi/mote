import MoteCore
import SecurityInterface
import SwiftUI
import WebKit

/// Page Info, as Firefox's: a window for one tab's page with what it is,
/// its pictures, what the site may do, and how safe it is.
@MainActor
enum PageInfo {
    private static var windows: [Tab.ID: NSWindow] = [:]
    /// The part it opens at; the bench asks for others.
    static var opening = "General"

    static func show(for tab: Tab, in browser: Browser) {
        if let open = windows[tab.id] { return open.makeKeyAndOrderFront(nil) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Page Info — \(tab.address?.absoluteString ?? tab.label)"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PageInfoView(browser: browser, tab: tab))
        window.center()
        windows[tab.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: tab.id) }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// What the page says of itself, read once in Mote's world.
private struct PageFacts: Decodable {
    var type = "", charset = "", mode = "", modified = "", referrer = ""
    var size = 0
    /// Each picture's address, width, height and alt text.
    var images: [[String]] = []

    static let script = """
        (() => {
          const nav = performance.getEntriesByType('navigation')[0] || {};
          const seen = new Set(), images = [];
          for (const img of document.images) {
            const src = img.currentSrc || img.src;
            if (!src || seen.has(src) || images.length >= 400) continue;
            seen.add(src);
            images.push([src, String(img.naturalWidth), String(img.naturalHeight), img.alt || '']);
          }
          return JSON.stringify({ type: document.contentType, charset: document.characterSet, mode: document.compatMode,
            modified: document.lastModified, referrer: document.referrer, size: nav.encodedBodySize || nav.transferSize || 0, images });
        })()
        """
}

private struct PageInfoView: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    private enum Part: String, CaseIterable {
        case general = "General", media = "Media", permissions = "Permissions", security = "Security"
    }

    @State private var part = Part(rawValue: PageInfo.opening) ?? .general
    @State private var facts = PageFacts()
    @State private var picked: String?
    @State private var storedData: [WKWebsiteDataRecord] = []
    @State private var certified: Bool?

    private var host: String { tab.address?.host() ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $part) { ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(12)
            Divider()
            Group {
                switch part {
                case .general: general
                case .media: media
                case .permissions: permissions
                case .security: security
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { await read() }
    }

    // MARK: - General

    private var general: some View {
        Form {
            LabeledContent("Title", value: tab.label)
            LabeledContent("Address") { Text(tab.address?.absoluteString ?? "").textSelection(.enabled).lineLimit(3) }
            LabeledContent("Type", value: facts.type)
            LabeledContent("Render mode", value: facts.mode == "CSS1Compat" ? "Standards" : facts.mode.isEmpty ? "" : "Quirks")
            LabeledContent("Encoding", value: facts.charset)
            LabeledContent(
                "Size", value: facts.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(facts.size), countStyle: .file) : "Unknown")
            LabeledContent("Modified", value: facts.modified)
            LabeledContent("Referring address", value: facts.referrer.isEmpty ? "None" : facts.referrer)
        }
        .formStyle(.grouped)
    }

    // MARK: - Media

    private var media: some View {
        VStack(spacing: 0) {
            List(facts.images, id: \.[0], selection: $picked) { image in
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: image[0])) {
                        $0.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.1)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image[0]).lineLimit(1).truncationMode(.middle)
                        Text("\(image[1]) × \(image[2])\(image[3].isEmpty ? "" : " · \(image[3])")").font(.caption).foregroundStyle(
                            .secondary
                        )
                        .lineLimit(1)
                    }
                }
            }
            HStack {
                Text(facts.images.isEmpty ? "No pictures on this page" : "\(facts.images.count) pictures").foregroundStyle(.secondary)
                Spacer()
                Button("Save Picture…") {
                    if let picked, let url = URL(string: picked), let web = tab.built { browser.downloadImage(at: url, from: web) }
                }
                .disabled(picked == nil)
            }
            .padding(12)
        }
    }

    // MARK: - Permissions

    private var permissions: some View {
        Form {
            Section("Permissions for \(host)") {
                capture("Use the camera", .camera)
                capture("Use the microphone", .microphone)
                Toggle(
                    "Block ads and trackers",
                    isOn: Binding(get: { !AdBlocker.shared.isPaused(on: host) }, set: { AdBlocker.shared.pause(host, !$0) }))
                LabeledContent("Zoom") {
                    HStack {
                        Text("\(Int((tab.zoom * 100).rounded()))%").monospacedDigit()
                        Button("Reset", action: browser.resetZoom).disabled(abs(tab.zoom - 1) < 0.01)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func capture(_ title: String, _ type: WKMediaCaptureType) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { CaptureRequests.remembered(host, type).map { $0 ? 1 : 2 } ?? 0 },
                set: { CaptureRequests.remember(host, type, $0 == 0 ? nil : $0 == 1) })
        ) {
            Text("Always Ask").tag(0)
            Text("Allow").tag(1)
            Text("Block").tag(2)
        }
    }

    // MARK: - Security

    private var security: some View {
        let connection = Connection.of(
            scheme: tab.address?.scheme, certified: certified, onlySecureContent: tab.built?.hasOnlySecureContent)
        return Form {
            Section("Website identity") {
                LabeledContent("Website", value: host)
                if let connection {
                    LabeledContent("Connection", value: connection.headline)
                    Text(connection.explanation).font(.callout).foregroundStyle(.secondary)
                }
                if let trust = tab.built?.serverTrust {
                    Button(certified == false ? "View Certificate (Not Valid)…" : "View Certificate…") {
                        if let window = NSApp.keyWindow {
                            SFCertificatePanel.shared().beginSheet(
                                for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false)
                        }
                    }
                }
            }
            Section("Privacy and history") {
                LabeledContent("Visited before", value: visits)
                LabeledContent("Cookies and site data") {
                    HStack {
                        Text(storedData.isEmpty ? "None" : "Stored")
                        Button("Clear", action: clearData).disabled(storedData.isEmpty)
                    }
                }
                LabeledContent("Saved passwords", value: "\(PasswordStore.logins(for: host).count)")
            }
        }
        .formStyle(.grouped)
    }

    private var visits: String {
        let count = browser.history.entries(matching: host).filter { $0.url.host() == host }.reduce(0) { $0 + $1.count }
        return count == 0 ? "No" : count == 1 ? "Once" : "\(count) times"
    }

    private var dataStore: WKWebsiteDataStore? { tab.built?.configuration.websiteDataStore }

    private func clearData() {
        let records = storedData
        storedData = []
        dataStore?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
    }

    // MARK: - Reading

    private func read() async {
        if let web = tab.built {
            let text = await withCheckedContinuation { done in
                web.evaluateInAppWorld(PageFacts.script) { done.resume(returning: $0 as? String) }
            }
            if let data = text?.data(using: .utf8), let read = try? JSONDecoder().decode(PageFacts.self, from: data) { facts = read }
            if let trust = web.serverTrust {
                SecTrustEvaluateAsyncWithError(trust, .main) { _, trusted, _ in MainActor.assumeIsolated { certified = trusted } }
            }
        }
        let records = await dataStore?.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) ?? []
        storedData = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
    }
}
