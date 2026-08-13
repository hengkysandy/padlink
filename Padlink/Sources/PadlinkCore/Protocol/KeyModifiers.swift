// Padlink/Sources/PadlinkCore/Protocol/KeyModifiers.swift
import Foundation

/// Wire bitfield. Bits 5 to 7 are reserved and must be zero.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1 << 0)
    public static let control  = KeyModifiers(rawValue: 1 << 1)
    public static let option   = KeyModifiers(rawValue: 1 << 2)
    public static let command  = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    public static let reservedMask = KeyModifiers(rawValue: 0b1110_0000)

    /// True when only shift is set, or nothing is set. This is the condition
    /// that lets text go through the layout-independent unicode path.
    public var isTextSafe: Bool {
        subtracting(.shift).isEmpty
    }
}
