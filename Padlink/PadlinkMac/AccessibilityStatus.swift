import AppKit
import ApplicationServices
import Foundation

/// Whether macOS trusts this app to synthesize input.
///
/// Without this permission every posted `CGEvent` is silently dropped, which
/// looks exactly like a broken app. The check is injected so the polling
/// behaviour can be tested without changing real system permissions.
@MainActor
final class AccessibilityStatus: ObservableObject {
    @Published private(set) var isTrusted: Bool

    private let checker: @Sendable () -> Bool
    private let pollInterval: TimeInterval
    // Read access is internal rather than private, so tests can capture the
    // Timer and assert on its `isValid` state directly, e.g. to prove
    // deinit invalidates it. The setter stays private.
    private(set) var timer: Timer?

    init(
        checker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        pollInterval: TimeInterval = 1.0
    ) {
        self.checker = checker
        self.pollInterval = pollInterval
        self.isTrusted = checker()
    }

    func refresh() {
        let current = checker()
        if current != isTrusted {
            isTrusted = current
        }
    }

    /// Polls so the UI updates the moment the user flips the switch in System
    /// Settings, with no restart and no "click here when done" button.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit {
        stopPolling()
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
