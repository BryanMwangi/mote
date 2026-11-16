import Foundation
import Testing

@testable import MoteCore

@Suite("ProxyRules")
struct ProxyRulesTests {
    private func server(_ kind: ProxyServer.Kind, _ host: String, _ port: UInt16) -> ProxyServer {
        ProxyServer(kind: kind, host: host, port: port)
    }

    // Chromium's ProxyListTest.SetFromPacString, as Network can follow it.
    @Test("PAC answers read as Chromium reads them")
    func pacAnswers() {
        #expect(ProxyRules.pacEntries("PROXY foopy:10") == [.proxy(server(.http, "foopy", 10))])
        #expect(ProxyRules.pacEntries(" DIRECT") == [.direct])
        #expect(
            ProxyRules.pacEntries("PROXY foopy1 ; proxy foopy2;\t DIRECT")
                == [.proxy(server(.http, "foopy1", 80)), .proxy(server(.http, "foopy2", 80)), .direct])
        #expect(
            ProxyRules.pacEntries("proxy foopy1 ; SOCKS5 foopy2")
                == [.proxy(server(.http, "foopy1", 80)), .proxy(server(.socks, "foopy2", 1080))])
        #expect(ProxyRules.pacEntries("HTTPS foopy:443") == [.proxy(server(.https, "foopy", 443))])
        #expect(ProxyRules.pacEntries("HTTP foopy") == [.proxy(server(.http, "foopy", 80))])
        // Nothing it can read is DIRECT.
        #expect(ProxyRules.pacEntries("PROXY-foopy:10") == [.direct])
        #expect(ProxyRules.pacEntries("PROXY foopy:10 junk") == [.direct])
        #expect(ProxyRules.pacEntries("DIRECT x") == [.direct])
        #expect(ProxyRules.pacEntries("") == [.direct])
        // A bad entry is skipped, the next taken.
        #expect(ProxyRules.pacEntries("BOGUS foopy; PROXY b:1") == [.proxy(server(.http, "b", 1))])
        #expect(ProxyRules.pacEntries("PROXY a:99999; PROXY b:1") == [.proxy(server(.http, "b", 1))])
    }

    @Test("SOCKS reads as Firefox's SOCKS 5; SOCKS4 and QUIC, which Network can't speak, are passed over")
    func pacSocks() {
        #expect(ProxyRules.pacAnswer("SOCKS s:1080") == .proxy(server(.socks, "s", 1080)))
        #expect(ProxyRules.pacAnswer("SOCKS4 s:1080; PROXY p:3128") == .proxy(server(.http, "p", 3128)))
        #expect(ProxyRules.pacAnswer("QUIC q:443; HTTPS h:443") == .proxy(server(.https, "h", 443)))
        // A VPN's country list: the first server.
        #expect(
            ProxyRules.pacAnswer("HTTPS nl1.vpn.example:443; HTTPS nl2.vpn.example:443") == .proxy(server(.https, "nl1.vpn.example", 443)))
    }

    @Test("IPv6 proxies keep their address")
    func pacIPv6() {
        #expect(ProxyRules.pacAnswer("PROXY [::1]:3128") == .proxy(server(.http, "::1", 3128)))
    }

    // Chromium's proxy_api_helpers_unittest: each mode of a setting.
    @Test("chrome.proxy.settings modes")
    func modes() {
        #expect(ProxyRules.setting(["mode": "direct"]) == .none)
        #expect(ProxyRules.setting(["mode": "system"]) == .none)
        #expect(ProxyRules.setting(["mode": "auto_detect"]) == .none)
        #expect(ProxyRules.setting(nil) == .none)
        #expect(
            ProxyRules.setting(["mode": "pac_script", "pacScript": ["data": "function FindProxyForURL(){}"]])
                == .pac(data: "function FindProxyForURL(){}", url: nil))
        #expect(
            ProxyRules.setting(["mode": "pac_script", "pacScript": ["url": "http://wpad/wpad.dat"]])
                == .pac(data: nil, url: "http://wpad/wpad.dat"))
        #expect(ProxyRules.setting(["mode": "pac_script", "pacScript": [:] as [String: Any]]) == .none)
    }

    @Test("fixed_servers: one proxy for all, else HTTPS's, the fallback, then HTTP's")
    func fixedServers() {
        let single: [String: Any] = [
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["scheme": "https", "host": "vpn.example", "port": 443], "bypassList": ["<local>", "*.lan"]],
        ]
        #expect(ProxyRules.setting(single) == .fixed(ProxyChoice(server: server(.https, "vpn.example", 443), bypass: ["lan"])))
        let perScheme: [String: Any] = [
            "mode": "fixed_servers",
            "rules": ["proxyForHttp": ["host": "h"], "proxyForHttps": ["scheme": "socks5", "host": "s"]],
        ]
        #expect(ProxyRules.setting(perScheme) == .fixed(ProxyChoice(server: server(.socks, "s", 1080))))
        let fallback: [String: Any] = ["mode": "fixed_servers", "rules": ["fallbackProxy": ["host": "f", "port": 8080]]]
        #expect(ProxyRules.setting(fallback) == .fixed(ProxyChoice(server: server(.http, "f", 8080))))
        // SOCKS 4, which Network can't speak, and nonsense.
        #expect(ProxyRules.setting(["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "socks4", "host": "s"]]]) == .none)
        #expect(ProxyRules.setting(["mode": "fixed_servers", "rules": ["singleProxy": ["host": ""]]]) == .none)
        #expect(ProxyRules.setting(["mode": "fixed_servers", "rules": ["singleProxy": ["host": "h", "port": 0]]]) == .none)
    }

    // Firefox's test_ext_proxy_settings.js values.
    @Test("A Firefox add-on's proxy.settings")
    func firefox() {
        let manual: [String: Any] = [
            "proxyType": "manual", "http": "www.mozilla.org:8080", "httpProxyAll": true, "passthrough": "localhost, .example.org",
        ]
        #expect(
            ProxyRules.setting(manual)
                == .fixed(ProxyChoice(server: server(.http, "www.mozilla.org", 8080), bypass: ["localhost", "example.org"])))
        let socks: [String: Any] = ["proxyType": "manual", "socks": "s.example:1081", "socksVersion": 5]
        #expect(ProxyRules.setting(socks) == .fixed(ProxyChoice(server: server(.socks, "s.example", 1081))))
        #expect(ProxyRules.setting(["proxyType": "manual", "socks": "s.example", "socksVersion": 4]) == .none)
        #expect(
            ProxyRules.setting(["proxyType": "autoConfig", "autoConfigUrl": "http://a/p.pac"]) == .pac(data: nil, url: "http://a/p.pac"))
        #expect(ProxyRules.setting(["proxyType": "none"]) == .none)
        #expect(ProxyRules.setting(["proxyType": "system"]) == .none)
    }

    // Chromium's ProxyBypassRules cases that Network can follow.
    @Test("Bypass entries as the domains Network takes")
    func bypass() {
        #expect(ProxyRules.domain(bypassing: "*.google.com") == "google.com")
        #expect(ProxyRules.domain(bypassing: ".google.com") == "google.com")
        #expect(ProxyRules.domain(bypassing: "http://www.google.com:80") == "www.google.com")
        #expect(ProxyRules.domain(bypassing: "WWW.Example.COM") == "www.example.com")
        #expect(ProxyRules.domain(bypassing: "[::1]") == "[::1]")
        #expect(ProxyRules.domain(bypassing: "<local>") == nil)
        #expect(ProxyRules.domain(bypassing: "192.168.1.1/16") == nil)
        #expect(ProxyRules.domain(bypassing: "*foo*") == nil)
        // A browser's own pages, which never reach a proxy.
        #expect(ProxyRules.domain(bypassing: "chrome://newtab/") == nil)
        #expect(ProxyRules.domain(bypassing: "chrome-extension://*") == nil)
        #expect(ProxyRules.domain(bypassing: "about:blank") == nil)
    }

    // Chromium's ProxyBypassRules and proxy_config_unittest: what goes direct.
    @Test("What goes direct: the Mac itself, and bypass domains and what's under them")
    func goesDirect() {
        #expect(ProxyRules.bypasses("localhost", []))
        #expect(ProxyRules.bypasses("127.0.0.1", []))
        #expect(ProxyRules.bypasses("[::1]", []))
        #expect(ProxyRules.bypasses("app.localhost", []))
        #expect(!ProxyRules.bypasses("example.com", []))
        #expect(ProxyRules.bypasses("google.com", ["google.com"]))
        #expect(ProxyRules.bypasses("maps.google.com", ["google.com"]))
        #expect(ProxyRules.bypasses("MAPS.Google.com", ["google.com"]))
        #expect(!ProxyRules.bypasses("notgoogle.com", ["google.com"]))
        #expect(!ProxyRules.bypasses("google.com.evil", ["google.com"]))
    }

    @Test("A CONNECT's target")
    func target() {
        #expect(ProxyRules.target("example.com:443")! == ("example.com", 443))
        #expect(ProxyRules.target("[2001:db8::1]:8443")! == ("2001:db8::1", 8443))
        #expect(ProxyRules.target("example.com") == nil)
        #expect(ProxyRules.target(":443") == nil)
        #expect(ProxyRules.target("example.com:0") == nil)
        #expect(ProxyRules.target("example.com:99999") == nil)
    }

    // Chromium's proxy_apitest and Firefox's ExtensionSettingsStore: the
    // newest install's setting is in effect.
    @Test("The newest install holds the setting, and the others are told so")
    func precedence() {
        let dates = ["old": Date(timeIntervalSince1970: 100), "new": Date(timeIntervalSince1970: 200)]
        let at = { (id: String) in dates[id] ?? .distantPast }
        #expect(ProxyRules.holder(of: ["old", "new"], installedAt: at) == "new")
        #expect(ProxyRules.holder(of: ["old"], installedAt: at) == "old")
        #expect(ProxyRules.holder(of: [String](), installedAt: at) == nil)
        #expect(ProxyRules.levelOfControl(for: "new", holder: "new", installedAt: at) == "controlled_by_this_extension")
        #expect(ProxyRules.levelOfControl(for: "old", holder: "new", installedAt: at) == "controlled_by_other_extensions")
        #expect(ProxyRules.levelOfControl(for: "old", holder: nil, installedAt: at) == "controllable_by_this_extension")
        // A newer one may take it from an older holder.
        #expect(ProxyRules.levelOfControl(for: "new", holder: "old", installedAt: at) == "controllable_by_this_extension")
    }

    @Test("A sign-in is kept under the server, whatever its case")
    func key() {
        #expect(server(.https, "VPN.example", 443).key == "https://vpn.example:443")
    }
}
