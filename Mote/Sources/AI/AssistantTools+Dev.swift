import AppKit
import MoteAI
import MoteCore
import WebKit

/// For testing a site, with Developer mode or a coding agent from outside:
/// running script, the console and failed requests, waiting for something to
/// show, phone and tablet sizes, tabs of its own; and, for everyone, looking
/// at a tab. The developer tools work only on the developer sites.
extension AssistantTools {
    var devTools: [Tool] {
        let tab = #""tab":{"type":"string","description":"A tab id from list_tabs"}"#
        var tools = [
            Tool(
                name: "screenshot_tab",
                description:
                    "A picture of a tab's page, to check what renders: what shows (the default), the whole page top to bottom, one element by its number from read_tab, or a region in page coordinates. Taken by the browser itself, so no screen recording permission is needed. save: true also saves it to the person's Downloads.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"what\":{\"type\":\"string\",\"enum\":[\"visible\",\"whole\",\"element\",\"region\"]},\"element\":{\"type\":\"integer\"},\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"width\":{\"type\":\"number\"},\"height\":{\"type\":\"number\"},\"save\":{\"type\":\"boolean\"}},\"required\":[\"tab\"]}")
        ]
        let script = "{\"type\":\"object\",\"properties\":{\(tab),\"script\":{\"type\":\"string\",\"description\":\"A function body; use return\"}},\"required\":[\"tab\",\"script\"]}"
        // Anywhere, asked per site: what to reach for when no tool does what's asked in a page.
        let anywhere = Tool(
            name: "run_script",
            description:
                "Runs JavaScript in a tab's page and returns what it returns (JSON-able values). When no tool does what's asked in a page, read the page first, then do it with a short script: reading things no tool reads, checking a layout, setting something up for a test. Asks first, per site. Never reads or writes password fields.",
            schema: script)
        tools += [
            anywhere,
            Tool(
                name: "page_appearance",
                description:
                    "Shows a tab's page in light or dark (its prefers-color-scheme), or back to Mote's (auto): for testing both, with screenshot_tab between.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"look\":{\"type\":\"string\",\"enum\":[\"light\",\"dark\",\"auto\"]}},\"required\":[\"tab\",\"look\"]}"),
        ]
        guard developing else { return tools }
        let sites = prefs.aiDevSites
        tools.removeAll { $0.name == "run_script" }
        tools += [
            Tool(
                name: "run_script", description: "Runs JavaScript in a tab's page (developer sites: \(sites)) and returns what it returns.",
                schema: "{\"type\":\"object\",\"properties\":{\(tab),\"script\":{\"type\":\"string\",\"description\":\"A function body; use return\"}},\"required\":[\"tab\",\"script\"]}"),
            Tool(
                name: "console", description: "A tab's console messages and uncaught errors since it loaded (developer sites).",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
            Tool(
                name: "network_errors", description: "Requests in a tab that failed or answered with an error status (developer sites).",
                schema: "{\"type\":\"object\",\"properties\":{\(tab)},\"required\":[\"tab\"]}"),
            Tool(
                name: "wait_for", description: "Waits until a tab has the words, or an element matching a CSS selector, or has loaded; at most 30 seconds.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"text\":{\"type\":\"string\"},\"selector\":{\"type\":\"string\"},\"seconds\":{\"type\":\"number\"}},\"required\":[\"tab\"]}"),
            Tool(
                name: "responsive_design_mode",
                description:
                    "Shows a tab at a device's size, as Responsive Design Mode does: by a device's name (list_devices), or a width and height; rotate turns it; off goes back to the window's size.",
                schema:
                    "{\"type\":\"object\",\"properties\":{\(tab),\"device\":{\"type\":\"string\"},\"width\":{\"type\":\"number\"},\"height\":{\"type\":\"number\"},\"rotate\":{\"type\":\"boolean\"},\"off\":{\"type\":\"boolean\"}},\"required\":[\"tab\"]}"),
            Tool(name: "list_devices", description: "The devices responsive_design_mode knows, with their sizes."),
            Tool(
                name: "new_test_tab", description: "Opens an address on a developer site in a test tab: marked with a flask, kept out of history and the person's session.",
                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
            Tool(name: "close_test_tabs", description: "Closes every test tab."),
        ]
        return tools
    }

    func runDev(_ call: ToolCall) async -> ToolOutput? {
        let input = call.input
        // These act without asking on the developer sites; in Plan nothing acts.
        if planning, ["new_test_tab", "close_test_tabs", "run_script", "responsive_design_mode"].contains(call.name) {
            return ToolOutput(Self.planOnly)
        }
        switch call.name {
        case "screenshot_tab":
            guard let found = find(input) else { return ToolOutput("There's no open tab with that id; list the tabs again.") }
            return await screenshot(found.tab, input)
        case "list_devices":
            guard developing else { return nil }
            return ToolOutput(DeviceList.shared.all.map { "\($0.name)\t\(Int($0.width))×\(Int($0.height))" }.joined(separator: "\n"))
        case "close_test_tabs":
            guard developing else { return nil }
            let tests = everyTab.filter(\.tab.bench)
            for (browser, group) in Dictionary(grouping: tests, by: { ObjectIdentifier($0.browser) }).compactMap({ ($0.value.first?.browser, $0.value) }) {
                browser?.closeTogether(group.map(\.tab))
            }
            return ToolOutput("Closed \(tests.count) test tab\(tests.count == 1 ? "" : "s").")
        case "new_test_tab":
            guard developing else { return nil }
            guard let url = web(input["url"]?.string), developerSite(url) else {
                return ToolOutput("Test tabs open on the developer sites only: \(prefs.aiDevSites). The person can add more in Settings › AI.")
            }
            let tab = browser.benchOpen(url)
            browser.select(tab)
            return ToolOutput("Opened test tab \(Self.id(tab)).")
        case "page_appearance":
            guard let found = find(input) else { return ToolOutput(Self.noTab) }
            return ToolOutput(await appearance(found, input["look"]?.string ?? "auto"))
        case "run_script" where !developing || !developerSite(find(input)?.tab.address):
            // Off the developer sites: asked per site, as acting in a page is.
            guard let found = find(input) else { return ToolOutput(Self.noTab) }
            guard found.tab.built != nil, let address = found.tab.address else {
                return ToolOutput("\(Self.line(found.tab)) is asleep; read it first, which wakes it.")
            }
            guard await permit(.inPage(address), "Run a script on \(Address.siteHost(of: address) ?? "this page")?") else { return ToolOutput(refused) }
            return ToolOutput(await develop("run_script", input, on: found))
        case "run_script", "console", "network_errors", "wait_for", "responsive_design_mode":
            guard developing else { return nil }
            guard let found = find(input) else { return ToolOutput("There's no open tab with that id; list the tabs again.") }
            let tab = found.tab
            guard developerSite(tab.pending ?? tab.address) else {
                return ToolOutput("Developer tools work on the developer sites only: \(prefs.aiDevSites). The person can add more in Settings › AI.")
            }
            return ToolOutput(await develop(call.name, input, on: found))
        default:
            return nil
        }
    }

    /// Light, dark, or Mote's own look for one tab's page.
    private func appearance(_ found: Found, _ look: String) async -> String {
        guard await permit(.gentle, "") else { return refused }
        let web = found.tab.web
        let was = web.appearance
        web.appearance = look == "light" ? NSAppearance(named: .aqua) : look == "dark" ? NSAppearance(named: .darkAqua) : nil
        return "\(Self.line(found.tab)) shows \(look == "auto" ? "in Mote's own look" : "in \(look)") now." + record("Showed \(Self.line(found.tab)) in \(look)") {
            web.appearance = was
            return "Its look is as it was."
        }
    }

    private func develop(_ tool: String, _ input: JSON, on found: Found) async -> String {
        let tab = found.tab
        // Working in the page: shown on it, and the person's hands kept off it, as for a click.
        if tool == "run_script" || tool == "wait_for" {
            if let taken = taken(tab) { return taken }
            show(found, tool == "run_script" ? "Running a script" : "Waiting for the page")
        }
        defer { if tool == "run_script" || tool == "wait_for" { tab.agent.end() } }
        switch tool {
        case "responsive_design_mode":
            if input["off"]?.bool == true {
                tab.device = nil
                return "Back to the window's size."
            }
            if input["rotate"]?.bool == true, let device = tab.device {
                tab.device = device.rotated
                return "Turned to \(Int(device.height))×\(Int(device.width))."
            }
            if let name = input["device"]?.string {
                guard let device = DeviceList.shared.all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
                    return "No device is called “\(name)”; list_devices has their names."
                }
                tab.device = device
                bringForward(found)
                return "Showing “\(tab.label)” as \(device.name), \(Int(device.width))×\(Int(device.height))."
            }
            guard let width = input["width"]?.double, let height = input["height"]?.double else { return "Give a device, or a width and height." }
            let base = tab.device ?? DeviceList.shared.all.first ?? Device(name: "Custom", width: width, height: height, scale: 2, touch: false)
            tab.device = base.sized(width: width, height: height)
            bringForward(found)
            return "Showing “\(tab.label)” at \(Int(width))×\(Int(height))."
        case "wait_for":
            let seconds = min(max(input["seconds"]?.double ?? 10, 0.5), 30)
            let text = input["text"]?.string
            let selector = input["selector"]?.string
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if text == nil, selector == nil, !tab.loading { return "Loaded." }
                let script =
                    "return (sel ? !!document.querySelector(sel) : true) && (words ? document.body.innerText.includes(words) : true);"
                if await inPage(tab, script, ["sel": selector ?? "", "words": text ?? ""]) == "true" { return "It's there." }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return "Not there after \(Int(seconds)) seconds."
        case "console":
            return await inPage(tab, "return (window.__moteDevLog?.console ?? []).join('\\n');")?.ifEmpty("Nothing in the console.")
                ?? "The page has no console log yet: reload it, now that it's a developer site."
        case "network_errors":
            return await inPage(tab, "return (window.__moteDevLog?.network ?? []).join('\\n');")?.ifEmpty("No requests failed.")
                ?? "The page has no request log yet: reload it, now that it's a developer site."
        default:
            let script = input["script"]?.string ?? ""
            return await inPage(tab, script) ?? "It returned nothing, or failed; check console."
        }
    }

