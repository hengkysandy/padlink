import XCTest
@testable import PadlinkMac

@MainActor
final class AccessibilityStatusTests: XCTestCase {
    func testReadsTheInitialValueFromTheChecker() {
        let status = AccessibilityStatus(checker: { true })
        XCTAssertTrue(status.isTrusted)
    }

    func testReportsUntrustedWhenTheCheckerSaysSo() {
        let status = AccessibilityStatus(checker: { false })
        XCTAssertFalse(status.isTrusted)
    }

    func testRefreshPicksUpAChange() {
        // The real case: the user flips the switch in System Settings while
        // the app is running, and the UI must update without a restart.
        let granted = LockedFlag(false)
        let status = AccessibilityStatus(checker: { granted.value })
        XCTAssertFalse(status.isTrusted)

        granted.value = true
        status.refresh()
        XCTAssertTrue(status.isTrusted)
    }

    func testPollingPicksUpAChangeWithoutAnExplicitRefresh() {
        let granted = LockedFlag(false)
        let status = AccessibilityStatus(checker: { granted.value }, pollInterval: 0.01)
        status.startPolling()
        granted.value = true

        let updated = expectation(description: "isTrusted becomes true")
        Task { @MainActor in
            for _ in 0 ..< 200 where status.isTrusted == false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if status.isTrusted { updated.fulfill() }
        }
        wait(for: [updated], timeout: 5)
        status.stopPolling()
    }
}

/// Small thread-safe box, because the checker closure is @Sendable.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
