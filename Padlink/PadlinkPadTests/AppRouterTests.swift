// Padlink/PadlinkPadTests/AppRouterTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// Which screen the app shows, and the one rule that keeps the local network
/// permission honest.
///
/// iOS has no API to ask whether local network access was granted. The prompt
/// fires the moment the browser starts, and never again. "Explain before the
/// prompt" therefore cannot mean "check a status first". It can only mean
/// "reach the screen that starts browsing only after the explanation has been
/// acknowledged", which is a routing rule, which is this file.
final class AppRouterTests: XCTestCase {

    // MARK: - Which screen

    func testWithNoPairingTheAppShowsThePairingScreen() {
        XCTAssertEqual(
            AppRouter.screen(
                hasPairing: false,
                hasAcknowledgedLocalNetwork: false,
                wantsToPairAgain: false
            ),
            .pairing
        )
    }

    /// Acknowledging the network explanation is not pairing. An unpaired iPad
    /// still has nothing to connect to.
    func testAcknowledgingTheNoticeDoesNotSkipPairing() {
        XCTAssertEqual(
            AppRouter.screen(
                hasPairing: false,
                hasAcknowledgedLocalNetwork: true,
                wantsToPairAgain: false
            ),
            .pairing
        )
    }

    func testAFreshlyPairedIPadSeesTheLocalNetworkNoticeFirst() {
        XCTAssertEqual(
            AppRouter.screen(
                hasPairing: true,
                hasAcknowledgedLocalNetwork: false,
                wantsToPairAgain: false
            ),
            .localNetworkNotice
        )
    }

    func testOnceBothAreDoneTheAppShowsTheTrackpad() {
        XCTAssertEqual(
            AppRouter.screen(
                hasPairing: true,
                hasAcknowledgedLocalNetwork: true,
                wantsToPairAgain: false
            ),
            .trackpad
        )
    }

    /// "Pair again" has to work from a working connection, because the reason
    /// to use it is usually that the Mac was renamed or re-paired.
    func testPairingAgainOverridesEverything() {
        XCTAssertEqual(
            AppRouter.screen(
                hasPairing: true,
                hasAcknowledgedLocalNetwork: true,
                wantsToPairAgain: true
            ),
            .pairing
        )
    }

    // MARK: - The gate in front of the local network prompt

    /// The trackpad screen is the only one that browses, so it is the only one
    /// allowed to. If either of the other two started discovery, iOS would ask
    /// the local network question before the app had explained it, and the
    /// answer to that question is permanent.
    func testOnlyTheTrackpadScreenMayStartDiscovery() {
        XCTAssertFalse(AppRouter.mayStartDiscovery(.pairing))
        XCTAssertFalse(AppRouter.mayStartDiscovery(.localNetworkNotice))
        XCTAssertTrue(AppRouter.mayStartDiscovery(.trackpad))
    }

    // MARK: - Reading the store

    func testAnEmptyStoreIsNotPaired() {
        XCTAssertFalse(AppRouter.hasPairing(in: InMemoryPairingStore()))
    }

    func testAStoreWithARecordIsPaired() throws {
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(
            id: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            peerName: "Studio Mac",
            serviceName: "Studio Mac",
            pairedAt: Date()
        ))
        XCTAssertTrue(AppRouter.hasPairing(in: store))
    }

    /// A Keychain that will not open counts as paired, not as unpaired.
    ///
    /// `PadService` has a specific message for a stored pairing it cannot read,
    /// and it tells the user something true. Routing to the pairing screen
    /// instead would replace that message with a blank slate that says nothing
    /// went wrong.
    func testAnUnreadableStoreCountsAsPaired() {
        XCTAssertTrue(AppRouter.hasPairing(in: UnreadablePairingStore()))
    }
}

/// A store whose Keychain is unavailable.
private struct UnreadablePairingStore: PairingStore {
    struct Unavailable: Error {}
    func save(_ record: PairingRecord) throws { throw Unavailable() }
    func load(id: PairingID) throws -> PairingRecord? { throw Unavailable() }
    func loadAll() throws -> [PairingRecord] { throw Unavailable() }
    func delete(id: PairingID) throws { throw Unavailable() }
}

/// The explanation is shown once, then never again, so the fact that it was
/// shown has to survive the app being killed.
final class LocalNetworkConsentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PadlinkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAFreshInstallHasNotAcknowledged() {
        XCTAssertFalse(LocalNetworkConsent(defaults: defaults).hasAcknowledged)
    }

    func testAcknowledgingIsRemembered() {
        LocalNetworkConsent(defaults: defaults).acknowledge()
        XCTAssertTrue(LocalNetworkConsent(defaults: defaults).hasAcknowledged)
    }
}
