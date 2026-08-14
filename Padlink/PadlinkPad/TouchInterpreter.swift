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

    /// How far a two finger gesture must move before it commits to being a
    /// scroll or a zoom.
    ///
    /// Both start identically: two fingers on the glass, not yet moving. The
    /// choice cannot be made at touch down, so it is made at the first movement
    /// worth reading, and then locked for the rest of the gesture. Locking is
    /// the important half. Deciding afresh on every frame makes a slow diagonal
    /// pinch flicker between zooming and scrolling, which is unusable and looks
    /// like a bug in the Mac rather than in the gesture.
    ///
    /// Twelve points is roughly a small deliberate movement, above the noise of
    /// a finger resting on glass and below anything the user would call a
    /// gesture.
    static let twoFingerDecision: Double = 12

    /// How far three or four fingers must travel before the swipe fires.
    ///
    /// Larger than the other thresholds on purpose. A swipe fires a keystroke
    /// that changes the whole screen (Mission Control, another space, a page
    /// back), and there is no way to take that back from the iPad. Forty points
    /// is a movement nobody makes by accident while resting a hand.
    static let swipeThreshold: Double = 40

    /// Below this speed at lift, in points per second, a scroll simply stops.
    /// Above it, momentum carries on.
    static let momentumMinSpeed: Double = 120

    /// Momentum stops when it decays below this, in points per second. Without
    /// a floor the scroll creeps forward for several seconds at a speed the
    /// user cannot see but the Mac can.
    static let momentumStopSpeed: Double = 24

    /// The fraction of its speed momentum keeps after one second. Applied
    /// continuously as `pow(retention, dt)`, so the feel does not depend on how
    /// often the display link happens to fire.
    static let momentumRetention: Double = 0.135

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

    /// What a two finger gesture turned out to be.
    private enum TwoFingerMode {
        /// Still deciding. A two finger tap ends here and never moves on.
        case undecided
        case scroll
        case zoom
    }

    /// Two fingers: a scroll, a zoom, or a tap that becomes a right click.
    private struct TwoFinger {
        let startedAt: TimeInterval
        let startCentroid: CGPoint
        let startSpread: Double
        var centroid: CGPoint
        var spread: Double
        var mode: TwoFingerMode
        /// The furthest the centroid has been from where it started, for the
        /// same reason `Pointer.maxDistance` exists: a gesture that wandered
        /// away and came back is not still.
        var maxTravel: Double
        /// Points per second, smoothed, for momentum. Only meaningful once
        /// `mode` is `.scroll`.
        var velocityX: Double
        var velocityY: Double
        var lastMovedAt: TimeInterval
    }

    /// Three or four fingers: one swipe, which fires at most one keystroke.
    private struct Multi {
        let fingerCount: Int
        let startCentroid: CGPoint
        var centroid: CGPoint
        /// Set once the swipe has fired. The rest of the gesture then sends
        /// nothing at all, so a long swipe cannot switch four spaces.
        var fired: Bool
    }

    /// A scroll that outlived the fingers that started it.
    private struct Momentum {
        var velocityX: Double
        var velocityY: Double
        var lastSteppedAt: TimeInterval
    }

    private enum Gesture {
        case none
        case pointer(Pointer)
        case twoFinger(TwoFinger)
        case multi(Multi)
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
    /// True while a zoom is holding Command on the Mac. Read by every exit,
    /// because this is the one piece of state here that can outlive the app.
    private var zoomHoldsCommand = false
    private var momentum: Momentum?

    /// Modifiers the Mac is holding for somebody else, normally the on screen
    /// keyboard's locked ones.
    ///
    /// A zoom holds Command by sending `modifierState`, and `modifierState` is
    /// absolute: it replaces the Mac's whole held set. Without knowing what was
    /// already held, releasing Command at the end of a pinch would also release
    /// a Command the user had locked on the keyboard, and the keyboard would go
    /// on showing it as locked. Kept in sync by whoever owns the keyboard.
    var baseModifiers: KeyModifiers = []

    /// Whether a flick is still scrolling after the fingers left the glass.
    /// The view layer drives `stepMomentum` while this is true.
    var hasMomentum: Bool { momentum != nil }

    init() {}

    /// Turns one touch event into the messages to send, in order.
    func handle(_ event: TouchEvent) -> [ClientMessage] {
        // A finger on the glass stops a coasting scroll, exactly as it does on
        // a real trackpad. Done before anything else, so no path below can be
        // written without it.
        momentum = nil

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
        messages += releaseZoomModifier()
        throttle.end()
        gesture = .none
        activeIDs = []
        lastTapEndedAt = nil
        pendingScrollX = 0
        pendingScrollY = 0
        momentum = nil
        return messages
    }

    /// Advances a scroll that is still coasting after the fingers lifted.
    ///
    /// Driven by the view's display link rather than by a timer owned here, so
    /// this type still holds no clock and every step is a value the test can
    /// choose. Returns nothing once the speed decays past the floor, and
    /// `hasMomentum` goes false in the same call, which is the view's signal to
    /// stop asking.
    func stepMomentum(at timestamp: TimeInterval) -> [ClientMessage] {
        guard var current = momentum else { return [] }

        // Clamped for the same reason `MoveThrottle` clamps: the display link
        // stalls whenever the app is interrupted, and one huge `dt` would turn
        // a gentle flick into a single enormous jump.
        let dt = min(max(timestamp - current.lastSteppedAt, 0), 0.1)
        current.lastSteppedAt = timestamp

        let decay = pow(Self.momentumRetention, dt)
        current.velocityX *= decay
        current.velocityY *= decay

        guard hypot(current.velocityX, current.velocityY) >= Self.momentumStopSpeed else {
            momentum = nil
            pendingScrollX = 0
            pendingScrollY = 0
            return []
        }

        momentum = current
        return scrollMessages(dx: current.velocityX * dt, dy: current.velocityY * dt)
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

        case let .twoFinger(two):
            // A two finger tap is a right click. It qualifies only if the
            // gesture never became a scroll or a zoom, which is a stricter test
            // than measuring travel again: `twoFingerDecision` has already
            // rejected everything that moved enough to mean something.
            //
            // Emitted the moment the gesture ends, even with one finger still
            // down. Two fingers almost never leave the glass in the same event,
            // so waiting for none would mean waiting for a finger that is
            // already lifting, and the leftover pointer is not tap eligible so
            // it cannot add a left click of its own.
            //
            // `remainingCount < 2` is what keeps that from firing on the way
            // *up* in finger count. Without it, a third finger landing ends the
            // two finger gesture with no travel and no time elapsed, which
            // looks exactly like a tap, and every three finger swipe would open
            // a context menu before it started.
            let wasTap = !cancelled
                && two.mode == .undecided
                && remainingCount < 2
                && timestamp - two.startedAt <= Self.tapMaxDuration
                && two.maxTravel <= Self.tapMaxMovement

            if wasTap {
                messages.append(.pointerButton(button: .right, isDown: true))
                messages.append(.pointerButton(button: .right, isDown: false))
            }

            if two.mode == .scroll, !cancelled {
                messages += startMomentum(from: two, at: timestamp)
            }

            messages += releaseZoomModifier()
            pendingScrollX = 0
            pendingScrollY = 0
            // A right click does not open the drag window. Chaining a left
            // button drag onto a right click is not a gesture anyone makes, and
            // leaving it open would make the next touch silently hold the
            // button down after a context menu.
            lastTapEndedAt = nil

        case .multi:
            lastTapEndedAt = nil
        }

        gesture = .none
        return messages
    }

    /// Hands a finished scroll its remaining speed, if it had any worth keeping.
    private func startMomentum(from two: TwoFinger, at timestamp: TimeInterval) -> [ClientMessage] {
        // A finger that came to rest before lifting means the user stopped on
        // purpose. Without this, a scroll that ended perfectly still would
        // coast on whatever velocity it had a moment earlier.
        guard timestamp - two.lastMovedAt <= 0.06 else { return [] }
        guard hypot(two.velocityX, two.velocityY) >= Self.momentumMinSpeed else { return [] }

        momentum = Momentum(
            velocityX: two.velocityX,
            velocityY: two.velocityY,
            lastSteppedAt: timestamp
        )
        return []
    }

    /// Gives Command back if a zoom was holding it, and nothing otherwise.
    ///
    /// `modifierState` is absolute, so this restores `baseModifiers` rather
    /// than sending an empty set. Sending empty would release a Command the
    /// user had locked on the on screen keyboard, which would keep showing it
    /// as locked while the Mac had let it go.
    private func releaseZoomModifier() -> [ClientMessage] {
        guard zoomHoldsCommand else { return [] }
        zoomHoldsCommand = false
        return [.modifierState(modifiers: baseModifiers)]
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

        case 2:
            pendingScrollX = 0
            pendingScrollY = 0
            gesture = .twoFinger(TwoFinger(
                startedAt: timestamp,
                startCentroid: Self.centroid(of: active),
                startSpread: Self.spread(of: active),
                centroid: Self.centroid(of: active),
                spread: Self.spread(of: active),
                mode: .undecided,
                maxTravel: 0,
                velocityX: 0,
                velocityY: 0,
                lastMovedAt: timestamp
            ))

        default:
            // Three fingers and four. Five is treated as four rather than
            // ignored: a hand resting while three fingers swipe is common, and
            // doing nothing at all would read as the gesture being broken.
            gesture = .multi(Multi(
                fingerCount: min(active.count, 4),
                startCentroid: Self.centroid(of: active),
                centroid: Self.centroid(of: active),
                fired: false
            ))
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

        case .twoFinger(var two):
            let centroid = Self.centroid(of: active)
            let spread = Self.spread(of: active)
            let dx = Double(centroid.x - two.centroid.x)
            let dy = Double(centroid.y - two.centroid.y)
            let dSpread = spread - two.spread
            two.centroid = centroid
            two.spread = spread
            two.maxTravel = max(two.maxTravel, Double(hypot(
                centroid.x - two.startCentroid.x,
                centroid.y - two.startCentroid.y
            )))

            var messages: [ClientMessage] = []
            if two.mode == .undecided {
                two.mode = Self.decide(
                    travel: two.maxTravel,
                    spreadChange: abs(spread - two.startSpread)
                )
                switch two.mode {
                case .undecided:
                    // Banked rather than dropped. `pendingScrollX` and its pair
                    // are the sub-pixel accumulator a scroll uses anyway, so
                    // movement made while the gesture was still deciding is
                    // simply flushed with the first real scroll below. Dropping
                    // it instead would lose up to `twoFingerDecision` points off
                    // the front of every scroll, which reads as the content
                    // lagging behind the fingers and never catching up.
                    pendingScrollX += dx
                    pendingScrollY += dy
                    gesture = .twoFinger(two)
                    return []

                case .zoom:
                    // The opposite choice, on purpose. A zoom is relative, so
                    // there is no drift to correct, and flushing the spread
                    // change that accumulated while deciding would jump three
                    // zoom levels the instant the pinch was recognised.
                    pendingScrollX = 0
                    pendingScrollY = 0
                    zoomHoldsCommand = true
                    messages.append(.modifierState(modifiers: baseModifiers.union(.command)))

                case .scroll:
                    break
                }
            }

            switch two.mode {
            case .undecided:
                gesture = .twoFinger(two)
                return messages

            case .scroll:
                two.velocityX = Self.smoothed(two.velocityX, dx, over: timestamp - two.lastMovedAt)
                two.velocityY = Self.smoothed(two.velocityY, dy, over: timestamp - two.lastMovedAt)
                // Only when the fingers really moved. A finger resting still
                // produces a stream of `.moved` events with nothing in them,
                // and treating those as movement makes "held still, then
                // lifted" look identical to "lifted while moving", which is the
                // difference between stopping and coasting.
                if dx != 0 || dy != 0 {
                    two.lastMovedAt = timestamp
                }
                gesture = .twoFinger(two)
                return messages + scrollMessages(dx: dx, dy: dy)

            case .zoom:
                two.lastMovedAt = timestamp
                gesture = .twoFinger(two)
                // Fingers spreading apart zoom in. Positive `dy` is a scroll
                // up, and Command plus scroll up is zoom in on the Mac, so the
                // sign carries straight across. Scaled down because Command
                // scroll steps a zoom level far faster than a scroll moves a
                // page, and one to one makes a small pinch jump three levels.
                return messages + scrollMessages(dx: 0, dy: dSpread * 0.25)
            }

        case .multi(var multi):
            guard multi.fired == false else { return [] }
            let centroid = Self.centroid(of: active)
            multi.centroid = centroid

            let dx = Double(centroid.x - multi.startCentroid.x)
            let dy = Double(centroid.y - multi.startCentroid.y)
            guard max(abs(dx), abs(dy)) >= Self.swipeThreshold else {
                gesture = .multi(multi)
                return []
            }

            multi.fired = true
            gesture = .multi(multi)
            return Self.swipe(fingers: multi.fingerCount, dx: dx, dy: dy)
        }
    }

    /// Which of the two things a two finger gesture is, once it has moved far
    /// enough to tell.
    ///
    /// Whichever measure crossed further wins, rather than testing them in
    /// order. A pinch always moves its centroid a little, and a scroll always
    /// changes its spread a little, so a first-past-the-post test on either one
    /// alone picks the wrong answer roughly half the time.
    private static func decide(travel: Double, spreadChange: Double) -> TwoFingerMode {
        guard max(travel, spreadChange) >= twoFingerDecision else { return .undecided }
        return spreadChange > travel ? .zoom : .scroll
    }

    /// One swipe, as the keystroke the Mac already answers to.
    ///
    /// macOS has no public way to synthesize a real swipe event, so each one is
    /// sent as the keyboard shortcut for the same thing. That is why these are
    /// keystrokes and not gestures on the wire.
    ///
    /// The mapping is macOS's own, including a configuration it ships but does
    /// not switch on by default: three fingers for page navigation, four for
    /// spaces. Keeping them apart is what lets both exist. Overloading one
    /// count with both would mean guessing, in the app the user is looking at,
    /// whether a sideways swipe meant "go back" or "next desktop".
    ///
    /// Directions follow the content, matching natural scrolling and the two
    /// finger scroll above. Fingers moving left pull the next space in from the
    /// right, so that is Control and right arrow. Fingers moving right pull the
    /// previous page back in from the left, so that is Command and left
    /// bracket.
    private static func swipe(fingers: Int, dx: Double, dy: Double) -> [ClientMessage] {
        let isHorizontal = abs(dx) > abs(dy)

        if isHorizontal == false {
            // Up is Mission Control, down is App Exposé, for three fingers and
            // four alike. macOS treats them the same way here, and so does
            // everyone's muscle memory.
            return stroke(dy < 0 ? .arrowUp : .arrowDown, .control)
        }

        if fingers == 3 {
            return stroke(dx > 0 ? .leftBracket : .rightBracket, .command)
        }
        return stroke(dx < 0 ? .arrowRight : .arrowLeft, .control)
    }

    /// A whole keystroke: down, then up, both carrying the same modifiers.
    ///
    /// The modifiers ride on the key messages rather than being held with
    /// `modifierState`, so a connection dying between the down and the up
    /// cannot leave Control held on the Mac.
    private static func stroke(_ key: PadlinkKey, _ modifiers: KeyModifiers) -> [ClientMessage] {
        [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }

    /// Blends a new sample into a running points-per-second velocity.
    ///
    /// Smoothed rather than taken from the last frame alone, because the last
    /// frame before a lift is often a short one with a tiny delta, and reading
    /// momentum from it makes a firm flick stop dead.
    private static func smoothed(_ current: Double, _ delta: Double, over dt: TimeInterval) -> Double {
        // A tenth of a second with no movement is a finger that has stopped, so
        // the answer is zero rather than "keep what we had". Keeping it is how
        // a scroll that was paused before lifting coasts away on a speed it
        // reached a second earlier.
        guard dt < 0.1 else { return 0 }
        // Too short to divide by: the quotient is dominated by timer noise.
        guard dt > 0.0005 else { return current }
        let sample = delta / dt
        return current * 0.7 + sample * 0.3
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

    /// How far apart the fingers are: the mean distance from the centroid.
    ///
    /// Not the distance between two named fingers, even though a pinch is
    /// almost always two. The mean has no ordering to get wrong, so it cannot
    /// change sign when UIKit reports the same two touches in the other order,
    /// which it is free to do because `active` comes from a `Set`.
    private static func spread(of samples: [TouchSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        let middle = centroid(of: samples)
        let total = samples.reduce(Double(0)) {
            $0 + Double(hypot($1.location.x - middle.x, $1.location.y - middle.y))
        }
        return total / Double(samples.count)
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
