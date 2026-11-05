import AppKit
import MoteCore
import WebKit

extension Browser {
    /// Take Screenshot, as Firefox's: an overlay on the page to pick an
    /// element or drag out a region, or save what shows or the whole page.
    /// See Scripts/src/screenshot.ts.
    func startScreenshot() {
        guard let tab = active, !tab.isBlank, let web = tab.built else { return }
        web.callInAppWorld(Tab.overlay, arguments: [:]) { [weak tab] value in
            guard let tab, let choice = value as? [String: Any] else { return }
            let numbers = { (key: String) in (choice[key] as? [Double]) ?? [] }
            switch choice["kind"] as? String {
            case "visible": tab.screenshot()
            case "full": tab.screenshot(.wholePage)
            case let kind where kind == "copy" || kind == "save":
                let rect = numbers("rect"), scroll = numbers("scroll")
                guard rect.count == 4, scroll.count == 2 else { return }
                tab.screenshot(
                    .region(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), scrolled: CGPoint(x: scroll[0], y: scroll[1])),
                    copy: kind == "copy")
            default: break
            }
        }
    }
}

/// Pictures of the page, as Firefox's screenshots take them: what shows, or
/// the whole page top to bottom; saved to the downloads folder or copied.
extension Tab {
    enum Shot: Equatable {
        case visible, wholePage
        /// Part of the page, in its own coordinates, with how far it was scrolled.
        case region(CGRect, scrolled: CGPoint)
    }

    static let overlay = InjectedScript.source("screenshot") + "\nreturn await \(InjectedScript.globalName("screenshot")).run();"

    /// The tallest whole page taken, in points, so a never-ending feed can't
    /// ask for a picture too big to hold.
    private static let tallest: CGFloat = 16_000

    /// A picture of the page (at the device's width in Responsive Design
    /// Mode), into the downloads folder, or onto the clipboard.
    func screenshot(_ shot: Shot = .visible, copy: Bool = false) {
        guard let web = built, let browser = owner as? Browser else { return }
        var name = "\(label) – \(shot == .wholePage ? "whole page" : "screenshot").png"
        if let device { name = "\(label) – \(device.name) \(Int(device.width))×\(Int(device.height)).png" }
        // Beside earlier ones, never over them: "Name 2.png", "Name 3.png".
        let base = name.replacingOccurrences(of: "/", with: "-").dropLast(4)
        var file = browser.downloadsFolder.appendingPathComponent(base + ".png")
        var n = 1
        while FileManager.default.fileExists(atPath: file.path) {
            n += 1
            file = browser.downloadsFolder.appendingPathComponent("\(base) \(n).png")
        }
        let done = { (image: NSImage?) in
            guard let image else { return browser.announce("The screenshot couldn't be taken") }
            if copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                return browser.announce("Screenshot copied")
            }
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                (try? png.write(to: file)) != nil
            else { return browser.announce("The screenshot couldn't be saved") }
            browser.announce("Screenshot saved to \(browser.downloadsFolder.lastPathComponent)")
        }
        switch shot {
        case .region(let rect, let scrolled):
            // What shows is a snapshot, as the eye saw it; what reaches past
            // the window comes from WebKit's PDF of the page.
            let shown = rect.offsetBy(dx: -scrolled.x, dy: -scrolled.y)
            if shown.minY >= 0, shown.maxY <= web.bounds.height, shown.minX >= 0, shown.maxX <= web.bounds.width {
                let config = WKSnapshotConfiguration()
                config.rect = shown
                web.takeSnapshot(with: config) { image, _ in MainActor.assumeIsolated { done(image) } }
            } else {
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, Self.tallest))
                web.createPDF(configuration: config) { result in
                    MainActor.assumeIsolated {
                        done((try? result.get()).flatMap { Self.picture(ofPDF: $0, scale: web.window?.backingScaleFactor ?? 2) })
                    }
                }
            }
        case .visible:
            let config = WKSnapshotConfiguration()
            if let device { config.snapshotWidth = NSNumber(value: Double(device.width)) }
            web.takeSnapshot(with: config) { image, _ in MainActor.assumeIsolated { done(image) } }
        case .wholePage:
            // WebKit's snapshots only see what's on screen; its PDF of the page
            // takes all of it, drawn here into a picture at the screen's density.
            let size =
                "[document.documentElement.scrollWidth, Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
            web.evaluateJavaScript(size) { value, _ in
                MainActor.assumeIsolated {
                    guard let numbers = value as? [Double], numbers.count == 2, numbers[0] > 0, numbers[1] > 0 else { return done(nil) }
                    let config = WKPDFConfiguration()
                    config.rect = CGRect(x: 0, y: 0, width: numbers[0], height: min(numbers[1], Self.tallest))
                    web.createPDF(configuration: config) { result in
                        MainActor.assumeIsolated {
                            let scale = web.window?.backingScaleFactor ?? 2
                            done((try? result.get()).flatMap { Self.picture(ofPDF: $0, scale: scale) })
                        }
                    }
                }
            }
        }
    }

    /// "Take Screenshot…" for the page's menus: the overlay.
    func screenshotItem() -> NSMenuItem {
        ActionItem("Take Screenshot…") { [weak self] in (self?.owner as? Browser)?.startScreenshot() }
    }

    /// The first page of a PDF, drawn into a bitmap `scale` times its size.
    private static func picture(ofPDF data: Data, scale: CGFloat) -> NSImage? {
        guard let pdf = NSPDFImageRep(data: data) else { return nil }
        let bounds = pdf.bounds
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        bitmap.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        bounds.fill()
        pdf.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}
