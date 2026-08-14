// Padlink/Sources/PadlinkCore/Input/HeldInputState.swift

/// One thing the Mac must undo when a connection ends.
public enum ReleaseAction: Equatable, Sendable {
    case button(PointerButton)
    case key(PadlinkKey)
    /// Exactly one modifier flag, so the consumer posts one key event per action.
    case modifier(KeyModifiers)
}

/// Tracks which mouse buttons, key codes, and modifiers the peer currently has
/// held, so they can all be released when the connection ends.
///
/// Without this, a connection dying mid-drag leaves a stuck Command key and a
/// Mac that behaves strangely until it is rebooted.
///
/// This lives in Core rather than the Mac app because it is pure bookkeeping
/// with no OS calls, so it can be tested with no Mac and no device.
public struct HeldInputState: Sendable, Equatable {
    public private(set) var heldButtons: Set<PointerButton> = []
    public private(set) var heldKeys: Set<PadlinkKey> = []
    public private(set) var heldModifiers: KeyModifiers = []

    public init() {}

    public var isEmpty: Bool {
        heldButtons.isEmpty && heldKeys.isEmpty && heldModifiers.isEmpty
    }

    public mutating func recordButton(_ button: PointerButton, isDown: Bool) {
        if isDown {
            heldButtons.insert(button)
        } else {
            heldButtons.remove(button)
        }
    }

    /// A key down and its matching key up arrive as two separate messages, so
    /// a connection dying between them leaves that key held at the HID level
    /// and the Mac repeating the character with nothing left to stop it.
    public mutating func recordKey(_ key: PadlinkKey, isDown: Bool) {
        if isDown {
            heldKeys.insert(key)
        } else {
            heldKeys.remove(key)
        }
    }

    /// Absolute, not a delta: this replaces the held set entirely, matching
    /// the wire message that reports the complete current modifier state.
    public mutating func recordModifiers(_ modifiers: KeyModifiers) {
        heldModifiers = modifiers
    }

    /// Returns everything that must be released, and clears the state so a
    /// second call returns nothing.
    ///
    /// The order is fixed rather than incidental. Buttons first, in
    /// `PointerButton` order; then keys, in `PadlinkKey.allCases` order; then
    /// modifiers in shift, control, option, command, function order.
    ///
    /// Two of those choices matter. Keys are sorted by `allCases` rather than
    /// handed back in Set order, because Set iteration order is not stable
    /// between runs and a test asserting on it would flake. And keys are
    /// released before modifiers, because releasing Command first would leave
    /// a bare Tab still down and repeating, while releasing Tab first cannot
    /// leave anything behind.
    public mutating func drainReleases() -> [ReleaseAction] {
        var actions: [ReleaseAction] = []

        for button in PointerButton.allCases where heldButtons.contains(button) {
            actions.append(.button(button))
        }

        for key in PadlinkKey.allCases where heldKeys.contains(key) {
            actions.append(.key(key))
        }

        let orderedModifiers: [KeyModifiers] = [.shift, .control, .option, .command, .function]
        for modifier in orderedModifiers where heldModifiers.contains(modifier) {
            actions.append(.modifier(modifier))
        }

        heldButtons.removeAll()
        heldKeys.removeAll()
        heldModifiers = []
        return actions
    }
}
