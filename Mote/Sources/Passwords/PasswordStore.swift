import CryptoKit
import Foundation
import LocalAuthentication
import MoteCore
import Security

/// Saved passwords, sealed with AES-GCM in the profile's folder under one key
/// kept in the macOS keychain. One key, not an item per password: macOS asks
/// whether Mote may read a keychain item again after every update of an app
/// signed as Mote is, and with an item per password it asked once for each.
/// Never in a log, and the passwords never kept in memory between reads.
/// (Safari's own passwords can't be read by other browsers.)
///
/// Earlier Motes kept an item per password. Each is moved into the vault the
/// first time it's read; until then it's listed from the keychain as before.
enum PasswordStore {
    // MARK: - Reading

    /// Logins saved for exactly this host.
    static func logins(for host: String) -> [Login] {
        let kept = Vault.logins().filter { $0.host == host }
        return kept + Keychain.items(server: host).filter { item in !kept.contains { $0.user == item.account } }.compactMap(moved)
    }

    /// Logins for the host and other hosts on the same site, most recent
    /// first, without the passwords of those still in the old keychain items
    /// (`password(for:)` reads one when it's picked).
    static func accounts(matching host: String) -> [Login] {
        let domain = registrable(host)
        return Login.matching(host, in: accounts().filter { $0.host == host || registrable($0.host) == domain }, site: registrable)
    }

    /// Every saved account, by site and account. Passwords are read only when
    /// asked for (`password(for:)`).
    static func accounts() -> [Login] {
        let kept = Vault.logins().map { Login(host: $0.host, user: $0.user, password: "", used: $0.used, clear: $0.clear) }
        let old = Keychain.items().filter { item in !kept.contains { $0.host == item.server && $0.user == item.account } }
        return Login.listed(kept + old.map { Login(host: $0.server, user: $0.account, password: "", used: $0.used, clear: $0.clear) })
    }

    /// A listed account's password.
    static func password(for login: Login) -> String? {
        if let kept = Vault.logins().first(where: { $0.host == login.host && $0.user == login.user }) { return kept.password }
        return Keychain.items(server: login.host).first { $0.account == login.user }.flatMap(moved)?.password
    }

    /// An old keychain item's login, read and moved into the vault.
    private static func moved(_ item: Keychain.Item) -> Login? {
        guard let login = item.login else { return nil }
        Vault.save(login)
        return login
    }

    // MARK: - Writing

