// Padlink/PadlinkMac/MacInputSynthesizer.swift
import AppKit
import CoreGraphics
import PadlinkCore

/// Posts real input events. No decisions live here on purpose.
final class MacInputSynthesizer: InputSynthesizing {
    /// Virtual key codes for the modifier keys themselves. Posting a key event
    /// for one of these is what makes macOS emit the `flagsChanged` event that
    /// the application switcher and similar UI depend on.
    private static let modifierVirtualKeys: [(KeyModifiers, UInt16)] = [
        (.shift, 0x38),
        (.control, 0x3B),
        (.option, 0x3A),
        (.command, 0x37),
        (.function, 0x3F)
    ]

    var currentCursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveCursor(to point: CGPoint, draggingButton: PointerButton?) {
        // While a button is held, movement MUST be posted as a drag. Many apps
        // ignore plain moves during a drag, so text selection and window
        // dragging would silently not work.
        let type: CGEventType
        let button: CGMouseButton
        switch draggingButton {
        case .left:
            type = .leftMouseDragged
            button = .left
        case .right:
            type = .rightMouseDragged
            button = .right
        case nil:
            type = .mouseMoved
            button = .left
        }

        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:
            type = isDown ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case .right:
            type = isDown ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        }

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: cgButton
        )
        // Without this, macOS never recognises a double click.
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
    }

    func scroll(deltaX: Int32, deltaY: Int32, modifiers: KeyModifiers) {
        // Pixel units give smooth scrolling rather than notched jumps.
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        // Set on the scroll itself, and not left to whatever the modifier key
        // events posted a moment ago happened to leave in the global state.
        //
        // This is the Mac half of pinch to zoom. macOS decides that a scroll is
        // a zoom by reading the Command flag on the scroll event, so a Command
        // that is genuinely held down but absent from these flags produces an
        // ordinary scroll. A freshly created `CGEvent` inherits flags from the
        // combined session state, which does usually include a synthetic
        // modifier, but "usually" is not a contract and it silently stops being
        // true when a real key is held at the same time.
        event.flags = Self.cgFlags(from: modifiers)
        event.post(tap: .cghidEventTap)
    }

    func insertText(_ text: String) {
        // Virtual key 0 plus a unicode string types the character correctly
        // whatever keyboard layout the Mac is set to, and handles accents,
        // emoji, and non-Latin scripts with no mapping table.
        var utf16 = Array(text.utf16)
        guard utf16.isEmpty == false else { return }

        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
            else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(virtualCode),
            keyDown: isDown
        ) else { return }
        event.flags = Self.cgFlags(from: modifiers)
        event.post(tap: .cghidEventTap)
    }

    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool) {
        guard let entry = Self.modifierVirtualKeys.first(where: { $0.0 == modifier }) else { return }
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(entry.1),
            keyDown: isDown
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// The undocumented gesture event, which is the only way to produce a real
    /// pinch.
    ///
    /// **These are private constants and that is a deliberate, measured
    /// choice.** There is no public API for synthesizing a magnify event, and
    /// the supported alternative, Command held across a scroll, is what a mouse
    /// wheel user does rather than what a trackpad does. It was tested: it
    /// zooms Chrome, and does nothing at all in Preview, Photos, Maps or Xcode,
    /// which all want a real gesture. The gesture event was tested the same way
    /// and zoomed Preview immediately.
    ///
    /// The risk is that Apple changes these numbers in a future macOS and
    /// pinching quietly stops working. Everything else in the app keeps
    /// working, because this is confined to one method, and the fallback is to
    /// go back to Command and scroll.
    private enum Gesture {
        /// `NSEventTypeMagnify`.
        static let eventType = CGEventType(rawValue: 29)!
        /// Which gesture this is.
        static let typeField = CGEventField(rawValue: 110)!
        /// How much, as a fraction of the current size.
        static let valueField = CGEventField(rawValue: 113)!
        /// Began, changed or ended.
        static let phaseField = CGEventField(rawValue: 132)!
        /// `kIOHIDEventTypeZoom`.
        static let zoom: Int64 = 8
    }

    func pinch(phase: PinchPhase, magnification: Int16) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = Gesture.eventType
        event.setIntegerValueField(Gesture.typeField, value: Gesture.zoom)
        // Thousandths on the wire, a fraction here.
        event.setDoubleValueField(Gesture.valueField, value: Double(magnification) / 1000)
        event.setIntegerValueField(Gesture.phaseField, value: Self.phaseValue(phase))
        event.post(tap: .cghidEventTap)
    }

    /// The phase numbers macOS uses, which are a bitfield rather than a count:
    /// 1 began, 2 changed, 4 ended.
    private static func phaseValue(_ phase: PinchPhase) -> Int64 {
        switch phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        }
    }

    func perform(_ action: SystemAction) {
        switch action {
        case .missionControl:
            // Launching the app, rather than posting Control and Up.
            //
            // Mission Control's shortcut belongs to the Dock, and a shortcut
            // the Dock owns cannot be triggered by an event this app posts.
            // That was measured on real hardware: `CGEvent` for Command+A and
            // Command+C work, and Control+Up and Command+Shift+3 do nothing at
            // all. Opening the app is a different route to the same place, and
            // it is a supported one.
            //
            // `Mission Control.app` is a real bundle in `/System/Applications`,
            // so this needs no private API and no extra permission.
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    static func cgFlags(from modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
