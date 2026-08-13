// Padlink/PadlinkMac/Views/MenuContentView.swift
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var service: PadlinkService
    @ObservedObject var accessibility: AccessibilityStatus
    let onPair: () -> Void
    let onShowOnboarding: () -> Void
    let onQuit: () -> Void

    var body: some View {
        if accessibility.isTrusted == false {
            Button("Accessibility permission needed", action: onShowOnboarding)
            Divider()
        }

        switch service.state {
        case .idle:
            Text("Not connected")
        case .pairing:
            Text("Waiting for a device to pair")
        case let .connected(deviceName):
            Text("Connected: \(deviceName)")
        case let .failed(message):
            Text("Problem: \(message)")
        }

        Divider()
        Button("Pair a device", action: onPair)
        Divider()
        Button("Quit Padlink", action: onQuit)
    }
}
