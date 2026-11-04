import AppKit
import MoteCore
import VisionKit
import WebKit

// Right-clicking an image shows Mote's own menu. WebKit's Download Image
// skips the navigation delegate, and its Copy Image leaves a promise on the
// pasteboard that some apps never paste; neither can be fixed from outside,
// so the page's script stops WebKit's menu over images and asks for this one.

/// Hears which image was right-clicked.
final class ImageRelay: NSObject, WKScriptMessageHandler {
    static let name = "moteImages"

    /// In every frame; broken images and 1×1 trackers are left alone.
    /// See Scripts/src/image-menu.ts.
    static let watch = InjectedScript.source("image-menu")

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let image = (body["src"] as? String).flatMap(ImageAddress.usable) else { return }
        MainActor.assumeIsolated { tab?.imageMenu(for: image) }
    }
}

extension Browser {
    /// Where the pointer is: the ask comes from the page, with no event to
    /// place the menu by.
    func showImageMenu(for tab: Tab, at image: URL) {
        guard let web = tab.built, let window = web.window else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // In Zen's order.
        var items: [NSMenuItem] = [
            ActionItem("Open Image in New Tab") { [weak self] in self?.open(image, foreground: true, from: tab) },
            ActionItem("Download Image") { [weak self] in self?.downloadImage(at: image, from: web) },
            ActionItem("Copy Image") { [weak self] in self?.copyImage(at: image) },
            ActionItem("Copy Image Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(image.absoluteString, forType: .string)
            },
            NSSharingServicePicker(items: [image]).standardShareMenuItem,
            ActionItem("Copy Text From Image") { [weak self] in self?.copyText(from: image) },
            .separator(),
            ActionItem("Set Image as Desktop Background") { [weak self] in self?.setDesktop(to: image, on: window.screen) },
            .separator(),
            ActionItem("Take Screenshot") { tab.screenshot() },
            ActionItem("Ask about This Page") { [weak self] in if self?.chatting == false { self?.togglePageChat() } },
        ]
        // Extensions' items go last, as on the page's own menu.
        if #available(macOS 15.4, *) {
            let extra = Extensions.shared.menuItems(for: tab)
            if !extra.isEmpty { items += [.separator()] + extra }
        }
        items.forEach(menu.addItem)
        let pointer = web.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: pointer, in: web)
    }

    /// The image itself goes on the pasteboard, not a promise of it, so it
    /// pastes anywhere.
    func copyImage(at url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else {
                return announce("Couldn't copy that image")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            announce("Image copied")
        }
    }

    /// The words in the picture, as Live Text reads them, onto the pasteboard.
    func copyText(from url: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init(.text)),
                !analysis.transcript.isEmpty
            else { return announce("No text found in that image") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(analysis.transcript, forType: .string)
            announce("Text copied")
        }
    }

    /// The picture, kept in the app's own folder, as the screen's background.
    func setDesktop(to url: URL, on screen: NSScreen?) {
        Task {
            guard let screen = screen ?? NSScreen.main, let (data, _) = try? await URLSession.shared.data(from: url) else {
                return announce("Couldn't set that image")
            }
            let file = Storage.folder.appendingPathComponent(
                "Desktop-\(UUID().uuidString.prefix(8)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            do {
                try data.write(to: file)
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [:])
                announce("Desktop background set")
            } catch {
                announce("Couldn't set that image")
            }
        }
    }

    /// Through the usual downloads, like any other.
    func downloadImage(at url: URL, from web: WKWebView) {
        web.startDownload(using: URLRequest(url: url)) { [weak self] download in self?.keep(download) }
    }
}
