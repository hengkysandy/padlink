import AppKit
import Foundation
import SwiftUI
import PadlinkCore

@main
struct PadlinkMacApp: App {
    @StateObject private var accessibility = AccessibilityStatus()
    @StateObject private var service: PadlinkService
    @State private var pairing: PairingPayload?
    @State private var pairingExpiry = Date()

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        let router = MessageRouter(
            synthesizer: MacInputSynthesizer(),
            geometry: ScreenGeometry.current()
        )
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let service = PadlinkService(
            store: KeychainPairingStore(),
            router: router,
            macName: macName
        )
        _service = StateObject(wrappedValue: service)

        // Loads stored pairings and starts listening right away, so a
        // previously paired iPad can reconnect without the user having to
        // open the menu first. `service` here is the local `let` above, not
        // `self`, which is not yet fully initialized at this point.
        Task { await service.start() }
    }

    var body: some Scene {
        MenuBarExtra("Padlink", systemImage: menuIcon) {
            MenuContentView(
                service: service,
                accessibility: accessibility,
                onPair: startPairing,
                onShowOnboarding: { openWindow(id: "onboarding") },
                onQuit: quit
            )
        }

        Window("Pair a device", id: "pairing") {
            if let pairing {
                PairingView(payload: pairing, expiresAt: pairingExpiry) {
                    service.cancelPairing()
                    self.pairing = nil
                    dismissWindow(id: "pairing")
                }
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Accessibility", id: "onboarding") {
            AccessibilityOnboardingView(status: accessibility)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    private var menuIcon: String {
        if case .connected = service.state { return "keyboard.fill" }
        return "keyboard"
    }

    private func startPairing() {
        do {
            let payload = try service.beginPairing()
            pairing = payload
            pairingExpiry = Date().addingTimeInterval(PadlinkService.pairingWindow)
            openWindow(id: "pairing")
        } catch {
            pairing = nil
        }
    }

    /// Releases any held button or modifier before the process dies, so a
    /// quit mid-drag cannot leave a key stuck down on the Mac.
    private func quit() {
        service.stop()
        NSApplication.shared.terminate(nil)
    }
}
