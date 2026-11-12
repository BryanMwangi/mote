/// A password made for a new account: three groups of six letters joined by
/// hyphens, one of the letters a capital and one a digit, as easy to read
/// aloud as such a thing can be (no l, no o), and about 89 bits strong.
public enum StrongPassword {
    static let letters = Array("abcdefghijkmnpqrstuvwxyz")
    static let capitals = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")

    public static func make() -> String {
        var random = SystemRandomNumberGenerator()
        return make(using: &random)
    }

    public static func make(using random: inout some RandomNumberGenerator) -> String {
        var characters = (0..<18).map { _ in letters.randomElement(using: &random)! }
        let capital = Int.random(in: 0..<18, using: &random)
        var digit = Int.random(in: 0..<17, using: &random)
        if digit >= capital { digit += 1 }
        characters[capital] = capitals.randomElement(using: &random)!
        characters[digit] = digits.randomElement(using: &random)!
        return stride(from: 0, to: 18, by: 6).map { String(characters[$0..<$0 + 6]) }.joined(separator: "-")
    }
}
