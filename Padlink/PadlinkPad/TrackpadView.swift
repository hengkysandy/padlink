// Padlink/PadlinkPad/TrackpadView.swift
import PadlinkCore
import SwiftUI
import UIKit

/// Holds the one `TouchInterpreter` for the life of the view, and posts what it
/// returns.
///
/// It decides nothing. It exists because SwiftUI rebuilds `TrackpadView` on
/// every state change, and the interpreter's state (which finger is which, how
/// far it has travelled, whether the button is held, the sub-pixel remainder)
/// has to outlive that.
@MainActor
final class TrackpadCoordinator {
    /// Where messages go. A closure rather than `PadService` so this can be
    /// tested without a socket, and reassigned when SwiftUI rebuilds the view.
    var send: (ClientMessage) -> Void

    private let interpreter = TouchInterpreter()

    /// Drives momentum scrolling after the fingers have left the glass.
    ///
    /// A display link rather than a `Timer`, so each step lands once per frame
    /// and carries the frame's own timestamp. The interpreter holds no clock at
    /// all: it is handed a time and asked what to send, which is what makes
    /// coasting testable without waiting for one.
    ///
    /// A running link retains its target, so while momentum is spending itself
    /// this coordinator keeps itself alive. That is a cycle, and it is left
    /// alone deliberately: momentum always decays to a stop, `syncDisplayLink`
    /// invalidates the link the moment it does, and the cycle breaks on its own
    /// within about two seconds. A weak proxy object to avoid it would be more
    /// code than the problem.
    private var displayLink: CADisplayLink?

    /// Modifiers the on screen keyboard is holding on the Mac.
    ///
    /// Passed through to the interpreter, which needs it before a pinch can
    /// release Command without also releasing the keyboard's locks.
    var lockedModifiers: KeyModifiers = [] {
        didSet { interpreter.baseModifiers = lockedModifiers }
    }

    /// `nonisolated(unsafe)` only so `deinit`, which is not isolated, can read
    /// it to unregister. It is written once in `init` and read once in
    /// `deinit`, both on the main thread, and never touched in between.
    private nonisolated(unsafe) var resignObserver: (any NSObjectProtocol)?

    init(send: @escaping (ClientMessage) -> Void) {
        self.send = send

        // Trap: the app going to the background with a finger down. UIKit
        // usually cancels the touch, but not always, and if it does not, a held
        // mouse button stays held on the Mac with the user looking at a
        // different app entirely. `releaseAll` sends nothing when nothing is
        // held, so the two paths overlapping costs nothing.
        //
        // `queue: nil` means the block runs on whichever thread posted, and
        // UIKit posts lifecycle notifications on the main thread, which is what
        // `assumeIsolated` asserts. A synchronous release is also what makes it
        // testable without waiting on a run loop.
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseHeldInput()
            }
        }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    /// Reports how many fingers are on the surface, for the readout the user
    /// sees. Called on every touch event, including the ones that produce no
    /// message at all.
    var onFingerCountChanged: (Int) -> Void = { _ in }

    func deliver(_ event: TouchEvent) {
        for message in interpreter.handle(event) {
            send(message)
        }
        // After `handle`, not before, so the count and whatever the gesture did
        // are reported from the same event.
        onFingerCountChanged(event.active.count)
        syncDisplayLink()
    }

    func releaseHeldInput() {
        for message in interpreter.releaseAll() {
            send(message)
        }
        syncDisplayLink()
    }

    /// Runs the display link exactly while there is momentum to spend.
    ///
    /// Called after everything that can start or stop a coast, so there is one
    /// rule rather than a start call and a stop call to keep in step. A display
    /// link left running wakes the app sixty times a second forever, which on
    /// an iPad is a battery complaint with no visible cause.
    private func syncDisplayLink() {
        if interpreter.hasMomentum {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        // The frame's own timestamp, never `Date()`, for the same reason touch
        // events use theirs: it is when the frame is, not when this method got
        // around to running.
        for message in interpreter.stepMomentum(at: link.timestamp) {
            send(message)
        }
        syncDisplayLink()
    }
}

/// The surface the user actually touches.
///
/// Raw `touches…` callbacks rather than gesture recognizers: recognizers add
/// latency while they decide what a gesture is, and they hide the per-event
/// timing that `dtMicros` needs.
final class TrackpadSurface: UIView {
    var onTouches: ((TouchEvent) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Off by default on `UIView`, and without it the view only ever sees
        // one finger. Two finger scrolling would simply never happen, with
        // nothing in the code to suggest why.
        isMultipleTouchEnabled = true
        backgroundColor = .secondarySystemBackground
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(.began, touches, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(.moved, touches, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(.ended, touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(.cancelled, touches, event)
    }

    private func report(_ phase: TouchPhase, _ touches: Set<UITouch>, _ event: UIEvent?) {
        // `allTouches` is the whole hand, not just the fingers that changed,
        // which is what the interpreter needs to tell one finger from two.
        //
        // Two filters, both load bearing. It still lists touches that just
        // ended or were cancelled, and `TouchEvent.active` means still on the
        // glass. And it lists every touch in the event, including ones
        // delivered to other views in the same window, so a finger resting on
        // the status bar or on a button next to the trackpad would otherwise
        // count as a second finger and turn a drag into a scroll.
        let all = event?.allTouches ?? touches
        let active = all
            .filter { $0.view === self }
            .filter { $0.phase != .ended && $0.phase != .cancelled }
            .map {
                TouchSample(
                    id: TouchID(Int(bitPattern: ObjectIdentifier($0))),
                    location: $0.location(in: self)
                )
            }

        // The event's own timestamp, never `Date()`. It is when the touch
        // happened rather than when this handler got around to running, and the
        // difference becomes `dtMicros`, which drives the Mac's acceleration.
        let timestamp = event?.timestamp ?? touches.first?.timestamp ?? 0

        onTouches?(TouchEvent(phase: phase, active: active, timestamp: timestamp))
    }
}

/// The trackpad, for SwiftUI.
struct TrackpadView: UIViewRepresentable {
    /// Normally `padService.send`.
    var send: (ClientMessage) -> Void

    /// What the on-screen keyboard currently has locked on the Mac. A pinch
    /// holds Command with `modifierState`, which is absolute, so it has to know
    /// what else was held before it can let go of Command alone.
    var lockedModifiers: KeyModifiers = []

    /// How many fingers are on the surface right now.
    var onFingerCountChanged: (Int) -> Void = { _ in }

    func makeCoordinator() -> TrackpadCoordinator {
        TrackpadCoordinator(send: send)
    }

    func makeUIView(context: Context) -> TrackpadSurface {
        let surface = TrackpadSurface(frame: .zero)
        let coordinator = context.coordinator
        surface.onTouches = { event in
            coordinator.deliver(event)
        }
        return surface
    }

    func updateUIView(_ surface: TrackpadSurface, context: Context) {
        // SwiftUI rebuilds the struct on every state change, so the closure
        // captured at `makeCoordinator` time goes stale. The coordinator, and
        // with it the interpreter's state, survives.
        context.coordinator.send = send
        context.coordinator.lockedModifiers = lockedModifiers
        context.coordinator.onFingerCountChanged = onFingerCountChanged
    }
}
