import CoreGraphics
import Foundation
import Testing

@testable import MoteCore

@Suite("Logins")
struct LoginTests {
    /// "a.example.com" → "example.com": the last two labels.
    private func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }

    @Test("Logins for the host and the rest of its site, newest first")
    func matching() {
        let old = Date(timeIntervalSince1970: 1)
        let new = Date(timeIntervalSince1970: 2)
        let logins = [
            Login(host: "example.com", user: "wide", password: "x", used: new),
            Login(host: "accounts.example.com", user: "old", password: "x", used: old),
            Login(host: "accounts.example.com", user: "new", password: "x", used: new),
            Login(host: "other.com", user: "no", password: "x"),
        ]
        let found = Login.matching("accounts.example.com", in: logins, site: site)
        #expect(found.map(\.user) == ["wide", "new", "old"] || found.map(\.user) == ["new", "wide", "old"])
        #expect(!found.contains { $0.host == "other.com" })
    }

    @Test("The list is sorted by site, then account")
    func listed() {
        let logins = [
            Login(host: "b.com", user: "a", password: "x"), Login(host: "a.com", user: "z", password: "x"),
            Login(host: "a.com", user: "b", password: "x"),
        ]
        #expect(Login.listed(logins).map(\.id) == ["a.com\u{1}b", "a.com\u{1}z", "b.com\u{1}a"])
    }

    @Test("Typed sites become bare hosts")
    func typedHosts() {
        #expect(Address.siteHost(typed: " www.Example.com/login ") == "example.com")
        #expect(Address.siteHost(typed: "http://shop.test:8080/") == "shop.test")
        #expect(Address.siteHost(typed: "") == "")
    }
}

@Suite("CSV")
struct CSVTests {
    @Test("Quoted fields keep commas, doubled quotes and line breaks")
    func quoting() {
        let text = "a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"two\nlines\"\n"
        #expect(CSV.rows(text) == [["a", "b", "c"], ["x, y", #"say "hi""#, "two\nlines"]])
    }

    @Test("Blank lines are dropped and a last line without a break is kept")
    func blanks() {
        #expect(CSV.rows("a,b\n\n,\nc,d") == [["a", "b"], ["c", "d"]])
        #expect(CSV.rows("") == [])
    }
}

@Suite("Password exports")
struct PasswordExportTests {
    @Test("Chrome's export")
    func chrome() {
        let csv = "name,url,username,password,note\nGitHub,https://github.com/login,me,secret,\nOld,http://www.shop.test/,you,pw,\n"
        let result = PasswordExport.read(csv: csv)
        #expect(
            result.logins == [
                Login(host: "github.com", user: "me", password: "secret"),
                Login(host: "shop.test", user: "you", password: "pw", clear: true),
            ])
        #expect(result.skipped == 0)
    }

    @Test("Bitwarden's column names")
    func bitwarden() {
        let csv = "folder,favorite,type,name,notes,fields,login_uri,login_username,login_password\n,,login,X,,,https://x.com,u,p\n"
        #expect(PasswordExport.read(csv: csv).logins == [Login(host: "x.com", user: "u", password: "p")])
    }

    @Test("Rows without a site or password, or too short, are skipped")
    func skipped() {
        let csv = "url,username,password\n,u,p\nhttps://a.com,u,\nhttps://b.com\nhttps://c.com,u,p\n"
        let result = PasswordExport.read(csv: csv)
        #expect(result.logins.map(\.host) == ["c.com"])
        #expect(result.skipped == 3)
    }

    @Test("A file without the needed columns reads nothing")
    func unknown() {
        #expect(PasswordExport.read(csv: "a,b\n1,2\n3,4\n") == PasswordExport.Result(skipped: 2))
    }
}

@Suite("Form events")
struct FormEventTests {
    @Test("Messages from the forms script")
    func reading() {
        #expect(FormEvent(["kind": "submit", "user": "me", "password": "pw"]) == .sent(user: "me", password: "pw"))
        #expect(FormEvent(["kind": "submit"]) == .sent(user: "", password: ""))
        #expect(FormEvent(["kind": "settled"]) == .settled)
        #expect(
            FormEvent(["kind": "focus", "typing": true, "rect": ["x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0]])
                == .focus(typing: true, field: CGRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(FormEvent(["kind": "focus", "rect": ["x": 1.0]]) == .focus(typing: false, field: nil))
        #expect(
            FormEvent(["kind": "focus", "typing": true, "contact": ["x": 5.0, "y": 6.0, "w": 7.0, "h": 8.0]])
                == .focus(typing: true, field: nil, contact: CGRect(x: 5, y: 6, width: 7, height: 8)))
        #expect(FormEvent(["kind": "fullscreen", "on": true]) == .fullscreen(true))
        #expect(FormEvent(["kind": "menu", "field": "password"]) == .menu(.password))
        #expect(FormEvent(["kind": "menu", "field": "user"]) == .menu(.user))
        #expect(FormEvent(["kind": "menu", "field": "other"]) == .menu(nil))
        #expect(FormEvent(["kind": "menu"]) == .menu(nil))
    }

    @Test("Anything else is ignored")
    func unknown() {
        #expect(FormEvent(["kind": "form"]) == nil)
        #expect(FormEvent("nonsense") == nil)
    }
}

@Suite("Strong passwords")
struct StrongPasswordTests {
    @Test("Three groups of six, with one capital and one digit")
    func shape() {
        for _ in 0..<200 {
            let made = StrongPassword.make()
            let groups = made.split(separator: "-")
            #expect(groups.count == 3 && groups.allSatisfy { $0.count == 6 })
            let characters = made.filter { $0 != "-" }
            #expect(characters.filter(\.isUppercase).count == 1)
            #expect(characters.filter(\.isNumber).count == 1)
            #expect(!characters.contains { "lIoO01".contains($0) })
        }
    }

    @Test("Never the same twice")
    func fresh() {
        #expect(Set((0..<100).map { _ in StrongPassword.make() }).count == 100)
    }
}
