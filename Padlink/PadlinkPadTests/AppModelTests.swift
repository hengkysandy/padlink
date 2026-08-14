// Padlink/PadlinkPadTests/AppModelTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// The glue: which screen is on, and what pairing does to it.
///
/// Nothing here touches the network. `AppModel` builds a `PadService` but never
/// starts it; discovery begins when the trackpad screen appears, which is the
/// gate that keeps the local network prompt behind its explanation.
@MainActor
final class AppModelTests: XCTestCase {

    private var store: InMemoryPairingStore!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        store = InMemoryPairingStore()
        suiteName = "PadlinkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func model() -> AppModel {
        AppModel(store: store, defaults: defaults, deviceName: "Test iPad")
    }

    private func code(macName: String = "Studio Mac") throws -> String {
        PairingPayload(
            pairingID: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            macName: macName,
            serviceName: macName
        ).urlString
    }

    // MARK: - Where a launch lands

    func testAnUnpairedLaunchShowsPairing() {
        XCTAssertEqual(model().screen, .pairing)
    }

    func testAPairedLaunchThatHasSeenTheNoticeGoesStraightToTheTrackpad() throws {
        try store.save(PairingRecord(
            id: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            peerName: "Studio Mac",
            serviceName: "Studio Mac",
            pairedAt: Date()
        ))
        LocalNetworkConsent(defaults: defaults).acknowledge()

        XCTAssertEqual(model().screen, .trackpad)
    }

    // MARK: - Pairing moves the app on

    /// The explanation comes between pairing and the trackpad, because the
    /// trackpad screen is what starts browsing, and browsing is what makes iOS
    /// ask the question.
    func testPairingLandsOnTheLocalNetworkNoticeAndNotTheTrackpad() throws {
        let model = self.model()

        _ = model.submitPairing(try code())

        XCTAssertEqual(model.screen, .localNetworkNotice)
    }

    func testAcknowledgingTheNoticeReachesTheTrackpad() throws {
        let model = self.model()
        _ = model.submitPairing(try code())

        model.acknowledgeLocalNetwork()

        XCTAssertEqual(model.screen, .trackpad)
    }

    /// Asked once, ever. A second launch must not ask again.
    func testTheNoticeIsNotShownTwice() throws {
        let first = model()
        _ = first.submitPairing(try code())
        first.acknowledgeLocalNetwork()

        XCTAssertEqual(model().screen, .trackpad)
    }

    func testARejectedCodeLeavesTheUserOnThePairingScreen() {
        let model = self.model()

        guard case .rejected = model.submitPairing("hello there") else {
            return XCTFail("nonsense was accepted as a pairing code")
        }
        XCTAssertEqual(model.screen, .pairing)
    }

    // MARK: - Pairing again

    func testPairAgainReturnsToThePairingScreen() throws {
        let model = self.model()
        _ = model.submitPairing(try code())
        model.acknowledgeLocalNetwork()

        model.pairAgain()

        XCTAssertEqual(model.screen, .pairing)
    }

    /// "Pair again" is one tap away from the trackpad, so it will be tapped by
    /// accident. Without a way back, the only escape from that tap is pairing,
    /// and the user may not have their Mac in front of them.
    func testBackingOutOfPairingAgainReturnsToTheTrackpad() throws {
        let model = self.model()
        _ = model.submitPairing(try code())
        model.acknowledgeLocalNetwork()
        model.pairAgain()

        model.cancelPairingAgain()

        XCTAssertEqual(model.screen, .trackpad)
    }

    /// Backing out of the very first pairing has nowhere to go back to.
    func testBackingOutWithNoPairingStaysOnThePairingScreen() {
        let model = self.model()
        model.cancelPairingAgain()
        XCTAssertEqual(model.screen, .pairing)
    }

    /// So the screen can leave the button off rather than showing one that
    /// does nothing.
    func testThereIsNoWayBackFromTheFirstPairing() {
        XCTAssertFalse(model().canCancelPairing)
    }

    func testThereIsAWayBackWhenAPairingAlreadyExists() throws {
        let model = self.model()
        _ = model.submitPairing(try code())
        model.acknowledgeLocalNetwork()
        model.pairAgain()

        XCTAssertTrue(model.canCancelPairing)
    }

    /// The latch that stops one QR code being scanned forty times must not
    /// stop the next deliberate pairing. Coming back to this screen is a new
    /// intent, so it gets a fresh latch.
    func testPairingAgainCanActuallyPairAgain() throws {
        let model = self.model()
        _ = model.submitPairing(try code(macName: "Studio Mac"))
        model.acknowledgeLocalNetwork()
        model.pairAgain()

        XCTAssertEqual(
            model.submitPairing(try code(macName: "Kitchen Mac")),
            .paired(macName: "Kitchen Mac")
        )
        XCTAssertEqual(model.screen, .trackpad)
    }
}
