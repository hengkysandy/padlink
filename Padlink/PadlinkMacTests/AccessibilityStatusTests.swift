import Combine
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

    func testStartPollingTwiceDoesNotDoubleTheFiringRate() {
        // Regression test for the `guard timer == nil` idempotence check.
        // Asserts on observable firing rate rather than the private `timer`
        // field: two instances run side by side under identical load for
        // the same window, one polling normally and one with
        // startPolling() called twice. Comparing them directly (instead of
        // against a fixed nominal count) keeps the test robust on a slow or
        // loaded machine, since both instances slow down together.
        let singleCalls = LockedCounter()
        let doubleCalls = LockedCounter()
        let pollInterval = 0.01

        let singleStatus = AccessibilityStatus(checker: { singleCalls.incrementAndGet(); return false }, pollInterval: pollInterval)
        let doubleStatus = AccessibilityStatus(checker: { doubleCalls.incrementAndGet(); return false }, pollInterval: pollInterval)

        singleStatus.startPolling()
        doubleStatus.startPolling()
        doubleStatus.startPolling() // idempotent call: must not create a second timer

        let window = 0.3
        let elapsed = expectation(description: "polling window elapsed")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(window))
            elapsed.fulfill()
        }
        wait(for: [elapsed], timeout: window + 5)
        singleStatus.stopPolling()
        doubleStatus.stopPolling()

        // A correct implementation fires doubleStatus at roughly the same
        // rate as singleStatus (one timer each). A regressed guard would
        // fire doubleStatus at roughly twice the rate. 1.5x sits clearly
        // between those two outcomes.
        let ratio = Double(doubleCalls.value) / Double(max(singleCalls.value, 1))
        XCTAssertLessThan(ratio, 1.5, "startPolling() called twice should not roughly double the firing rate")
    }

    func testRefreshDoesNotPublishWhenTheCheckerValueIsUnchanged() {
        // Regression test for the `if current != isTrusted` publish guard.
        // objectWillChange does not replay on subscribe (unlike $isTrusted,
        // which is backed by a CurrentValueSubject-like publisher), so no
        // initial event needs to be accounted for here.
        let status = AccessibilityStatus(checker: { false })
        var changeCount = 0
        let cancellable = status.objectWillChange.sink { changeCount += 1 }
        XCTAssertEqual(changeCount, 0, "subscribing alone must not publish")

        status.refresh()
        status.refresh()
        status.refresh()

        XCTAssertEqual(changeCount, 0, "refresh() must not publish when the checker's value has not changed")
        cancellable.cancel()
    }

    // MARK: - Telling the connection, not only the menu

    /// The iPad hears the Accessibility answer once, in `helloAck`. When the
    /// user grants the permission, something has to tell the iPad, or the
    /// orange "your Mac is ignoring this" banner stays up until the connection
    /// is rebuilt. This callback is that something.
    func testAChangeIsReportedToTheObserver() {
        let granted = LockedFlag(false)
        let status = AccessibilityStatus(checker: { granted.value })
        var reported: [Bool] = []
        status.onChange = { reported.append($0) }

        granted.value = true
        status.refresh()

        XCTAssertEqual(reported, [true])
    }

    /// The revoke direction, which is the worse one: the iPad would otherwise
    /// keep saying everything is fine while macOS throws every event away.
    func testARevocationIsReportedToTheObserver() {
        let granted = LockedFlag(true)
        let status = AccessibilityStatus(checker: { granted.value })
        var reported: [Bool] = []
        status.onChange = { reported.append($0) }

        granted.value = false
        status.refresh()

        XCTAssertEqual(reported, [false])
    }

    /// The poller runs once a second for the life of the app. Reporting on
    /// every tick would put a message on the wire every second forever.
    func testNothingIsReportedWhenTheAnswerHasNotChanged() {
        let status = AccessibilityStatus(checker: { false })
        var reported: [Bool] = []
        status.onChange = { reported.append($0) }

        status.refresh()
        status.refresh()
        status.refresh()

        XCTAssertTrue(reported.isEmpty, "reported \(reported) for an unchanged answer")
    }

    func testDeinitInvalidatesThePollingTimer() {
        // Regression test for the orphaned-timer leak: if an instance is
        // deallocated while polling, the timer must be invalidated instead
        // of being left on the run loop, firing into a no-op forever.
        //
        // Counting checker calls before/after dealloc does NOT catch this:
        // the timer's closure captures self weakly, so `self?.refresh()`
        // is already a no-op post-dealloc whether or not the timer itself
        // was ever invalidated. Capturing the actual Timer and asserting on
        // `isValid` is the only way to observe the fix from outside.
        var status: AccessibilityStatus? = AccessibilityStatus(checker: { false }, pollInterval: 0.01)
        status?.startPolling()

        let timerRef = status?.timer
        XCTAssertEqual(timerRef?.isValid, true, "precondition: polling should have created a valid timer")

        status = nil // last strong reference gone; deinit should invalidate the timer

        XCTAssertEqual(timerRef?.isValid, false, "deinit should invalidate the polling timer")
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

/// Thread-safe call counter, for the same reason `LockedFlag` exists: the
/// checker closure is @Sendable and may be invoked from a timer.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        storage += 1
        return storage
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}