    /// Saves or updates a login. Fails for an empty site or password, or when
    /// the keychain wouldn't give up the vault's key.
    @discardableResult
    static func save(_ login: Login) -> Bool {
        guard !login.host.isEmpty, !login.password.isEmpty else { return false }
        return Vault.save(login)
    }

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false) -> Bool {
        save(Login(host: host, user: user, password: password, used: used, clear: clear))
    }

    /// Notes that the login was just used.
    static func touch(_ login: Login) {
        guard let password = login.password.isEmpty ? password(for: login) : login.password else { return }
        save(Login(host: login.host, user: login.user, password: password, used: Date(), clear: login.clear))
    }

    static func forget(host: String, user: String) {
        Vault.forget(host: host, user: user)
        Keychain.delete(server: host, account: user)
    }

    /// Brings in a passwords CSV export. The file itself is not kept.
    static func take(csv text: String) -> (kept: Int, skipped: Int) {
        let read = PasswordExport.read(csv: text)
        let kept = Vault.save(read.logins.filter { !$0.host.isEmpty && !$0.password.isEmpty })
        return (kept, read.skipped + read.logins.count - kept)
    }

    // MARK: - Sites never to offer saving for

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Storage.settings.stringArray(forKey: neverKey) ?? []) }
        set { Storage.settings.set(newValue.sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - Sites

    /// The registrable domain: `example.com` for `accounts.example.com`,
    /// `bbc.co.uk` for itself.
    static func registrable(_ host: String) -> String {
        RegistrableDomain.of(host, isPublicSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    nonisolated static func host(of text: String) -> String { Address.siteHost(typed: text) }

    // MARK: - Proving it's you

    /// Asks for Touch ID, a watch or the account password before a password
    /// is shown or copied. A Mac with no way to ask (no account password) lets it through.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return done(true) }
        Task { done((try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false) }
    }

    /// Whether filling waits for Touch ID (Settings › Passwords).
    static var provesFilling: Bool {
        get { Storage.settings.bool(forKey: "passwords.touchID") }
        set { Storage.settings.set(newValue, forKey: "passwords.touchID") }
    }

    /// Proven for filling: once, then until the Mac locks or Mote quits.
    @MainActor private static var provenToFill = false
    @MainActor private static var watchingLock: NSObjectProtocol?

    /// Before a saved password goes into a page, when filling waits for Touch ID.
    @MainActor static func proveToFill(_ host: String, _ done: @escaping (Bool) -> Void) {
        guard provesFilling, !provenToFill else { return done(true) }
        watchingLock = watchingLock ?? DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { provenToFill = false } }
        prove("fill your password for \(host)") { ok in
            MainActor.assumeIsolated {
                if ok { provenToFill = true }
                done(ok)
            }
        }
    }
}

/// The sealed passwords, and the one keychain item that holds their key.
private enum Vault {
    private static let file = Storage.file("passwords.vault")
    private static let lock = NSLock()
    /// Read once a launch: macOS asks at most once, after an update.
    nonisolated(unsafe) private static var known: SymmetricKey?
    /// The person said no to macOS's question: not asked again this launch.
    nonisolated(unsafe) private static var declined = false

    static func logins() -> [Login] {
        lock.withLock { read() } ?? []
    }

    @discardableResult
    static func save(_ login: Login) -> Bool { save([login]) == 1 }

    /// Saves or updates each, by site and account; how many were kept.
    @discardableResult
    static func save(_ logins: [Login]) -> Int {
        lock.withLock {
            guard !logins.isEmpty, var all = read() else { return 0 }
            for login in logins {
                all.removeAll { $0.host == login.host && $0.user == login.user }
                all.append(login)
            }
            return write(all) ? logins.count : 0
        }
    }

    static func forget(host: String, user: String) {
        lock.withLock {
            guard var all = read() else { return }
            all.removeAll { $0.host == host && $0.user == user }
            _ = write(all)
        }
    }

    /// Every login, or nil when there's no key to open them with.
    private static func read() -> [Login]? {
        guard let key = key() else { return nil }
        guard let sealed = try? Data(contentsOf: file) else { return [] }
        guard let box = try? AES.GCM.SealedBox(combined: sealed), let data = try? AES.GCM.open(box, using: key),
            let logins = try? JSONDecoder().decode([Login].self, from: data)
        else {
            // Sealed under a key that's gone: kept aside, never written over.
            NSLog("Passwords: the vault can't be opened; it's kept as passwords.vault.unopened")
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unopened"))
            return []
        }
        return logins
    }

    private static func write(_ logins: [Login]) -> Bool {
        guard let key = key(), let data = try? JSONEncoder().encode(logins), let sealed = try? AES.GCM.seal(data, using: key).combined
        else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? sealed.write(to: file, options: .atomic)) != nil
    }

    /// The vault's key, made the first time. Nil when the keychain says no:
    /// then nothing is read or written, and no new key replaces the old.
    private static func key() -> SymmetricKey? {
        if let known { return known }
        if declined { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Mote Safe Storage",
            kSecAttrAccount as String: Keychain.label,
        ]
        var found: CFTypeRef?
        var status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
        if status == errSecItemNotFound {
            let made = SymmetricKey(size: .bits256)
            query[kSecValueData as String] = made.withUnsafeBytes { Data($0) }
            query[kSecAttrLabel as String] = "Mote Safe Storage"
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                NSLog("Passwords: the keychain wouldn't keep the vault's key (%d)", status)
                return nil
            }
            known = made
            return made
        }
        if status == errSecUserCanceled || status == errSecAuthFailed { declined = true }
        guard status == errSecSuccess, let data = found as? Data, data.count == 32 else {
            NSLog("Passwords: the keychain wouldn't give up the vault's key (%d)", status)
            return nil
        }
        known = SymmetricKey(data: data)
        return known
    }
}

/// The internet-password items earlier Motes kept, one per password.
private enum Keychain {
    /// Every item carries this label. Test worlds use their own, so their
    /// items never mix with the real ones.
    static let label = (Storage.world.map { "Mote (\($0))" } ?? "Mote") + (Storage.profile.map { " profile \($0)" } ?? "")

    /// An item's attributes, without its secret.
    struct Item {
        let server: String
        let account: String
        let used: Date?
        let clear: Bool

        /// The item with its password read, or nil if it can't be.
        var login: Login? {
            secret(server: server, account: account).map {
                Login(host: server, user: account, password: $0, used: used, clear: clear)
            }
        }
    }

    private static func base(server: String? = nil, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: label]
        if let server { query[kSecAttrServer as String] = server }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Lists items by their attributes. The keychain can't return several
    /// items' secrets in one query (errSecParam), so those are read one by one.
    static func items(server: String? = nil) -> [Item] {
        var query = base(server: server)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let rows = found as? [[String: Any]] else {
            // The list can't show this apart from an empty keychain, so say it here.
            if status != errSecItemNotFound { NSLog("Passwords: keychain list failed (%d)", status) }
            return []
        }
        return rows.compactMap { row in
            guard let server = row[kSecAttrServer as String] as? String, let account = row[kSecAttrAccount as String] as? String
            else { return nil }
            // The last use is kept in the comment, as a Unix time.
            let used = (row[kSecAttrComment as String] as? String).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let clear = row[kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTP as String
            return Item(server: server, account: account, used: used, clear: clear)
        }
    }

    static func secret(server: String, account: String) -> String? {
        var query = base(server: server, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data else {
            if status != errSecItemNotFound { NSLog("Passwords: keychain read failed (%d)", status) }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(server: String, account: String) {
        SecItemDelete(base(server: server, account: account) as CFDictionary)
    }
}
