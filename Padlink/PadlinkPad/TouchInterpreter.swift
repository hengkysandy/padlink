// Padlink/PadlinkPad/TouchInterpreter.swift
import CoreGraphics
import Foundation
import PadlinkCore

/// One finger, identified by something that stays the same for as long as that
/// finger is on the glass.
///
/// `TrackpadView` derives it from the address of the `UITouch`, which UIKit
/// guarantees to keep for the lifetime of the touch. UIKit recycles those
/// objects between gestures, so the same value can come back later for a
/// different finger. That is harmless here: an id is only ever compared against
/// ids from the same live gesture.
struct TouchID: Hashable, Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

/// Where one finger is, in the trackpad view's own coordinates.
struct TouchSample: Equatable, Sendable {
    let id: TouchID
    let location: CGPoint
}

enum TouchPhase: Sendable {
    case began
    case moved
    case ended
    /// The system took the touch away: an incoming call, a system edge
    /// gesture, the app being sent to the background. Distinct from `ended`,
    /// because the user did not finish the gesture and must not be given a
    /// click for it.
    case cancelled
}

/// One touch event, with no UIKit in it.
struct TouchEvent: Sendable {
    let phase: TouchPhase

    /// Every touch still on the glass **after** this event.
    ///
    /// This is the whole contract between `TrackpadView` and this type, and it
    /// is the one thing worth being careful about. A touch reported by
    /// `touchesEnded` is **absent** here, because it is no longer down.
    /// `UIEvent.allTouches` does include it, with a phase of `.ended`, so the
    /// view filters those out. Getting this backwards would leave every gesture
    /// one finger too wide and make a lift look like a move.
    let active: [TouchSample]

    /// `UIEvent.timestamp`, in seconds since the device booted. Never a clock
    /// read: see the note on `TouchInterpreter`.
    let timestamp: TimeInterval
}

/// The trackpad, minus UIKit.
///
/// Every decision the user can feel lives here: what counts as a tap, when the
/// button is held for a drag, when a gesture becomes a scroll, and what happens
/// when the system takes a touch away mid-drag. `TrackpadView` translates
/// `UITouch` into `TouchEvent` and posts whatever comes back. It decides
/// nothing, which is what makes all of this testable without a device.
///
/// Three rules run through the whole type:
///
/// - **Time comes from the event.** `MoveThrottle` turns the gap between
///   timestamps into `dtMicros`, which drives the Mac's pointer acceleration.
///   A `Date()` read in the handler measures when the handler ran, not when the
///   finger moved, and the difference shows up as a cursor whose speed feels
///   wrong in a way that looks like a sensitivity setting.
/// - **A change in the set of fingers ends one gesture and starts another.**
///   Never a partial adjustment. This is what stops a second finger landing
///   from being read as the first one teleporting.
/// - **A held button is released by every exit, not just the tidy one.** A
///   stuck mouse button on the Mac makes every later movement drag-select, has
///   no visible cause, and cannot be fixed from the iPad.
///
/// A reference type on purpose. It owns one `MoveThrottle`, which is a struct
/// carrying a sub-pixel accumulator; copying it would fork that accumulator and
/// make slow drags stall in a way that only appears below some speed.
///
/// Not thread safe. One instance belongs to one view on the main thread.
final class TouchInterpreter {
    /// Longer than this and the touch is a press, not a tap.
    ///
    /// A quarter of a second is comfortably above a deliberate tap and well
    /// below a press, and it sits under the Mac's own half second double click
    /// interval, so two chained taps still reach it in time.
    static let tapMaxDuration: TimeInterval = 0.25

    /// Further than this from where the finger landed and the touch is a drag,
    /// not a tap. Ten points matches UIKit's own allowance for a press that is
    /// meant to stay put.
    static let tapMaxMovement: Double = 10

    /// How long after a tap a new touch means "and now drag".
    ///
    /// This is what makes text selection work: tap, then put the finger back
    /// down and move, and the button stays held for the whole movement. It is
    /// deliberately shorter than the Mac's half second double click interval,
    /// so the Mac still counts the pair as a double click and the drag selects
    /// by word rather than by character.
    ///
    /// Time only, with no check on where the second touch landed. A proximity
    /// limit would be more literal but it fails silently and invisibly when it
    /// is a little too tight, and the failure (no selection) looks like the
    /// feature was never built.
    static let dragChainWindow: TimeInterval = 0.3

    /// One finger, moving the cursor.
    private struct Pointer {
        let id: TouchID
        let start: CGPoint
        let startedAt: TimeInterval
        var last: CGPoint
        /// The furthest this finger has been from where it landed, not where it
        /// is now. A finger that sweeps away and comes back has already dragged
        /// the cursor across the screen, so clicking when it lifts would click
        /// somewhere the user never aimed at.
        var maxDistance: Double
        /// False for a pointer that was left behind when a multi-touch gesture
        /// lost fingers. Two fingers almost never leave the glass in the same
        /// event, so every two finger tap passes through a moment of one finger
        /// on its way to none. Without this flag, every one of them would
        /// click.
        let tapEligible: Bool
    }

