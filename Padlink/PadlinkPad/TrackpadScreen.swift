// Padlink/PadlinkPad/TrackpadScreen.swift
import PadlinkCore
import SwiftUI

/// The screen the app exists for: a keyboard, a surface to drag on, and one line
/// at the top saying whether any of it is reaching the Mac.
///
/// Laid out like the machine it is driving: status at the top, then the
/// keyboard, then the trackpad, then a thin strip of controls. The keyboard
/// above the trackpad is the whole point. It is where a MacBook puts it, so a
/// hand that knows the MacBook already knows this.
///
/// It decides nothing. `PadStatus` turns the connection into words, `AppRouter`
/// decided this screen may browse at all, `KeyboardLayout` says which keys
/// exist, and `KeystrokeTranslator` turns typed text into messages.
struct TrackpadScreen: View {
    @ObservedObject var model: AppModel
    /// Observed separately from `model`, because the connection state is
    /// published by `PadService` and a view watching only `AppModel` would
    /// never redraw when the connection changed.
    @ObservedObject var service: PadService

    @State private var isTyping = false
    @State private var showingLayoutPicker = false
    @State private var showingTextEntry = false
    /// Held modifiers travel from the keyboard down to the trackpad, so a pinch
    /// can give Command back without also clearing a lock the user set.
    @State private var lockedModifiers: KeyModifiers = []
    /// How many fingers are on the trackpad right now.
    ///
    /// Shown while there is more than one, and not stored anywhere. It exists
    /// because a multi-finger gesture that does nothing gives no clue whether
    /// the fingers were seen at all: a hand that strays over the edge of the
    /// surface has touches filtered out, and three fingers silently arrive as
    /// two. This turns that from a mystery into something visible.
    @State private var fingerCount = 0

    /// What the trackpad made of those fingers.
    ///
    /// Shown beside the count because the count alone cannot tell the two
    /// failures apart. Three fingers that never arrive read as "2". Three that
    /// arrive and are then taken away by iPadOS read as "cancelled by iPadOS".
    /// Both look like nothing happening from the chair, and they need opposite
    /// fixes.
    @State private var activity = TouchInterpreter.Activity.idle

    /// Remembered across launches. Choosing a keyboard is a preference about
    /// the hardware in front of the user, not about this session, and having to
    /// set it again every launch is what makes a setting feel broken.
    @AppStorage("keyboardLayout") private var layoutID = KeyboardLayout.macBook.rawValue

    /// Also remembered, and separate from the layout on purpose: whether the
    /// keyboard is up is something you flip while working, and which keyboard
    /// it is is something you set once.
    @AppStorage("keyboardVisible") private var keyboardVisible = true

    private var layout: KeyboardLayout {
        KeyboardLayout(rawValue: layoutID) ?? .macBook
    }

    private var status: PadStatus { PadStatus(service.state) }

