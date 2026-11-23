import Foundation

/// A person's details for filling in forms: kept by Mote (sealed on the Mac),
/// or read from their own card in Contacts. Its parts are named as the forms
/// script names a field's ("given", "email", "postal").
public struct ContactCard: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var given = ""
    public var family = ""
    public var organization = ""
    public var email = ""
    public var tel = ""
    public var street = ""
    public var city = ""
    public var region = ""
    public var postal = ""
    public var country = ""
    /// Last filled into a page, for putting the likeliest first.
    public var used: Date?
    /// From Contacts: shown, never changed here.
    public var fromContacts = false

    public init() {}

    /// A card from parts as the forms script names them; a whole "name" is
    /// split into given and family.
    public init(parts: [String: String]) {
        let part = { (key: String) in parts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        given = part("given")
        family = part("family")
        if given.isEmpty, family.isEmpty {
            let words = part("name").split(separator: " ").map(String.init)
            given = words.first ?? ""
            family = words.dropFirst().joined(separator: " ")
        }
        organization = part("organization")
        email = part("email")
        tel = part("tel")
        street = part("street")
        city = part("city")
        region = part("region")
        postal = part("postal")
        country = part("country")
    }

    /// The parts a form is filled from, empty ones left out.
    public var parts: [String: String] {
        [
            "given": given, "family": family, "name": name, "organization": organization, "email": email, "tel": tel,
            "street": street, "city": city, "region": region, "postal": postal, "country": country,
        ].filter { !$0.value.isEmpty }
    }

    public var name: String { [given, family].filter { !$0.isEmpty }.joined(separator: " ") }

    /// What tells it apart in a list, under its name: a postcode, else an email or phone.
    public var summary: String { [postal, email, tel, city].first { !$0.isEmpty } ?? "" }

    /// Worth keeping: a name and something to reach them by or send to.
    public var worthSaving: Bool { !name.isEmpty && !(email.isEmpty && tel.isEmpty && street.isEmpty) }

    /// The same person's details as `other` already holds: the same email or
    /// phone, or the same name at the same postcode. Nothing new to save.
    public func isCovered(by other: ContactCard) -> Bool {
        let digits = { (text: String) in text.filter(\.isNumber) }
        if !email.isEmpty, email.lowercased() == other.email.lowercased() { return true }
        if !tel.isEmpty, digits(tel).count >= 6, digits(tel) == digits(other.tel) { return true }
        return !name.isEmpty && name.lowercased() == other.name.lowercased() && !postal.isEmpty
            && postal.replacingOccurrences(of: " ", with: "").lowercased() == other.postal.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
