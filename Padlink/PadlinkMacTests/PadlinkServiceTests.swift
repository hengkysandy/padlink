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

    /// Builds a service over a router the test can inspect, with the left
    /// mouse button already held, which is what a user mid-drag looks like.
    private func serviceHoldingTheLeftButton() -> (PadlinkService, RecordingSynthesizer) {
        let synthesizer = RecordingSynthesizer()
        let router = MessageRouter(
            synthesizer: synthesizer,
            geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        )
        let service = PadlinkService(
            store: InMemoryPairingStore(),
            router: router,
            macName: "Test Mac"
        )
        router.handle(.pointerButton(button: .left, isDown: true))
        return (service, synthesizer)
    }

    private func assertLeftButtonWasReleased(
        _ synthesizer: RecordingSynthesizer,
        _ message: String,
        line: UInt = #line
    ) {
        let released = synthesizer.calls.contains { call in
            if case .button(.left, isDown: false, _, _) = call { return true }
            return false
        }
        XCTAssertTrue(released, message, line: line)
    }

    // MARK: - Releasing held input when a connection ends
    //
    // The worst failure this app can produce. A stuck mouse button is not a
    // Padlink problem the user can quit their way out of: it is posted at the
    // HID level, so the Mac's own trackpad starts dragging too.

    /// The reconnection case, and the common one. Wi-Fi drops mid-drag with no
    /// FIN, the iPad rejoins, and `accept()` replaces `self.connection` before
    /// the old read loop has even noticed its socket died.
    ///
    /// The old loop is therefore never the current connection when it ends, so
    /// an identity guard placed *above* the release means the release never
    /// runs at all. `MessageRouter.held` is one instance for the whole process,
    /// so the held button then belongs to nobody and is never let go.
    func testASupersededConnectionStillReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.endSession(isCurrentConnection: false, reason: .transportFailed("Wi-Fi went away"))
        assertLeftButtonWasReleased(
            synthesizer,
            "a superseded connection must still release the button it left held"
        )
    }

    /// The other branch, so the fix cannot be "moved into the else".
    func testTheCurrentConnectionEndingAlsoReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.endSession(isCurrentConnection: true, reason: .peerClosed)
        assertLeftButtonWasReleased(
            synthesizer,
            "the current connection ending must release the button it left held"
        )
    }

    /// The dead-heartbeat path reaches the same place. Without this, silence
    /// detection would notice a dead peer and still leave the button down.
    func testASilentPeerReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.peerWentSilent()
        assertLeftButtonWasReleased(
            synthesizer,
            "a peer that stopped answering must not leave a button held"
        )
    }

    // MARK: - Telling the iPad the Accessibility answer changed

    /// `helloAck` reports Accessibility once. With no connection there is
    /// nobody to tell, and saying so must not be a crash: the poller keeps
    /// running whether or not an iPad is attached.
    func testReportingAnAccessibilityChangeWithNoConnectionIsHarmless() {
        let service = makeService()
        service.accessibilityChanged(granted: true)
        service.accessibilityChanged(granted: false)
        XCTAssertEqual(service.state, .idle)
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

    // MARK: - Only the device that used the pairing key may be paired
    //
    // The pairing window is the only moment at which a new permanent credential
    // can be created. If any connection at all can create one, then a secret
    // nobody ever scanned becomes a stored pairing, and the 120 second window
    // bounds nothing.

    /// The identity of a pairing already stored before the window opened.
    private let previouslyPairedIdentity = Data(repeating: 1, count: PairingID.byteCount)

    private func storeHoldingOnePairing() throws -> InMemoryPairingStore {
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(
            id: try XCTUnwrap(PairingID(bytes: previouslyPairedIdentity)),
            secret: try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32))),
            peerName: "Old iPad",
            serviceName: nil,
            pairedAt: Date()
        ))
        return store
    }

    /// The finding itself. An already-paired iPad reconnecting during someone
    /// else's pairing window must not turn that window's unscanned secret into
    /// a permanent credential.
    func testAConnectionOnAnotherKeyDoesNotPromoteTheCandidate() throws {
        let store = try storeHoldingOnePairing()
        let service = makeService(store: store)
        _ = try service.beginPairing()

        service.promoteCandidateIfNeeded(
            deviceName: "Old iPad",
            acceptedIdentity: previouslyPairedIdentity
        )

        XCTAssertEqual(
            try store.loadAll().count,
            1,
            "a peer that authenticated with an already-paired key must not store the candidate"
        )
    }

    /// A connection whose pre-shared key identity is not known must not promote
    /// either. Nil is what an ambiguous listener reports, and ambiguity is not
    /// proof that the candidate's own key was used.
    func testAConnectionWithNoKnownKeyIdentityDoesNotPromoteTheCandidate() throws {
        let store = InMemoryPairingStore()
        let service = makeService(store: store)
        _ = try service.beginPairing()

        service.promoteCandidateIfNeeded(deviceName: "Mystery iPad", acceptedIdentity: nil)

        XCTAssertTrue(
            try store.loadAll().isEmpty,
            "an unidentified connection must not store the candidate"
        )
    }

    /// The other branch, so the fix cannot be "never promote".
    func testAConnectionOnTheCandidateKeyPromotesIt() throws {
        let store = InMemoryPairingStore()
        let service = makeService(store: store)
        let payload = try service.beginPairing()

        service.promoteCandidateIfNeeded(
            deviceName: "New iPad",
            acceptedIdentity: payload.pairingID.bytes
        )

        XCTAssertEqual(try store.loadAll().map(\.id.bytes), [payload.pairingID.bytes])
    }

    /// Network.framework cannot report which pre-shared key identity an
    /// established connection negotiated, so the only honest source of that
    /// fact is which listener accepted it. That works only if a listener built
    /// for a pairing window accepts exactly one key.
    func testAnOpenPairingWindowAcceptsOnlyTheCandidateKey() throws {
        let service = makeService(store: try storeHoldingOnePairing())
        let payload = try service.beginPairing()

        XCTAssertEqual(
            service.acceptedKeysForTesting.map(\.identity),
            [payload.pairingID.bytes],
            "a pairing window must accept the candidate key and nothing else"
        )
    }

    /// The cost of the exclusive window is that paired devices cannot reconnect
    /// while it is open, so it must end the moment the pairing lands.
    func testASuccessfulPairingRestoresTheOtherStoredKeys() throws {
        let store = try storeHoldingOnePairing()
        let service = makeService(store: store)
        let payload = try service.beginPairing()

        service.promoteCandidateIfNeeded(
            deviceName: "New iPad",
            acceptedIdentity: payload.pairingID.bytes
        )

        XCTAssertEqual(
            Set(service.acceptedKeysForTesting.map(\.identity)),
            [previouslyPairedIdentity, payload.pairingID.bytes],
            "once the window closes, every paired device must be able to connect again"
        )
    }

    /// A rejected promotion must leave the window open and unchanged, not
    /// quietly discard the candidate the real iPad is about to use.
    func testARejectedPromotionLeavesTheWindowOpen() throws {
        let service = makeService(store: try storeHoldingOnePairing())
        let payload = try service.beginPairing()

        service.promoteCandidateIfNeeded(
            deviceName: "Old iPad",
            acceptedIdentity: previouslyPairedIdentity
        )

        XCTAssertEqual(
            service.acceptedKeysForTesting.map(\.identity),
            [payload.pairingID.bytes],
            "a rejected promotion must not close the pairing window"
        )
    }

    // MARK: - Telling the app the pairing window can close

    /// The QR code on screen becomes a permanent credential the instant it is
    /// stored. Leaving it up under an expired countdown displays a live key to
    /// the room.
    func testASuccessfulPairingIsAnnouncedSoTheWindowCanClose() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(service.completedPairings, 0)

        service.promoteCandidateIfNeeded(
            deviceName: "New iPad",
            acceptedIdentity: payload.pairingID.bytes
        )

        XCTAssertEqual(
            service.completedPairings,
            1,
            "a stored pairing must tell the app to take the code off the screen"
        )
    }

    /// A pairing that did not reach disk is not a pairing. The window must stay
    /// up so the user can see the failure and try again.
    func testAPairingThatCouldNotBeSavedIsNotAnnounced() throws {
        let store = BreakableStore()
        let service = makeService(store: store)
        let payload = try service.beginPairing()
        store.savingFails = true

        service.promoteCandidateIfNeeded(
            deviceName: "New iPad",
            acceptedIdentity: payload.pairingID.bytes
        )

        XCTAssertEqual(
            service.completedPairings,
            0,
            "a pairing that failed to save must not close the window"
        )
    }

    // MARK: - Closing the pairing window must not fail silently

    /// The finding. `loadAll` throwing left the candidate in `acceptedKeys` and
    /// the listener rebuilt still accepting it, while the UI said the window
    /// had closed. A live pairing key then outlives the window the user
    /// believes expired.
    func testAPairingWindowThatCannotBeClosedDropsTheCandidateKey() throws {
        let store = BreakableStore()
        let service = makeService(store: store)
        _ = try service.beginPairing()
        store.loadingFails = true

        service.cancelPairing()

        XCTAssertTrue(
            service.acceptedKeysForTesting.isEmpty,
            "a window that could not be closed cleanly must not keep accepting its key"
        )
    }

    func testAPairingWindowThatCannotBeClosedIsReportedAsAFailure() throws {
        let store = BreakableStore()
        let service = makeService(store: store)
        _ = try service.beginPairing()
        store.loadingFails = true

        service.cancelPairing()

        guard case .failed = service.state else {
            return XCTFail("expected failed, got \(service.state)")
        }
    }

    /// The ordinary close still reports idle, so "fail closed" cannot be
    /// implemented as "always fail".
    func testAPairingWindowThatClosesCleanlyReportsIdle() throws {
        let service = makeService(store: BreakableStore())
        _ = try service.beginPairing()

        service.cancelPairing()

        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - What the socket actually accepts
    //
    // `acceptedKeys` is the intent. `listeningIdentities` is what the running
    // listener was really built for. Every finding here is about the two
    // drifting apart, so both are worth asserting on separately.

    func testTheRunningListenerAcceptsOnlyTheCandidateDuringAWindow() throws {
        let service = makeService(store: try storeHoldingOnePairing())
        let payload = try service.beginPairing()

        XCTAssertEqual(service.listeningIdentities, [payload.pairingID.bytes])
    }

    /// Without a rebuild here the socket would still be the pairing window's
    /// one-key listener, so every other paired device stays locked out for as
    /// long as the app runs.
    func testASuccessfulPairingRebuildsTheListenerForEveryPairedDevice() throws {
        let service = makeService(store: try storeHoldingOnePairing())
        let payload = try service.beginPairing()

        service.promoteCandidateIfNeeded(
            deviceName: "New iPad",
            acceptedIdentity: payload.pairingID.bytes
        )

        XCTAssertEqual(
            Set(service.listeningIdentities),
            [previouslyPairedIdentity, payload.pairingID.bytes],
            "the socket, not just the intent, must accept every paired device again"
        )
    }

    /// Fail closed means the socket stops accepting, not merely that a variable
    /// was emptied.
    func testAWindowThatCannotBeClosedStopsListeningAltogether() throws {
        let store = BreakableStore()
        let service = makeService(store: store)
        _ = try service.beginPairing()
        store.loadingFails = true

        service.cancelPairing()

        XCTAssertTrue(service.listeningIdentities.isEmpty)
    }

    /// Quitting takes the socket down, so nothing may still claim it is up.
    func testStoppingTheServiceStopsListening() throws {
        let service = makeService(store: try storeHoldingOnePairing())
        _ = try service.beginPairing()

        service.stop()

        XCTAssertTrue(service.listeningIdentities.isEmpty)
    }

    // MARK: - Which key identity a listener can vouch for

    func testAOneKeyListenerVouchesForThatKey() {
        let key = TLSPSK(identity: Data([1, 2, 3]), key: Data(repeating: 9, count: 32))
        XCTAssertEqual(PadlinkService.soleIdentity(of: [key]), key.identity)
    }

    /// Two keys means the handshake could have used either, and "either" is not
    /// evidence. Reporting one of them would be a check that verifies nothing.
    func testAMultiKeyListenerVouchesForNothing() {
        let first = TLSPSK(identity: Data([1]), key: Data(repeating: 9, count: 32))
        let second = TLSPSK(identity: Data([2]), key: Data(repeating: 8, count: 32))
        XCTAssertNil(PadlinkService.soleIdentity(of: [first, second]))
    }

    func testAListenerWithNoKeysVouchesForNothing() {
        XCTAssertNil(PadlinkService.soleIdentity(of: []))
    }
}

/// A store whose Keychain can be made to refuse, which is what a locked
/// Keychain or a missing entitlement looks like from `PadlinkService`.
private final class BreakableStore: PairingStore, @unchecked Sendable {
    enum Failure: Error { case keychainRefused }

    private let inner = InMemoryPairingStore()
    nonisolated(unsafe) var loadingFails = false
    nonisolated(unsafe) var savingFails = false

    func save(_ record: PairingRecord) throws {
        if savingFails { throw Failure.keychainRefused }
        try inner.save(record)
    }

    func load(id: PairingID) throws -> PairingRecord? {
        try inner.load(id: id)
    }

    func loadAll() throws -> [PairingRecord] {
        if loadingFails { throw Failure.keychainRefused }
        return try inner.loadAll()
    }

    func delete(id: PairingID) throws {
        try inner.delete(id: id)
    }
}
