import AppKit
import MoteCore
import UniformTypeIdentifiers

/// What can come over from another browser.
enum ImportKind: String, CaseIterable, Identifiable, Hashable {
    case bookmarks, history, passwords
    /// Zen's own: spaces with their essentials, pinned and open tabs, split
    /// views and colours.
    case spaces
    case shortcuts
    /// The same extensions, from their stores.
    case addOns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .passwords: "Passwords"
        case .spaces: "Spaces and tabs"
        case .shortcuts: "Keyboard shortcuts"
        case .addOns: "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .bookmarks: "book"
        case .history: "clock.arrow.circlepath"
        case .passwords: "key"
        case .spaces: "square.stack"
        case .shortcuts: "command"
        case .addOns: "puzzlepiece.extension"
        }
    }
}

/// Somewhere to import from: a browser's profile, of one of the families Mote
/// reads (Chromium, Firefox, Safari), or a file. A browser built on one of
/// them with things of its own, Zen so far, is the family plus a bolt-on.
struct ImportSource: Identifiable, Hashable {
    enum Family: Hashable {
        case chromium(ChromiumImporter.Source)
        /// A Firefox-family profile's folder.
        case firefox(URL)
        /// What Safari's File › Export Browsing Data writes, picked when importing.
        case safari
        case passwordsFile
        case bookmarksFile
    }

    let id: String
    /// The browser, and the profile when it has more than one.
    let name: String
    let browser: String
    let bundle: String?
    let family: Family
    var zen: ZenImporter.Profile?

    var kinds: [ImportKind] {
        switch family {
        case .chromium, .firefox: [.bookmarks, .history, .passwords] + (zen == nil ? [] : [.spaces, .shortcuts]) + Self.extensions
        case .safari: [.bookmarks, .history, .passwords]
        case .passwordsFile: [.passwords]
        case .bookmarksFile: [.bookmarks]
        }
    }

    /// Extensions run from macOS 15.4.
    private static var extensions: [ImportKind] {
        if #available(macOS 15.4, *) { return [.addOns] }
        return []
    }

    /// Its extensions that came from a store, to install here (as WebKit can
    /// run them: see AddOns.Found.forWebKit). Names and store ids only.
    var addOns: [AddOns.Found] {
        let found: [AddOns.Found]
        switch family {
        case .firefox(let folder):
            found = (try? Data(contentsOf: folder.appending(path: "extensions.json"))).map(AddOns.firefox) ?? []
        case .chromium(let chromium):
            found = chromium.profiles.flatMap { profile in
                let preferences = ["Secure Preferences", "Preferences"].lazy
                    .compactMap { try? Data(contentsOf: profile.appending(path: $0)) }
                    .map { AddOns.chromium(preferences: $0, name: { Self.folderName(of: $0, in: profile) }) }
                    .first { !$0.isEmpty }
                return preferences ?? []
            }
        default:
            found = []
        }
        var seen = Set<String>()
        return found.map(\.forWebKit).filter { seen.insert($0.id).inserted }
    }

