// Padlink/PadlinkPad/KeyboardPanel.swift
import PadlinkCore
import SwiftUI

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
                        .font(.system(size: max(9, unit * 0.26)))
                        .foregroundStyle(.secondary)
                }
                Text(cap.label)
                    .font(.system(size: max(11, unit * 0.36), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: unit * cap.width, height: unit * 0.92)
            .background(background(for: cap))
            .foregroundStyle(foreground(for: cap))
            .clipShape(RoundedRectangle(cornerRadius: max(4, unit * 0.14)))
        }
        // Plain, not bordered. The default button style animates a highlight
        // and adds its own padding, which fights the exact sizing above.
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: cap))
    }

    private func press(_ cap: KeyCap) {
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
