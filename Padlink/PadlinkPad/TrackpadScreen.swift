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
    @State private var showingLayoutPicker = false
    /// Held modifiers travel from the keyboard down to the trackpad, so a pinch
    /// can give Command back without also clearing a lock the user set.
    @State private var lockedModifiers: KeyModifiers = []

    /// Remembered across launches. Choosing a keyboard is a preference about
    /// the hardware in front of the user, not about this session, and having to
    /// set it again every launch is what makes a setting feel broken.
    @AppStorage("keyboardLayout") private var layoutID = KeyboardLayout.macBook.rawValue

    private var layout: KeyboardLayout {
        KeyboardLayout(rawValue: layoutID) ?? .macBook
    }

    private var status: PadStatus { PadStatus(service.state) }

    var body: some View {
        // One `GeometryReader` for the whole screen, only so the keyboard can
        // be given a height that matches the key size it will draw at. The
        // panel derives its key size from its own width, so the height has to
        // be computed from that same width or the bottom row is clipped on a
        // narrow iPad and floats in empty space on a wide one.
        GeometryReader { geometry in
            content(width: geometry.size.width, height: geometry.size.height)
        }
        // The first thing in this app that can make iOS ask about the local
        // network, and it happens here because this is the screen that comes
        // after the explanation.
        .onAppear { model.startDiscoveryIfNeeded() }
        .sheet(isPresented: $showingLayoutPicker) {
            LayoutPicker(selection: $layoutID)
        }
        // Changing layout gives every locked modifier back first.
        //
        // The panel is keyed on the layout, so switching rebuilds it with a
        // fresh engine holding nothing. Without this the Mac would still be
        // holding whatever the old keyboard locked, and the new one would show
        // it as off. Switching to "Trackpad only" is the case that makes it
        // unrecoverable: the keyboard is gone, so there is nothing left to tap
        // to release it.
        .onChange(of: layoutID) {
            guard lockedModifiers.isEmpty == false else { return }
            service.send(.modifierState(modifiers: []))
            lockedModifiers = []
        }
    }

    /// How much room to give the keyboard, in points.
    ///
    /// Its natural height is whatever the width allows, but it is capped at
    /// four tenths of the screen. Uncapped, the full MacBook layout on an 11
    /// inch iPad in landscape takes about 470 points and leaves the trackpad a
    /// 200 point strip, which is too short to drag across. The panel scales its
    /// keys down to whatever it is given, so the cap costs key size rather than
    /// cutting the bottom row off.
    private func keyboardHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        let rows = layout.rows.count
        guard rows > 0 else { return 0 }
        // 16 for the panel's own horizontal padding, which is not available to
        // the keys and so must not be counted when working out the key size.
        let unit = max(0, width - 16) / layout.widthInUnits
        let natural = unit * KeyboardPanel.heightInUnits(rows: rows)
        return min(natural, height * 0.4)
    }

    private func content(width: CGFloat, height: CGFloat) -> some View {
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

            TrackpadView(
                send: { message in service.send(message) },
                lockedModifiers: lockedModifiers
            )
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

            if layout != .trackpadOnly {
                KeyboardPanel(
                    layout: layout,
                    send: { message in service.send(message) },
                    onLockedModifiersChanged: { lockedModifiers = $0 }
                )
                .frame(height: keyboardHeight(width: width, height: height))
                // Rebuilt whenever the connection comes or goes, which throws
                // away the engine's held modifiers along with it. That is the
                // correct answer rather than a shortcut: the Mac releases
                // everything it was holding when a connection ends, so a
                // keyboard that went on showing Command as locked would be
                // showing something that stopped being true.
                .id("\(layoutID)-\(service.state.isConnected)")
                .padding(.bottom, 6)
            }

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
    }

    private var typingBar: some View {
        HStack(spacing: 12) {
            Button {
                showingLayoutPicker = true
            } label: {
                Image(systemName: "keyboard.badge.ellipsis")
            }
            .accessibilityLabel("Choose a keyboard layout. Currently \(layout.title).")

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

/// Which on-screen keyboard to show.
///
/// A sheet with a row per layout rather than a segmented control in the typing
/// bar. Three names alone do not say what the difference is, and the difference
/// is the whole choice: one of them removes the keyboard entirely, which is a
/// surprising thing to discover by tapping.
private struct LayoutPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(KeyboardLayout.allCases) { layout in
                Button {
                    selection = layout.rawValue
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(layout.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(layout.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if layout.rawValue == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityAddTraits(layout.rawValue == selection ? [.isSelected] : [])
            }
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
