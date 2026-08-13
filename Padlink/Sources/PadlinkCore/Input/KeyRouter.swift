// Padlink/Sources/PadlinkCore/Input/KeyRouter.swift
import Foundation

/// Decides how a keystroke should reach the Mac.
///
/// Rule: plain text, or text with only shift, takes the layout-independent
/// unicode path. Anything with control, option, command, or function must take
/// the virtual key code path, because shortcuts are positional. `Cmd+C` only
/// copies when the Mac sees the C key code, not the letter "c".
public enum KeyRouter {
    private static let characterMap: [Character: PadlinkKey] = {
        var map: [Character: PadlinkKey] = [:]

        let letters: [(Character, PadlinkKey)] = [
            ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e), ("f", .f),
            ("g", .g), ("h", .h), ("i", .i), ("j", .j), ("k", .k), ("l", .l),
            ("m", .m), ("n", .n), ("o", .o), ("p", .p), ("q", .q), ("r", .r),
            ("s", .s), ("t", .t), ("u", .u), ("v", .v), ("w", .w), ("x", .x),
            ("y", .y), ("z", .z)
        ]
        for (character, key) in letters {
            map[character] = key
            // Uppercase maps to the same physical key.
            for upper in String(character).uppercased() {
                map[upper] = key
            }
        }

        let digits: [(Character, PadlinkKey)] = [
            ("0", .digit0), ("1", .digit1), ("2", .digit2), ("3", .digit3),
            ("4", .digit4), ("5", .digit5), ("6", .digit6), ("7", .digit7),
            ("8", .digit8), ("9", .digit9)
        ]
        for (character, key) in digits { map[character] = key }

        let punctuation: [(Character, PadlinkKey)] = [
            ("-", .minus), ("=", .equal), ("[", .leftBracket), ("]", .rightBracket),
            ("\\", .backslash), (";", .semicolon), ("'", .quote), ("`", .grave),
            (",", .comma), (".", .period), ("/", .slash), (" ", .space)
        ]
        for (character, key) in punctuation { map[character] = key }

        return map
    }()

    /// The physical key a character sits on, for a US ANSI layout. Nil when
    /// the character has no fixed physical position, such as an emoji or an
    /// accented letter.
    public static func padlinkKey(forCharacter character: Character) -> PadlinkKey? {
        characterMap[character]
    }

    /// Builds the messages the iPad should send for a typed character.
    ///
    /// The text path is one message. The key code path is two, a down and a
    /// matching up, because a down with no up leaves the key held on the Mac.
    public static func messages(
        forCharacter character: Character,
        modifiers: KeyModifiers
    ) -> [ClientMessage] {
        if modifiers.isTextSafe {
            return [.keyText(String(character))]
        }
        guard let key = padlinkKey(forCharacter: character) else {
            // No physical position for this character, so the modifier cannot
            // be applied. Sending the text at least delivers the character.
            return [.keyText(String(character))]
        }
        return [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }
}