    /// Two or more fingers, scrolling.
    private struct Scroll {
        var centroid: CGPoint
    }

    private enum Gesture {
        case none
        case pointer(Pointer)
        case scroll(Scroll)
    }

    private var gesture: Gesture = .none
    private var activeIDs: Set<TouchID> = []
    /// Exactly one, mutated in place. See the note on the type.
    private var throttle = MoveThrottle()
    private var buttonIsDown = false
    /// When the last tap finished, or nil if the last gesture was not a tap.
    /// Opens `dragChainWindow`.
    private var lastTapEndedAt: TimeInterval?
    /// Scroll's own sub-pixel accumulator. `MoveThrottle` does this for moves,
    /// but scroll does not go through it, and a slow two finger scroll suffers
    /// from truncation exactly as much as a slow drag does.
    private var pendingScrollX: Double = 0
    private var pendingScrollY: Double = 0

    init() {}

    /// Turns one touch event into the messages to send, in order.
    func handle(_ event: TouchEvent) -> [ClientMessage] {
        if event.phase == .cancelled {
            return cancel(remaining: event.active, at: event.timestamp)
        }

        // Driven by which fingers are down rather than by the phase, so an
        // event that adds and removes a touch at the same time still lands on
        // the transition path. The phase only has to distinguish a cancellation
        // from a clean lift.
        let ids = Set(event.active.map(\.id))
        guard ids != activeIDs else {
            return moved(event.active, at: event.timestamp)
        }

        let wasAtRest = isAtRest
        var messages = finishGesture(
            remainingCount: event.active.count,
            at: event.timestamp,
            cancelled: false
        )
        messages += beginGesture(event.active, at: event.timestamp, mayTapOrChain: wasAtRest)
        activeIDs = ids
        return messages
    }

    /// Gives back everything the Mac is currently holding for us.
    ///
    /// The safety net for the case UIKit does not always report as a cancelled
    /// touch: the app being sent to the background with a finger down. Sends
    /// nothing when nothing is held, so calling it alongside a real
    /// `touchesCancelled` does not produce a second button up that the Mac
    /// would read as another click.
    func releaseAll() -> [ClientMessage] {
        var messages: [ClientMessage] = []
        if buttonIsDown {
            messages.append(.pointerButton(button: .left, isDown: false))
            buttonIsDown = false
        }
        throttle.end()
        gesture = .none
        activeIDs = []
        lastTapEndedAt = nil
        pendingScrollX = 0
        pendingScrollY = 0
        return messages
    }

    // MARK: - Gesture boundaries

    private var isAtRest: Bool {
        if case .none = gesture { return true }
        return false
    }

    private func cancel(remaining: [TouchSample], at timestamp: TimeInterval) -> [ClientMessage] {
        var messages = finishGesture(
            remainingCount: remaining.count,
            at: timestamp,
            cancelled: true
        )
        // A cancelled gesture cannot open the drag window. Leaving it open
        // would make the next ordinary touch silently hold the button down.
        lastTapEndedAt = nil
        messages += beginGesture(remaining, at: timestamp, mayTapOrChain: false)
        activeIDs = Set(remaining.map(\.id))
        return messages
    }

    private func finishGesture(
        remainingCount: Int,
        at timestamp: TimeInterval,
        cancelled: Bool
    ) -> [ClientMessage] {
        var messages: [ClientMessage] = []

        switch gesture {
        case .none:
            break

        case let .pointer(pointer):
            throttle.end()

            // A tap is the whole gesture ending cleanly, soon, and near where
            // it started. Anything that leaves other fingers down is part of a
            // larger gesture, not a tap.
            let wasTap = !cancelled
                && remainingCount == 0
                && pointer.tapEligible
                && timestamp - pointer.startedAt <= Self.tapMaxDuration
                && pointer.maxDistance <= Self.tapMaxMovement

            if buttonIsDown {
                // Every exit from a held drag comes through here: a clean lift,
                // a cancellation, and a second finger landing. Only releasing
                // on the clean lift is how the Mac's mouse button gets stuck
                // down with nothing on screen to explain it.
                messages.append(.pointerButton(button: .left, isDown: false))
                buttonIsDown = false
            } else if wasTap {
                messages.append(.pointerButton(button: .left, isDown: true))
                messages.append(.pointerButton(button: .left, isDown: false))
            }

            lastTapEndedAt = wasTap ? timestamp : nil

        case .scroll:
            pendingScrollX = 0
            pendingScrollY = 0
            lastTapEndedAt = nil
        }

        gesture = .none
        return messages
    }

