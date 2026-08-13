import SwiftUI
import PadlinkCore

@main
struct PadlinkMacApp: App {
    var body: some Scene {
        MenuBarExtra("Padlink", systemImage: "keyboard") {
            Text("Padlink \(Padlink.protocolVersion)")
            Divider()
            Button("Quit Padlink") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
