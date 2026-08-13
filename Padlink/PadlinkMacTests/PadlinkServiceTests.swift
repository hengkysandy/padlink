// Padlink/PadlinkMacTests/PadlinkServiceTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

@MainActor
final class PadlinkServiceTests: XCTestCase {
    private func makeService(store: any PairingStore = InMemoryPairingStore()) -> PadlinkService {
        PadlinkService(
            store: store,
            router: MessageRouter(
                synthesizer: RecordingSynthesizer(),
                geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
            ),
            macName: "Test Mac"
        )
    }

    func testStartsIdle() {
        XCTAssertEqual(makeService().state, .idle)
    }

    func testBeginPairingProducesAPayloadNamingThisMac() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(payload.macName, "Test Mac")
        XCTAssertEqual(payload.serviceName, "Test Mac")
    }

    func testBeginPairingMovesToThePairingState() throws {
        let service = makeService()
        _ = try service.beginPairing()
        guard case .pairing = service.state else {
            return XCTFail("expected pairing, got \(service.state)")
        }
    }

    func testTwoPairingAttemptsProduceDifferentSecrets() throws {
        let service = makeService()
        let first = try service.beginPairing()
        service.cancelPairing()
        let second = try service.beginPairing()
        XCTAssertNotEqual(first.secret.bytes, second.secret.bytes)
        XCTAssertNotEqual(first.pairingID.bytes, second.pairingID.bytes)
    }

    func testCancelPairingReturnsToIdleAndDiscardsTheCandidate() throws {
        let service = makeService()
        _ = try service.beginPairing()
        service.cancelPairing()
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.acceptedKeysForTesting.isEmpty)
    }

    func testPairingAddsTheCandidateToTheAcceptedKeys() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(
            service.acceptedKeysForTesting.map(\.identity),
            [payload.pairingID.bytes]
        )
    }

    func testStoredPairingsBecomeAcceptedKeys() throws {
        let store = InMemoryPairingStore()
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        try store.save(PairingRecord(
            id: id,
            secret: secret,
            peerName: "iPad",
            serviceName: nil,
            pairedAt: Date()
        ))

        let service = makeService(store: store)
        try service.reloadAcceptedKeysForTesting()
        XCTAssertEqual(service.acceptedKeysForTesting.map(\.identity), [id.bytes])
    }
}
