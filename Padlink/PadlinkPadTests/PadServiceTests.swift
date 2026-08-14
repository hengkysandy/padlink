// Padlink/PadlinkPadTests/PadServiceTests.swift
import XCTest
import Network
import PadlinkCore
@testable import PadlinkPad

/// Tests for `PadStateMachine`, the pure decision half of `PadService`.
///
/// The socket and the browser are not tested here: both need a real Mac on a
/// real network. Every rule about *what state the app is in* lives in this
/// machine, and every one of those rules is tested.
final class PadStateMachineTests: XCTestCase {
    private func machine() -> PadStateMachine { PadStateMachine() }

    private func connecting() -> PadStateMachine {
        var m = machine()
        m.apply(.searchStarted)
        m.apply(.discovered(.service(
            name: "Mac", type: Padlink.bonjourServiceType, domain: "local.", interface: nil
        )))
        return m
    }

    private func connected(accessibilityGranted: Bool = true) -> PadStateMachine {
        var m = connecting()
        m.apply(.received(.helloAck(
            protocolVersion: Padlink.protocolVersion,
            accessibilityGranted: accessibilityGranted
        )))
        return m
    }

    // MARK: - The happy path

    func testStartsIdle() {
        XCTAssertEqual(machine().state, .idle)
    }

    func testSearchStartedMovesToSearching() {
        var m = machine()
        m.apply(.searchStarted)
        XCTAssertEqual(m.state, .searching)
    }

    func testFindingTheMacMovesToConnecting() {
        XCTAssertEqual(connecting().state, .connecting)
    }

    func testHelloAckConnects() {
        XCTAssertEqual(connected().state, .connected(accessibilityGranted: true))
    }

    // MARK: - Accessibility, the failure that looks like the iPad being broken

    /// The Mac accepts every message and then silently throws all of them
    /// away, so the iPad looks broken while being perfectly fine. This already
    /// cost real time with the command line client. It is a successful
    /// connection, so the state is `.connected`, but the flag must survive.
    func testAMacWithoutAccessibilityStillConnectsButCarriesTheFlag() {
        XCTAssertEqual(
            connected(accessibilityGranted: false).state,
            .connected(accessibilityGranted: false)
        )
    }

    func testThereIsNoAccessibilityWarningWhenItIsGranted() {
        XCTAssertNil(connected(accessibilityGranted: true).state.accessibilityWarning)
    }

