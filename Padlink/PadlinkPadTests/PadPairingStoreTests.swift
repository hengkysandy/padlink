// Padlink/PadlinkPadTests/PadPairingStoreTests.swift
import XCTest
import PadlinkCore
import Security
@testable import PadlinkPad

final class PadPairingStoreTests: XCTestCase {
    private var store: PadPairingStore!
    private let testService = "com.hengkysandy.padlink.pad.tests"

    override func setUpWithError() throws {
        store = PadPairingStore(service: testService)
        try store.deleteAll()
    }

    override func tearDownWithError() throws {
        try store.deleteAll()
    }

    private func record(
        _ byte: UInt8,
        name: String,
        serviceName: String? = "Test Mac"
    ) throws -> PairingRecord {
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: byte, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: byte, count: 32)))
        return PairingRecord(
            id: id,
            secret: secret,
            peerName: name,
            serviceName: serviceName,
            pairedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    func testSavesAndLoadsARecord() throws {
        let saved = try record(1, name: "Home Mac")
        try store.save(saved)
        XCTAssertEqual(try store.load(id: saved.id), saved)
    }

    /// The whole product rests on this being byte-for-byte correct: these
    /// bytes are the TLS pre-shared key.
    func testTheSecretSurvivesTheRoundTripExactly() throws {
        let saved = try record(0xAB, name: "Home Mac")
        try store.save(saved)
        let loaded = try XCTUnwrap(try store.load(id: saved.id))
        XCTAssertEqual(loaded.secret.bytes, saved.secret.bytes)
    }

    /// The iPad needs this one specifically. `MacBrowser` matches on it, and a
    /// dropped service name means the iPad can never find the Mac it paired
    /// with.
    func testTheServiceNameSurvivesTheRoundTrip() throws {
        let saved = try record(0x11, name: "Home Mac", serviceName: "Home Mac (2)")
        try store.save(saved)
        XCTAssertEqual(try store.load(id: saved.id)?.serviceName, "Home Mac (2)")
    }

    func testLoadingAnUnknownIDReturnsNil() throws {
        let unknown = try XCTUnwrap(PairingID(bytes: Data(repeating: 9, count: 8)))
        XCTAssertNil(try store.load(id: unknown))
    }

    func testSavingTheSameIDTwiceReplacesEverything() throws {
        let first = try record(2, name: "old name")
        try store.save(first)
        let secondSecret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 0xCD, count: 32)))
        let second = PairingRecord(
            id: first.id,
            secret: secondSecret,
            peerName: "new name",
            serviceName: first.serviceName,
            pairedAt: first.pairedAt
        )
        try store.save(second)

        let loaded = try XCTUnwrap(try store.load(id: first.id))
        XCTAssertEqual(loaded.peerName, "new name")
        XCTAssertEqual(loaded.secret.bytes, secondSecret.bytes)
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testLoadAllReturnsOldestFirst() throws {
        let older = try record(3, name: "older")
        let newerID = try XCTUnwrap(PairingID(bytes: Data(repeating: 4, count: 8)))
        let newerSecret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 4, count: 32)))
        let newer = PairingRecord(
            id: newerID,
            secret: newerSecret,
            peerName: "newer",
            serviceName: nil,
            pairedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        try store.save(newer)
        try store.save(older)

        XCTAssertEqual(try store.loadAll().map(\.peerName), ["older", "newer"])
    }

    func testANilServiceNameSurvives() throws {
        let saved = try record(5, name: "no service", serviceName: nil)
        try store.save(saved)
        XCTAssertNil(try store.load(id: saved.id)?.serviceName)
    }

    func testDeleteRemovesARecord() throws {
        let saved = try record(6, name: "gone")
        try store.save(saved)
        try store.delete(id: saved.id)
        XCTAssertNil(try store.load(id: saved.id))
    }

    func testDeletingAnUnknownIDIsNotAnError() throws {
        let unknown = try XCTUnwrap(PairingID(bytes: Data(repeating: 7, count: 8)))
        XCTAssertNoThrow(try store.delete(id: unknown))
    }

    func testLoadingAMalformedRecordThrowsMalformedStoredRecord() throws {
        // The store cannot produce a malformed record itself, so this writes
        // one directly, bypassing `save`.
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 8, count: 8)))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: id.hexString,
            kSecValueData as String: Data([0x00, 0x01, 0x02]), // not valid JSON
            kSecAttrAccessible as String: PadPairingStore.accessibility
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        XCTAssertThrowsError(try store.load(id: id)) { error in
            XCTAssertEqual(error as? PadKeychainError, .malformedStoredRecord)
        }
    }

    // MARK: - How the item is protected

    /// Two properties, both load-bearing, both invisible from a round trip.
    ///
    /// `AfterFirstUnlock` and not `WhenUnlocked`: a paired iPad has to be able
    /// to reconnect after a restart without the user unlocking it first.
    ///
    /// `ThisDeviceOnly`: without it the item travels in an encrypted backup
    /// and can be restored onto a **different** iPad, which would then hold a
    /// working key to someone's Mac without ever having paired with it. The
    /// unlock behaviour is identical either way, so this costs nothing.
    func testTheStoredItemIsAfterFirstUnlockAndCannotLeaveThisDevice() throws {
        let saved = try record(0x21, name: "Home Mac")
        try store.save(saved)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: saved.id.hexString
        ]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)

        let attributes = try XCTUnwrap(result as? [String: Any])
        let accessible = attributes[kSecAttrAccessible as String] as CFTypeRef?
        XCTAssertEqual(
            accessible as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    /// The key must never sync to iCloud Keychain. `kSecAttrSynchronizable`
    /// defaults to false, and this pins that default so a later edit that adds
    /// it is caught.
    func testTheStoredItemDoesNotSyncToICloud() throws {
        let saved = try record(0x22, name: "Home Mac")
        try store.save(saved)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: saved.id.hexString,
            kSecAttrSynchronizable as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        // Asking only for synchronizable items must find nothing.
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound)
    }
}
