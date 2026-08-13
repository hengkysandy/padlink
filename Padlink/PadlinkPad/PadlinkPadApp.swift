// Padlink/PadlinkPad/PadlinkPadApp.swift
import SwiftUI
import PadlinkCore

/// Placeholder shell. The real screens arrive in later tasks; this exists so
/// the target builds, launches, and can be seen running in the simulator.
@main
struct PadlinkPadApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 64))
            Text("Padlink")
                .font(.largeTitle.weight(.semibold))
            Text("Protocol version \(Padlink.protocolVersion)")
                .foregroundStyle(.secondary)
        }
    }
}
