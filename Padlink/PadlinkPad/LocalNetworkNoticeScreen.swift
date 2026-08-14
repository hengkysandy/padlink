// Padlink/PadlinkPad/LocalNetworkNoticeScreen.swift
import SwiftUI

/// The explanation that has to come before iOS asks its question.
///
/// iOS asks about the local network exactly once, the instant an `NWBrowser`
/// starts, and a "Don't Allow" is permanent until the user finds the switch in
/// Settings. An app that never explains itself gets refused by people who had
/// no idea what they were refusing, and then looks broken rather than blocked.
///
/// This screen is the only reason `AppRouter` gates discovery: nothing browses
/// until the user has read this and tapped through it.
struct LocalNetworkNoticeScreen: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "wifi")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Padlink needs your local network")
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 16) {
                    Point(
                        icon: "magnifyingglass",
                        text: """
                            Your Mac announces Padlink on the Wi-Fi you are both on. \
                            This iPad has to listen for that announcement to find it.
                            """
                    )
                    Point(
                        icon: "lock",
                        text: """
                            Everything the two send each other is encrypted with the \
                            key from the pairing code, and none of it leaves your \
                            network.
                            """
                    )
                    Point(
                        icon: "exclamationmark.triangle",
                        text: """
                            iOS is about to ask you this once. If you answer "Don't \
                            Allow", Padlink can never see your Mac again until you \
                            turn it back on in Settings, Privacy & Security, Local \
                            Network.
                            """
                    )
                }

                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct Point: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
