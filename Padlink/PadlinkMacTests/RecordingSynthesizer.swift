// Padlink/PadlinkMacTests/RecordingSynthesizer.swift
import CoreGraphics
import PadlinkCore
@testable import PadlinkMac

/// Records what it was asked to do instead of touching the OS, so routing
/// decisions can be tested without moving the real cursor.
final class RecordingSynthesizer: InputSynthesizing {
    enum Call: Equatable {
        case move(to: CGPoint, dragging: PointerButton?)
        case button(PointerButton, isDown: Bool, at: CGPoint, clickCount: Int)
        case scroll(deltaX: Int32, deltaY: Int32)
        case insertText(String)
        case key(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers)
        case modifierKey(KeyModifiers, isDown: Bool)
    }

    private(set) var calls: [Call] = []
    var cursorLocation = CGPoint(x: 100, y: 100)

    var currentCursorLocation: CGPoint { cursorLocation }

    func moveCursor(to point: CGPoint, draggingButton: PointerButton?) {
        calls.append(.move(to: point, dragging: draggingButton))
        cursorLocation = point
    }

    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int) {
        calls.append(.button(button, isDown: isDown, at: point, clickCount: clickCount))
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        calls.append(.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    func insertText(_ text: String) {
        calls.append(.insertText(text))
    }

    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers) {
        calls.append(.key(virtualCode: virtualCode, isDown: isDown, modifiers: modifiers))
    }

    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool) {
        calls.append(.modifierKey(modifier, isDown: isDown))
    }
}
