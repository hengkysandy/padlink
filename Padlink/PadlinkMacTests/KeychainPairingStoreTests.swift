// Padlink/PadlinkMacTests/KeychainPairingStoreTests.swift
import XCTest
import PadlinkCore
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
        let second = PairingRecord(
            id: first.id,
            secret: first.secret,
            peerName: "new name",
            serviceName: first.serviceName,
            pairedAt: first.pairedAt
        )
        try store.save(second)

        XCTAssertEqual(try store.load(id: first.id)?.peerName, "new name")
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
}
