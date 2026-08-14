import AppKit
import Foundation
import SwiftUI
import PadlinkCore

@main
struct PadlinkMacApp: App {
    @StateObject private var accessibility: AccessibilityStatus
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

        let accessibility = AccessibilityStatus()
        // Told to the iPad, not only shown in the menu. Without this the iPad
        // is stuck with whatever `helloAck` said at handshake time: an orange
        // warning that survives the user granting the permission, or a green
        // "Connected" over a session where every event is being discarded.
        accessibility.onChange = { [weak service] granted in
            service?.accessibilityChanged(granted: granted)
        }
        // Polls for the life of the app, not only while the onboarding window
        // happens to be open. That window is suppressed at launch and most
        // users never open it, so polling from its `onAppear` alone meant the
        // permission was in practice only ever read once, at startup, and both
        // the menu's own warning and this callback were dead.
        accessibility.startPolling()
        _accessibility = StateObject(wrappedValue: accessibility)

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
                    closePairingWindow()
                }
                // A stored pairing is not a pairing code any more: the same id
                // and secret are now the iPad's permanent credential. Leaving
                // the QR code up under a countdown that has already run out
                // shows a live key to everyone in the room, and invites a
                // second device to be pointed at a window that is finished.
                //
                // `cancelPairing()` is deliberately not called here. The
                // candidate is already gone and the listener already rebuilt,
                // so calling it would only rebuild a second time.
                .onChange(of: service.completedPairings) { _, _ in
                    closePairingWindow()
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

    /// Takes the pairing code off the screen.
    ///
    /// Clearing `pairing` matters as much as dismissing: the window's content
    /// is built from it, so a payload left behind would still be rendered, and
    /// reopening the window would show a code that is no longer live.
    private func closePairingWindow() {
        // If "Copy pairing code" was used, take it back off the clipboard. The
        // code is finished either way: paired means it is a stored credential
        // that nobody needs to paste again, cancelled or expired means it is
        // worthless.
        if let pairing { PairingClipboard.clear(pairing) }
        pairing = nil
        dismissWindow(id: "pairing")
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

            // The code is deliberately *not* put on the clipboard here. It used
            // to be, so the command line client could pair with a paste, back
            // when the iPad could not scan. The iPad scans now, so the clipboard
            // is no longer on the path anyone normally takes, and the clipboard
            // is readable by every app on this machine. "Copy pairing code" in
            // the window still puts it there when the user asks for it, which
            // keeps `./padlink paste` working.
            //
            // The cost: if this window ever fails to come forward, there is no
            // longer a copy waiting on the clipboard as a way through. The menu
            // still shows the pairing state, and Cancel plus a second attempt
            // is the recovery.
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
