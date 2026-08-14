// Padlink/PadlinkPadTests/PadStatusTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// What the top of the main screen says.
///
/// The messages in `PadFailure` and `PadState.accessibilityWarning` were
/// written once, carefully, and are pinned by their own tests. The job of this
/// layer is to show them, whole and unedited. Every test here exists because
/// the tempting thing to write instead is a short summary of my own, and a
/// short summary is exactly what left three people staring at a connection
/// that said "Connected" and did nothing.
final class PadStatusTests: XCTestCase {

    /// Every failure there is. `PadFailure` carries associated values, so it
    /// cannot be `CaseIterable`; this list stands in for that, and a new case
    /// added without a line here is the one gap this file has.
    private let allFailures: [PadFailure] = [
        .notPaired,
        .storeUnreadable("the Keychain returned -25300"),
        .localNetworkDenied,
        .macNotFound(serviceName: "Studio Mac"),
        .wrongMacsOnly(paired: "Studio Mac", seen: ["Kitchen Mac"]),
        .browserFailed("the browser stopped"),
        .handshakeRefused("the Mac said no"),
        .handshakeTimedOut,
        .protocolMismatch(mac: 2, pad: 1),
        .macReportedError(code: 7, message: "unknown pairing"),
        .connectionLost("the Wi-Fi went away")
    ]

    // MARK: - Failures reach the screen word for word

    /// Not "contains", not "starts with". The whole sentence, unchanged. A
    /// paraphrase here would quietly undo the wording that makes
    /// `localNetworkDenied` send the user to Settings and `macNotFound` send
    /// them to their Wi-Fi.
    func testEveryFailureShowsItsOwnMessageUnedited() {
        for failure in allFailures {
            let status = PadStatus(.failed(failure))
            XCTAssertEqual(
                status.detail,
                failure.message,
                "\(failure) reached the screen as something other than its own message"
            )
        }
    }

    func testEveryFailureIsShownAsAnError() {
        for failure in allFailures {
            XCTAssertEqual(PadStatus(.failed(failure)).level, .error, "\(failure)")
        }
    }

    /// Two different failures must not read the same on screen. The whole
    /// point of eleven cases is that they send the user to eleven places.
    func testNoTwoFailuresProduceTheSameDetail() {
        let details = allFailures.map { PadStatus(.failed($0)).detail }
        XCTAssertEqual(Set(details.compactMap { $0 }).count, allFailures.count)
    }

    // MARK: - The failure that looks like success

    /// Without Accessibility on the Mac, everything works and nothing moves.
    /// The state is `.connected`, so any check for "are we connected" says yes,
    /// and the only thing standing between the user and an hour of confusion is
    /// this banner being present.
    func testConnectedWithoutAccessibilityShowsTheWarningInFull() {
        let state = PadState.connected(accessibilityGranted: false)
        let status = PadStatus(state)

        XCTAssertNotNil(state.accessibilityWarning)
        XCTAssertEqual(status.detail, state.accessibilityWarning)
    }

    /// Not `.connected`, which is drawn quietly. This one has to be loud.
    func testConnectedWithoutAccessibilityIsNotDrawnAsASuccess() {
        XCTAssertEqual(PadStatus(.connected(accessibilityGranted: false)).level, .warning)
    }

    /// The headline alone must not say everything is fine, because the headline
    /// is the part that is always visible.
    func testConnectedWithoutAccessibilityDoesNotHeadlineAsPlainConnected() {
        XCTAssertNotEqual(
            PadStatus(.connected(accessibilityGranted: false)).headline,
            PadStatus(.connected(accessibilityGranted: true)).headline
        )
    }

    // MARK: - The quiet states

    func testAWorkingConnectionHasNothingToExplain() {
        let status = PadStatus(.connected(accessibilityGranted: true))
        XCTAssertNil(status.detail)
        XCTAssertEqual(status.level, .connected)
    }

    /// "Looking for your Mac" and not an empty screen: ten seconds of silence
    /// with no words on it reads as broken.
    func testSearchingSaysSoWithoutClaimingAnythingIsWrong() {
        let status = PadStatus(.searching)
        XCTAssertNil(status.detail)
        XCTAssertEqual(status.level, .working)
        XCTAssertFalse(status.headline.isEmpty)
    }

    func testConnectingIsAWorkingState() {
        XCTAssertEqual(PadStatus(.connecting).level, .working)
    }

    func testIdleIsNeitherAnErrorNorASuccess() {
        let status = PadStatus(.idle)
        XCTAssertEqual(status.level, .idle)
        XCTAssertNil(status.detail)
    }

    /// Every state has to say something. A blank header is the state that
    /// looks most like a crash.
    func testEveryStateHasAHeadline() {
        var states: [PadState] = [
            .idle, .searching, .connecting,
            .connected(accessibilityGranted: true),
            .connected(accessibilityGranted: false)
        ]
        states.append(contentsOf: allFailures.map { PadState.failed($0) })

        for state in states {
            XCTAssertFalse(PadStatus(state).headline.isEmpty, "\(state)")
        }
    }
}
