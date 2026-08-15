// Padlink/PadlinkMac/KeychainPairingStore.swift
import Foundation
import PadlinkCore
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedStoredRecord
}

/// A `PairingStore` backed by the Keychain.
///
/// The whole record is stored as one JSON value rather than spread across
/// Keychain attributes, because `peerName`, `pairedAt`, and `serviceName` have
/// no natural attribute and inventing one would be worse.
///
/// The JSON encoding lives in a private DTO rather than by making
/// `PairingRecord` itself `Codable`. A public `Codable` conformance on a type
/// holding a 256-bit pre-shared key invites it being serialised somewhere it
/// should not be.
final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    private let service: String

    // Guards `dataProtectionDecision` only. `PairingStore` is `Sendable`, and a
    // final class stops being implicitly Sendable the moment it holds a `var`.
    private let lock = NSLock()
    private var dataProtectionDecision: Bool?

    init(service: String = Padlink.keychainService) {
        self.service = service
    }

    /// Whether this build is allowed to use the data protection keychain.
    ///
    /// Measured once, not declared. The keychain that is available depends on
    /// how the app was signed, and the same source now ships two ways: a local
    /// build signed with the user's Apple team, and the ad-hoc signed build in
    /// the released .dmg. Only the first carries the
    /// `keychain-access-groups` entitlement, so only the first can write to the
    /// data protection keychain. The second gets -34018
    /// (`errSecMissingEntitlement`) on every write.
    ///
    /// An ad-hoc build cannot simply keep the entitlement and lose the team:
    /// `keychain-access-groups` is a restricted entitlement, and the kernel
    /// kills an ad-hoc signed process that claims one. So the released build has
    /// no entitlements at all, and falls back to the legacy file keychain.
    ///
    /// The legacy keychain's known problem (a login-password prompt on every
    /// launch that "Always Allow" cannot stop) comes from `get-task-allow`,
    /// which only a Debug build carries. The released build is Release and
    /// ad-hoc, so its item access list holds a stable snapshot and reads
    /// succeed across launches with no prompt. Measured on macOS on
    /// 2026-08-15, not assumed.
    /// Internal rather than private so the tests can write raw items into
    /// whichever keychain the store itself chose. Writing to the other one
    /// leaves items where nothing ever cleans them up.
    var usesDataProtectionKeychain: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let decided = dataProtectionDecision { return decided }
        let decided = Self.dataProtectionKeychainAcceptsWrites(service: service)
        dataProtectionDecision = decided
        return decided
    }

    /// Tries a throwaway write, rather than reading the signature or the
    /// entitlement and guessing what the keychain will make of it.
    ///
    /// A write is the only operation that reveals the answer. Reading the wrong
    /// keychain returns `errSecItemNotFound`, which is indistinguishable from an
    /// app that has simply never paired, so a read-based probe would silently
    /// pick the wrong backend and make an existing pairing look lost.
    private static func dataProtectionKeychainAcceptsWrites(service: String) -> Bool {
        // Deliberately not a `PairingID`-shaped account, so `loadAll` skips it
        // even if a crash between the add and the delete leaves it behind.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "data-protection-probe",
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(probe as CFDictionary)

        var add = probe
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { return false }

        SecItemDelete(probe as CFDictionary)
        return true
    }

    private struct StoredRecord: Codable {
        let secret: Data
        let peerName: String
        let pairedAt: Date
        let serviceName: String?
    }

    private func baseQuery(account: String?) -> [String: Any] {
        // The data protection keychain, matching iOS, whenever this build is
        // signed well enough to be allowed it.
        //
        // A team-signed build gets it. Items there key on the signed identity,
        // so they survive rebuilds and never prompt for the login password.
        //
        // The ad-hoc signed release build cannot have it, and drops to the
        // legacy file keychain instead. See `usesDataProtectionKeychain` for
        // why, and for why the legacy keychain's prompt-on-every-launch problem
        // does not apply to a Release build.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func save(_ record: PairingRecord) throws {
        let stored = StoredRecord(
            secret: record.secret.bytes,
            peerName: record.peerName,
            pairedAt: record.pairedAt,
            serviceName: record.serviceName
        )
        let data = try JSONEncoder().encode(stored)

        // Update-first, add-on-not-found, rather than delete-then-add. A
        // delete that succeeds followed by an add that fails would destroy
        // an existing pairing's TLS pre-shared key with no way back short of
        // re-scanning the QR code. Updating in place never removes the old
        // item before its replacement is committed, so a failed write
        // leaves the previous pairing intact.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            // This device only, so the secret never syncs to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: record.id.hexString) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var add = baseQuery(account: record.id.hexString)
        add[kSecValueData as String] = data
        // This device only, so the secret never syncs to iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func load(id: PairingID) throws -> PairingRecord? {
        var query = baseQuery(account: id.hexString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.malformedStoredRecord }

        return try decode(data, id: id)
    }

    func loadAll() throws -> [PairingRecord] {
        // Two passes rather than one combined query. Asking for
        // kSecReturnData and kSecReturnAttributes together with
        // kSecMatchLimitAll measurably fails with errSecParam (-50) on this
        // project's legacy file keychain, even though each option works on
        // its own. So this first pass asks for attributes only, to learn
        // which ids exist, then the second pass reuses `load(id:)`, which
        // already fetches a single item's data successfully.
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { throw KeychainError.malformedStoredRecord }

        var records: [PairingRecord] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = PairingID(hexString: account),
                  let record = try load(id: id)
            else { continue }
            records.append(record)
        }
        return records.sorted { $0.pairedAt < $1.pairedAt }
    }

    func delete(id: PairingID) throws {
        let status = SecItemDelete(baseQuery(account: id.hexString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Test support: removes every item under this store's service.
    func deleteAll() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func decode(_ data: Data, id: PairingID) throws -> PairingRecord {
        let stored: StoredRecord
        do {
            stored = try JSONDecoder().decode(StoredRecord.self, from: data)
        } catch {
            throw KeychainError.malformedStoredRecord
        }
        guard let secret = PairingSecret(bytes: stored.secret) else {
            throw KeychainError.malformedStoredRecord
        }
        return PairingRecord(
            id: id,
            secret: secret,
            peerName: stored.peerName,
            serviceName: stored.serviceName,
            pairedAt: stored.pairedAt
        )
    }
}
