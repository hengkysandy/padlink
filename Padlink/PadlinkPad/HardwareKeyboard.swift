// Padlink/PadlinkPad/HardwareKeyboard.swift
import PadlinkCore
import UIKit

/// A keyboard attached to the iPad, driving the Mac.
///
/// This is the fastest typing path the app has and the only one with no screen
/// in it: a physical key press becomes a wire message with no on-screen keyboard
/// and no text field in between.
///
/// # Why physical position, and not the character
///
/// `UIKey` offers both. `characters` is what the iPad's own keyboard layout says
/// the key produced; `keyCode` is which physical key was pressed. This sends the
/// physical key.
///
/// That is the difference between driving a Mac and typing into an iPad. The Mac
/// has its own keyboard layout, and a virtual key code is interpreted through
/// it. Sending the position means a Mac set to French produces French, a Mac set
/// to Dvorak produces Dvorak, and the letters printed on the iPad's keys stop
/// mattering. Sending the character instead would force the iPad's layout onto
/// the Mac, which is the wrong machine's opinion.
///
/// It also fixes key repeat for free. Holding a key gives one `pressesBegan` and
/// no repeats, so nothing here can repeat a character. But the down and the up
/// are sent as they happen, so the key is genuinely held on the Mac, and the
/// Mac's own repeat takes over. The right answer is the one where this type does
/// nothing at all.
///
/// # Why modifiers are held rather than attached
///
/// A modifier is sent as `modifierState`, which really holds it down on the Mac,
/// rather than only riding along as a flag on the next key. `Cmd` held across
/// three presses of `Tab` has to keep the app switcher open, and a flag on each
/// separate keystroke opens and closes it three times.
///
/// The cost is that a held modifier can be stranded if the app goes away
/// mid-shortcut. `releaseAll` is the answer, and it is called from the same
/// places that release a held mouse button.
struct HardwareKeyboardState {
    /// Modifiers the Mac is holding for us right now.
    private(set) var heldModifiers: KeyModifiers = []

    init() {}

    /// Turns one physical key event into the messages to send.
    ///
    /// - Parameters:
    ///   - usage: the physical key, from `UIKey.keyCode`.
    ///   - characters: `UIKey.characters`, used only as a fallback for keys with
    ///     no physical position in the protocol.
    ///   - isDown: whether this is a press or a release.
    mutating func handle(
        usage: UIKeyboardHIDUsage,
        characters: String,
        isDown: Bool
    ) -> [ClientMessage] {
        if let modifier = Self.modifier(for: usage) {
            // Computed from this event, not read from `UIKey.modifierFlags`.
            // The flags describe the moment the event was created, and whether
            // they still include a modifier that is in the middle of being
            // released is not something to depend on. Adding and removing the
            // one key that actually changed cannot be ambiguous.
            let updated = isDown
                ? heldModifiers.union(modifier)
                : heldModifiers.subtracting(modifier)
            guard updated != heldModifiers else { return [] }
            heldModifiers = updated
            return [.modifierState(modifiers: heldModifiers)]
        }

        if let key = Self.key(for: usage) {
            return [.keyCode(key: key, isDown: isDown, modifiers: heldModifiers)]
        }

        // No physical position in the protocol. Send the character the iPad
        // produced, on the press only, because text has no release. This covers
        // the keys the map does not name and anything a layout puts somewhere
        // Padlink has no code for.
        //
        // Skipped entirely when a modifier is held: `Cmd` plus a character the
        // Mac cannot place is not a shortcut anybody meant, and inserting the
        // text instead would type a stray letter into whatever is focused.
        guard isDown, characters.isEmpty == false, heldModifiers.isEmpty else { return [] }
        return [.keyText(characters)]
    }

    /// Gives every held modifier back.
    ///
    /// Called when the app leaves the foreground and when the connection ends,
    /// because a `Cmd` held on the Mac with the iPad no longer in front of the
    /// user turns their next keystroke into a shortcut.
    mutating func releaseAll() -> [ClientMessage] {
        guard heldModifiers.isEmpty == false else { return [] }
        heldModifiers = []
        return [.modifierState(modifiers: [])]
    }

    // MARK: - The map

    /// The modifier a key is, or nil if it is an ordinary key.
    ///
    /// Left and right map to the same flag. The protocol has one `shift`, and
    /// so does macOS as far as a shortcut is concerned.
    static func modifier(for usage: UIKeyboardHIDUsage) -> KeyModifiers? {
        switch usage {
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .option
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        default: return nil
        }
    }

    /// The physical key, or nil for one Padlink has no code for.
    static func key(for usage: UIKeyboardHIDUsage) -> PadlinkKey? {
        switch usage {
        case .keyboardA: return .a
        case .keyboardB: return .b
        case .keyboardC: return .c
        case .keyboardD: return .d
        case .keyboardE: return .e
        case .keyboardF: return .f
        case .keyboardG: return .g
        case .keyboardH: return .h
        case .keyboardI: return .i
        case .keyboardJ: return .j
        case .keyboardK: return .k
        case .keyboardL: return .l
        case .keyboardM: return .m
        case .keyboardN: return .n
        case .keyboardO: return .o
        case .keyboardP: return .p
        case .keyboardQ: return .q
        case .keyboardR: return .r
        case .keyboardS: return .s
        case .keyboardT: return .t
        case .keyboardU: return .u
        case .keyboardV: return .v
        case .keyboardW: return .w
        case .keyboardX: return .x
        case .keyboardY: return .y
        case .keyboardZ: return .z

        // HID numbers the digit row 1 to 9 and then 0, which is the order they
        // are printed on the key caps and not the order they count in.
        case .keyboard1: return .digit1
        case .keyboard2: return .digit2
        case .keyboard3: return .digit3
        case .keyboard4: return .digit4
        case .keyboard5: return .digit5
        case .keyboard6: return .digit6
        case .keyboard7: return .digit7
        case .keyboard8: return .digit8
        case .keyboard9: return .digit9
        case .keyboard0: return .digit0

        case .keyboardHyphen: return .minus
        case .keyboardEqualSign: return .equal
        case .keyboardOpenBracket: return .leftBracket
        case .keyboardCloseBracket: return .rightBracket
        case .keyboardBackslash: return .backslash
        case .keyboardSemicolon: return .semicolon
        case .keyboardQuote: return .quote
        case .keyboardGraveAccentAndTilde: return .grave
        case .keyboardComma: return .comma
        case .keyboardPeriod: return .period
        case .keyboardSlash: return .slash

        case .keyboardSpacebar: return .space
        case .keyboardReturnOrEnter, .keypadEnter: return .enter
        case .keyboardTab: return .tab
        case .keyboardEscape: return .escape
        case .keyboardDeleteOrBackspace: return .delete
        case .keyboardDeleteForward: return .forwardDelete

        case .keyboardLeftArrow: return .arrowLeft
        case .keyboardRightArrow: return .arrowRight
        case .keyboardUpArrow: return .arrowUp
        case .keyboardDownArrow: return .arrowDown

        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown

        case .keyboardF1: return .f1
        case .keyboardF2: return .f2
        case .keyboardF3: return .f3
        case .keyboardF4: return .f4
        case .keyboardF5: return .f5
        case .keyboardF6: return .f6
        case .keyboardF7: return .f7
        case .keyboardF8: return .f8
        case .keyboardF9: return .f9
        case .keyboardF10: return .f10
        case .keyboardF11: return .f11
        case .keyboardF12: return .f12

        default: return nil
        }
    }
}
