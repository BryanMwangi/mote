import CoreGraphics
import Foundation
import Testing

@testable import MoteCore

@Suite("Devices")
struct DevicesTests {
    private let iPhone = Device(name: "iPhone 14 / 15 / 16", type: "phones", width: 393, height: 852, scale: 3, touch: true)

    @Test("Firefox's device list reads as it is, its pixel ratio a number")
    func decodesFirefoxList() throws {
        let json = """
            [{"name": "Galaxy Note 9", "type": "phones", "width": 414, "height": 846, "pixelRatio": 3.5, "touch": true,
              "userAgent": "Mozilla/5.0 (Linux; Android 7.0)", "featured": true},
             {"name": "Laptop with MDPI screen", "type": "laptops", "width": 1280, "height": 800, "pixelRatio": 1, "touch": false,
              "userAgent": "", "featured": false}]
            """
        let devices = try Devices.decode(Data(json.utf8))
        #expect(devices.count == 2)
        #expect(devices[0].scale == 3.5)
        #expect(devices[0].touch)
        #expect(devices[0].userAgent.hasPrefix("Mozilla/5.0 (Linux"))
        #expect(devices[1].userAgent.isEmpty)
        #expect(!devices[1].featured)
    }

    @Test("A device that fits is centred at its own size")
    func fits() {
        let placed = Devices.place(iPhone.size, in: CGRect(x: 0, y: 0, width: 1000, height: 900), fits: true)
        #expect(placed.scale == 1)
        #expect(placed.frame == CGRect(x: 303, y: 24, width: 393, height: 852))
    }

    @Test("A device bigger than the area is scaled down to fit, never up")
    func scalesDown() {
        let placed = Devices.place(iPhone.size, in: CGRect(x: 10, y: 20, width: 800, height: 426), fits: true)
        #expect(placed.scale == 0.5)
        #expect(placed.frame.size == CGSize(width: 197, height: 426))
        #expect(placed.frame.minY == 20)
        #expect(placed.frame.minX == 311)
    }

    @Test("At its own size a tall device starts at the top")
    func ownSize() {
        let placed = Devices.place(iPhone.size, in: CGRect(x: 0, y: 0, width: 800, height: 400), fits: false)
        #expect(placed.scale == 1)
        #expect(placed.frame == CGRect(x: 203, y: 0, width: 393, height: 852))
    }

    @Test("Rotating swaps the sides and keeps the name; resizing makes it custom, never below the smallest")
    func rotateAndResize() {
        #expect(iPhone.rotated.size == CGSize(width: 852, height: 393))
        #expect(iPhone.rotated.name == iPhone.name)
        #expect(iPhone.rotated.sized(width: 852, height: 393).name == iPhone.name)
        let resized = iPhone.sized(width: 500.4, height: 852)
        #expect(resized.size == CGSize(width: 500, height: 852))
        #expect(resized.name == Devices.custom)
        #expect(iPhone.sized(width: 10, height: 10).size == CGSize(width: Devices.smallest, height: Devices.smallest))
    }
}
