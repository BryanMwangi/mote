import Foundation
import Testing

@testable import MoteCore

@Suite("Boost")
struct BoostTests {
    @Test("Nothing changed is no stylesheet")
    func empty() {
        #expect(Boost().isEmpty)
        #expect(Boost().stylesheet.isEmpty)
    }

    @Test("Only the filters that change, the font kept off code, then the CSS")
    func stylesheet() {
        let boost = Boost(brightness: 0.8, saturation: 1.2, font: "Georgia", css: "a { color: red }")
        let sheet = boost.stylesheet
        #expect(sheet.contains("filter: brightness(0.80) saturate(1.20) !important"))
        #expect(!sheet.contains("contrast"))
        #expect(sheet.contains(#"font-family: "Georgia""#) && sheet.contains(":not(code)"))
        #expect(sheet.hasSuffix("a { color: red }"))
    }

    @Test("A font can't break out of its rule")
    func fontEscaped() {
        #expect(!Boost(font: #"x"; } body { display: none; "#).stylesheet.contains("display: none;\""))
    }

    @Test("Dark turns pictures back; size, case and accent each have a rule; off is nothing")
    func more() {
        let sheet = Boost(dark: true, size: 1.25, textCase: "uppercase").stylesheet
        #expect(sheet.contains("invert(1) hue-rotate(180deg)") && sheet.contains("img, video"))
        #expect(sheet.contains("zoom: 1.25") && sheet.contains("text-transform: uppercase"))
        #expect(!Boost(textCase: "none; } body { display: none").stylesheet.contains("display"))
        #expect(Boost(dark: true, enabled: false).stylesheet.isEmpty)
    }

    @Test("The dots go to the colours script, not the stylesheet; off sends none")
    func colors() {
        let boost = Boost(tint: "#0000ff", accent: "#ffcc00")
        #expect(boost.stylesheet.isEmpty)
        #expect(boost.colors?.primary == "#0000ff" && boost.colors?.secondary == "#ffcc00")
        #expect((boost.colors?.strength ?? 0) > 0.25)
        #expect(Boost(tint: "#0000ff", enabled: false).colors == nil)
    }

    @Test("Older boosts still read")
    func old() throws {
        let old = #"{"brightness":0.9,"contrast":1,"saturation":1,"css":""}"#
        let boost = try JSONDecoder().decode(Boost.self, from: Data(old.utf8))
        #expect(boost.brightness == 0.9 && boost.enabled && boost.size == 1)
    }
}
