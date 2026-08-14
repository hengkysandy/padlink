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
final class KeychainPairingStore: PairingStore {
    private let service: String

    init(service: String = Padlink.keychainService) {
        self.service = service
    }

    private struct StoredRecord: Codable {
        let secret: Data
        let peerName: String
        let pairedAt: Date
        let serviceName: String?
    }

    private func baseQuery(account: String?) -> [String: Any] {
        // The data protection keychain, matching iOS.
        //
        // The Task 0 spike rejected this because it returned -34018
        // (errSecMissingEntitlement) from the ad-hoc signed bundle the project
        // had then. That blocker is gone: the app now signs with a real team
        // and carries a keychain-access-group entitlement.
        //
        // The claim that replaced it, that the legacy keychain "survives
        // rebuilds", turned out to be false in practice. Legacy items are
        // guarded by a per-item access list holding a snapshot of the trusted
        // binary, and a Debug build carries `get-task-allow`, so macOS treats
        // it as debuggable and refuses to persist the grant at all. That is a
        // login-password prompt on every launch which "Always Allow" cannot
        // stop. This keychain keys on the signed identity instead, so it
        // survives rebuilds and never prompts.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
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
