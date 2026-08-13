// Padlink/Sources/PadlinkCore/Input/HeldInputState.swift

/// One thing the Mac must undo when a connection ends.
public enum ReleaseAction: Equatable, Sendable {
    case button(PointerButton)
    /// Exactly one modifier flag, so the consumer posts one key event per action.
    case modifier(KeyModifiers)
}

/// Tracks which mouse buttons and modifiers the peer currently has held, so
/// they can all be released when the connection ends.
///
/// Without this, a connection dying mid-drag leaves a stuck Command key and a
/// Mac that behaves strangely until it is rebooted.
///
/// This lives in Core rather than the Mac app because it is pure bookkeeping
/// with no OS calls, so it can be tested with no Mac and no device.
public struct HeldInputState: Sendable, Equatable {
    public private(set) var heldButtons: Set<PointerButton> = []
    public private(set) var heldModifiers: KeyModifiers = []

    public init() {}

    public var isEmpty: Bool {
        heldButtons.isEmpty && heldModifiers.isEmpty
    }

    public mutating func recordButton(_ button: PointerButton, isDown: Bool) {
        if isDown {
            heldButtons.insert(button)
        } else {
            heldButtons.remove(button)
        }
    }

    /// Absolute, not a delta: this replaces the held set entirely, matching
    /// the wire message that reports the complete current modifier state.
    public mutating func recordModifiers(_ modifiers: KeyModifiers) {
        heldModifiers = modifiers
    }

    /// Returns everything that must be released, and clears the state so a
    /// second call returns nothing. Buttons come first, in `PointerButton`
    /// order, then modifiers in shift, control, option, command, function
    /// order, so the result is deterministic.
    public mutating func drainReleases() -> [ReleaseAction] {
        var actions: [ReleaseAction] = []

        for button in PointerButton.allCases where heldButtons.contains(button) {
            actions.append(.button(button))
        }

        let orderedModifiers: [KeyModifiers] = [.shift, .control, .option, .command, .function]
        for modifier in orderedModifiers where heldModifiers.contains(modifier) {
            actions.append(.modifier(modifier))
        }

        heldButtons.removeAll()
        heldModifiers = []
        return actions
    }
}
