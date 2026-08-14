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
    /// The Accessibility answer changed after the handshake.
    ///
    /// `helloAck` reports it once, at connect time. Without this message the
    /// iPad keeps showing whatever was true then: an orange warning that will
    /// not go away after the user grants the permission, or, worse, a green
    /// "Connected" after the permission was revoked and every event the iPad
    /// sends is being thrown away.
    ///
    /// Absolute, not a delta, for the same reason `modifierState` is: a lost
    /// message self-corrects on the next one instead of leaving the two sides
    /// permanently disagreeing.
    case accessibilityChanged(granted: Bool)
}
