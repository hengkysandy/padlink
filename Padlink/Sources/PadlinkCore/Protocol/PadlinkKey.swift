// Padlink/Sources/PadlinkCore/Protocol/PadlinkKey.swift
import Foundation

/// A platform-neutral key identity. These raw values travel on the wire, so
/// they must never change. Gaps between groups leave room to add keys later.
public enum PadlinkKey: UInt16, Sendable, Hashable, CaseIterable {
    // Letters, 1 to 26
    case a = 1, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digit row, 30 to 39
    case digit0 = 30, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9

    // Punctuation, 50 to 60
    case minus = 50, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, grave, comma, period, slash

    // Named keys, 70 to 83
    case space = 70, enter, tab, escape, delete, forwardDelete
    case arrowLeft, arrowRight, arrowUp, arrowDown
    case home, end, pageUp, pageDown

    // Function row, 100 to 111
    case f1 = 100, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}
