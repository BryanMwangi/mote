import Foundation
import MoteCore
import SQLite3
import Security

/// Brings passwords, bookmarks, history and icons over from Chromium-based
/// browsers on this Mac. Reading their formats is `Chromium`'s job; this
/// finds the profiles, asks the keychain for the password key (macOS asks the
/// user first) and reads the databases.
nonisolated enum ChromiumImporter {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        /// The keychain item holding the password key.
        let service: String
        let account: String
        /// One profile's folder name, when only it is meant.
        var profile: String? = nil

        var id: String { name + (profile.map { ":\($0)" } ?? "") }

        var root: URL { URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory) }

        /// Each profile's folder (one with a "Login Data" file), or the one meant.
        var profiles: [URL] {
            let folders =
                (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return folders.filter {
                (profile == nil || $0.lastPathComponent == profile) && FileManager.default.fileExists(atPath: $0.appending(path: "Login Data").path)
            }
        }

        /// Only one of its profiles.
        func only(_ folder: String) -> Source {
            var one = self
            one.profile = folder
            return one
        }

        /// A file in every profile that has it.
        func files(_ name: String) -> [URL] {
            profiles.map { $0.appending(path: name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    static let known: [Source] = [
        ("Dia", "Dia/User Data"), ("Chrome", "Google/Chrome"), ("Arc", "Arc/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"), ("Vivaldi", "Vivaldi"), ("Chromium", "Chromium"),
    ].map { name, folder in
        let account = name == "Edge" ? "Microsoft Edge" : name
        return Source(name: name, folder: folder, service: "\(account) Safe Storage", account: account)
    }

    /// The known browsers with a profile on this Mac.
    static func installed() -> [Source] {
        known.filter { !$0.profiles.isEmpty }
    }

    /// Its profiles' folders and the names the browser shows for them
    /// ("Local State"'s profile list), "Default" first.
    static func profileNames(in source: Source) -> [(folder: String, name: String)] {
        let state = (try? Data(contentsOf: source.root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let info = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
        return source.profiles.map(\.lastPathComponent)
            .sorted { ($0 == "Default" ? 0 : 1, $0) < ($1 == "Default" ? 0 : 1, $1) }
            .map { ($0, info[$0]?["name"] as? String ?? $0) }
    }

    enum Trouble: Error {
        /// macOS didn't hand over the password key.
        case noPassphrase
        case unreadable
    }

    // MARK: - Passwords

    static func read(_ source: Source) throws -> Chromium.Passwords {
        guard let passphrase = passphrase(for: source) else { throw Trouble.noPassphrase }
        let tables = source.files("Login Data").compactMap { file in
            try? SQLiteCopy.rows(
                of: file, "SELECT origin_url, username_value, password_value, blacklisted_by_user, date_last_used FROM logins"
            ) { row in
                Chromium.LoginRow(
                    origin: row.text(0), user: row.text(1), blob: row.blob(2), never: row.int(3) != 0, used: Chromium.date(row.int(4)))
            }
        }
        guard !tables.isEmpty else { throw Trouble.unreadable }
        return Chromium.passwords(in: tables.flatMap { $0 }, key: Chromium.key(passphrase: passphrase))
    }

    /// The "<Name> Safe Storage" passphrase. macOS asks before giving it out.
    private static func passphrase(for source: Source) -> String? {
        var found: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.service,
            kSecAttrAccount as String: source.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: - Bookmarks

    static func bookmarks(in source: Source) -> [Bookmark] {
        source.files("Bookmarks").flatMap { (try? Data(contentsOf: $0)).map(Chromium.bookmarks(json:)) ?? [] }
    }

    // MARK: - History

    struct Place {
        let url: URL
        let title: String
        let count: Int
        let last: Date
    }

    /// The most recent places across profiles, to seed address completion.
    static func places(in source: Source, limit: Int = 3000) -> [Place] {
        let sql =
            "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND visit_count > 0 ORDER BY last_visit_time DESC LIMIT \(limit)"
        let places = source.files("History").flatMap { file in
            (try? SQLiteCopy.rows(of: file, sql) { row -> Place? in
                guard let url = URL(string: row.text(0)), ["http", "https"].contains(url.scheme) else { return nil }
                return Place(url: url, title: row.text(1), count: max(1, Int(row.int(2))), last: Chromium.date(row.int(3)) ?? Date())
            })?.compactMap { $0 } ?? []
        }
        return Array(places.sorted { $0.last > $1.last }.prefix(limit))
    }

    // MARK: - Icons

    /// Icons by site from the profiles' "Favicons" databases: the biggest
    /// bitmap for the page, or else for the site's root.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        let sites = Chromium.iconSites(urls, limit: limit)
        var icons: [String: Data] = [:]
        guard !sites.isEmpty else { return icons }
        let sql = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ? AND b.width BETWEEN 16 AND 256 ORDER BY b.width DESC LIMIT 1
            """
        for file in source.files("Favicons") {
            try? SQLiteCopy.open(file) { database in
                for (host, url) in sites where icons[host] == nil {
                    for page in Chromium.iconPages(for: url) {
                        // Tiny blobs are placeholders, not icons.
                        if let data = database.first(sql, binding: page, { $0.blob(0) }), data.count > 60 {
                            icons[host] = data
                            break
                        }
                    }
                }
            }
        }
        return icons
    }
}
