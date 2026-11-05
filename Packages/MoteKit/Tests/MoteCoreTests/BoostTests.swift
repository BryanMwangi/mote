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
        #expect(Boost(accent: "#ff0000").stylesheet.contains("color: #ff0000"))
        #expect(!Boost(textCase: "none; } body { display: none").stylesheet.contains("display"))
        #expect(Boost(dark: true, enabled: false).stylesheet.isEmpty)
    }

    @Test("A tint casts the page toward its hue")
    func tint() {
        // Pure blue, 240°: sepia's 38° turned 202°.
        #expect(Boost(tint: "#0000ff").stylesheet.contains("hue-rotate(202deg)"))
    }

    @Test("Older boosts still read")
    func old() throws {
        let old = #"{"brightness":0.9,"contrast":1,"saturation":1,"css":""}"#
        let boost = try JSONDecoder().decode(Boost.self, from: Data(old.utf8))
        #expect(boost.brightness == 0.9 && boost.enabled && boost.size == 1)
    }
}
