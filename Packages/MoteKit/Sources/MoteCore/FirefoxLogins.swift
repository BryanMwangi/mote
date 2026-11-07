import CommonCrypto
import CryptoKit
import Foundation

/// The passwords Firefox-family browsers (Firefox, Zen, LibreWolf…) keep:
/// `logins.json`, encrypted with a key that `key4.db` holds, itself locked
/// with the primary password (empty unless one was set). As NSS does it,
/// and firefox_decrypt after it: PBES2 (PBKDF2-SHA256, AES-256-CBC) for
/// keys since Firefox 58, SHA1 and 3DES before; logins in 3DES or, since
/// Firefox 144, AES.
public enum FirefoxLogins {
    public enum Trouble: Error, Equatable {
        /// A primary password is set, and this isn't it.
        case primaryPassword
        case unreadable
    }

    /// `key4.db`'s rows, read by the caller: the global salt and the
    /// encrypted check (`metadata` where id is "password": item1, item2),
    /// and the encrypted keys (`nssPrivate`: a11, a102).
    public struct KeyStore: Sendable {
        public var globalSalt: Data
        public var check: Data
        public var keys: [(key: Data, id: Data)]

        public init(globalSalt: Data, check: Data, keys: [(key: Data, id: Data)]) {
            self.globalSalt = globalSalt
            self.check = check
            self.keys = keys
        }
    }

    /// The logins keys: the check decrypts to "password-check" with the right
    /// password, then every key NSS keeps for logins (since Firefox 144 an AES
    /// one beside the old 3DES one, under the same id).
    public static func keys(_ store: KeyStore, primaryPassword: String = "") throws -> [Data] {
        let password = Data(primaryPassword.utf8)
        guard let check = DER.parse(store.check), let clear = decrypt(check, salt: store.globalSalt, password: password),
            clear.starts(with: Data("password-check".utf8))
        else { throw Trouble.primaryPassword }
        // Without their padding: 24 bytes for 3DES, 32 for AES.
        let keys = store.keys.compactMap { row in
            DER.parse(row.key).flatMap { decrypt($0, salt: store.globalSalt, password: password) }.flatMap(unpadded)
        }
        guard !keys.isEmpty else { throw Trouble.unreadable }
        return keys
    }

    public struct Login: Equatable, Sendable {
        public var site: String
        public var user: String
        public var password: String
        public var used: Date?
    }

    /// Every login in `logins.json` that decrypts with one of the keys.
    public static func logins(json: Data, keys: [Data]) -> [Login] {
        func open(_ field: Any?) -> String? {
            guard let field = field as? String else { return nil }
            return keys.lazy.compactMap { Self.open(field, key: $0) }.first
        }
        guard let file = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let entries = file["logins"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let site = entry["hostname"] as? String,
                let user = open(entry["encryptedUsername"]), let password = open(entry["encryptedPassword"])
            else { return nil }
            let used = (entry["timeLastUsed"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return Login(site: site, user: user, password: password, used: used)
        }
    }

    /// A login's field: base64 of SEQUENCE { key id, SEQUENCE { cipher, iv }, ciphertext }.
    static func open(_ field: String, key: Data) -> String? {
        guard let data = Data(base64Encoded: field), let der = DER.parse(data), der.children.count == 3,
            der.children[1].children.count == 2, let algorithm = der.children[1].children[0].oid
        else { return nil }
        let iv = der.children[1].children[1].body, cipher = der.children[2].body
        let clear: Data? =
            switch algorithm {
            case "2.16.840.1.101.3.4.1.42" where key.count == 32: crypt(kCCAlgorithmAES, key: key, iv: iv, cipher)
            case "1.2.840.113549.3.7" where key.count == 24: crypt(kCCAlgorithm3DES, key: key, iv: iv, cipher)
            default: nil
            }
        return clear.flatMap(unpadded).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A key4.db item: SEQUENCE { SEQUENCE { algorithm, parameters }, ciphertext }.
    static func decrypt(_ item: DER, salt globalSalt: Data, password: Data) -> Data? {
        guard item.children.count == 2, item.children[0].children.count == 2, let algorithm = item.children[0].children[0].oid
        else { return nil }
        let parameters = item.children[0].children[1], cipher = item.children[1].body
        let hashed = Data(Insecure.SHA1.hash(data: globalSalt + password))
        switch algorithm {
        case "1.2.840.113549.1.5.13":  // PBES2
            let derivation = parameters.children.first?.children.last, scheme = parameters.children.last
            guard let derivation, let scheme, derivation.children.count >= 2, scheme.children.count == 2,
                let rounds = derivation.children[1].integer
            else { return nil }
            let salt = derivation.children[0].body
            var key = [UInt8](repeating: 0, count: 32)
            let status = hashed.withUnsafeBytes { pass in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: CChar.self), hashed.count, Array(salt),
                    salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, key.count)
            }
            guard status == kCCSuccess else { return nil }
            // NSS keeps 14 bytes of the IV, without its DER header.
            var iv = scheme.children[1].body
            if iv.count == 14 { iv = Data([0x04, 0x0e]) + iv }
            return crypt(kCCAlgorithmAES, key: Data(key), iv: iv, cipher)
        case "1.2.840.113549.1.12.5.1.3":  // SHA1 and 3DES, before Firefox 58
            guard let entrySalt = parameters.children.first?.body else { return nil }
            let padded = entrySalt + Data(repeating: 0, count: max(0, 20 - entrySalt.count))
            let combined = Data(Insecure.SHA1.hash(data: hashed + entrySalt))
            func mac(_ message: Data) -> Data { Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: combined))) }
            let derived = mac(padded + entrySalt) + mac(mac(padded) + entrySalt)
            return crypt(kCCAlgorithm3DES, key: derived.prefix(24), iv: derived.suffix(8), cipher)
        default:
            return nil
        }
    }

    /// CBC, unpadded: callers check or strip the padding themselves.
    private static func crypt(_ algorithm: Int, key: Data, iv: Data, _ input: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(algorithm), 0, Array(key), key.count, Array(iv), Array(input), input.count, &output,
            output.count, &written)
        return status == kCCSuccess ? Data(output.prefix(written)) : nil
    }

    private static func unpadded(_ data: Data) -> Data? {
        guard let last = data.last, last > 0, last <= 16, data.count >= Int(last) else { return nil }
        return data.dropLast(Int(last))
    }
}

/// Just enough DER for NSS's records: a tag, its bytes, and what's inside.
struct DER {
    let tag: UInt8
    let body: Data
    let children: [DER]

    static func parse(_ data: Data) -> DER? { elements(Data(data)).first }

    private static func elements(_ data: Data) -> [DER] {
        var found: [DER] = []
        var at = data.startIndex
        while at < data.endIndex {
            let tag = data[at]
            at += 1
            guard at < data.endIndex else { break }
            var length = Int(data[at])
            at += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count <= 4, at + count <= data.endIndex else { break }
                length = data[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
                at += count
            }
            guard at + length <= data.endIndex else { break }
            let body = Data(data[at..<at + length])
            found.append(DER(tag: tag, body: body, children: tag & 0x20 != 0 ? elements(body) : []))
            at += length
        }
        return found
    }

    var oid: String? {
        guard tag == 0x06, let first = body.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in body.dropFirst() {
            value = value << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    var integer: Int? { tag == 0x02 ? body.reduce(0) { $0 << 8 | Int($1) } : nil }
}
