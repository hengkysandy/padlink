// Padlink/PadlinkPadTests/MacBrowserTests.swift
import XCTest
import Network
import PadlinkCore
@testable import PadlinkPad

/// Tests for `DiscoveryTracker`, the pure decision half of `MacBrowser`.
///
/// `NWBrowser` itself is not tested here. Its results depend on a real network
/// with a real Mac advertising on it, and a test that needs that is not a unit
/// test. What *is* tested is every decision the tracker makes about what the
/// browser reports, because those decisions are where the wrong answer sends
/// the user to the wrong place.
final class DiscoveryTrackerTests: XCTestCase {
    private let paired = "Hengky's Mac"

    private func endpoint(_ name: String) -> NWEndpoint {
        .service(name: name, type: Padlink.bonjourServiceType, domain: "local.", interface: nil)
    }

    private func tracker() -> DiscoveryTracker {
        DiscoveryTracker(serviceName: paired)
    }

    // MARK: - Finding the right Mac

    func testStartsIdle() {
        XCTAssertEqual(tracker().state, .idle)
    }

    func testReadyMeansSearching() {
        var t = tracker()
        t.apply(browserState: .ready)
        XCTAssertEqual(t.state, .searching)
    }

    func testSetupChangesNothing() {
        var t = tracker()
        t.apply(browserState: .setup)
        XCTAssertEqual(t.state, .idle)
    }

    func testAnExactServiceNameMatchIsFound() {
        var t = tracker()
        t.apply(browserState: .ready)
        t.apply(endpoints: [endpoint("Some Other Mac"), endpoint(paired)])
        XCTAssertEqual(t.state, .found(endpoint(paired)))
    }

    /// A Mac called "Hengky's Mac (2)" is a different machine, and its key will
    /// not match. Matching on a prefix would connect to it and produce a bare
    /// TLS failure with no explanation.
    func testMatchingIsExactNotAPrefix() {
        var t = tracker()
        t.apply(endpoints: [endpoint(paired + " (2)")])
        XCTAssertEqual(t.state, .otherMacsOnly([paired + " (2)"]))
    }

    /// Distinct from "nothing found". One means check the Wi-Fi, the other
    /// means this iPad is paired with a Mac that is not the one on this
    /// network.
    func testADifferentMacIsReportedSeparatelyFromFindingNothing() {
        var t = tracker()
        t.apply(browserState: .ready)
        t.apply(endpoints: [endpoint("Work MacBook")])
        XCTAssertEqual(t.state, .otherMacsOnly(["Work MacBook"]))
    }

    func testOtherMacNamesAreSortedSoTheMessageIsStable() {
        var t = tracker()
        t.apply(endpoints: [endpoint("Zoe's Mac"), endpoint("Alice's Mac")])
        XCTAssertEqual(t.state, .otherMacsOnly(["Alice's Mac", "Zoe's Mac"]))
    }

    /// A Bonjour browser only ever yields `.service` endpoints, but the enum
    /// has other cases and an unchecked pattern match would be a crash waiting
    /// for the day one arrives.
    func testNonServiceEndpointsAreIgnored() {
        var t = tracker()
        t.apply(browserState: .ready)
        t.apply(endpoints: [.hostPort(host: "192.168.1.10", port: 5000)])
        XCTAssertEqual(t.state, .searching)
    }

    func testAnEmptyResultSetWhileSearchingStaysSearching() {
        var t = tracker()
        t.apply(browserState: .ready)
        t.apply(endpoints: [])
        XCTAssertEqual(t.state, .searching)
    }

    /// The Mac went to sleep. Going back to searching is right: the browser is
    /// still running and the Mac may come back.
    func testTheMacDisappearingReturnsToSearching() {
        var t = tracker()
        t.apply(endpoints: [endpoint(paired)])
        t.apply(endpoints: [])
        XCTAssertEqual(t.state, .searching)
    }

    /// `.ready` arrives once, before any results. It must not overwrite a
    /// found Mac if the two ever land the other way round.
    func testReadyDoesNotClobberAFoundMac() {
        var t = tracker()
        t.apply(endpoints: [endpoint(paired)])
        t.apply(browserState: .ready)
        XCTAssertEqual(t.state, .found(endpoint(paired)))
    }

    func testCancelledReturnsToIdle() {
        var t = tracker()
        t.apply(endpoints: [endpoint(paired)])
        t.apply(browserState: .cancelled)
        XCTAssertEqual(t.state, .idle)
    }

    // MARK: - Permission denied, which is not "not found"

    /// The constant, pinned against the SDK. `dns_sd.h` defines
    /// `kDNSServiceErr_PolicyDenied = -65570`. A typo here would turn every
    /// permission denial into a generic failure and send the user to check
    /// their Wi-Fi instead of their Settings.
    func testThePolicyDeniedConstantMatchesTheSDK() {
        XCTAssertEqual(LocalNetworkPermission.policyDenied, -65570)
    }

    func testAPolicyDeniedFailureIsReportedAsAPermissionProblem() {
        var t = tracker()
        t.apply(browserState: .failed(.dns(LocalNetworkPermission.policyDenied)))
        XCTAssertEqual(t.state, .localNetworkDenied)
    }

    /// The denial can surface as `.waiting` rather than `.failed`, because
    /// Network.framework treats it as something that might recover. It will
    /// not recover on its own, so it must be reported the same way.
    func testAPolicyDeniedWaitIsReportedAsAPermissionProblem() {
        var t = tracker()
        t.apply(browserState: .waiting(.dns(LocalNetworkPermission.policyDenied)))
        XCTAssertEqual(t.state, .localNetworkDenied)
    }

    /// The opposite mistake: calling an ordinary DNS failure a permission
    /// problem sends the user into Settings to toggle something that is
    /// already on.
    func testAnOrdinaryDNSFailureIsNotCalledAPermissionProblem() {
        var t = tracker()
        // kDNSServiceErr_NoSuchRecord, nothing to do with permission.
        t.apply(browserState: .failed(.dns(-65554)))
        guard case .failed = t.state else {
            return XCTFail("expected failed, got \(t.state)")
        }
    }

    func testAPosixFailureIsNotCalledAPermissionProblem() {
        var t = tracker()
        t.apply(browserState: .failed(.posix(.ENETDOWN)))
        guard case .failed = t.state else {
            return XCTFail("expected failed, got \(t.state)")
        }
    }

    /// The trap, stated directly. A denied browser reports an empty result
    /// set forever, exactly like a browser on a network with no Mac on it. If
    /// the empty set overwrites the denial, the app tells the user to check
    /// their Wi-Fi for a problem no amount of Wi-Fi will fix.
    func testAnEmptyResultSetDoesNotEraseAPermissionDenial() {
        var t = tracker()
        t.apply(browserState: .failed(.dns(LocalNetworkPermission.policyDenied)))
        t.apply(endpoints: [])
        XCTAssertEqual(t.state, .localNetworkDenied)
    }

    func testAnEmptyResultSetDoesNotEraseABrowserFailure() {
        var t = tracker()
        t.apply(browserState: .failed(.posix(.ENETDOWN)))
        t.apply(endpoints: [])
        guard case .failed = t.state else {
            return XCTFail("expected failed, got \(t.state)")
        }
    }

    /// A result arriving proves the browser can see the network, whatever it
    /// reported a moment ago, so a real result does clear a stale failure.
    func testARealResultClearsAStaleFailure() {
        var t = tracker()
        t.apply(browserState: .failed(.posix(.ENETDOWN)))
        t.apply(endpoints: [endpoint(paired)])
        XCTAssertEqual(t.state, .found(endpoint(paired)))
    }
}
