import Foundation
import MoteCore
import Testing

@testable import Mote

/// PAC scripts as extensions set them, run as Mote runs them.
@Suite("ExtensionPAC")
struct ExtensionPACTests {
    /// What `script` answers for `host`, through Mote's PAC functions.
    private func answer(_ body: String, _ host: String = "www.example.com") -> PACEntry? {
        ExtensionPAC.Run("function FindProxyForURL(url, host) { \(body) }")?.ask(host)
    }

    private func truth(_ expression: String) -> Bool {
        answer("return (\(expression)) ? 'PROXY yes:1' : 'DIRECT';") == .proxy(ProxyServer(kind: .http, host: "yes", port: 1))
    }

    // Chromium's pac_library_unittest and proxy_resolver_v8 pac_library_unittest.js cases.
    @Test("The functions every PAC script may call")
    func library() {
        #expect(truth("isPlainHostName('www')"))
        #expect(!truth("isPlainHostName('www.google.com')"))
        #expect(truth("dnsDomainIs('google.com', '.com')"))
        #expect(truth("dnsDomainIs('google.co.uk', '.co.uk')"))
        #expect(!truth("dnsDomainIs('google.com', '.co.uk')"))
        #expect(!truth("dnsDomainIs('www.adobe.com', '.ad')"))
        #expect(truth("localHostOrDomainIs('www.google.com', 'www.google.com')"))
        #expect(truth("localHostOrDomainIs('www', 'www.google.com')"))
        #expect(!truth("localHostOrDomainIs('maps.google.com', 'www.google.com')"))
        #expect(truth("dnsDomainLevels('www.google.com') == 2"))
        #expect(truth("dnsDomainLevels('www') == 0"))
        #expect(truth("shExpMatch('foo.jpg', '*.jpg')"))
        #expect(truth("shExpMatch('foo5.jpg', 'foo?.jpg')"))
        #expect(!truth("shExpMatch('foo.jpg', '.jpg')"))
        #expect(!truth("shExpMatch('foo.com', 'foo.co?m')"))
        #expect(truth("shExpMatch('http://maps.google.com/x', '*.google.com/*')"))
        #expect(truth("isInNet('192.89.132.25', '192.89.132.25', '255.255.255.255')"))
        #expect(!truth("isInNet('192.89.132.25', '192.89.132.24', '255.255.255.255')"))
        #expect(truth("isInNet('192.89.132.25', '192.89.0.0', '255.255.0.0')"))
        #expect(!truth("isInNet('193.89.132.25', '192.89.0.0', '255.255.0.0')"))
        #expect(!truth("isInNet('256.0.0.1', '0.0.0.0', '0.0.0.0')"))
        #expect(truth("isInNetEx('198.95.249.79', '198.95.0.0/16')"))
        #expect(!truth("isInNetEx('198.94.249.79', '198.95.0.0/16')"))
        #expect(truth("isInNetEx('fe80::1', 'fe80::/10')"))
        #expect(!truth("isInNetEx('2001:db8::1', 'fc00::/7')"))
        #expect(truth("dnsResolve('127.0.0.1') == '127.0.0.1'"))
        #expect(truth("typeof myIpAddress() == 'string'"))
        #expect(truth("sortIpAddressList('10.2.3.9;10.2.3.8') == '10.2.3.8;10.2.3.9'"))
        #expect(truth("weekdayRange('SUN', 'SAT')"))
        #expect(truth("timeRange(0, 23)"))
        #expect(truth("dateRange('JAN', 'DEC')"))
    }

    @Test("A script that fails, answers nonsense or has no FindProxyForURL is none")
    func broken() {
        #expect(answer("throw 'no';") == nil)
        #expect(answer("return 42;") == nil)
        #expect(ExtensionPAC.Run("var x = 1;") == nil)
        #expect(ExtensionPAC.Run("function FindProxyForURL( {") == nil)
        #expect(answer("return 'GARBAGE';") == .direct)
    }

    @Test("A script that never ends is stopped")
    func endless() {
        let started = Date()
        #expect(answer("while (true) {}") == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("FindProxyForURLEx is preferred, as in Chromium")
    func ex() {
        let run = ExtensionPAC.Run(
            "function FindProxyForURL() { return 'PROXY a:1'; } function FindProxyForURLEx() { return 'PROXY b:2'; }")
        #expect(run?.ask("x.com") == .proxy(ProxyServer(kind: .http, host: "b", port: 2)))
    }

    // Shaped as a VPN's: countries with servers to try in turn, sites that
    // go direct, sites sent to another country, private addresses direct.
    @Test("A VPN's PAC script, asked per host")
    func vpn() {
        let run = ExtensionPAC.Run(
            #"""
            const countries = {"us": "HTTPS us1.vpn.example:443; HTTPS us2.vpn.example:443", "nl": "HTTPS nl.vpn.example:443"};
            const ignore = ["bank.example"];
            const filters = [{value: "tv.example", country: "nl"}];
            function FindProxyForURL(url, host) {
              if (isPlainHostName(host) || isInNet(host, "10.0.0.0", "255.0.0.0")) return "DIRECT";
              if (ignore.some(d => host === d || dnsDomainIs(host, "." + d))) return "DIRECT";
              const f = filters.find(f => host === f.value || host.endsWith("." + f.value));
              return f ? countries[f.country] : countries["us"];
            }
            """#)
        let us1 = ProxyServer(kind: .https, host: "us1.vpn.example", port: 443)
        let us2 = ProxyServer(kind: .https, host: "us2.vpn.example", port: 443)
        #expect(run?.askAll("www.example.com") == [.proxy(us1), .proxy(us2)])
        #expect(run?.askAll("online.bank.example") == [.direct])
        #expect(run?.askAll("10.1.2.3") == [.direct])
        #expect(run?.askAll("intranet") == [.direct])
        #expect(run?.askAll("watch.tv.example") == [.proxy(ProxyServer(kind: .https, host: "nl.vpn.example", port: 443))])
    }
}
