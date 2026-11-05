import CryptoKit
import Foundation

/// addons.mozilla.org, Firefox's add-on store: finding an add-on from its
/// page's address, Mozilla's public API for its latest file, checking that
/// file, and what an add-on asks for that WebKit can't give.
public enum AMO {
    /// An add-on as the API describes its current version.
    public struct Addon: Equatable, Sendable {
        public let slug: String
        public let guid: String
        public let name: String
        public let version: String
        public let file: URL
        /// The file's SHA-256, as lowercase hex.
        public let sha256: String
    }

    /// The add-on's slug from its page's address ("…/firefox/addon/ublock-origin/"),
    /// or "amo:slug"; nil for anything else.
    public static func slug(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("amo:") { return valid(String(text.dropFirst(4))) }
        guard let url = URL(string: text), let host = url.host()?.lowercased(),
            host == "addons.mozilla.org" || host == "addons.allizom.org"
        else { return nil }
        let parts = url.pathComponents
        guard let at = parts.firstIndex(of: "addon"), parts.indices.contains(at + 1) else { return nil }
        return valid(parts[at + 1])
    }

    private static func valid(_ slug: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@{}"))
        return !slug.isEmpty && slug.unicodeScalars.allSatisfy(allowed.contains) ? slug : nil
    }

    /// Mozilla's v5 API for one add-on.
    public static func apiURL(for slug: String) -> URL {
        URL(
            string:
                "https://addons.mozilla.org/api/v5/addons/addon/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/"
        )!
    }

    /// The add-on in an API reply; nil when it isn't one, or has no file.
    public static func addon(in json: Data) -> Addon? {
        guard let reply = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let slug = reply["slug"] as? String, let guid = reply["guid"] as? String,
            let current = reply["current_version"] as? [String: Any], let version = current["version"] as? String,
            let file = current["file"] as? [String: Any], let address = (file["url"] as? String).flatMap(URL.init(string:)),
            let hash = file["hash"] as? String, hash.hasPrefix("sha256:")
        else { return nil }
        let names = reply["name"] as? [String: String] ?? [:]
        let name = names["en-US"] ?? names[reply["default_locale"] as? String ?? ""] ?? names.values.first ?? slug
        return Addon(slug: slug, guid: guid, name: name, version: version, file: address, sha256: String(hash.dropFirst(7)).lowercased())
    }

    /// Whether `file` is what the API said it would be.
    public static func verified(_ file: Data, as addon: Addon) -> Bool {
        SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined() == addon.sha256
    }

    /// A manifest written for Firefox: it names a gecko id.
    public static func isFirefox(manifest: [String: Any]) -> Bool {
        let settings = manifest["browser_specific_settings"] as? [String: Any] ?? manifest["applications"] as? [String: Any]
        return settings?["gecko"] != nil
    }

    /// What a Firefox add-on asks for that WebKit doesn't have, said plainly,
    /// for the question before it's installed.
    public static func unsupported(manifest: [String: Any]) -> [String] {
        let asked = Set(
            ((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
        var missing: [String] = []
        if asked.contains("contextualIdentities") { missing.append("Containers (Mote's spaces with their own sign-ins do this)") }
        if asked.contains("webRequestBlocking") { missing.append("Blocking requests as they're made") }
        if asked.contains("proxy") { missing.append("Setting a proxy") }
        if asked.contains("dns") { missing.append("Looking up addresses itself") }
        if asked.contains("pkcs11") { missing.append("Security devices") }
        if asked.contains("theme") || manifest["theme"] != nil { missing.append("Changing the browser's theme") }
        if manifest["sidebar_action"] != nil { missing.append("A sidebar of its own") }
        return missing
    }
}
