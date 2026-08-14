// Padlink/PadlinkPad/KeyboardPanel.swift
import AudioToolbox
import PadlinkCore
import SwiftUI
import UIKit

/// The on-screen keyboard.
///
/// It decides nothing. `KeyboardLayout` says which keys exist and how wide they
/// are, `KeyboardEngine` says what a tap produces and how a modifier behaves,
/// and this draws the result and reports which modifiers ended up held.
///
/// Sizing is done from the layout's own width in key units rather than from a
/// fixed point size. A key is `width / widthInUnits` wide, so every row lines up
/// on every iPad, in both orientations, without a single hard-coded number and
/// without a row that can overflow the screen.
struct KeyboardPanel: View {
    let layout: KeyboardLayout
    let send: (ClientMessage) -> Void
    /// Called whenever the locked set changes, so the trackpad can restore it
    /// after a pinch instead of clearing the Mac's modifiers outright.
    let onLockedModifiersChanged: (KeyModifiers) -> Void

    @State private var engine = KeyboardEngine()

    /// Whether a key makes a sound.
    ///
    /// Sound and not haptics, which is worth stating because haptics would be
    /// the obvious answer on a phone. No iPad has a Taptic Engine, so
    /// `UIImpactFeedbackGenerator` does nothing at all here. Sound is the only
    /// feedback available beyond the key moving.
    ///
    /// Off is a real choice, so it is a setting rather than a decision made for
    /// the user. A sound that cannot be turned off is worse than no sound.
    @AppStorage("keyClickSound") private var keyClickSound = true

    var body: some View {
        GeometryReader { geometry in
            // The smaller of what the width allows and what the height allows.
            //
            // Width alone is the natural size, and it is what the screen uses
            // to ask for a height. But the screen also caps that height, so the
            // full MacBook layout in landscape does not leave the trackpad a
            // strip too small to drag on. Taking only the width here would draw
            // keys too tall for the frame and clip the bottom row, which is the
            // space bar and every modifier.
            let unit = min(
                geometry.size.width / layout.widthInUnits,
                geometry.size.height / Self.heightInUnits(rows: layout.rows.count)
            )
            VStack(spacing: unit * 0.06) {
                ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: unit * 0.06) {
                        ForEach(row) { cap in
                            keyButton(cap, unit: unit)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .padding(.horizontal, 8)
        // Leaving the app gives every locked modifier back.
        //
        // Backgrounding does not close the connection: `PadService` only makes
        // a note of it, so the socket can outlive the app being on screen. A
        // Command locked here would stay held on the Mac while the user was
        // somewhere else entirely, turning their next keystroke into a
        // shortcut, with the one thing that could explain it (this keyboard)
        // not visible. The trackpad already does the same for a held mouse
        // button, for the same reason.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in
            for message in engine.clearModifiers() {
                send(message)
            }
            onLockedModifiersChanged(engine.lockedModifiers)
        }
    }

    /// How tall `rows` rows are, in key units: 0.92 per key and 0.06 of spacing
    /// between them.
    ///
    /// Shared with `TrackpadScreen`, which asks for a height before this view
    /// exists. Two copies of these numbers would drift, and the symptom would
    /// be a keyboard that does not quite fill the space reserved for it.
    static func heightInUnits(rows: Int) -> Double {
        guard rows > 0 else { return 1 }
        return Double(rows) * 0.92 + Double(rows - 1) * 0.06
    }

    private func keyButton(_ cap: KeyCap, unit: CGFloat) -> some View {
        Button {
            press(cap)
        } label: {
            VStack(spacing: 1) {
                if let secondary = cap.secondaryLabel {
                    Text(secondary)
                        .font(.system(size: max(9, unit * 0.24)))
                        .foregroundStyle(.secondary)
                }
                Text(cap.label)
                    .font(.system(size: max(11, unit * 0.38), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        // A style rather than a modified label, because only a style can see
        // `isPressed`. The default button styles animate their own highlight and
        // add their own padding, which fights the exact key sizing.
        .buttonStyle(KeyCapStyle(
            unit: unit,
            width: cap.width,
            background: background(for: cap),
            foreground: foreground(for: cap)
        ))
        // Animates the latch colour, so a modifier arming or locking is a change
        // the eye catches rather than a repaint it might miss.
        .animation(.easeOut(duration: 0.15), value: latch(for: cap))
        .accessibilityLabel(accessibilityLabel(for: cap))
    }

    private func press(_ cap: KeyCap) {
        if keyClickSound {
            // 1104 is the system keyboard click, the same one the iPad's own
            // keyboard uses. Borrowed rather than shipped as an audio file so
            // it matches whatever the user already expects a key to sound like,
            // and it follows the ringer switch on its own.
            AudioServicesPlaySystemSound(1104)
        }
        for message in engine.press(cap.action) {
            send(message)
        }
        onLockedModifiersChanged(engine.lockedModifiers)
    }

    // MARK: - Showing what is held

    /// A modifier's state has to be visible, because it survives the tap that
    /// set it. An armed Command that looks the same as an off Command turns the
    /// next letter into a shortcut with nothing on screen to explain it.
    private func latch(for cap: KeyCap) -> ModifierLatch {
        switch cap.action {
        case let .modifier(modifier): return engine.latch(of: modifier)
        case .capsLock: return engine.latch(of: .shift) == .locked ? .locked : .off
        case .key: return .off
        }
    }

    private func background(for cap: KeyCap) -> Color {
        switch latch(for: cap) {
        case .locked: return .accentColor
        case .oneShot: return .accentColor.opacity(0.35)
        case .off: return Color(uiColor: .secondarySystemBackground)
        }
    }

    private func foreground(for cap: KeyCap) -> Color {
        latch(for: cap) == .locked ? .white : .primary
    }

    private func accessibilityLabel(for cap: KeyCap) -> String {
        switch latch(for: cap) {
        case .locked: return "\(cap.label), locked"
        case .oneShot: return "\(cap.label), on for the next key"
        case .off: return cap.label
        }
    }
}

/// One key: the shape, and what it does under a finger.
///
/// A real keycap moves when pressed and a flat rectangle does not, and on a
/// glass keyboard that movement is the only confirmation there is. There is no
/// travel to feel and the result appears on a different screen, so without it a
/// key that was missed and a key that was hit look identical.
///
/// The press feedback is deliberately faster going down than coming back up.
/// Touch down has to feel instant, and the release can afford to settle, which
/// is what makes it read as a key rather than a fade.
private struct KeyCapStyle: ButtonStyle {
    let unit: CGFloat
    let width: Double
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let radius = max(4, unit * 0.14)

        return configuration.label
            .frame(width: unit * width, height: unit * 0.92)
            .background(pressed ? Color.accentColor : background)
            .foregroundStyle(pressed ? Color.white : foreground)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            // The seat the keycap sits in. Dropped while pressed, so the key
            // looks like it went down into the board rather than just changing
            // colour.
            .shadow(
                color: .black.opacity(pressed ? 0.05 : 0.18),
                radius: pressed ? 1 : 2,
                y: pressed ? 0 : 1
            )
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(
                pressed
                    ? .easeOut(duration: 0.06)
                    : .spring(response: 0.28, dampingFraction: 0.55),
                value: pressed
            )
    }
}
