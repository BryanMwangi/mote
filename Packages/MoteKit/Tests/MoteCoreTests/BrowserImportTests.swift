import Foundation
import SQLite3
import Testing

@testable import MoteCore

@Suite("Importing from other browsers, on their real files")
struct BrowserImportTests {
    private static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    private func file(_ path: String) -> URL { Self.fixtures.appending(path: path) }

    /// key4.db's rows, as the app reads them.
    private func store(_ profile: String) throws -> FirefoxLogins.KeyStore {
        let db = file("\(profile)/key4.db")
        let check = try SQLiteCopy.rows(of: db, "SELECT item1, item2 FROM metadata WHERE id = 'password'") { ($0.blob(0), $0.blob(1)) }
        let keys = try SQLiteCopy.rows(of: db, "SELECT a11, a102 FROM nssPrivate") { (key: $0.blob(0), id: $0.blob(1)) }
        let first = try #require(check.first)
        return FirefoxLogins.KeyStore(globalSalt: first.0, check: first.1, keys: keys)
    }

    /// firefox_decrypt's own export of the same logins.
    private func expected() throws -> Set<[String]> {
        let rows = CSV.rows(try String(contentsOf: file("firefox_expected_passwords.csv"), encoding: .utf8)).dropFirst()
        return Set(rows.map { Array($0.prefix(3)) })
    }

    private func logins(_ profile: String, password: String = "") throws -> Set<[String]> {
        let keys = try FirefoxLogins.keys(store(profile), primaryPassword: password)
        let found = FirefoxLogins.logins(json: try Data(contentsOf: file("\(profile)/logins.json")), keys: keys)
        return Set(found.map { [$0.site, $0.user, $0.password] })
    }

    @Test("Firefox 114's passwords decrypt with no primary password (PBES2, 3DES)")
    func firefoxPlain() throws {
        // This profile has one login more than the export lists.
        #expect(try logins("firefox_nopassword_114") == expected().union([["https://github.com", "john", "john"]]))
    }

    @Test("Firefox 144's need its primary password, and its logins are AES")
    func firefoxPrimary() throws {
        #expect(throws: FirefoxLogins.Trouble.primaryPassword) { try FirefoxLogins.keys(store("firefox_144")) }
        let password = try String(contentsOf: file("firefox_144/primary_password.txt"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        #expect(try logins("firefox_144", password: password) == expected())
    }

    @Test("Safari's exported bookmarks: favourites at the top, an empty reading list left out")
    func safariBookmarks() throws {
        let found = NetscapeBookmarks.read(html: try String(contentsOf: file("safari_export/Bookmarks.html"), encoding: .utf8))
        #expect(found.map(\.title) == ["Apple", "Bing", "Google", "Yahoo", "iPhone User Guide"])
        #expect(found[2].url == "https://www.google.ca/?client=safari&channel=iphone_bm")
    }

    @Test("Safari's exported history: each page once, at its last visit")
    func safariHistory() throws {
        let visits = SafariExport.history(json: try Data(contentsOf: file("safari_export/History.json")))
        #expect(visits.count == 6)
        #expect(visits.first { $0.url.absoluteString == "https://example.com/" }?.count == 6)
        #expect(visits.first { $0.url.absoluteString == "https://sebsg.github.io/" }?.title == "sebsg.github.io")
    }

    @Test("Safari's exported passwords: the ones with a site")
    func safariPasswords() throws {
        let read = PasswordExport.read(csv: try String(contentsOf: file("safari_export/Passwords.csv"), encoding: .utf8))
        #expect(read.logins.map(\.user) == ["Barackalypse", "Homer_Simpson", "Superman"])
        #expect(read.skipped == 1)
    }

    @Test("Firefox's places: the toolbar on top, the menu as a folder, history newest first")
    func firefoxPlaces() throws {
        let db = FileManager.default.temporaryDirectory.appending(path: "places-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(db.path, &handle) == SQLITE_OK)
        // Firefox's own tables, with the columns the importer reads.
        let sql = """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0,
              hidden INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
              position INTEGER, title LONGVARCHAR, guid TEXT);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.org/', 'Mozilla', 3, 0, 1700000000000000),
              (2, 'https://example.com/', 'Example', 1, 0, 1710000000000000), (3, 'place:sort=8', NULL, 0, 1, NULL);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________'),
              (2, 2, NULL, 1, 0, 'menu', 'menu________'), (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____'),
              (4, 2, NULL, 1, 2, 'unfiled', 'unfiled_____'), (5, 1, 1, 3, 0, 'Mozilla', 'a'),
              (6, 2, NULL, 3, 1, 'Work', 'b'), (7, 1, 2, 6, 0, 'Example', 'c'), (8, 1, 3, 2, 0, 'Recent', 'd'),
              (9, 3, NULL, 2, 1, '', 'e'), (10, 1, 2, 2, 2, 'Example again', 'f');
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let rows = try SQLiteCopy.rows(of: db, FirefoxPlaces.bookmarksSQL) { row in
            FirefoxPlaces.Row(
                id: row.int(0), parent: row.int(1), type: row.int(2), title: row.text(3), url: row.text(4), guid: row.text(5))
        }
        let tree = FirefoxPlaces.bookmarks(rows)
        #expect(tree.map(\.title) == ["Mozilla", "Work", "Bookmarks Menu"])
        #expect(tree[1].children?.map(\.title) == ["Example"])
        // Not the internal place: query, nor the separator.
        #expect(tree[2].children?.map(\.title) == ["Example again"])
        let history = try SQLiteCopy.rows(of: db, FirefoxPlaces.historySQL) { ($0.text(0), FirefoxPlaces.date($0.int(3))) }
        #expect(history.map(\.0) == ["https://example.com/", "https://mozilla.org/"])
        #expect(history[1].1 == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
