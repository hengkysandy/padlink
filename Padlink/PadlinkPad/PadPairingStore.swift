// Padlink/PadlinkPad/PadPairingStore.swift
import Foundation
import PadlinkCore
import Security

enum PadKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedStoredRecord
}

/// The iPad's `PairingStore`, backed by the Keychain.
///
/// It is a near twin of the Mac's `KeychainPairingStore`, and deliberately not
/// shared with it. The two differ in exactly the parts that matter most, and
/// both differences come from the platform rather than from taste:
///
/// - **`kSecUseDataProtectionKeychain`.** iOS has only the data protection
///   keychain, so asking for it is honest and free. The Mac cannot: the Task 0
///   spike measured `errSecMissingEntitlement` (-34018) from an ad-hoc-signed
///   bundle, so the Mac still uses the legacy file keychain.
/// - **`loadAll` in one pass.** The Mac needs two passes, because asking for
///   `kSecReturnData` and `kSecReturnAttributes` together with
///   `kSecMatchLimitAll` fails with `errSecParam` (-50) on its legacy
///   keychain. The data protection keychain accepts the combined query.
///
/// Sharing the code would mean a type carrying both platforms' workarounds and
/// a flag to pick between them, which is harder to read than two files that
/// each say plainly what their own platform does.
///
/// The whole record is stored as one JSON value rather than spread across
/// Keychain attributes, because `peerName`, `pairedAt`, and `serviceName` have
/// no natural attribute. The JSON encoding lives in a private DTO rather than
/// by making `PairingRecord` itself `Codable`: a public `Codable` conformance
/// on a type holding a 256-bit pre-shared key invites it being serialised
/// somewhere it should not be.
final class PadPairingStore: PairingStore {
    private let service: String

    /// `AfterFirstUnlock` and not `WhenUnlocked`, so a paired iPad can
    /// reconnect after a restart without being unlocked first.
    ///
    /// `ThisDeviceOnly` on top of that, which the plan did not ask for. The
    /// unlock behaviour is identical; the difference is that an item without
    /// it travels inside an encrypted backup and can be restored onto a
    /// **different** iPad. That iPad would then hold a working pre-shared key
    /// to someone's Mac, and could drive its cursor and keyboard, without ever
    /// having scanned a pairing code. The Mac side of this pairing already
    /// uses `ThisDeviceOnly` for the same reason, so this also keeps the two
    /// halves of one secret protected to the same standard.
    /// Bridged to `String` rather than kept as the `CFString` the Security
    /// framework hands out: `CFString` is not `Sendable`, so a static of that
    /// type does not compile under Swift 6 strict concurrency. The bridge back
    /// to `CFString` happens when the query dictionary crosses into the C API.
    static let accessibility: String = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // iOS only has this keychain, so naming it costs nothing and stops
            // the query silently meaning something else on any other platform.
            kSecUseDataProtectionKeychain as String: true,
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

        // Update-first, add-on-not-found, rather than delete-then-add. A
        // delete that succeeds followed by an add that fails would destroy an
        // existing pairing's pre-shared key with no way back short of scanning
        // the QR code again. Updating in place never removes the old item
        // before its replacement is committed.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: record.id.hexString) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PadKeychainError.unexpectedStatus(updateStatus)
        }

        var add = baseQuery(account: record.id.hexString)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessibility

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PadKeychainError.unexpectedStatus(addStatus)
        }
    }

    func load(id: PairingID) throws -> PairingRecord? {
        var query = baseQuery(account: id.hexString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PadKeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw PadKeychainError.malformedStoredRecord }

        return try decode(data, id: id)
    }

    func loadAll() throws -> [PairingRecord] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PadKeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else {
            throw PadKeychainError.malformedStoredRecord
        }

        var records: [PairingRecord] = []
        for item in items {
            // A single unreadable item is skipped rather than thrown, so one
            // corrupt entry cannot lock the user out of a second, good pairing
            // that is sitting right next to it.
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = PairingID(hexString: account),
                  let data = item[kSecValueData as String] as? Data,
                  let record = try? decode(data, id: id)
            else { continue }
            records.append(record)
        }
        return records.sorted { $0.pairedAt < $1.pairedAt }
    }

    func delete(id: PairingID) throws {
        let status = SecItemDelete(baseQuery(account: id.hexString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PadKeychainError.unexpectedStatus(status)
        }
    }

    /// Test support: removes every item under this store's service.
    func deleteAll() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PadKeychainError.unexpectedStatus(status)
        }
    }

    private func decode(_ data: Data, id: PairingID) throws -> PairingRecord {
        let stored: StoredRecord
        do {
            stored = try JSONDecoder().decode(StoredRecord.self, from: data)
        } catch {
            // Deliberately not the underlying decoding error: it quotes the
            // data it failed on, and that data is the key.
            throw PadKeychainError.malformedStoredRecord
        }
        guard let secret = PairingSecret(bytes: stored.secret) else {
            throw PadKeychainError.malformedStoredRecord
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