    /// An extension's name from its newest folder in a Chromium profile.
    private static func folderName(of id: String, in profile: URL) -> String? {
        let versions = profile.appending(path: "Extensions/\(id)", directoryHint: .isDirectory)
        guard let newest = (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil))?.max(by: {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
        }), let manifest = try? Data(contentsOf: newest.appending(path: "manifest.json"))
        else { return nil }
        return AddOns.name(manifest: manifest) { try? Data(contentsOf: newest.appending(path: "_locales/\($0)/messages.json")) }
    }

    /// A browser rather than a file, so it can be brought into a profile of its own.
    var isBrowser: Bool {
        switch family {
        case .passwordsFile, .bookmarksFile: false
        default: true
        }
    }

    var icon: NSImage {
        if let bundle, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return NSWorkspace.shared.icon(forFile: app.path)
        }
        return NSWorkspace.shared.icon(for: family == .passwordsFile ? .commaSeparatedText : .html)
    }

    /// The Firefox-family browsers Mote knows, by their folder in Application Support.
    private static let firefoxes = [
        ("Firefox", "Firefox", "org.mozilla.firefox"), ("Zen", "zen", "app.zen-browser.zen"),
        ("LibreWolf", "librewolf", "io.gitlab.librewolf-community"), ("Floorp", "Floorp", "one.ablaze.floorp"),
        ("Waterfox", "Waterfox", "net.waterfox.waterfox"),
    ]

    private static let chromiumBundles = [
        "Dia": "company.thebrowser.dia", "Chrome": "com.google.Chrome", "Arc": "company.thebrowser.Browser",
        "Brave": "com.brave.Browser", "Edge": "com.microsoft.edgemac", "Vivaldi": "com.vivaldi.Vivaldi",
        "Chromium": "org.chromium.Chromium",
    ]

    /// Every browser profile on this Mac Mote can read, the Mac's default
    /// browser first; then Safari, through its export; then files.
    static func found() -> [ImportSource] {
        var browsers: [ImportSource] = []
        for source in ChromiumImporter.installed() {
            let profiles = ChromiumImporter.profileNames(in: source)
            for (folder, profile) in profiles {
                browsers.append(
                    ImportSource(
                        id: "chromium:\(source.name):\(folder)", name: profiles.count > 1 ? "\(source.name) — \(profile)" : source.name,
                        browser: source.name, bundle: chromiumBundles[source.name], family: .chromium(source.only(folder))))
            }
        }
        let zens = ZenImporter.profiles()
        for (name, folder, bundle) in firefoxes {
            let profiles = firefoxProfiles(in: folder)
            for (profile, path) in profiles {
                browsers.append(
                    ImportSource(
                        id: "firefox:\(path.path)", name: profiles.count > 1 ? "\(name) — \(profile)" : name, browser: name, bundle: bundle,
                        family: .firefox(path), zen: name == "Zen" ? zens.first { $0.folder.standardizedFileURL == path.standardizedFileURL } : nil))
            }
        }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        browsers.sort { ($0.bundle == preferred ? 0 : 1) < ($1.bundle == preferred ? 0 : 1) }
        let safari = ImportSource(id: "safari", name: "Safari", browser: "Safari", bundle: "com.apple.Safari", family: .safari)
        let files = [
            ImportSource(id: "file:passwords", name: "Passwords from CSV file", browser: "a file", bundle: nil, family: .passwordsFile),
            ImportSource(id: "file:bookmarks", name: "Bookmarks from HTML file", browser: "a file", bundle: nil, family: .bookmarksFile),
        ]
        return preferred == "com.apple.Safari" ? [safari] + browsers + files : browsers + [safari] + files
    }

    /// A Firefox-family browser's profiles that have something to bring, the default first.
    private static func firefoxProfiles(in folder: String) -> [(String, URL)] {
        let root = URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
        guard let list = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
        let installs = try? String(contentsOf: root.appending(path: "installs.ini"), encoding: .utf8)
        return FirefoxProfiles.parse(profiles: list, installs: installs)
            .sorted { $0.isDefault && !$1.isDefault }
            .compactMap { found in
                let path = found.isRelative ? root.appending(path: found.path, directoryHint: .isDirectory) : URL(fileURLWithPath: found.path)
                let has = ["places.sqlite", "logins.json"].contains { FileManager.default.fileExists(atPath: path.appending(path: $0).path) }
                return has ? (found.name, path) : nil
            }
    }
}

/// What came over.
struct ImportTally: Equatable {
    var bookmarks = 0
    var history = 0
    var passwords = 0
    var spaces = 0
    var tabs = 0
    var shortcuts = false
    var addOns = 0

    var summary: String {
        var parts: [String] = []
        if bookmarks > 0 { parts.append("\(bookmarks) bookmarks") }
        if history > 0 { parts.append("\(history) pages of history") }
        if passwords > 0 { parts.append("\(passwords) passwords") }
        if spaces > 0 { parts.append("\(spaces) spaces with \(tabs) tabs") }
        if shortcuts { parts.append("keyboard shortcuts") }
        if addOns > 0 { parts.append(addOns == 1 ? "1 extension" : "\(addOns) extensions") }
        return parts.isEmpty ? "Nothing new to bring." : ListFormatter.localizedString(byJoining: parts) + "."
    }
}

enum ImportTrouble: Error, Equatable {
    /// Firefox's passwords are locked with a primary password; this isn't it.
    case primaryPassword
    /// macOS didn't hand over a Chromium browser's password key.
    case locked
    case unreadable
}

