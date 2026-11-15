import CryptoKit
import Foundation

/// A site's push messages, as the Web Push standards have them (RFC 8291 on
/// RFC 8188, "aes128gcm"): each subscription has a key pair and an
/// authentication secret; the site encrypts to them, and only Mote can read
/// what arrives.
public enum WebPush {
    /// A subscription's own secrets: its P-256 private key and its 16-byte
    /// authentication secret.
    public struct Keys: Codable, Equatable, Sendable {
        public let privateKey: Data
        public let auth: Data

        public init(privateKey: Data, auth: Data) {
            self.privateKey = privateKey
            self.auth = auth
        }

        /// New keys for a new subscription.
        public static func make() -> Keys {
            var auth = Data(count: 16)
            auth.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return Keys(privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation, auth: auth)
        }

        /// The public key a site encrypts to (`p256dh`), uncompressed.
        public var publicKey: Data {
            (try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation) ?? Data()
        }
    }

    public enum Failure: Error, Equatable {
        case short, key, record, padding
    }

    /// The words of a message encrypted to `keys`.
    public static func decrypt(_ body: Data, with keys: Keys) throws -> Data {
        let body = Data(body)
        // Header: salt (16), record size (4), key id length (1), key id: the sender's public key.
        guard body.count > 21 else { throw Failure.short }
        let salt = body.prefix(16)
        let size = body.dropFirst(16).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        let idLength = Int(body[body.startIndex + 20])
        guard size > 17, body.count >= 21 + idLength else { throw Failure.short }
        let sender = body.dropFirst(21).prefix(idLength)
        guard let private_ = try? P256.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey),
            let them = try? P256.KeyAgreement.PublicKey(x963Representation: sender)
        else { throw Failure.key }
        let (key, nonce) = try derive(
            salt: salt, shared: private_.sharedSecretFromKeyAgreement(with: them), auth: keys.auth,
            receiver: private_.publicKey.x963Representation, sender: Data(sender))
        var plain = Data()
        let records = body.dropFirst(21 + idLength)
        var at = records.startIndex
        var sequence: UInt64 = 0
        while at < records.endIndex {
            let end = min(at + size, records.endIndex)
            let record = records[at..<end]
            guard record.count > 16 else { throw Failure.record }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: mix(nonce, sequence)), ciphertext: record.dropLast(16), tag: record.suffix(16))
            guard let opened = try? AES.GCM.open(box, using: key) else { throw Failure.record }
            // Padding: the words, a delimiter (2 for the last record, 1 before), zeros.
            guard let delimiter = opened.lastIndex(where: { $0 != 0 }), opened[delimiter] == (end == records.endIndex ? 2 : 1) else {
                throw Failure.padding
            }
            plain.append(opened[opened.startIndex..<delimiter])
            at = end
            sequence += 1
        }
        return plain
    }

    /// The words of a message in the older scheme ("aesgcm", draft 4 of the
    /// standard), which servers still send: its salt and record size come in
    /// the `Encryption` header, the sender's key in `Crypto-Key`.
    public static func decrypt(aesgcm body: Data, encryption: String, cryptoKey: String, with keys: Keys) throws -> Data {
        let body = Data(body)
        let params = parameters(encryption.split(separator: ",", maxSplits: 1).first.map(String.init) ?? "")
        // The sender's key: the one named by the same key id, or the first.
        let offered = cryptoKey.split(separator: ",").map { parameters(String($0)) }
        let dh =
            offered.first { $0["keyid"] != nil && $0["keyid"] == params["keyid"] && $0["dh"] != nil }?["dh"]
            ?? offered.first { $0["dh"] != nil }?["dh"]
        guard let salt = params["salt"].flatMap(data(base64url:)), salt.count == 16, let sender = dh.flatMap(data(base64url:)) else {
            throw Failure.short
        }
        let size = params["rs"].map { Int($0) ?? 0 } ?? 4096
        // Records hold the size and a tag; the last is short, an empty one if need be.
        guard size >= 1, !body.isEmpty, body.count % (size + 16) != 0 else { throw Failure.short }
        guard let private_ = try? P256.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey),
            let them = try? P256.KeyAgreement.PublicKey(x963Representation: sender)
        else { throw Failure.key }
        let secret = try private_.sharedSecretFromKeyAgreement(with: them).withUnsafeBytes { Data($0) }
        let input = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: keys.auth, info: Data("Content-Encoding: auth".utf8) + [0],
            outputByteCount: 32)
        let receiver = private_.publicKey.x963Representation
        // "P-256", then each key after its length in two bytes.
        var context = Data("P-256".utf8) + [0]
        for key in [receiver, sender] {
            context.append(contentsOf: [UInt8(key.count >> 8), UInt8(key.count & 0xff)])
            context.append(key)
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, salt: salt, info: Data("Content-Encoding: aesgcm".utf8) + [0] + context, outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0] + context, outputByteCount: 12
        ).withUnsafeBytes { Data($0) }
        var plain = Data()
        var at = body.startIndex
        var sequence: UInt64 = 0
        while at < body.endIndex {
            let end = min(at + size + 16, body.endIndex)
            let record = body[at..<end]
            guard record.count > 16,
                let opened = try? AES.GCM.open(
                    AES.GCM.SealedBox(
                        nonce: AES.GCM.Nonce(data: mix(nonce, sequence)), ciphertext: record.dropLast(16), tag: record.suffix(16)),
                    using: key)
            else { throw Failure.record }
            // Padding: its length in two bytes, then that many zeros.
            guard opened.count >= 2 else { throw Failure.padding }
            let pad = Int(opened[opened.startIndex]) << 8 | Int(opened[opened.startIndex + 1])
            let words = opened.startIndex + 2 + pad
            guard words <= opened.endIndex, opened[(opened.startIndex + 2)..<words].allSatisfy({ $0 == 0 }) else { throw Failure.padding }
            plain.append(opened[words...])
            at = end
            sequence += 1
        }
        return plain
    }

    /// A header's `name=value; name="value"` parameters.
    private static func parameters(_ field: String) -> [String: String] {
        var found: [String: String] = [:]
        for part in field.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            found[pair[0].lowercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return found
    }

    /// `plain` encrypted to a subscription's public key and secret, as a site
    /// would send it, in one record.
    public static func encrypt(_ plain: Data, to publicKey: Data, auth: Data) throws -> Data {
        let mine = P256.KeyAgreement.PrivateKey()
        guard let them = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey) else { throw Failure.key }
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let sender = mine.publicKey.x963Representation
        let (key, nonce) = try derive(
            salt: salt, shared: mine.sharedSecretFromKeyAgreement(with: them), auth: auth, receiver: publicKey, sender: sender)
        let sealed = try AES.GCM.seal(plain + [2], using: key, nonce: AES.GCM.Nonce(data: mix(nonce, 0)))
        let size = UInt32(plain.count + 1 + 16)
        return salt + withUnsafeBytes(of: size.bigEndian) { Data($0) } + [UInt8(sender.count)] + sender + sealed.ciphertext + sealed.tag
    }

    private static func derive(
        salt: Data, shared: SharedSecret, auth: Data, receiver: Data, sender: Data
    ) throws -> (
        SymmetricKey, Data
    ) {
        let secret = shared.withUnsafeBytes { Data($0) }
        let input = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: auth, info: Data("WebPush: info".utf8) + [0] + receiver + sender,
            outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, salt: salt, info: Data("Content-Encoding: aes128gcm".utf8) + [0], outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0], outputByteCount: 12)
        return (key, nonce.withUnsafeBytes { Data($0) })
    }

    /// The record's nonce: the base nonce with its sequence number XORed into the end.
    private static func mix(_ nonce: Data, _ sequence: UInt64) -> Data {
        var mixed = [UInt8](nonce)
        for index in 0..<8 { mixed[mixed.count - 1 - index] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(index))) }
        return Data(mixed)
    }

    // MARK: - Base64url, as push messages and keys travel

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}