    /// Starts whatever gesture the fingers now on the glass describe, always
    /// with a fresh baseline.
    ///
    /// The baseline is the point. Carrying the old one across a change in the
    /// set of fingers is what turns a second finger landing into one enormous
    /// `pointerMove`, seen as the cursor flying across the screen.
    ///
    /// - Parameter mayTapOrChain: whether this gesture started from a hand off
    ///   the glass. False when fingers were lifted from a larger gesture, or
    ///   after a cancellation.
    private func beginGesture(
        _ active: [TouchSample],
        at timestamp: TimeInterval,
        mayTapOrChain: Bool
    ) -> [ClientMessage] {
        var messages: [ClientMessage] = []

        switch active.count {
        case 0:
            gesture = .none

        case 1:
            let sample = active[0]
            if mayTapOrChain,
               let tapEndedAt = lastTapEndedAt,
               timestamp - tapEndedAt <= Self.dragChainWindow {
                messages.append(.pointerButton(button: .left, isDown: true))
                buttonIsDown = true
            }
            // No need to clear `lastTapEndedAt` here: `finishGesture` sets it
            // on every path that ends a pointer or a scroll, so it is already
            // either this gesture's tap time or nil by the time it is read
            // again. Clearing it as well looked right but no test could tell
            // the difference, which is how it was found to be unreachable.
            throttle.begin(at: timestamp)
            gesture = .pointer(Pointer(
                id: sample.id,
                start: sample.location,
                startedAt: timestamp,
                last: sample.location,
                maxDistance: 0,
                tapEligible: mayTapOrChain
            ))

        default:
            pendingScrollX = 0
            pendingScrollY = 0
            gesture = .scroll(Scroll(centroid: Self.centroid(of: active)))
        }

        return messages
    }

    // MARK: - Movement

    private func moved(_ active: [TouchSample], at timestamp: TimeInterval) -> [ClientMessage] {
        switch gesture {
        case .none:
            return []

        case .pointer(var pointer):
            guard let sample = active.first(where: { $0.id == pointer.id }) else { return [] }
            let dx = Double(sample.location.x - pointer.last.x)
            let dy = Double(sample.location.y - pointer.last.y)
            pointer.last = sample.location
            pointer.maxDistance = max(pointer.maxDistance, Double(hypot(
                sample.location.x - pointer.start.x,
                sample.location.y - pointer.start.y
            )))
            gesture = .pointer(pointer)

            // Every pointer move goes through the throttle: it is what bounds
            // the gap and the deltas before they reach a conversion that would
            // otherwise trap, and what accumulates sub-pixel movement. A nil
            // means there is nothing worth sending yet.
            guard let message = throttle.move(dx: dx, dy: dy, at: timestamp) else { return [] }
            return [message]

        case .scroll(var scroll):
            let centroid = Self.centroid(of: active)
            let dx = Double(centroid.x - scroll.centroid.x)
            let dy = Double(centroid.y - scroll.centroid.y)
            scroll.centroid = centroid
            gesture = .scroll(scroll)
            return scrollMessages(dx: dx, dy: dy)
        }
    }

    /// Turns a centroid delta into a scroll, with the sign left alone.
    ///
    /// **Natural scrolling, matching the iPad itself: the content follows the
    /// fingers.** Two fingers moving down the glass give a positive `dy` in
    /// view coordinates, which is sent unchanged, and macOS reads a positive
    /// vertical scroll as a scroll up, which moves the content down with the
    /// fingers. The horizontal axis follows the same rule. Inverting either one
    /// is instantly obvious to use and a one character fix, but only for
    /// someone who knows which way it was meant to go.
    ///
    /// Scroll deliberately does not go through `MoveThrottle`: it carries no
    /// `dtMicros`, and the Mac applies no acceleration to it. It still needs
    /// the same two guards, so they are repeated here rather than abstracted.
    private func scrollMessages(dx: Double, dy: Double) -> [ClientMessage] {
        guard dx.isFinite, dy.isFinite else { return [] }

        pendingScrollX += dx
        pendingScrollY += dy

        // Toward zero rather than `floor`, so -0.4 and +0.4 behave the same.
        let wholeX = pendingScrollX.rounded(.towardZero)
        let wholeY = pendingScrollY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return [] }

        pendingScrollX -= wholeX
        pendingScrollY -= wholeY

        return [.scroll(dx: Self.clampedToInt16(wholeX), dy: Self.clampedToInt16(wholeY))]
    }

    /// Bounds the value before converting, never after. `Int16(value)` on
    /// anything outside the range traps, which on iOS means the app disappears
    /// mid-scroll.
    private static func clampedToInt16(_ value: Double) -> Int16 {
        if value <= Double(Int16.min) { return .min }
        if value >= Double(Int16.max) { return .max }
        return Int16(value)
    }

    private static func centroid(of samples: [TouchSample]) -> CGPoint {
        guard samples.isEmpty == false else { return .zero }
        let count = CGFloat(samples.count)
        return CGPoint(
            x: samples.reduce(CGFloat(0)) { $0 + $1.location.x } / count,
            y: samples.reduce(CGFloat(0)) { $0 + $1.location.y } / count
        )
    }
}