extension Browser {
    /// Brings `kinds` over from `source`. Safari and the files need `file`:
    /// Safari's export (its folder or zip), or the file itself. Nothing in the
    /// other browser changes.
    func bring(_ kinds: Set<ImportKind>, from source: ImportSource, file: URL? = nil, primaryPassword: String = "")
        async throws -> ImportTally
    {
        var tally = ImportTally()
        switch source.family {
        case .chromium(let chromium):
            if kinds.contains(.bookmarks) { tally.bookmarks = takeBookmarks(from: chromium, saying: false) }
            if kinds.contains(.history) { tally.history = await takePlaces(from: chromium) }
            if kinds.contains(.passwords) {
                switch await logins.bring(from: chromium) {
                case .success(let kept): tally.passwords = kept
                case .failure(.locked): throw ImportTrouble.locked
                case .failure: break
                }
            }
        case .firefox(let folder):
            if kinds.contains(.passwords) {
                let found = try await Task.detached(priority: .userInitiated) {
                    try Self.firefoxLogins(in: folder, primaryPassword: primaryPassword)
                }.value
                tally.passwords = found.filter { login in
                    PasswordStore.save(
                        host: Address.siteHost(typed: login.site), user: login.user, password: login.password, used: login.used,
                        clear: login.site.lowercased().hasPrefix("http://"))
                }.count
                logins.reload()
            }
            let places = folder.appending(path: "places.sqlite")
            if kinds.contains(.bookmarks) {
                let rows = (try? SQLiteCopy.rows(of: places, FirefoxPlaces.bookmarksSQL) { row in
                    FirefoxPlaces.Row(
                        id: row.int(0), parent: row.int(1), type: row.int(2), title: row.text(3), url: row.text(4), guid: row.text(5))
                }) ?? []
                tally.bookmarks = take(FirefoxPlaces.bookmarks(rows), from: source.browser)
            }
            if kinds.contains(.history) {
                let visits = (try? SQLiteCopy.rows(of: places, FirefoxPlaces.historySQL) { row in
                    URL(string: row.text(0)).map { Visit(url: $0, title: row.text(1), count: Int(max(1, row.int(2))), last: FirefoxPlaces.date(row.int(3))) }
                })?.compactMap { $0 } ?? []
                tally.history = take(visits)
            }
        case .safari:
            guard let file else { throw ImportTrouble.unreadable }
            let folder = try Self.unpacked(file)
            func find(_ name: String) -> URL? {
                FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
            }
            if kinds.contains(.bookmarks), let html = find("Bookmarks.html").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
                tally.bookmarks = take(NetscapeBookmarks.read(html: html), from: "Safari")
            }
            if kinds.contains(.history), let json = find("History.json").flatMap({ try? Data(contentsOf: $0) }) {
                tally.history = take(SafariExport.history(json: json))
            }
            if kinds.contains(.passwords), let csv = find("Passwords.csv").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
                tally.passwords = PasswordStore.take(csv: csv).kept
                logins.reload()
            }
        case .passwordsFile:
            guard let file, let csv = try? String(contentsOf: file, encoding: .utf8) else { throw ImportTrouble.unreadable }
            tally.passwords = PasswordStore.take(csv: csv).kept
            logins.reload()
        case .bookmarksFile:
            guard let file, let html = try? String(contentsOf: file, encoding: .utf8) else { throw ImportTrouble.unreadable }
            tally.bookmarks = take(NetscapeBookmarks.read(html: html), from: file.deletingPathExtension().lastPathComponent)
        }
        if kinds.contains(.addOns), #available(macOS 15.4, *) {
            // Agreed to as a whole by the switch, which lists them: no question each.
            let found = source.addOns
            for addOn in found {
                switch addOn.store {
                case .chrome: Extensions.shared.install(from: addOn.id, agreed: true)
                case .firefox: Extensions.shared.installFirefox(addOn.id, agreed: true)
                }
            }
            tally.addOns = found.count
        }
        if let zen = source.zen {
            if kinds.contains(.spaces), let plan = try? ZenImporter.plan(for: zen) {
                let brought = importZen(plan)
                tally.spaces = brought.spaces
                tally.tabs = brought.tabs
            }
            if kinds.contains(.shortcuts), let keys = ZenImporter.shortcuts(in: zen) {
                prefs.shortcuts = keys
                tally.shortcuts = true
            }
        }
        return tally
    }

    private func take(_ found: [Bookmark], from browser: String) -> Int {
        bookmarks.take(found, from: browser)
        return BookmarkTree.count(found)
    }

    private func take(_ visits: [Visit]) -> Int {
        for visit in visits { history.merge(visit.url, title: visit.title, count: visit.count, last: visit.last) }
        history.scheduleSave()
        return visits.count
    }

    /// A Firefox-family profile's passwords, decrypted.
    nonisolated private static func firefoxLogins(in folder: URL, primaryPassword: String) throws -> [FirefoxLogins.Login] {
        let database = folder.appending(path: "key4.db")
        guard
            let check = try? SQLiteCopy.rows(of: database, "SELECT item1, item2 FROM metadata WHERE id = 'password'", { ($0.blob(0), $0.blob(1)) })
                .first,
            let keys = try? SQLiteCopy.rows(of: database, "SELECT a11, a102 FROM nssPrivate", { (key: $0.blob(0), id: $0.blob(1)) }),
            let json = try? Data(contentsOf: folder.appending(path: "logins.json"))
        else { return [] }
        do {
            let unlocked = try FirefoxLogins.keys(.init(globalSalt: check.0, check: check.1, keys: keys), primaryPassword: primaryPassword)
            return FirefoxLogins.logins(json: json, keys: unlocked)
        } catch FirefoxLogins.Trouble.primaryPassword {
            throw ImportTrouble.primaryPassword
        } catch {
            throw ImportTrouble.unreadable
        }
    }

    /// Safari's export as a folder: as chosen, or its zip unpacked.
    nonisolated private static func unpacked(_ file: URL) throws -> URL {
        guard file.pathExtension.lowercased() == "zip" else { return file }
        let folder = FileManager.default.temporaryDirectory.appending(path: "mote-safari-\(UUID().uuidString)")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, folder.path]
        guard (try? unzip.run()) != nil else { throw ImportTrouble.unreadable }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ImportTrouble.unreadable }
        return folder
    }
}
