// Padlink/PadlinkPad/KeystrokeTranslator.swift
import Foundation
import PadlinkCore

/// The three things a keyboard does to a text field.
///
/// Not a text value, and not a before-and-after pair. Comparing the field's old
/// string to its new one is the obvious way to do this and it does not work:
/// a deletion is not a `Character`, so a diff has nothing to hand
/// `KeyRouter.messages(forCharacter:modifiers:)`, and there is no way to tell
/// "the user pressed backspace" from "the user selected a word and retyped it".
/// `UIKeyInput` hands over these three events directly, so nothing has to be
/// reconstructed.
enum Keystroke: Equatable {
    /// Text arriving in one go: one character from a tap, several from a
    /// paste or a hardware keyboard.
    case insert(String)
    case deleteBackward
    case returnKey
}

/// Turns keystrokes into Padlink messages.
///
/// Pure, with no UIKit in sight, because the alternative is testing typing
/// through a `UITextField`, and a `UITextField` cannot be typed into from a
/// test.
enum KeystrokeTranslator {
    static func messages(for keystroke: Keystroke) -> [ClientMessage] {
        switch keystroke {
        case let .insert(text):
            return text.flatMap(messages(forCharacter:))
        case .deleteBackward:
            return press(.delete)
        case .returnKey:
            return press(.enter)
        }
    }

    private static func messages(forCharacter character: Character) -> [ClientMessage] {
        // Return and tab are keys, not characters.
        //
        // The Mac types text by posting a unicode string on virtual key zero.
        // That inserts a newline into a text editor, which looks right, but it
        // does not submit a form, run a shell command, or open the highlighted
        // Spotlight result, which is what pressing return is for. Same for tab
        // and moving between fields. Both have real key codes, so both use
        // them.
        switch character {
        case "\n", "\r":
            return press(.enter)
        case "\t":
            return press(.tab)
        default:
            // No modifiers. Whatever shift did, iOS already did it: the
            // character handed over is the character the user meant, upper
            // case, symbol, accent, emoji and all. Re-deriving a shift flag
            // here would be a second chance to disagree with the keyboard.
            return KeyRouter.messages(forCharacter: character, modifiers: [])
        }
    }

    /// A key down always comes with its key up. A down with no up leaves the
    /// key held on the Mac, which is a character repeating until someone
    /// notices.
    private static func press(_ key: PadlinkKey) -> [ClientMessage] {
        [
            .keyCode(key: key, isDown: true, modifiers: []),
            .keyCode(key: key, isDown: false, modifiers: [])
        ]
    }
}
