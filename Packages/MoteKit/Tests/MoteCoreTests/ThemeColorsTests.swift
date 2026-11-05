import Foundation
import Testing

@testable import MoteCore

@Suite("ThemeColors")
struct ThemeColorsTests {
    @Test(
        "A colour comes back to where it was picked",
        arguments: [CGPoint(x: 0.6, y: 0), CGPoint(x: -0.3, y: 0.5), CGPoint(x: 0.1, y: -0.8)])
    func roundTrip(point: CGPoint) {
        let back = ThemeColors.point(for: ThemeColors.hex(at: point))
        #expect(abs(back.x - point.x) < 0.03 && abs(back.y - point.y) < 0.03)
    }

    @Test("Angle is hue: right is red, a third of the way round is green")
    func hue() {
        let red = SpaceTheme.rgb(ThemeColors.hex(at: CGPoint(x: 1, y: 0)))!
        #expect(red.red > red.green && red.red > red.blue)
        let green = SpaceTheme.rgb(ThemeColors.hex(at: CGPoint(x: cos(2 * .pi / 3), y: sin(2 * .pi / 3))))!
        #expect(green.green > green.red && green.green > green.blue)
    }

    @Test("Harmonies turn the first dot about the centre, keeping its distance")
    func harmonies() {
        let first = CGPoint(x: 0.5, y: 0)
        let opposite = ThemeColors.others(.complementary, from: first)
        #expect(opposite.count == 1 && abs(opposite[0].x + 0.5) < 1e-9 && abs(opposite[0].y) < 1e-9)
        #expect(ThemeColors.others(.triadic, from: first).allSatisfy { abs(hypot($0.x, $0.y) - 0.5) < 1e-9 })
    }

    @Test("Old themes with grain on or off still read")
    func oldGrain() throws {
        let old = ##"{"colors":["#7c5cff"],"opacity":0.5,"grain":true}"##
        let theme = try JSONDecoder().decode(SpaceTheme.self, from: Data(old.utf8))
        #expect(theme.grain == 1 && theme.scheme == nil)
    }

    @Test("Zen's swatches: seven pages of nine; a three keeps its colour's lightness")
    func swatches() {
        #expect(SpaceTheme.swatches.count == 63)
        let pale = SpaceTheme.Swatch(hex: "#ffe9f3", dots: 3).colors
        #expect(pale.count == 3)
        // Turned, not darkened: each stays a pastel.
        #expect(pale.allSatisfy { hex in SpaceTheme.rgb(hex).map { min($0.red, $0.green, $0.blue) > 0.8 } ?? false })
        #expect(ThemeColors.turned("#808080", by: 50) == "#808080")
    }
}
