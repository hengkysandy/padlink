// Padlink/Sources/PadlinkCore/Protocol/Messages.swift
import Foundation

public enum PointerButton: UInt8, Sendable, Hashable, CaseIterable {
    case left = 0
    case right = 1
}

/// Sent by the iPad.
public enum ClientMessage: Sendable, Equatable {
    case hello(protocolVersion: UInt16, deviceName: String)
    /// Raw finger delta in points, plus the time since the previous move as
    /// measured on the iPad. The Mac must not measure this itself, because
    /// network jitter would corrupt the speed used for acceleration.
    case pointerMove(dx: Int16, dy: Int16, dtMicros: UInt16)
    case pointerButton(button: PointerButton, isDown: Bool)
    case scroll(dx: Int16, dy: Int16)
    /// Text to insert, layout-independent. Used when no modifier beyond shift is active.
    case keyText(String)
    case keyCode(key: PadlinkKey, isDown: Bool, modifiers: KeyModifiers)
    /// The complete current modifier state, reported on its own rather than
    /// attached to a keystroke. This is what lets Command stay held across
    /// several Tab presses, which the macOS app switcher requires.
    ///
    /// It is absolute, not a delta, so a lost message self-corrects on the
    /// next one instead of leaving the two sides permanently disagreeing.
    case modifierState(modifiers: KeyModifiers)
    case ping(seq: UInt32)
}

/// Sent by the Mac.
public enum ServerMessage: Sendable, Equatable {
    case helloAck(protocolVersion: UInt16, accessibilityGranted: Bool)
    case pong(seq: UInt32)
    case error(code: UInt8, message: String)
}
