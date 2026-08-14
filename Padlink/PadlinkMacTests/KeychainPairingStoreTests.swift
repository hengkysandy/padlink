// Padlink/PadlinkMacTests/KeychainPairingStoreTests.swift
import XCTest
import PadlinkCore
import Security
@testable import PadlinkMac

final class KeychainPairingStoreTests: XCTestCase {
    private var store: KeychainPairingStore!
    private let testService = "com.hengkysandy.padlink.tests"

    override func setUpWithError() throws {
        store = KeychainPairingStore(service: testService)
        try store.deleteAll()
    }

    override func tearDownWithError() throws {
        try store.deleteAll()
    }

    private func record(_ byte: UInt8, name: String, serviceName: String? = "Test Mac") throws -> PairingRecord {
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
        let saved = try record(1, name: "iPad Air")
        try store.save(saved)
        XCTAssertEqual(try store.load(id: saved.id), saved)
    }

    func testTheSecretSurvivesTheRoundTripExactly() throws {
        // The whole product rests on this being byte-for-byte correct.
        let saved = try record(0xAB, name: "iPad")
        try store.save(saved)
        let loaded = try XCTUnwrap(try store.load(id: saved.id))
        XCTAssertEqual(loaded.secret.bytes, saved.secret.bytes)
    }

    func testLoadingAnUnknownIDReturnsNil() throws {
        let unknown = try XCTUnwrap(PairingID(bytes: Data(repeating: 9, count: 8)))
        XCTAssertNil(try store.load(id: unknown))
    }

    func testSavingTheSameIDTwiceReplaces() throws {
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
        // Proves the update-first save path replaces the whole stored
        // value, including the secret, not just leaves the old JSON blob
        // with a coincidentally-matching peerName.
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

    func testLoadingAMalformedRecordThrowsMalformedStoredRecordNotADecodingError() throws {
        // The store cannot itself produce a malformed record, so this writes
        // one directly with SecItemAdd, bypassing `save`.
        //
        // `kSecUseDataProtectionKeychain` must match the store's own queries.
        // macOS has two separate keychains, and the flag chooses between them,
        // so without it this writes to the legacy one while the store reads the
        // modern one. The symptom is not a missing item but `errSecDuplicateItem`
        // on the second run, because the legacy writes accumulate where nothing
        // ever cleans them up.
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 8, count: 8)))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: id.hexString,
            kSecValueData as String: Data([0x00, 0x01, 0x02]), // not valid JSON
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        XCTAssertThrowsError(try store.load(id: id)) { error in
            XCTAssertEqual(error as? KeychainError, .malformedStoredRecord)
        }
    }
}
