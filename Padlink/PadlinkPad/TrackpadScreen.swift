// Padlink/PadlinkPad/TrackpadScreen.swift
import PadlinkCore
import SwiftUI

/// The screen the app exists for: a surface to drag on, a field to type in, and
/// one line at the top saying whether any of it is reaching the Mac.
///
/// It decides nothing. `PadStatus` turns the connection into words, `AppRouter`
/// decided this screen may browse at all, and `KeystrokeTranslator` turns keys
/// into messages.
struct TrackpadScreen: View {
    @ObservedObject var model: AppModel
    /// Observed separately from `model`, because the connection state is
    /// published by `PadService` and a view watching only `AppModel` would
    /// never redraw when the connection changed.
    @ObservedObject var service: PadService

    @State private var isTyping = false

    private var status: PadStatus { PadStatus(service.state) }

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader(
                status: status,
                // No retry entry point on `AppModel`, so this reaches for the
                // service directly. Safe here and only here: this is the
                // trackpad screen, which is the one screen `AppRouter` allows
                // to touch the network.
                onRetry: { service.start() },
                onPairAgain: { model.pairAgain() }
            )

            TrackpadView(send: { message in service.send(message) })
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            // Third signal for the state where everything looks
                            // perfect and nothing on the Mac moves.
                            status.level == .warning ? Color.orange : Color.secondary.opacity(0.35),
                            lineWidth: status.level == .warning ? 6 : 1
                        )
                )
                .overlay(
                    // A grey rectangle with nothing in it does not say "drag
                    // here", and this rectangle is the entire app.
                    // `allowsHitTesting(false)` so the label never swallows the
                    // first touch of a drag.
                    Text("Drag here to move your Mac's cursor. Two fingers to scroll.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                )
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Trackpad. Drag to move your Mac's cursor.")

            typingBar
        }
        // No `.ignoresSafeArea(.keyboard)`. The default is what keeps the
        // typing bar above the software keyboard instead of under it, which
        // would look like a bug in an app that was working.
        //
        // Plain white, not grouped grey: the trackpad surface is
        // `secondarySystemBackground`, which is the *same* grey as
        // `systemGroupedBackground` in light mode, so on a grouped background
        // the one thing the user is meant to touch is invisible.
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            // The first thing in this app that can make iOS ask about the local
            // network, and it happens here because this is the screen that
            // comes after the explanation.
            model.startDiscoveryIfNeeded()
        }
    }

    private var typingBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)

            TypingField(
                isActive: $isTyping,
                placeholder: isTyping
                    ? "Typing goes to your Mac"
                    : "Tap here to type on your Mac",
                onKeystroke: { keystroke in
                    for message in KeystrokeTranslator.messages(for: keystroke) {
                        service.send(message)
                    }
                }
            )
            .frame(height: 40)
            .frame(maxWidth: .infinity)

            if isTyping {
                Button("Done") { isTyping = false }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// The one line at the top, and the paragraph under it when there is one.
///
/// The detail is `PadStatus.detail` word for word. Every failure sends the user
/// somewhere different, and shortening any of them to "not connected" is how
/// "open Settings and turn Padlink on" becomes an evening spent on a router.
private struct StatusHeader: View {
    let status: PadStatus
    let onRetry: () -> Void
    let onPairAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(isLoud ? .title2 : .body)
                Text(status.headline)
                    .font(isLoud ? .title3.weight(.bold) : .headline)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if status.level == .error || status.level == .idle {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.bordered)
                }
                Button("Pair again", action: onPairAgain)
                    .buttonStyle(.bordered)
            }

            if let detail = status.detail {
                Text(detail)
                    .font(isLoud ? .body : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .foregroundStyle(foreground)
    }

    /// True for the Accessibility case only.
    ///
    /// It is the state where the connection is genuinely fine, the app is
    /// genuinely working, and macOS silently throws away every event it is
    /// sent. Every other signal on this screen says success, so this one has to
    /// contradict all of them at a size nobody scrolls past. That confusion has
    /// already cost real time on this project twice.
    private var isLoud: Bool { status.level == .warning }

    private var icon: String {
        switch status.level {
        case .idle: return "bolt.horizontal.circle"
        case .working: return "antenna.radiowaves.left.and.right"
        case .connected: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var background: Color {
        switch status.level {
        case .idle, .working:
            return Color(uiColor: .secondarySystemBackground)
        case .connected:
            return Color.green.opacity(0.18)
        case .warning:
            // Solid, not a tint. This one has to be impossible to mistake for
            // decoration.
            return Color.orange
        case .error:
            return Color.red.opacity(0.16)
        }
    }

    private var foreground: Color {
        status.level == .warning ? .black : .primary
    }
}
