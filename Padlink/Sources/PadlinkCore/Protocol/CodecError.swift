// Padlink/Sources/PadlinkCore/Protocol/CodecError.swift
import Foundation

public enum CodecError: Error, Equatable, Sendable {
    /// The buffer ended before the value did.
    case truncated
    case unknownMessageType(UInt8)
    case unknownKey(UInt16)
    case unknownPointerButton(UInt8)
    /// A newer iPad asked for something this Mac has never heard of. Rejected
    /// rather than ignored, so it cannot look as though it worked.
    case unknownSystemAction(UInt8)
    case unknownPinchPhase(UInt8)
    /// Bits 5 to 7 of the modifier bitfield must be zero.
    case reservedModifierBitsSet(UInt8)
    case invalidUTF8
    case stringTooLong
    /// The message decoded, but bytes were left over. Treated as corruption.
    case trailingBytes
}