    /// The message has to name the Mac as the place to fix it. A warning that
    /// only says "not working" sends the user looking at the iPad, which is
    /// the exact confusion this exists to prevent.
    func testTheAccessibilityWarningNamesTheMacSideFix() {
        let warning = connected(accessibilityGranted: false).state.accessibilityWarning
        let text = try? XCTUnwrap(warning)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("Accessibility") == true, "got: \(text ?? "nil")")
        XCTAssertTrue(text?.contains("Mac") == true, "got: \(text ?? "nil")")
    }

    // MARK: - Handshake failures

    func testAWrongProtocolVersionFailsInsteadOfConnecting() {
        var m = connecting()
        m.apply(.received(.helloAck(
            protocolVersion: Padlink.protocolVersion &+ 1,
            accessibilityGranted: true
        )))
        XCTAssertEqual(
            m.state,
            .failed(.protocolMismatch(mac: Padlink.protocolVersion &+ 1, pad: Padlink.protocolVersion))
        )
    }

    /// A frame arriving when no connection attempt is in progress must not
    /// fabricate a connected state.
    func testAStrayHelloAckWhileIdleIsIgnored() {
        var m = machine()
        m.apply(.received(.helloAck(protocolVersion: Padlink.protocolVersion, accessibilityGranted: true)))
        XCTAssertEqual(m.state, .idle)
    }

    func testASecondHelloAckDoesNotChangeALiveConnection() {
        var m = connected(accessibilityGranted: false)
        m.apply(.received(.helloAck(protocolVersion: Padlink.protocolVersion, accessibilityGranted: true)))
        XCTAssertEqual(m.state, .connected(accessibilityGranted: false))
    }

    func testAPongChangesNothing() {
        var m = connected()
        m.apply(.received(.pong(seq: 7)))
        XCTAssertEqual(m.state, .connected(accessibilityGranted: true))
    }

    func testAnErrorFromTheMacSurfaces() {
        var m = connected()
        m.apply(.received(.error(code: 3, message: "too many devices")))
        XCTAssertEqual(m.state, .failed(.macReportedError(code: 3, message: "too many devices")))
    }

    func testARefusedConnectionFails() {
        var m = connecting()
        m.apply(.connectFailed("failed(-9836)"))
        XCTAssertEqual(m.state, .failed(.handshakeRefused("failed(-9836)")))
    }

    func testTheHandshakeTimeoutFailsWhileConnecting() {
        var m = connecting()
        m.apply(.handshakeTimedOut)
        XCTAssertEqual(m.state, .failed(.handshakeTimedOut))
    }

    /// The timer is started when the connection attempt begins and cancelled
    /// when the ack arrives, but cancellation races. A timer that fires just
    /// after a successful handshake must not tear down a working connection.
    func testALateHandshakeTimeoutDoesNotKillALiveConnection() {
        var m = connected()
        m.apply(.handshakeTimedOut)
        XCTAssertEqual(m.state, .connected(accessibilityGranted: true))
    }

    // MARK: - Discovery failures

    func testADiscoveryFailureWhileSearchingFails() {
        var m = machine()
        m.apply(.searchStarted)
        m.apply(.discoveryFailed(.localNetworkDenied))
        XCTAssertEqual(m.state, .failed(.localNetworkDenied))
    }

    /// The browser is cancelled once a Mac is found, but a queued callback can
    /// still arrive. It must not overwrite a live connection.
    func testALateDiscoveryFailureDoesNotKillALiveConnection() {
        var m = connected()
        m.apply(.discoveryFailed(.localNetworkDenied))
        XCTAssertEqual(m.state, .connected(accessibilityGranted: true))
    }

    func testAnEndpointFoundWhileNotSearchingIsIgnored() {
        var m = connected()
        m.apply(.discovered(.service(
            name: "Another Mac", type: Padlink.bonjourServiceType, domain: "local.", interface: nil
        )))
        XCTAssertEqual(m.state, .connected(accessibilityGranted: true))
    }

    func testCannotStartAlwaysFails() {
        var m = connected()
        m.apply(.cannotStart(.notPaired))
        XCTAssertEqual(m.state, .failed(.notPaired))
    }

    // MARK: - Losing the connection

    /// We asked for it. Showing an error for a disconnect the app itself
    /// requested is how a clean shutdown ends up looking like a fault.
    func testOurOwnCancellationIsNotAFailure() {
        var m = connected()
        m.apply(.disconnected(.cancelled))
        XCTAssertEqual(m.state, .idle)
    }

    func testThePeerClosingIsAFailureTheUserCanSee() {
        var m = connected()
        m.apply(.disconnected(.peerClosed))
        guard case let .failed(.connectionLost(detail)) = m.state else {
            return XCTFail("expected connectionLost, got \(m.state)")
        }
        XCTAssertFalse(detail.isEmpty)
    }

    func testATransportFailureCarriesItsDetail() {
        var m = connected()
        m.apply(.disconnected(.transportFailed("POSIXErrorCode(rawValue: 54): Connection reset by peer")))
        XCTAssertEqual(
            m.state,
            .failed(.connectionLost("POSIXErrorCode(rawValue: 54): Connection reset by peer"))
        )
    }

    func testAFramingViolationIsReportedAsSuch() {
        var m = connected()
        m.apply(.disconnected(.framingViolation))
        guard case let .failed(.connectionLost(detail)) = m.state else {
            return XCTFail("expected connectionLost, got \(m.state)")
        }
        XCTAssertTrue(detail.lowercased().contains("frame"), "got: \(detail)")
    }

    func testAMissingCloseReasonStillFails() {
        var m = connected()
        m.apply(.disconnected(nil))
        guard case .failed(.connectionLost) = m.state else {
            return XCTFail("expected connectionLost, got \(m.state)")
        }
    }

    func testADisconnectWhileIdleIsIgnored() {
        var m = machine()
        m.apply(.disconnected(.peerClosed))
        XCTAssertEqual(m.state, .idle)
    }

    func testStoppingReturnsToIdleFromAFailure() {
        var m = machine()
        m.apply(.cannotStart(.notPaired))
        m.apply(.stopped)
        XCTAssertEqual(m.state, .idle)
    }
}

