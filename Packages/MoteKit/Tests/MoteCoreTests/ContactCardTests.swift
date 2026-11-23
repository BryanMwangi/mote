import Foundation
import Testing

@testable import MoteCore

@Suite("ContactCard")
struct ContactCardTests {
    @Test("A card from a form's parts splits a whole name, and gives back only what it holds")
    func parts() {
        let card = ContactCard(parts: ["name": "Ana Wanjiru Kamau", "email": " ana@x.io ", "postal": "00100"])
        #expect(card.given == "Ana")
        #expect(card.family == "Wanjiru Kamau")
        #expect(card.email == "ana@x.io")
        #expect(card.parts == ["given": "Ana", "family": "Wanjiru Kamau", "name": "Ana Wanjiru Kamau", "email": "ana@x.io", "postal": "00100"])
        #expect(card.summary == "00100")
    }

    @Test("Only a name with something to reach them by is worth saving")
    func worth() {
        #expect(ContactCard(parts: ["name": "Ana", "tel": "0700"]).worthSaving)
        #expect(!ContactCard(parts: ["name": "Ana"]).worthSaving)
        #expect(!ContactCard(parts: ["email": "ana@x.io"]).worthSaving)
    }

    @Test("Details already kept are known by email, phone, or name and postcode")
    func covered() {
        let kept = ContactCard(parts: ["name": "Ana Wanjiru", "email": "Ana@X.io", "tel": "+254 700 111 222", "postal": "00 100"])
        #expect(ContactCard(parts: ["name": "A W", "email": "ana@x.io"]).isCovered(by: kept))
        #expect(ContactCard(parts: ["name": "A W", "tel": "254700111222"]).isCovered(by: kept))
        #expect(ContactCard(parts: ["name": "ana wanjiru", "postal": "00100"]).isCovered(by: kept))
        #expect(!ContactCard(parts: ["name": "Ben", "email": "ben@x.io"]).isCovered(by: kept))
    }

    @Test("A card keeps through encoding")
    func codable() throws {
        var card = ContactCard(parts: ["given": "Ana", "city": "Nairobi"])
        card.used = Date(timeIntervalSince1970: 100)
        let back = try JSONDecoder().decode(ContactCard.self, from: JSONEncoder().encode(card))
        #expect(back == card)
    }
}
