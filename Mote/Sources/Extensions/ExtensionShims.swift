import CryptoKit
import IOKit.pwr_mgt
import MoteCore
import WebKit

// Chrome APIs WebKit doesn't have (bookmarks, history, downloads, the side
// panel, offscreen documents, identity…). A script written into each
// extension defines them and sends each call to Mote as a native message;
// ChromeAPI answers. Here: writing that script in, and what the answers
// remember between calls.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The native messaging app name that means Mote itself.
    static let application = "mote"

    nonisolated static let file = ShimRewrite.file
    nonisolated static let passkeys = ShimRewrite.passkeys
    nonisolated static let marker = ShimRewrite.marker
    nonisolated static let ender = ShimRewrite.ender
    nonisolated static let stamp = ShimRewrite.stamp

    /// The shim as built from Scripts/src/extension-shims.ts, before an
    /// extension's values go in (`shim(for:)`). It defines only what's
    /// missing, so WebKit's own APIs come first.
    nonisolated static let script = InjectedScript.source("extension-shims")

    /// Of the built scripts, not of `PasskeyRelay.page`: that carries this
    /// launch's random event names, and only its own small file is written
    /// again each launch.
    nonisolated static let version = version(of: script + InjectedScript.source("passkey-relay"))

    /// A hash of what's written, so a new shim prepares extensions again.
    nonisolated static func version(of written: String) -> String {
        SHA256.hash(data: Data(written.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + (Storage.testing ? "-test" : "")
    }

    // MARK: - Writing it in

    /// Writes the shim into an extension's manifest, worker and pages, unless
    /// this version already is. `fresh`: a new package, whose own copies of
    /// Mote's bookkeeping files are thrown away so it can't forge them.
    nonisolated static func prepare(_ folder: URL, fresh: Bool = false) throws {
        let files = FileManager.default
        let at = { folder.appendingPathComponent($0) }
        if fresh { [stamp, ShimRewrite.added].forEach { try? files.removeItem(at: at($0)) } }
        // This launch's event names: the one file written every launch.
        if (try? String(contentsOf: at(passkeys), encoding: .utf8)) != PasskeyRelay.page {
            try PasskeyRelay.page.write(to: at(passkeys), atomically: true, encoding: .utf8)
        }
        if (try? String(contentsOf: at(stamp), encoding: .utf8)) == version { return }
        defer { try? version.write(to: at(stamp), atomically: true, encoding: .utf8) }

        guard let read = try JSONSerialization.jsonObject(with: Data(contentsOf: at("manifest.json"))) as? [String: Any] else {
            throw CRX.Failure.unpack
        }
        let shim = shim(for: folder)
        try shim.write(to: at(file), atomically: true, encoding: .utf8)

        let before =
            (try? Data(contentsOf: at(ShimRewrite.added))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let (manifest, added) = ShimRewrite.manifest(read, added: before)
        if let list = try? JSONSerialization.data(withJSONObject: added) { try? list.write(to: at(ShimRewrite.added)) }

        // Not a worker outside the package, or a link to one.
        if let (path, module) = ShimRewrite.worker(in: manifest), let worker = inside(path, of: folder),
            let source = try? String(contentsOf: worker, encoding: .utf8)
        {
            try ShimRewrite.worker(source, shim: shim, module: module).write(to: worker, atomically: true, encoding: .utf8)
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]).write(
            to: at("manifest.json"), options: .atomic)

        for page in shippedFiles(in: folder, ending: ["html", "htm"]) {
            guard let html = try? String(contentsOf: page, encoding: .utf8), let shimmed = ShimRewrite.page(html) else { continue }
            try? shimmed.write(to: page, atomically: true, encoding: .utf8)
        }
    }

    /// The package's own files of these kinds, links left out.
    private nonisolated static func shippedFiles(in folder: URL, ending kinds: Set<String>) -> [URL] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        return (walker?.allObjects as? [URL] ?? []).filter {
            kinds.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }

    /// A path inside the package, or nil when it leads out of it (through
    /// `..` or a linked folder) or is a link itself: writing to a link would
    /// copy an outside file into the package.
    nonisolated static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
            (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim with this extension's values: the events its code mentions,
    /// so listeners added late still hear them, and its scripts, so
    /// importScripts can fail fast for one that isn't there.
    nonisolated static func shim(for folder: URL) -> String {
        let root = folder.standardizedFileURL.path
        var events = Set<String>()
        var scripts: [(path: String, empty: Bool)] = []
        for script in (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        where script.pathExtension == "js" {
            let text = try? String(contentsOf: script, encoding: .utf8)
            if script.lastPathComponent != file, let text { events.formUnion(ShimRewrite.events(in: text)) }
            let empty = (text ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((String(script.standardizedFileURL.path.dropFirst(root.count)), empty))
        }
        let manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let values = ShimConfig(
            events: events.sorted(), scripts: ShimRewrite.scriptList(scripts), chromeVersion: CRX.chromeVersion, verbose: Storage.testing,
            firefox: manifest.map(AMO.isFirefox) ?? false, firefoxVersion: "140.0")
        return InjectedScript.source("extension-shims", config: values)
    }

    /// What the shim reads as `moteConfig` (ShimConfig in
    /// Scripts/src/extension-shims/types.ts).
    nonisolated struct ShimConfig: Encodable {
        /// `namespace.onEvent` names the extension's code mentions.
        let events: [String]
        /// Its scripts by path; an empty one starts with "-".
        let scripts: [String]
        let chromeVersion: String
        /// A test run: the extension's console errors come to Mote too.
        let verbose: Bool
        /// A Firefox add-on (its manifest names a gecko id): told it's in Firefox.
        let firefox: Bool
        let firefoxVersion: String
    }

    // MARK: - Remembered between calls

    /// Each extension's side panel page (setOptions), for every tab and for
    /// single tabs, and whether its button opens it.
    static var panelPaths: [String: String] = [:]
    static var panelTabPaths: [String: [Tab.ID: String]] = [:]
    static var panelOnClick: Set<String> = []
    /// Offscreen documents; Chrome allows one per extension.
    static var offscreen: [String: WKWebView] = [:]
    /// action.setPopup's choices, by tab id or "*" for every tab.
    static var popups: [String: [String: String]] = [:]
    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    /// Answers the shim: `{api, args}` in, `{value}` or `{error}` out.
    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else { return ["error": "Not a Mote message"] }
        do {
            let call = try ChromeCall(api: api, args: body["args"] as? [Any] ?? [], context: context, owner: owner)
            return ["value": try await ChromeAPI.run(call) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The manifest's panel: Chrome's side_panel, or Firefox's sidebar_action.
    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        let manifest = context.webExtension.manifest
        return (manifest["side_panel"] as? [String: Any])?["default_path"] as? String
            ?? (manifest["sidebar_action"] as? [String: Any])?["default_panel"] as? String
    }

    /// The page an extension's panel shows for `tab` (nil: every tab).
    static func panelPath(for id: String, tab: Tab.ID?, context: WKWebExtensionContext) -> String? {
        tab.flatMap { panelTabPaths[id]?[$0] } ?? panelPaths[id] ?? defaultPanel(context)
    }

    /// Opens an extension's panel in the window `tab` is in (else the one
    /// in front): for that tab alone when it was given a page of its own,
    /// else for the whole window, as in Chrome.
    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions, tab: Tab? = nil) {
        let id = context.uniqueIdentifier
        guard let browser = tab.flatMap(owner.holder(of:)) ?? owner.front,
            panelPath(for: id, tab: tab?.id, context: context) != nil
        else { return }
        let own = tab.flatMap { panelTabPaths[id]?[$0.id] } != nil
        browser.open(SidePanel(kind: .extension(id), tab: own ? tab?.id : nil))
    }

    static func togglePanel(_ context: WKWebExtensionContext, owner: Extensions) {
        let id = context.uniqueIdentifier
        guard let browser = owner.front else { return }
        if browser.panel(id: "ext:" + id) != nil, browser.shownPanels.contains(where: { $0.id == "ext:" + id }) {
            return browser.closePanel(id: "ext:" + id)
        }
        openPanel(context, owner: owner, tab: browser.active)
    }
}
