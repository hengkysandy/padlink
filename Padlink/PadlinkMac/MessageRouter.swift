// Padlink/PadlinkMac/MessageRouter.swift
import CoreGraphics
import Foundation
import PadlinkCore

/// Turns decoded messages into synthesizer calls.
///
/// Every decision lives here rather than in `MacInputSynthesizer`, so it can
/// be tested with a recording fake and no real cursor movement.
final class MessageRouter {
    private let synthesizer: any InputSynthesizing
    private var geometry: ScreenGeometry
    private let acceleration: PointerAcceleration
    private let now: () -> Date

    private(set) var held = HeldInputState()

    /// Double-click bookkeeping. macOS only recognises a double click when the
    /// event carries a click state above 1.
    private var lastClickTime: Date?
    private var lastClickButton: PointerButton?
    private var clickCount = 1
    private static let doubleClickInterval: TimeInterval = 0.5

    init(
        synthesizer: any InputSynthesizing,
        geometry: ScreenGeometry,
        acceleration: PointerAcceleration = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.synthesizer = synthesizer
        self.geometry = geometry
        self.acceleration = acceleration
        self.now = now
    }

    /// Called when displays are added, removed, or rearranged.
    func updateGeometry(_ geometry: ScreenGeometry) {
        self.geometry = geometry
    }

    func handle(_ message: ClientMessage) {
        switch message {
        case let .pointerMove(dx, dy, dtMicros):
            handlePointerMove(dx: dx, dy: dy, dtMicros: dtMicros)

        case let .pointerButton(button, isDown):
            handleButton(button, isDown: isDown)

        case let .scroll(dx, dy):
            // Carrying the held modifiers, because a zoom is Command plus a
            // scroll and macOS reads that Command off the scroll event itself.
            synthesizer.scroll(
                deltaX: Int32(dx),
                deltaY: Int32(dy),
                modifiers: held.heldModifiers
            )

        case let .keyText(text):
            synthesizer.insertText(text)

        case let .keyCode(key, isDown, modifiers):
            // Recorded for the same reason a button is. The down and the up
            // are two separate frames, so a connection that dies between them
            // leaves this key down at the HID level with nothing to let it go.
            held.recordKey(key, isDown: isDown)
            synthesizer.postKey(
                virtualCode: MacVirtualKeys.code(for: key),
                isDown: isDown,
                modifiers: modifiers
            )

        case let .modifierState(modifiers):
            handleModifierState(modifiers)

        case .hello, .ping:
            // Owned by PadlinkService, not by input synthesis.
            break
        }
    }

    /// Releases every held button, key, and modifier. Runs when the connection
    /// ends and when the app quits, so a drop mid-drag or mid-keystroke cannot
    /// leave anything stuck down.
    ///
    /// A key release carries no modifier flags. It is posted only as part of
    /// this cleanup, and every modifier is released in the same drain a moment
    /// later, so "nothing is held" is the truth being made true. Carrying the
    /// flags from the original key down would mean storing per-key modifier
    /// state for an event whose flags change nothing.
    func releaseEverything() {
        let point = synthesizer.currentCursorLocation
        for action in held.drainReleases() {
            switch action {
            case let .button(button):
                synthesizer.setButton(button, isDown: false, at: point, clickCount: 1)
            case let .key(key):
                synthesizer.postKey(
                    virtualCode: MacVirtualKeys.code(for: key),
                    isDown: false,
                    modifiers: []
                )
            case let .modifier(modifier):
                synthesizer.postModifierKey(modifier, isDown: false)
            }
        }
    }

    private func handlePointerMove(dx: Int16, dy: Int16, dtMicros: UInt16) {
        let accelerated = acceleration.accelerate(
            dx: Double(dx),
            dy: Double(dy),
            dtSeconds: Double(dtMicros) / 1_000_000
        )

        let current = synthesizer.currentCursorLocation
        let target = geometry.clamp(CGPoint(
            x: current.x + accelerated.dx,
            y: current.y + accelerated.dy
        ))

        // Deterministic order, so a left and right button held at once always
        // drags with the same one.
        let dragging = held.heldButtons.contains(.left)
            ? PointerButton.left
            : (held.heldButtons.contains(.right) ? .right : nil)

        synthesizer.moveCursor(to: target, draggingButton: dragging)
    }

    private func handleButton(_ button: PointerButton, isDown: Bool) {
        if isDown {
            let clickTime = now()
            if let last = lastClickTime,
               lastClickButton == button,
               clickTime.timeIntervalSince(last) < Self.doubleClickInterval {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = clickTime
            lastClickButton = button
        }

        held.recordButton(button, isDown: isDown)
        synthesizer.setButton(
            button,
            isDown: isDown,
            at: synthesizer.currentCursorLocation,
            clickCount: clickCount
        )
    }

    private func handleModifierState(_ modifiers: KeyModifiers) {
        let previous = held.heldModifiers
        let all: [KeyModifiers] = [.shift, .control, .option, .command, .function]

        for modifier in all {
            let wasHeld = previous.contains(modifier)
            let isHeld = modifiers.contains(modifier)
            guard wasHeld != isHeld else { continue }
            synthesizer.postModifierKey(modifier, isDown: isHeld)
        }

        held.recordModifiers(modifiers)
    }
}
