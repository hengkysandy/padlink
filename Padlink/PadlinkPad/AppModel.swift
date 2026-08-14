// Padlink/PadlinkPad/AppModel.swift
import Foundation
import PadlinkCore
import UIKit

/// Everything the app owns that outlives a single screen: the pairing store,
/// the connection, which screen is showing, and the one rule about when the
/// network may be touched.
///
/// It decides almost nothing itself. `AppRouter` decides the screen,
/// `PairingIntake` decides what a pairing code means, and `PadService` decides
/// what the connection is doing. This type holds them and passes messages
/// between them, which is the part SwiftUI needs and the part that cannot be
/// tested.
@MainActor
final class AppModel: ObservableObject {
    /// Published so the views redraw. `PadService` publishes its own state
    /// separately, and the trackpad screen observes it directly.
    @Published private(set) var screen: AppScreen = .pairing

    let service: PadService

    private let store: any PairingStore
    private let consent: LocalNetworkConsent
    private var intake: PairingIntake

    private var hasPairing: Bool
    private var wantsToPairAgain = false

    init(
        store: any PairingStore = PadPairingStore(),
        defaults: UserDefaults = .standard,
        deviceName: String? = nil
    ) {
        self.store = store
        self.consent = LocalNetworkConsent(defaults: defaults)
        self.intake = PairingIntake(store: store)
        self.hasPairing = AppRouter.hasPairing(in: store)
        self.service = PadService(
            store: store,
            // iOS 16 and later returns a generic model name here unless the app
            // is entitled to the real one. That is fine: it only ever appears
            // in the Mac's list of paired devices.
            deviceName: deviceName ?? UIDevice.current.name
        )
        updateScreen()
    }

    // MARK: - Pairing

    func submitPairing(_ text: String) -> PairingIntakeResult {
        let result = intake.accept(text)
        if case .paired = result {
            hasPairing = true
            wantsToPairAgain = false
            updateScreen()
        }
        return result
    }

    func pairAgain() {
        // A new intake, so a new latch. The old one closed on the pairing that
        // is being replaced, and would ignore every code scanned from here on.
        intake = PairingIntake(store: store)
        wantsToPairAgain = true
        updateScreen()
    }

    /// Whether the pairing screen should offer a way back at all.
    ///
    /// Backing out only means something when there is a pairing to back out
    /// to. On the very first run there is nowhere to go, and `cancelPairingAgain`
    /// correctly does nothing, so the screen leaves the button off rather than
    /// showing one that looks broken.
    var canCancelPairing: Bool { hasPairing }

    func cancelPairingAgain() {
        wantsToPairAgain = false
        updateScreen()
    }

    // MARK: - The local network gate

    func acknowledgeLocalNetwork() {
        consent.acknowledge()
        updateScreen()
    }

    /// Called when the trackpad screen appears, and the first thing in this app
    /// that can make iOS ask about the local network.
    ///
    /// The guard is not defensive: it is the whole mechanism. There is no API
    /// to ask whether local network access is allowed, so the explanation can
    /// only come first by making sure nothing browses until the screen that
    /// browses is the screen that is showing.
    func startDiscoveryIfNeeded() {
        guard AppRouter.mayStartDiscovery(screen) else { return }
        // `PadService.start()` tears down and rebuilds, so calling it on a
        // live connection would drop it. The scene becoming active can arrive
        // at the same moment this view appears, and only one of the two should
        // win.
        guard service.state == .idle else { return }
        service.start()
    }

    // MARK: - Scene lifecycle

    func becameActive() {
        guard AppRouter.mayStartDiscovery(screen) else { return }
        service.applicationDidBecomeActive()
    }

    func enteredBackground() {
        // No gate. Telling the service the app went away is true on every
        // screen, and it starts nothing.
        service.applicationDidEnterBackground()
    }

    // MARK: -

    private func updateScreen() {
        screen = AppRouter.screen(
            hasPairing: hasPairing,
            hasAcknowledgedLocalNetwork: consent.hasAcknowledged,
            wantsToPairAgain: wantsToPairAgain
        )
    }
}
