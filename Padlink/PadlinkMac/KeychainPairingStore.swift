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
        // Deliberately NOT setting kSecUseDataProtectionKeychain. The Task 0
        // spike measured that it fails from an ad-hoc-signed bundle with
        // errSecMissingEntitlement (-34018). The legacy file keychain works
        // and survives rebuilds. Revisit when a Developer ID identity and a
        // keychain-access-group entitlement exist.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
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

        // Replace rather than add, so saving the same id twice does not
        // produce a duplicate item.
        SecItemDelete(baseQuery(account: record.id.hexString) as CFDictionary)

        var add = baseQuery(account: record.id.hexString)
        add[kSecValueData as String] = data
        // This device only, so the secret never syncs to iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
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
        let stored = try JSONDecoder().decode(StoredRecord.self, from: data)
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