    /// Runs script in the page's own world (developer sites only); its answer
    /// as text. A script that takes the page elsewhere, or runs past half a
    /// minute, is answered at once rather than waited on.
    private func inPage(_ tab: Tab, _ body: String, _ arguments: [String: Any] = [:]) async -> String? {
        guard let web = tab.built else { return nil }
        let answer: Settled<String?> = await settle(tab, within: 30) { give in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                let text: String? =
                    switch result {
                    case .success(let value as String): value
                    case .success(let value as Bool): value ? "true" : "false"
                    case .success(let value as NSNumber): value.stringValue
                    case .success(let value) where JSONSerialization.isValidJSONObject(value):
                        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) }
                    case .success: nil
                    case .failure(let error): "Error: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)"
                    }
                give(text)
            }
        }
        switch answer {
        case .done(let text): return text
        case .went(let url): return "The script took the page to \(url?.absoluteString ?? "another page"); read the tab for what's there now."
        case .late: return "The script was still running after 30 seconds; it's left running. Read the tab to see where it got to."
        }
    }

    /// A picture of the page, through Mote's own screenshots (Tab.picture):
    /// what shows, the whole page, an element or a region; scaled down to
    /// what a model takes, as a JPEG.
    private func screenshot(_ tab: Tab, _ input: JSON) async -> ToolOutput {
        guard tab.built != nil else { return ToolOutput("“\(tab.label)” has no page to look at; it may be asleep. read_tab wakes it.") }
        let what = input["what"]?.string ?? (input["element"] != nil ? "element" : "visible")
        let shot: Tab.Shot
        switch what {
        case "whole":
            shot = .wholePage
        case "element":
            guard let n = input["element"]?.int else { return ToolOutput("Give the element's number from read_tab.") }
            guard let json = await page(tab, "rect", ["n": n]),
                let place = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double],
                let x = place["x"], let y = place["y"], let w = place["w"], let h = place["h"], w > 0, h > 0
            else { return ToolOutput("Element \(n) is gone: the page changed; read the tab again.") }
            let scrolled = CGPoint(x: place["sx"] ?? 0, y: place["sy"] ?? 0)
            // Its place in the page, a little round it.
            shot = .region(CGRect(x: x + scrolled.x, y: y + scrolled.y, width: w, height: h).insetBy(dx: -8, dy: -8), scrolled: scrolled)
        case "region":
            guard let x = input["x"]?.double, let y = input["y"]?.double, let w = input["width"]?.double, let h = input["height"]?.double else {
                return ToolOutput("Give x, y, width and height, in the page's coordinates.")
            }
            // How far the page is scrolled, so what shows is taken as it shows.
            let offset: [Double] = await withCheckedContinuation { done in
                tab.web.callInAppWorld("return [window.scrollX, window.scrollY];", arguments: [:]) { done.resume(returning: ($0 as? [Double]) ?? [0, 0]) }
            }
            shot = .region(CGRect(x: x, y: y, width: w, height: h), scrolled: CGPoint(x: offset.first ?? 0, y: offset.last ?? 0))
        default:
            shot = .visible
        }
        let image: NSImage? = await withCheckedContinuation { done in tab.picture(shot) { done.resume(returning: $0) } }
        // Shrunk and encoded off the main thread: a tall page is a big picture.
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let jpeg = await Task.detached(priority: .userInitiated) { cg.flatMap(Self.jpeg) }.value
        guard let image, let jpeg else { return ToolOutput("The picture couldn't be taken; the page may still be loading.") }
        if input["save"]?.bool == true { tab.screenshot(shot) }
        let size = "\(Int(image.size.width))×\(Int(image.size.height))"
        let device = tab.device.map { ", as \($0.name)" } ?? ""
        return ToolOutput("A picture of “\(tab.label)” (\(what), \(size) points\(device)).", image: jpeg)
    }

    /// At most 1600 wide and 7800 tall, as a model takes them.
    nonisolated private static func jpeg(_ cg: CGImage) -> Data? {
        let scale = min(1, 1600 / CGFloat(cg.width), 7800 / CGFloat(cg.height))
        let width = Int(CGFloat(cg.width) * scale)
        let height = Int(CGFloat(cg.height) * scale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