/// The failure messages themselves. They are the whole product here: the two
/// traps this task exists to avoid are both "the right thing happened but the
/// user was told the wrong thing".
final class PadFailureMessageTests: XCTestCase {

    /// The trap, stated directly. One is fixed in Settings, the other means
    /// check the Wi-Fi. Reporting both as "not found" sends the user down the
    /// wrong path for as long as they keep trying.
    func testPermissionDeniedAndMacNotFoundSendTheUserToDifferentPlaces() {
        let denied = PadFailure.localNetworkDenied.message
        let notFound = PadFailure.macNotFound(serviceName: "Hengky's Mac").message

        XCTAssertNotEqual(denied, notFound)
        XCTAssertTrue(denied.contains("Settings"), "denied message: \(denied)")
        XCTAssertTrue(notFound.contains("Wi-Fi"), "not-found message: \(notFound)")
        // And neither may borrow the other's advice.
        XCTAssertFalse(denied.contains("Wi-Fi"), "denied message: \(denied)")
        XCTAssertFalse(notFound.contains("Settings"), "not-found message: \(notFound)")
    }

    func testTheMacNotFoundMessageNamesTheMacItLookedFor() {
        XCTAssertTrue(
            PadFailure.macNotFound(serviceName: "Hengky's Mac").message.contains("Hengky's Mac")
        )
    }

    /// A rejected pre-shared key does not fail cleanly: it leaves the
    /// connection waiting, so it looks like a slow network. The message has to
    /// name the pairing as the likely cause, or the user spends the next
    /// twenty minutes on their router.
    func testTheHandshakeTimeoutMessageNamesThePairing() {
        let message = PadFailure.handshakeTimedOut.message.lowercased()
        XCTAssertTrue(message.contains("pair"), "got: \(message)")
    }

    func testTheRefusedHandshakeMessageNamesThePairingAndKeepsTheDetail() {
        let message = PadFailure.handshakeRefused("failed(-9836)").message
        XCTAssertTrue(message.lowercased().contains("pair"), "got: \(message)")
        XCTAssertTrue(message.contains("-9836"), "got: \(message)")
    }

    func testTheWrongMacMessageNamesBothTheSeenAndThePairedMac() {
        let message = PadFailure.wrongMacsOnly(
            paired: "Home Mac", seen: ["Work MacBook"]
        ).message
        XCTAssertTrue(message.contains("Home Mac"), "got: \(message)")
        XCTAssertTrue(message.contains("Work MacBook"), "got: \(message)")
    }

    func testTheNotPairedMessageTellsTheUserWhatToDo() {
        XCTAssertTrue(PadFailure.notPaired.message.lowercased().contains("pair"))
    }

    func testTheProtocolMismatchMessageNamesBothVersions() {
        let message = PadFailure.protocolMismatch(mac: 2, pad: 1).message
        XCTAssertTrue(message.contains("2"), "got: \(message)")
        XCTAssertTrue(message.contains("1"), "got: \(message)")
    }

    /// No message may ever be empty. An empty string in the UI is
    /// indistinguishable from the app hanging.
    func testEveryFailureHasSomethingToSay() {
        let all: [PadFailure] = [
            .notPaired,
            .storeUnreadable("x"),
            .localNetworkDenied,
            .macNotFound(serviceName: "M"),
            .wrongMacsOnly(paired: "M", seen: ["N"]),
            .browserFailed("x"),
            .handshakeRefused("x"),
            .handshakeTimedOut,
            .protocolMismatch(mac: 2, pad: 1),
            .macReportedError(code: 1, message: "x"),
            .connectionLost("x")
        ]
        for failure in all {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
        }
    }
}

/// The two remaining pure decisions: what "we gave up looking" means, and when
/// coming back to the foreground should reconnect.
final class PadServiceDecisionTests: XCTestCase {

    func testGivingUpWithNothingSeenIsMacNotFound() {
        XCTAssertEqual(
            PadService.searchTimeoutFailure(pairedServiceName: "Home Mac", lastSeen: .searching),
            .macNotFound(serviceName: "Home Mac")
        )
    }

    func testGivingUpAfterSeeingOtherMacsNamesThem() {
        XCTAssertEqual(
            PadService.searchTimeoutFailure(
                pairedServiceName: "Home Mac",
                lastSeen: .otherMacsOnly(["Work MacBook"])
            ),
            .wrongMacsOnly(paired: "Home Mac", seen: ["Work MacBook"])
        )
    }

