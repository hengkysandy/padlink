// Padlink/PadlinkMac/Views/AccessibilityOnboardingView.swift
import SwiftUI

struct AccessibilityOnboardingView: View {
    @ObservedObject var status: AccessibilityStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Padlink needs Accessibility permission")
                .font(.headline)
            Text("""
                macOS does not let an app move the cursor or type until you \
                allow it. Without this, Padlink connects but nothing happens \
                when you move your finger.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Privacy & Security settings") {
                status.openSystemSettings()
            }

            Text("This window updates on its own once you turn Padlink on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
    }
}