    /// Read once per appearance, not per redraw. Opening and parsing the
    /// provisioning profile on every frame of a drag would be absurd, and the
    /// answer cannot change while the app is running.
    @State private var expiryWarning: String?

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
        .onAppear {
            model.startDiscoveryIfNeeded()
            expiryWarning = BuildExpiry.warning(expiry: BuildExpiry.expiryDate())
        }
        .sheet(isPresented: $showingLayoutPicker) {
            LayoutPicker(selection: $layoutID)
        }
        .sheet(isPresented: $showingTextEntry) {
            TextEntrySheet(isTyping: $isTyping) { keystroke in
                for message in KeystrokeTranslator.messages(for: keystroke) {
                    service.send(message)
                }
            }
        }
        // Changing layout, or putting the keyboard away, gives every locked
        // modifier back first.
        //
        // The panel is keyed on both, so either one rebuilds it with a fresh
        // engine holding nothing. Without this the Mac would still be holding
        // whatever the old keyboard locked, and the new one would show it as
        // off. Hiding the keyboard is the case that makes it unrecoverable:
        // there is no keyboard left to tap to release it.
        .onChange(of: layoutID) { releaseLockedModifiers() }
        .onChange(of: keyboardVisible) { releaseLockedModifiers() }
    }

    private func releaseLockedModifiers() {
        guard lockedModifiers.isEmpty == false else { return }
        service.send(.modifierState(modifiers: []))
        lockedModifiers = []
    }

    /// How much room to give the keyboard, in points.
    ///
    /// Its natural height is whatever the width allows: the biggest keys that
    /// fit across the screen. The cap exists only to stop a very tall, narrow
    /// screen giving the whole display to the keyboard.
    ///
    /// The cap used to be four tenths, which was the wrong trade. It threw away
    /// about a third of the key size that would have fitted, on every screen, to
    /// protect a trackpad the user can now uncover with one tap. Keys that are
    /// hard to hit are a cost paid on every keystroke; a smaller trackpad is a
    /// cost paid only while the keyboard is up, and only until you tap Hide.
    ///
    /// Note what the ceiling really is. A MacBook keyboard is about 285mm wide
    /// and an 11 inch iPad is about 179mm, so a life-size copy cannot fit and no
    /// setting here can make one. The most that fits is the screen width divided
    /// by the layout's width in key units, which is what "natural" means below.
    /// The Compact layout is the real answer for big keys: 10 units instead of
    /// 14.5 makes each one about half again as wide.
    private func keyboardHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        guard keyboardVisible else { return 0 }
        let rows = layout.rows.count
        guard rows > 0 else { return 0 }
        // 16 for the panel's own horizontal padding, which is not available to
        // the keys and so must not be counted when working out the key size.
        let unit = max(0, width - 16) / layout.widthInUnits
        let natural = unit * KeyboardPanel.heightInUnits(rows: rows)
        return min(natural, height * 0.62)
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
                onPairAgain: { model.pairAgain() },
                latencyMillis: service.latencyMillis
            )

            if let expiryWarning {
                // One line, above everything. The failure it prevents is iOS
                // refusing to open the app with a message about an untrusted
                // developer, which looks like a fault rather than a licence
                // running out.
                Label(expiryWarning, systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.25))
            }

            if keyboardVisible {
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
                .padding(.top, 6)
                // Slides up out of the way rather than vanishing. The trackpad
                // grows into the space it leaves, and seeing that happen is
                // what makes the connection between the two obvious the first
                // time somebody taps Hide.
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            trackpad

            toolbar
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

    private var trackpad: some View {
        TrackpadView(
            send: { message in service.send(message) },
            lockedModifiers: lockedModifiers,
            onGestureChanged: { count, activity in
                fingerCount = count
                self.activity = activity
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    // Third signal for the state where everything looks perfect
                    // and nothing on the Mac moves.
                    status.level == .warning ? Color.orange : Color.secondary.opacity(0.35),
                    lineWidth: status.level == .warning ? 6 : 1
                )
        )
        .overlay(trackpadOverlay)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Trackpad. Drag to move your Mac's cursor.")
    }

    /// The hint, replaced by the finger count while more than one finger is
    /// down.
    ///
    /// `allowsHitTesting(false)` on both, so neither can swallow the first touch
    /// of a drag.
    @ViewBuilder private var trackpadOverlay: some View {
        if fingerCount > 1 || activity == .cancelled {
            // The number, large, and under it what the trackpad made of it.
            //
            // A gesture that does nothing gives no clue where it went wrong,
            // and there are three quite different places. The fingers may never
            // have arrived, because a hand straying over the edge of the
            // surface has those touches filtered out and three fingers become
            // two. iPadOS may have taken them away mid-gesture. Or everything
            // may have worked and the Mac ignored the keystroke. The first two
            // are readable here; only the third is left to guess at.
            VStack(spacing: 2) {
                Text("\(fingerCount)")
                    .font(.system(size: 64, weight: .light, design: .rounded))
                Text(activity.label)
                    .font(.footnote)
                    .foregroundStyle(activity == .cancelled ? Color.orange : .secondary)
            }
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            // A grey rectangle with nothing in it does not say "drag here", and
            // this rectangle is most of the app.
            //
            // Four gestures, not twelve. The list exists so the surface does
            // not look blank, and a list long enough to be a reference is one
            // nobody reads. The rest are in the learning docs.
            Text("Drag to move the cursor. Two fingers to scroll, "
                + "two to tap for a right click, pinch to zoom.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
        }
    }

    /// The thin strip along the bottom.
    ///
    /// Icons, not a full width text field. The field that used to live here was
    /// the only way to type before there was a keyboard; now it is a second way,
    /// and a second way does not deserve a permanent stripe of the screen that
    /// the trackpad could have instead.
    private var toolbar: some View {
        HStack(spacing: 24) {
            Button {
                withAnimation(.snappy(duration: 0.32)) { keyboardVisible.toggle() }
            } label: {
                Label(
                    keyboardVisible ? "Hide keyboard" : "Show keyboard",
                    systemImage: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"
                )
                .labelStyle(.iconOnly)
                .font(.title3)
            }
            .accessibilityLabel(keyboardVisible ? "Hide the keyboard" : "Show the keyboard")

            Button {
                showingLayoutPicker = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
            }
            .accessibilityLabel("Choose a keyboard layout. Currently \(layout.title).")

            Spacer()

            // Kept, because the on-screen keyboard is a US layout of real key
            // codes and cannot produce an accent, an emoji, or a paragraph
            // pasted from somewhere else. This opens the iPad's own keyboard for
            // those, and stays out of the way the rest of the time.
            Button {
                showingTextEntry = true
            } label: {
                Image(systemName: "character.cursor.ibeam")
                    .font(.title3)
            }
            .accessibilityLabel("Type longer text, accents, or emoji")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// The iPad's own keyboard, on demand.
///
/// A sheet rather than a bar, so it costs nothing until it is asked for. What it
/// is for is everything the on-screen Mac keyboard cannot do: accents, emoji,
/// dictation, and pasting a block of text.
private struct TextEntrySheet: View {
    @Binding var isTyping: Bool
    let onKeystroke: (Keystroke) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TypingField(
                    isActive: $isTyping,
                    placeholder: "Everything you type here goes to your Mac",
                    onKeystroke: onKeystroke
                )
                .frame(height: 44)

                Text("For accents, emoji and dictation. Letters, shortcuts and "
                    + "arrows are quicker on the keyboard behind this.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Type on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isTyping = false
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(220)])
        // Opened so the user can type, so put the cursor in the field rather
        // than making them tap once more to reach the thing they asked for.
        .onAppear { isTyping = true }
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
    /// Read here as well as in the panel. `@AppStorage` on the same key is one
    /// value in two places, not two values, so the toggle and the keyboard
    /// cannot disagree.
    @AppStorage("keyClickSound") private var keyClickSound = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(KeyboardLayout.allCases) { layout in
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
                }

                Section {
                    Toggle("Key click sound", isOn: $keyClickSound)
                } footer: {
                    // Says what it is instead of what it is not. The honest
                    // version, that no iPad has the hardware for a haptic
                    // click, belongs in the code and not in front of the user.
                    Text("The same click the iPad's own keyboard makes. "
                        + "It follows the silent switch.")
                }
            }
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                // The two things about this app that cannot be fixed in code,
                // put where somebody hunting for gesture settings will find
                // them. Both make a gesture do nothing at all, which without a
                // note like this reads as the app being broken.
                Text("Swipe three fingers up for Mission Control, and left or "
                    + "right to go back and forward in Safari and Finder. "
                    + "Swiping down, and four-finger swipes, do nothing: macOS "
                    + "does not accept those shortcuts from another device. "
                    + "iPadOS also keeps four and five finger swipes for itself "
                    + "unless you turn off Four and Five Finger Gestures in "
                    + "Settings, General, Multitasking & Gestures.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(16)
                    .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
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
    let latencyMillis: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: isCalm ? 4 : 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(isLoud ? .title2 : .body)
                Text(status.headline)
                    .font(headlineFont)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let latencyMillis, status.level == .connected || status.level == .warning {
                    // The round trip, live. It is the difference between "this
                    // feels bad, the app is broken" and "this feels bad, the
                    // Wi-Fi is busy", which from the outside look identical.
                    //
                    // Monospaced digits so a figure changing from 9 to 10 does
                    // not shift the row, which reads as flicker.
                    Text("\(latencyMillis) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(latencyColor(latencyMillis))
                        .accessibilityLabel("Round trip \(latencyMillis) milliseconds")
                }

                if status.level == .error || status.level == .idle {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(isCalm ? .small : .regular)
                }
                Button("Pair again", action: onPairAgain)
                    .buttonStyle(.bordered)
                    .controlSize(isCalm ? .small : .regular)
            }

            if let detail = status.detail {
                Text(detail)
                    .font(isLoud ? .body : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Thin while everything is working, and only then. A connected banner
        // has one short line to say and repeats it forever, so the tall version
        // was spending about fifty points of screen on "yes, still fine" that
        // the keyboard and the trackpad both wanted. Every state that needs
        // reading keeps its full size.
        .padding(.horizontal, 16)
        .padding(.vertical, isCalm ? 7 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .foregroundStyle(foreground)
        .animation(.snappy(duration: 0.25), value: status.level)
    }

    /// True only when there is nothing to act on.
    private var isCalm: Bool { status.level == .connected }

    /// The thresholds come from the original design estimate of 20 to 40
    /// milliseconds, which until now had never been checked against anything.
    /// Green means the estimate held. Orange is noticeable if you look for it.
    /// Red is a trackpad that feels wrong, and the number says so before the
    /// user has to work out whether it is them.
    private func latencyColor(_ millis: Int) -> Color {
        if millis <= 40 { return .green }
        if millis <= 90 { return .orange }
        return .red
    }

    private var headlineFont: Font {
        if isLoud { return .title3.weight(.bold) }
        return isCalm ? .subheadline.weight(.medium) : .headline
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
