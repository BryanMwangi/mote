import Darwin
import Foundation
import JavaScriptCore
import MoteCore

/// A PAC script an extension sets (chrome.proxy's pac_script, a Firefox
/// add-on's autoConfig), asked about each host as pages connect to it
/// (ExtensionRelay), as Chrome asks it for each request. Run in
/// JavaScriptCore with the functions every PAC script may call, off the
/// main thread, and stopped if it runs too long.
enum ExtensionPAC {
    /// What a page load is asked as, to tell whether the script sends anything through a proxy.
    nonisolated static let sample = "www.example.com"

    /// A script, ready to be asked.
    nonisolated final class Script: @unchecked Sendable {
        let text: String
        private let run: Run
        /// Answers by host; a VPN's script answers the same until it's set again.
        private var answers: [String: [PACEntry]] = [:]

        fileprivate init(text: String, run: Run) {
            self.text = text
            self.run = run
        }

        /// Where a connection to `host` goes: the script's list, tried in turn.
        func entries(for host: String) async -> [PACEntry] {
            await withCheckedContinuation { done in
                queue.async {
                    if let known = self.answers[host] { return done.resume(returning: known) }
                    // A script that fails sends the page direct, as in Chrome.
                    let found = self.run.askAll(host) ?? [.direct]
                    if self.answers.count > 5000 { self.answers = [:] }
                    self.answers[host] = found
                    done.resume(returning: found)
                }
            }
        }
    }

    /// A script given whole or by address; nil when it can't be fetched or run.
    static func script(data: String?, url: String?) async -> Script? {
        var text = data
        if text == nil, let url, let address = URL(string: url) {
            text = try? await String(decoding: URLSession.shared.data(from: address).0, as: UTF8.self)
        }
        guard let text, !text.isEmpty else { return nil }
        // The same script set again keeps its answers.
        if let last, last.text == text { return last }
        let made: Script? = await withCheckedContinuation { done in
            queue.async { done.resume(returning: Run(text).map { Script(text: text, run: $0) }) }
        }
        if let made { last = made }
        return made
    }

    private static var last: Script?
    private nonisolated static let queue = DispatchQueue(label: "io.github.mote-browser.pac", qos: .userInitiated)

