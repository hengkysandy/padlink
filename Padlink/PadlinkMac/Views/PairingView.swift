// Padlink/PadlinkMac/Views/PairingView.swift
import AppKit
import SwiftUI
import PadlinkCore

struct PairingView: View {
    let payload: PairingPayload
    let expiresAt: Date
    let onCancel: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan this with your iPad")
                .font(.headline)

            if let image = QRCodeImage.make(from: payload.urlString, sideLength: 240) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                // Reachable if the payload exceeds the QR generator's capacity,
                // which a very long Mac name can cause. Never leave the pairing
                // window blank with no explanation.
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Could not make a QR code for this Mac's name.")
                        .font(.callout)
                    Text("Use the text below to pair instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 240, height: 240)
            }

            Text(timerInterval: Date() ... expiresAt, countsDown: true)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // The command line client cannot scan a QR code, so it needs the URL
            // itself. Offered as a copy button rather than printed text: at a
            // size that fits this window the URL is unreadable, and nobody
            // retypes a 32 byte key by hand.
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy pairing code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload.urlString, forType: .string)
                    copied = true
                }
                .disabled(copied)

                Button("Cancel", action: onCancel)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
