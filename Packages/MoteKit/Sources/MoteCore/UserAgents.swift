/// Develop › User Agent's list: other browsers as sites see them. Chrome's
/// and Firefox's numbers move every four weeks; these are November 2026's.
public enum UserAgents {
    public struct Preset: Equatable, Sendable {
        public let title: String
        public let value: String

        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    static let chrome = 154
    static let firefox = 157

    /// Grouped as the menu shows them. `safari` is the installed Safari's
    /// version, "26.1".
    public static func presets(safari: String) -> [[Preset]] {
        let major = safari.split(separator: ".").first.map(String.init) ?? safari
        let mac = "Macintosh; Intel Mac OS X 10_15_7"
        let windows = "Windows NT 10.0; Win64; x64"
        let android = "Linux; Android 10; K"
        // Safari on iOS and iPadOS 26 still says 18_6.
        let mobile = { (device: String) in
            "Mozilla/5.0 (\(device) 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Mobile/15E148 Safari/604.1"
        }
        let chromium = { (system: String, tail: String) in
            "Mozilla/5.0 (\(system)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome).0.0.0 \(tail)"
        }
        let gecko = { (system: String) in "Mozilla/5.0 (\(system); rv:\(firefox).0) Gecko/20100101 Firefox/\(firefox).0" }
        return [
            [
                Preset(
                    title: "Safari \(safari)",
                    value: "Mozilla/5.0 (\(mac)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15")
            ],
            [
                Preset(title: "Safari — iOS \(major) — iPhone", value: mobile("iPhone; CPU iPhone OS")),
                Preset(title: "Safari — iPadOS \(major) — iPad mini", value: mobile("iPad; CPU OS")),
            ],
            [
                Preset(title: "Microsoft Edge — macOS", value: chromium(mac, "Safari/537.36 Edg/\(chrome).0.0.0")),
                Preset(title: "Microsoft Edge — Windows", value: chromium(windows, "Safari/537.36 Edg/\(chrome).0.0.0")),
                Preset(title: "Microsoft Edge — Android", value: chromium(android, "Mobile Safari/537.36 EdgA/\(chrome).0.0.0")),
            ],
            [
                Preset(title: "Google Chrome — macOS", value: chromium(mac, "Safari/537.36")),
                Preset(title: "Google Chrome — Windows", value: chromium(windows, "Safari/537.36")),
                Preset(title: "Google Chrome — Android", value: chromium(android, "Mobile Safari/537.36")),
                Preset(title: "Google Chrome — ChromeOS", value: chromium("X11; CrOS x86_64 14541.0.0", "Safari/537.36")),
            ],
            [
                Preset(title: "Firefox — macOS", value: gecko("Macintosh; Intel Mac OS X 10.15")),
                Preset(title: "Firefox — Windows", value: gecko(windows)),
                Preset(
                    title: "Firefox — Android",
                    value: "Mozilla/5.0 (Android 15; Mobile; rv:\(firefox).0) Gecko/\(firefox).0 Firefox/\(firefox).0"),
            ],
        ]
    }
}