    /// One script, loaded in its own context.
    nonisolated final class Run {
        private let context: JSContext
        private let find: JSValue
        /// A script that looks up names waits on them: a few seconds per question at most.
        private var lookupsUntil = Date()

        init?(_ script: String) {
            guard let context = JSContext() else { return nil }
            self.context = context
            limitTime(of: context, seconds: 2)
            let lookup: @convention(block) (String) -> Any = { _ in NSNull() }
            context.setObject(lookup, forKeyedSubscript: "__moteResolve" as NSString)
            context.evaluateScript(Self.library)
            context.evaluateScript(script)
            let ex = context.objectForKeyedSubscript("FindProxyForURLEx")
            let plain = context.objectForKeyedSubscript("FindProxyForURL")
            guard let found = [ex, plain].compactMap({ $0 }).first(where: { $0.isObject }), context.exception == nil else { return nil }
            find = found
            // Defined now, so the script's own code above ran without lookups.
            let resolve: @convention(block) (String, Bool) -> Any = { [weak self] host, all in
                self?.resolve(host, all: all) ?? NSNull()
            }
            context.setObject(resolve, forKeyedSubscript: "__moteResolve" as NSString)
            let inNet: @convention(block) (String, String) -> Bool = { ip, prefix in Self.isInNet(ip, prefix: prefix) }
            context.setObject(inNet, forKeyedSubscript: "__moteInNetEx" as NSString)
            let mine: @convention(block) (Bool) -> String = { all in Self.myAddresses(all: all) }
            context.setObject(mine, forKeyedSubscript: "__moteMyAddress" as NSString)
        }

        /// The script's list for an HTTPS page on `host`; nil when it fails.
        func askAll(_ host: String) -> [PACEntry]? {
            context.exception = nil
            lookupsUntil = Date().addingTimeInterval(3)
            let answer = find.call(withArguments: ["https://\(host)/", host])
            guard context.exception == nil, let answer, answer.isString, let text = answer.toString() else { return nil }
            return ProxyRules.pacEntries(text)
        }

        /// The entry a page on `host` takes.
        func ask(_ host: String) -> PACEntry? { askAll(host)?.first }

        private func resolve(_ host: String, all: Bool) -> Any {
            if Self.isAddress(host) { return host }
            guard Date() < lookupsUntil else { return NSNull() }
            var hints = addrinfo()
            hints.ai_family = all ? AF_UNSPEC : AF_INET
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return NSNull() }
            defer { freeaddrinfo(list) }
            var found: [String] = []
            for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: name)
                    if !found.contains(text) { found.append(text) }
                }
            }
            return found.isEmpty ? NSNull() : (all ? found.joined(separator: ";") : found[0])
        }

        static func isAddress(_ text: String) -> Bool {
            var v4 = in_addr()
            var v6 = in6_addr()
            return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
        }

        /// isInNetEx: whether `ip` is in "prefix/length", IPv4 or IPv6.
        static func isInNet(_ ip: String, prefix: String) -> Bool {
            let parts = prefix.split(separator: "/")
            guard parts.count == 2, let length = Int(parts[1]), let net = bytes(String(parts[0])), let address = bytes(ip),
                net.count == address.count, (0...net.count * 8).contains(length)
            else { return false }
            for bit in 0..<length where (net[bit / 8] ^ address[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
            return true
        }

        private static func bytes(_ text: String) -> [UInt8]? {
            var v4 = in_addr()
            if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
            return nil
        }

        /// myIpAddress: the Mac's first address that isn't loopback.
        static func myAddresses(all: Bool) -> String {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return "127.0.0.1" }
            defer { freeifaddrs(list) }
            var found: [String] = []
            for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let address = entry.pointee.ifa_addr, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                    entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
                else { continue }
                let family = Int32(address.pointee.sa_family)
                guard family == AF_INET || (all && family == AF_INET6) else { continue }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let size = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(address, size, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(String(cString: name))
                }
            }
            if found.isEmpty { return "127.0.0.1" }
            return all ? found.joined(separator: ";") : found[0]
        }

        /// The functions a PAC script may call, as Netscape defined them and
        /// Chromium and Firefox give them, with Microsoft's IPv6 ones.
        static let library = #"""
            function dnsResolve(host) { return __moteResolve(String(host), false); }
            function dnsResolveEx(host) { var a = __moteResolve(String(host), true); return a === null ? "" : a; }
            function myIpAddress() { return __moteMyAddress(false); }
            function myIpAddressEx() { return __moteMyAddress(true); }
            function isResolvable(host) { return dnsResolve(host) !== null; }
            function isResolvableEx(host) { return dnsResolveEx(host) !== ""; }
            function isPlainHostName(host) { return String(host).indexOf(".") < 0; }
            function dnsDomainIs(host, domain) {
              host = String(host); domain = String(domain);
              return host.length >= domain.length && host.substring(host.length - domain.length) == domain;
            }
            function localHostOrDomainIs(host, hostdom) {
              host = String(host); hostdom = String(hostdom);
              return host == hostdom || hostdom.lastIndexOf(host + ".", 0) == 0;
            }
            function dnsDomainLevels(host) { return String(host).split(".").length - 1; }
            function convert_addr(ipchars) {
              var bytes = String(ipchars).split(".");
              return ((bytes[0] & 0xff) << 24) | ((bytes[1] & 0xff) << 16) | ((bytes[2] & 0xff) << 8) | (bytes[3] & 0xff);
            }
            function isInNet(ipaddr, pattern, maskstr) {
              var test = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ipaddr);
              if (test == null) {
                ipaddr = dnsResolve(ipaddr);
                if (ipaddr == null) return false;
              } else if (test[1] > 255 || test[2] > 255 || test[3] > 255 || test[4] > 255) {
                return false;
              }
              var host = convert_addr(ipaddr), pat = convert_addr(pattern), mask = convert_addr(maskstr);
              return (host & mask) == (pat & mask);
            }
            function isInNetEx(ipaddr, prefix) {
              if (!/^[0-9a-fA-F:.]+$/.test(ipaddr)) {
                ipaddr = dnsResolve(ipaddr);
                if (ipaddr == null) return false;
              }
              return __moteInNetEx(String(ipaddr), String(prefix));
            }
            function sortIpAddressList(list) {
              if (!list) return false;
              var items = String(list).split(";");
              var v4 = items.filter(function (a) { return a.indexOf(":") < 0; });
              var v6 = items.filter(function (a) { return a.indexOf(":") >= 0; });
              v4.sort(function (a, b) { return (convert_addr(a) >>> 0) - (convert_addr(b) >>> 0); });
              v6.sort();
              return v6.concat(v4).join(";");
            }
            function getClientVersion() { return "1.0"; }
            function shExpMatch(url, pattern) {
              pattern = String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
              return new RegExp("^" + pattern + "$").test(url);
            }
            var __wdays = { SUN: 0, MON: 1, TUE: 2, WED: 3, THU: 4, FRI: 5, SAT: 6 };
            var __months = { JAN: 0, FEB: 1, MAR: 2, APR: 3, MAY: 4, JUN: 5, JUL: 6, AUG: 7, SEP: 8, OCT: 9, NOV: 10, DEC: 11 };
            function weekdayRange() {
              function getDay(weekday) { return weekday in __wdays ? __wdays[weekday] : -1; }
              var date = new Date();
              var argc = arguments.length;
              var wday;
              if (argc < 1) return false;
              if (arguments[argc - 1] == "GMT") { argc--; wday = date.getUTCDay(); } else { wday = date.getDay(); }
              var wd1 = getDay(arguments[0]);
              var wd2 = argc == 2 ? getDay(arguments[1]) : wd1;
              if (wd1 == -1 || wd2 == -1) return false;
              if (wd1 <= wd2) return wd1 <= wday && wday <= wd2;
              return wd2 >= wday || wday >= wd1;
            }
            function dateRange() {
              function getMonth(name) { return name in __months ? __months[name] : -1; }
              var date = new Date();
              var argc = arguments.length;
              if (argc < 1) return false;
              var isGMT = arguments[argc - 1] == "GMT";
              if (isGMT) argc--;
              if (argc == 1) {
                var tmp = parseInt(arguments[0]);
                if (isNaN(tmp)) return (isGMT ? date.getUTCMonth() : date.getMonth()) == getMonth(arguments[0]);
                if (tmp < 32) return (isGMT ? date.getUTCDate() : date.getDate()) == tmp;
                return (isGMT ? date.getUTCFullYear() : date.getFullYear()) == tmp;
              }
              var year = date.getFullYear();
              var date1, date2;
              date1 = new Date(year, 0, 1, 0, 0, 0);
              date2 = new Date(year, 11, 31, 23, 59, 59);
              var adjustMonth = false;
              for (var i = 0; i < argc >> 1; i++) {
                var tmp = parseInt(arguments[i]);
                if (isNaN(tmp)) {
                  var mon = getMonth(arguments[i]);
                  date1.setMonth(mon);
                } else if (tmp < 32) {
                  adjustMonth = argc <= 2;
                  date1.setDate(tmp);
                } else {
                  date1.setFullYear(tmp);
                }
              }
              for (var i = argc >> 1; i < argc; i++) {
                var tmp = parseInt(arguments[i]);
                if (isNaN(tmp)) {
                  var mon = getMonth(arguments[i]);
                  date2.setMonth(mon);
                } else if (tmp < 32) {
                  date2.setDate(tmp);
                } else {
                  date2.setFullYear(tmp);
                }
              }
              if (adjustMonth) {
                date1.setMonth(date.getMonth());
                date2.setMonth(date.getMonth());
              }
              if (isGMT) {
                var tmp = date;
                tmp.setFullYear(date.getUTCFullYear());
                tmp.setMonth(date.getUTCMonth());
                tmp.setDate(date.getUTCDate());
                tmp.setHours(date.getUTCHours());
                tmp.setMinutes(date.getUTCMinutes());
                tmp.setSeconds(date.getUTCSeconds());
                date = tmp;
              }
              return date1 <= date2 ? date1 <= date && date <= date2 : date2 >= date || date >= date1;
            }
            function timeRange() {
              var argc = arguments.length;
              var date = new Date();
              var isGMT = false;
              if (argc < 1) return false;
              if (arguments[argc - 1] == "GMT") { isGMT = true; argc--; }
              var hour = isGMT ? date.getUTCHours() : date.getHours();
              var date1, date2;
              date1 = new Date();
              date2 = new Date();
              if (argc == 1) return hour == arguments[0];
              else if (argc == 2) return arguments[0] <= hour && hour <= arguments[1];
              else
                switch (argc) {
                  case 6:
                    date1.setSeconds(arguments[2]);
                    date2.setSeconds(arguments[5]);
                  case 4:
                    var middle = argc >> 1;
                    date1.setHours(arguments[0]);
                    date1.setMinutes(arguments[1]);
                    date2.setHours(arguments[middle]);
                    date2.setMinutes(arguments[middle + 1]);
                    if (middle == 2) {
                      date2.setSeconds(59);
                    }
                    break;
                  default:
                    throw "timeRange: bad number of arguments";
                }
              if (isGMT) {
                date.setFullYear(date.getUTCFullYear());
                date.setMonth(date.getUTCMonth());
                date.setDate(date.getUTCDate());
                date.setHours(date.getUTCHours());
                date.setMinutes(date.getUTCMinutes());
                date.setSeconds(date.getUTCSeconds());
              }
              return date1 <= date2 ? date1 <= date && date <= date2 : date2 >= date || date >= date1;
            }
            function alert() {}
            """#
    }

    /// JavaScriptCore's own time limit on a context's scripts, so a script
    /// that loops stops instead of holding its thread for good. Looked up
    /// at run time: it isn't in the public headers.
    nonisolated private static func limitTime(of context: JSContext, seconds: Double) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let set = unsafeBitCast(symbol, to: SetLimit.self)
        set(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
    }
}
