// Padlink/PadlinkMac/Views/MenuContentView.swift
import PadlinkCore
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
            // Says where the code went. Without this the app looks idle while
            // the useful thing has already happened on the clipboard.
            Text("Pairing code copied. Paste it into the test client.")
        case let .connected(deviceName):
            Text("Connected: \(deviceName)")
        case let .failed(message):
            Text("Problem: \(message)")
        }

        Divider()
        Button("Pair a device", action: onPair)

        // Revoking access. The design has always had a long-lived shared key
        // per device and, until now, no way to take one back: a paired iPad
        // that was lost or given away kept working forever. A key you cannot
        // revoke is the part of a pairing design that ages worst.
        let paired = service.pairedDevices()
        if paired.isEmpty == false {
            Menu("Forget a device") {
                ForEach(paired, id: \.id) { record in
                    Button(record.peerName) { service.forget(record) }
                }
            }
        }

        Divider()
        Button("Quit Padlink", action: onQuit)
    }
}
