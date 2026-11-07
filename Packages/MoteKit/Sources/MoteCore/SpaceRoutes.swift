import Foundation

/// A site that always opens in one space: an address
/// that contains, equals or matches a pattern goes to `space`.
public struct SpaceRoute: Codable, Identifiable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case contains, equals, pattern
    }

    public let id: UUID
    public var reference: String
    public var match: Match
    public var space: UUID

    public init(id: UUID = UUID(), reference: String, match: Match = .contains, space: UUID) {
        (self.id, self.reference, self.match, self.space) = (id, reference, match, space)
    }

    public func matches(_ address: String) -> Bool {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return false }
        switch match {
        case .contains: return address.lowercased().contains(reference.lowercased())
        case .equals: return Self.plain(address) == Self.plain(reference)
        case .pattern:
            return (try? NSRegularExpression(pattern: reference, options: .caseInsensitive))?
                .firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
    }

    /// The space the first matching rule names, if any.
    public static func space(for address: String, in routes: [SpaceRoute]) -> UUID? {
        routes.first { $0.matches(address) }?.space
    }

    private static func plain(_ address: String) -> String {
        var plain = address.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where plain.hasPrefix(prefix) { plain.removeFirst(prefix.count) }
        if plain.hasSuffix("/") { plain.removeLast() }
        return plain
    }
}
