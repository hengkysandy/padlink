// Padlink/PadlinkPad/MoveThrottle.swift
import Foundation
import PadlinkCore

/// Turns raw touch deltas and event timestamps into safe `pointerMove`
/// messages.
///
/// It exists because of one field. `ClientMessage.pointerMove` carries
/// `dtMicros` as a `UInt16`, which stops at 65535 microseconds, about 65
/// milliseconds. Nothing in `PadlinkCore` clamps it, because the Mac only ever
/// reads that field and never builds one. On the iPad a finger that rests for a
/// moment and then moves produces a gap far larger than that, and in Swift a
/// `UInt16(gap)` conversion that does not fit does not saturate or wrap: it
/// traps. A trap in a touch handler kills the process, so the app simply
/// disappears mid-drag. `dx` and `dy` are `Int16` and have exactly the same
/// problem. Every conversion here is bounded before it happens.
///
/// It also does two smaller jobs that belong in the same place, because both
/// depend on state carried between events:
///
/// - Sub-pixel deltas are accumulated rather than discarded. A slow drag can
///   deliver less than a point per event, and truncating each one to zero would
///   make the cursor refuse to move at all below some speed.
/// - Moves that round to nothing return `nil`, so a still finger does not fill
///   the socket with zero-length moves.
///
/// Not thread safe, and not meant to be: one instance belongs to one touch
/// handler on the main thread.
struct MoveThrottle {
    /// A gap of zero is legal for a `UInt16` but useless to the Mac, which
    /// divides distance by time to get the speed its acceleration curve needs.
    static let minDtMicros: UInt16 = 1
    /// `UInt16.max`, spelled out because it is the whole reason for this type.
    static let maxDtMicros: UInt16 = 65535

    /// Fractional points not yet reported, kept so slow drags still move.
    private var pendingX: Double = 0
    private var pendingY: Double = 0

    /// The timestamp of the last move actually sent, not the last one seen.
    ///
    /// This matters. When several events accumulate into one message, the
    /// distance in that message covers all of them, so the time must too.
    /// Measuring from the last event seen instead would report three events
    /// worth of distance against one event worth of time, and tell the Mac the
    /// finger was moving three times faster than it was.
    private var lastSentAt: TimeInterval?

    init() {}

    /// Starts a drag. Call on touch down.
    ///
    /// Clearing the state matters more than it looks. Without it, the gap for
    /// the first move of a new drag is measured from the end of the previous
    /// one, which includes however long the user spent not touching the screen.
    /// That is the oversized gap this type exists to prevent, arriving by the
    /// most ordinary route there is.
    mutating func begin(at timestamp: TimeInterval) {
        pendingX = 0
        pendingY = 0
        lastSentAt = timestamp.isFinite ? timestamp : nil
    }

    /// Ends a drag. Call on touch up or cancel.
    mutating func end() {
        pendingX = 0
        pendingY = 0
        lastSentAt = nil
    }

    /// Converts one touch delta into a message, or `nil` if there is nothing
    /// worth sending yet.
    ///
    /// - Parameters:
    ///   - dx: Horizontal movement in points since the previous event.
    ///   - dy: Vertical movement in points since the previous event.
    ///   - timestamp: `UIEvent.timestamp`, in seconds. Use the event's own
    ///     timestamp rather than `Date()`: it is the moment the touch happened,
    ///     not the moment the handler got around to running.
    mutating func move(dx: Double, dy: Double, at timestamp: TimeInterval) -> ClientMessage? {
        // Infinity and NaN cannot be converted to an integer either, so they
        // are the same crash by a different door. Drop them and keep the
        // accumulator clean; adding NaN to it would poison every later move.
        guard dx.isFinite, dy.isFinite, timestamp.isFinite else { return nil }

        pendingX += dx
        pendingY += dy

        // Toward zero, not `floor`, so that -0.4 and +0.4 behave the same way.
        let wholeX = pendingX.rounded(.towardZero)
        let wholeY = pendingY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return nil }

        // Keep only the fraction. An absurd delta is clamped below and the
        // excess is thrown away rather than carried, because carrying it would
        // turn one bad event into a cursor that keeps sliding for several more
        // events with no finger behind it.
        pendingX -= wholeX
        pendingY -= wholeY

        let message = ClientMessage.pointerMove(
            dx: Self.clampedToInt16(wholeX),
            dy: Self.clampedToInt16(wholeY),
            dtMicros: Self.dtMicros(from: lastSentAt, to: timestamp)
        )
        lastSentAt = timestamp
        return message
    }

    /// Bounds the value before converting, never after. `Int16(value)` on
    /// anything outside the range traps.
    private static func clampedToInt16(_ value: Double) -> Int16 {
        if value <= Double(Int16.min) { return .min }
        if value >= Double(Int16.max) { return .max }
        return Int16(value)
    }

    /// Bounds the gap to `1...65535` microseconds before converting.
    ///
    /// A missing start time yields the floor rather than a gap computed from an
    /// absolute timestamp, which would be an enormous number with no meaning.
    private static func dtMicros(from start: TimeInterval?, to now: TimeInterval) -> UInt16 {
        guard let start else { return minDtMicros }
        let micros = ((now - start) * 1_000_000).rounded()
        guard micros.isFinite else { return minDtMicros }
        // Also catches a negative gap from out-of-order events, which would
        // trap on an unsigned conversion just as hard as an oversized one.
        if micros <= Double(minDtMicros) { return minDtMicros }
        if micros >= Double(maxDtMicros) { return maxDtMicros }
        return UInt16(micros)
    }
}
