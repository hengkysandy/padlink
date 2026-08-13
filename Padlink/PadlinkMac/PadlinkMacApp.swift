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
                onShowOnboarding: { showWindow("onboarding") },
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

    /// Opens a window and brings it to the front.
    ///
    /// `LSUIElement` is true, so this is an accessory app: it has no Dock icon,
    /// and macOS never activates it on its own. Without the `activate()` call
    /// `openWindow` still creates the window, but it opens behind whatever the
    /// user is looking at and never takes focus, which is indistinguishable
    /// from the button doing nothing at all.
    private func showWindow(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate()
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

            // Also put the pairing URL on the clipboard, so the command line
            // client can be paired with a paste and never needs this window.
            // The window is for the iPad, which scans the QR code; on the Mac
            // the URL is the useful half, and a window that fails to come
            // forward should not be able to block pairing entirely.
            //
            // The clipboard is readable by other apps. Acceptable here: the key
            // is single-use, expires in 120 seconds, and only grants control of
            // this Mac from this network.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload.urlString, forType: .string)

            showWindow("pairing")
        } catch {
            // The service has already put the reason into its `state`, which the
            // menu renders. Clearing `pairing` keeps a stale payload from a
            // previous attempt out of the window.
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
