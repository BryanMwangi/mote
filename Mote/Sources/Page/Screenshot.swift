import AppKit
import MoteCore
import WebKit

extension Browser {
    /// Take Screenshot, from the page panel and the keys.
    func startScreenshot() { active?.screenshot() }
}

/// Pictures of the page, as Firefox's screenshots take them: what shows, or
/// the whole page top to bottom; saved to the downloads folder or copied.
extension Tab {
    enum Shot {
        case visible, wholePage
    }

    /// The tallest whole page taken, in points, so a never-ending feed can't
    /// ask for a picture too big to hold.
    private static let tallest: CGFloat = 16_000

    /// A picture of the page (at the device's width in Responsive Design
    /// Mode), into the downloads folder, or onto the clipboard.
    func screenshot(_ shot: Shot = .visible, copy: Bool = false) {
        guard let web = built, let browser = owner as? Browser else { return }
        var name = "\(label) – \(shot == .wholePage ? "whole page" : "screenshot").png"
        if let device { name = "\(label) – \(device.name) \(Int(device.width))×\(Int(device.height)).png" }
        let file = browser.downloadsFolder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
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

    /// "Take Screenshot ›" for the page's menus: what shows, the whole page,
    /// or what shows onto the clipboard.
    func screenshotItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Take Screenshot", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        item.submenu?.items = [
            ActionItem("Visible Part") { [weak self] in self?.screenshot() },
            ActionItem("Whole Page") { [weak self] in self?.screenshot(.wholePage) },
            ActionItem("Copy Visible Part") { [weak self] in self?.screenshot(copy: true) },
        ]
        return item
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
