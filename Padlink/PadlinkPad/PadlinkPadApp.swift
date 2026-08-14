// Padlink/PadlinkPad/PadlinkPadApp.swift
import SwiftUI

@main
struct PadlinkPadApp: App {
    /// The one `AppModel` for the life of the process. `@StateObject`, not
    /// `@State`: it owns the pairing store and the connection, and rebuilding
    /// it on a redraw would drop both.
    @StateObject private var model = AppModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // iOS suspends a backgrounded app and tears its sockets
                        // down without telling it, so a connection that
                        // survived on paper usually did not survive in fact.
                        // `PadService` decides whether this is one of those.
                        model.becameActive()
                    case .background:
                        model.enteredBackground()
                    case .inactive:
                        // Control Centre, a notification banner, the app
                        // switcher. Nothing has been torn down, so nothing is
                        // rebuilt.
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

/// The screen switch, and nothing else.
///
/// `AppRouter` decides which of the three it is, and the order of the three is
/// the mechanism that keeps the local network prompt behind its explanation.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.screen {
        case .pairing:
            PairingScreen(model: model)
        case .localNetworkNotice:
            LocalNetworkNoticeScreen(onContinue: { model.acknowledgeLocalNetwork() })
        case .trackpad:
            TrackpadScreen(model: model, service: model.service)
        }
    }
}