    /// The timeout must not launder a permission denial into "not found". The
    /// denial reaches the timeout looking exactly like nothing being found,
    /// which is the same trap one layer up.
    func testGivingUpAfterAPermissionDenialKeepsTheDenial() {
        XCTAssertEqual(
            PadService.searchTimeoutFailure(
                pairedServiceName: "Home Mac",
                lastSeen: .localNetworkDenied
            ),
            .localNetworkDenied
        )
    }

    func testGivingUpAfterABrowserFailureKeepsTheDetail() {
        XCTAssertEqual(
            PadService.searchTimeoutFailure(
                pairedServiceName: "Home Mac",
                lastSeen: .failed("ENETDOWN")
            ),
            .browserFailed("ENETDOWN")
        )
    }

    // MARK: - Reconnecting on foreground

    /// iOS suspends a backgrounded app and tears its sockets down, so a
    /// `.connected` state that survived a background trip is usually a lie.
    func testComingBackFromTheBackgroundAlwaysReconnects() {
        XCTAssertTrue(PadService.shouldReconnect(
            wasBackgrounded: true,
            state: .connected(accessibilityGranted: true)
        ))
    }

    /// A Control Centre pull-down deactivates the app without suspending it.
    /// Reconnecting there would drop a working connection for no reason.
    func testAMomentaryDeactivationDoesNotDropALiveConnection() {
        XCTAssertFalse(PadService.shouldReconnect(
            wasBackgrounded: false,
            state: .connected(accessibilityGranted: true)
        ))
        XCTAssertFalse(PadService.shouldReconnect(wasBackgrounded: false, state: .connecting))
    }

    func testComingBackAfterAFailureRetries() {
        XCTAssertTrue(PadService.shouldReconnect(
            wasBackgrounded: false,
            state: .failed(.localNetworkDenied)
        ))
    }
}

@MainActor
final class PadServiceTests: XCTestCase {

    /// The one lifecycle path that needs no network at all: an empty store
    /// means there is nothing to connect to, and the app must say so rather
    /// than sitting on "searching" forever.
    func testStartingWithNoPairingFailsImmediatelyWithoutBrowsing() {
        let service = PadService(store: InMemoryPairingStore(), deviceName: "Test iPad")
        service.start()
        XCTAssertEqual(service.state, .failed(.notPaired))
        XCTAssertNil(service.pairedMacName)
    }

    func testAnUnreadableStoreIsReportedSeparatelyFromNotBeingPaired() {
        let service = PadService(store: ThrowingPairingStore(), deviceName: "Test iPad")
        service.start()
        guard case .failed(.storeUnreadable) = service.state else {
            return XCTFail("expected storeUnreadable, got \(service.state)")
        }
    }

    func testStoppingReturnsToIdle() {
        let service = PadService(store: InMemoryPairingStore(), deviceName: "Test iPad")
        service.start()
        service.stop()
        XCTAssertEqual(service.state, .idle)
    }

    /// The Bonjour service name is what the browser matches on. A pairing
    /// saved without one falls back to the Mac's display name, because that is
    /// what `PadlinkService` advertises.
    func testTheServiceNameFallsBackToThePeerName() throws {
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        let record = PairingRecord(
            id: id, secret: secret, peerName: "Home Mac", serviceName: nil, pairedAt: Date()
        )
        XCTAssertEqual(PadService.serviceName(for: record), "Home Mac")

        let named = PairingRecord(
            id: id, secret: secret, peerName: "Home Mac", serviceName: "Home Mac (2)", pairedAt: Date()
        )
        XCTAssertEqual(PadService.serviceName(for: named), "Home Mac (2)")
    }
}

/// A store whose Keychain is unavailable. There is a real difference between
/// "you never paired" and "your saved pairing cannot be read", and only one of
/// them is fixed by pairing again.
private struct ThrowingPairingStore: PairingStore {
    struct Unavailable: Error {}
    func save(_ record: PairingRecord) throws { throw Unavailable() }
    func load(id: PairingID) throws -> PairingRecord? { throw Unavailable() }
    func loadAll() throws -> [PairingRecord] { throw Unavailable() }
    func delete(id: PairingID) throws { throw Unavailable() }
}
