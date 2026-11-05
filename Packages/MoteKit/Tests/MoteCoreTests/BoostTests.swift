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
}
