import Foundation
import Security

/// Where API keys are kept, by provider id.
public protocol Secrets: Sendable {
    func key(for provider: String) -> String?
    /// Saves the key, or forgets it when empty.
    @discardableResult func setKey(_ key: String, for provider: String) -> Bool
    /// Whether a key is kept, without reading it.
    func hasKey(for provider: String) -> Bool
}

extension Secrets {
    public func hasKey(for provider: String) -> Bool { key(for: provider) != nil }
}

/// API keys in the macOS keychain, as generic passwords under one service,
/// read when needed and never kept in memory or on disk.
public struct KeychainSecrets: Secrets {
    let service: String
    /// Every item carries it, so a test world's keys never mix with real ones.
    let label: String

    public init(service: String, label: String) {
        self.service = service
        self.label = label
    }

    private func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider]
    }

    public func key(for provider: String) -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    /// By the item's attributes alone, which the keychain gives without
    /// asking: reading the key asks again for each new build of Mote.
    public func hasKey(for provider: String) -> Bool {
        var query = query(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func setKey(_ key: String, for provider: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            let status = SecItemDelete(query(provider) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let fields: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrLabel as String: label]
        switch SecItemUpdate(query(provider) as CFDictionary, fields as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var item = query(provider).merging(fields) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }
}

/// Keys held in memory, for tests and previews.
public final class MemorySecrets: Secrets, @unchecked Sendable {
    private var keys: [String: String]
    private let lock = NSLock()

    public init(_ keys: [String: String] = [:]) { self.keys = keys }

    public func key(for provider: String) -> String? { lock.withLock { keys[provider] } }

    @discardableResult
    public func setKey(_ key: String, for provider: String) -> Bool {
        lock.withLock { keys[provider] = key.isEmpty ? nil : key }
        return true
    }
}
