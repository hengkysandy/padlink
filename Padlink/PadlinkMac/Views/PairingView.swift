// Padlink/PadlinkMac/Views/PairingView.swift
import SwiftUI
import PadlinkCore

struct PairingView: View {
    let payload: PairingPayload
    let expiresAt: Date
    let onCancel: () -> Void

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

            // Shown as text because the command line test client cannot scan a
            // QR code. Same secret, own screen, deliberately opened window.
            Text(payload.urlString)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
                .frame(width: 300)

            Button("Cancel", action: onCancel)
        }
        .padding(20)
    }
}
