import Foundation

/// Another browser's extensions, by the store each came from, so the same
/// ones can be installed here. Only names and store ids are read.
public enum AddOns {
    public struct Found: Equatable, Sendable {
        public enum Store: Equatable, Sendable {
            /// By its Chrome Web Store id.
            case chrome
            /// By its addons.mozilla.org id (a GUID or an email-like id).
            case firefox
        }

        public var name: String
        public var id: String
        public var store: Store

        public init(name: String, id: String, store: Store) {
            self.name = name
            self.id = id
            self.store = store
        }

        /// The one to install instead, when this one can't do its work in
        /// WebKit: uBlock Origin for Firefox blocks through `webRequest`,
        /// which WebKit doesn't have, so its Lite version, built on the
        /// blocking rules WebKit does run, comes instead.
        public var forWebKit: Found {
            guard store == .firefox, let chrome = Self.lighter[id] else { return self }
            return Found(name: chrome.name, id: chrome.id, store: .chrome)
        }

        static let lighter = ["uBlock0@raymondhill.net": (name: "uBlock Origin Lite", id: "ddkjiahejlhfcafbddmgiahcphecmpfh")]
    }

    /// The add-ons in a Firefox profile's `extensions.json` the user turned
    /// on themselves: not themes, dictionaries or language packs, nor what
    /// came with the browser.
    public static func firefox(json: Data) -> [Found] {
        guard let file = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let addons = file["addons"] as? [[String: Any]]
        else { return [] }
        return addons.compactMap { addon in
            guard addon["type"] as? String == "extension", addon["active"] as? Bool == true,
                addon["location"] as? String == "app-profile", let id = addon["id"] as? String,
                let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String
            else { return nil }
            return Found(name: name, id: id, store: .firefox)
        }
    }

    /// The extensions in a Chromium profile's `Secure Preferences` (or
    /// `Preferences`) that came from the Web Store and are turned on.
    /// `name` reads one's name from its folder when the file has none.
    public static func chromium(preferences: Data, name: (String) -> String?) -> [Found] {
        guard let file = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any],
            let settings = (file["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]]
        else { return [] }
        return settings.compactMap { id, setting in
            // Location 1 is "internal": installed from the Web Store, not built in or unpacked.
            guard setting["location"] as? Int == 1, setting["from_webstore"] as? Bool != false,
                (setting["disable_reasons"] as? [Any])?.isEmpty ?? true, (setting["disable_reasons"] as? Int ?? 0) == 0,
                setting["state"] as? Int ?? 1 == 1
            else { return nil }
            let named = ((setting["manifest"] as? [String: Any])?["name"] as? String).flatMap { $0.hasPrefix("__MSG_") ? nil : $0 }
            guard let shown = named ?? name(id) else { return nil }
            return Found(name: shown, id: id, store: .chrome)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An unpacked extension's name, from its manifest, or the default
    /// locale's messages when the manifest names a message.
    public static func name(manifest: Data, messages: (String) -> Data?) -> String? {
        guard let file = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any], let name = file["name"] as? String
        else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        guard let locale = file["default_locale"] as? String, let data = messages(locale),
            let table = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return nil }
        return table.first { $0.key.lowercased() == key }?.value["message"] as? String
    }
}
