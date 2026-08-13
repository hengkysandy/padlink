// Padlink/Sources/PadlinkCore/Input/MacVirtualKeys.swift
import Foundation

/// Padlink key identity to macOS virtual key code.
///
/// Values come from Apple's HIToolbox `Events.h` (`kVK_*` constants). They are
/// positional, not character based, which is exactly what shortcuts need.
/// This table lives in Core rather than the Mac app so it can be tested for
/// completeness without a simulator.
public enum MacVirtualKeys {
    /// Returned when a key has no mapping. The completeness test asserts this
    /// is never returned for any `PadlinkKey`.
    public static let unmapped: UInt16 = 0xFFFF

    public static func code(for key: PadlinkKey) -> UInt16 {
        switch key {
        case .a: return 0x00
        case .b: return 0x0B
        case .c: return 0x08
        case .d: return 0x02
        case .e: return 0x0E
        case .f: return 0x03
        case .g: return 0x05
        case .h: return 0x04
        case .i: return 0x22
        case .j: return 0x26
        case .k: return 0x28
        case .l: return 0x25
        case .m: return 0x2E
        case .n: return 0x2D
        case .o: return 0x1F
        case .p: return 0x23
        case .q: return 0x0C
        case .r: return 0x0F
        case .s: return 0x01
        case .t: return 0x11
        case .u: return 0x20
        case .v: return 0x09
        case .w: return 0x0D
        case .x: return 0x07
        case .y: return 0x10
        case .z: return 0x06

        case .digit0: return 0x1D
        case .digit1: return 0x12
        case .digit2: return 0x13
        case .digit3: return 0x14
        case .digit4: return 0x15
        case .digit5: return 0x17
        case .digit6: return 0x16
        case .digit7: return 0x1A
        case .digit8: return 0x1C
        case .digit9: return 0x19

        case .minus: return 0x1B
        case .equal: return 0x18
        case .leftBracket: return 0x21
        case .rightBracket: return 0x1E
        case .backslash: return 0x2A
        case .semicolon: return 0x29
        case .quote: return 0x27
        case .grave: return 0x32
        case .comma: return 0x2B
        case .period: return 0x2F
        case .slash: return 0x2C

        case .space: return 0x31
        case .enter: return 0x24
        case .tab: return 0x30
        case .escape: return 0x35
        case .delete: return 0x33
        case .forwardDelete: return 0x75
        case .arrowLeft: return 0x7B
        case .arrowRight: return 0x7C
        case .arrowUp: return 0x7E
        case .arrowDown: return 0x7D
        case .home: return 0x73
        case .end: return 0x77
        case .pageUp: return 0x74
        case .pageDown: return 0x79

        case .f1: return 0x7A
        case .f2: return 0x78
        case .f3: return 0x63
        case .f4: return 0x76
        case .f5: return 0x60
        case .f6: return 0x61
        case .f7: return 0x62
        case .f8: return 0x64
        case .f9: return 0x65
        case .f10: return 0x6D
        case .f11: return 0x67
        case .f12: return 0x6F
        }
    }
}
