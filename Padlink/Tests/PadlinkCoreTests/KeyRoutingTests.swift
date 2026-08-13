// Padlink/Tests/PadlinkCoreTests/KeyRoutingTests.swift
import Foundation
import Testing
@testable import PadlinkCore

@Test func plainTextGoesThroughTheUnicodePath() {
    #expect(KeyRouter.messages(forCharacter: "a", modifiers: []) == [.keyText("a")])
}

@Test func shiftedTextStillGoesThroughTheUnicodePath() {
    // Shift is already baked into the character the iPad keyboard produced.
    #expect(KeyRouter.messages(forCharacter: "A", modifiers: [.shift]) == [.keyText("A")])
}

@Test func commandShortcutSendsKeyDownThenKeyUp() {
    // Both are required. A down with no up leaves the key held on the Mac.
    #expect(
        KeyRouter.messages(forCharacter: "c", modifiers: [.command]) == [
            .keyCode(key: .c, isDown: true, modifiers: [.command]),
            .keyCode(key: .c, isDown: false, modifiers: [.command])
        ]
    )
}

@Test func uppercaseShortcutCharacterMapsToTheSameKey() {
    #expect(
        KeyRouter.messages(forCharacter: "C", modifiers: [.command, .shift]) == [
            .keyCode(key: .c, isDown: true, modifiers: [.command, .shift]),
            .keyCode(key: .c, isDown: false, modifiers: [.command, .shift])
        ]
    )
}

@Test func unmappableCharacterWithAModifierFallsBackToText() {
    // There is no Padlink key for "é", so the modifier cannot be applied.
    // Falling back to text is the honest outcome: the user gets the character.
    #expect(KeyRouter.messages(forCharacter: "é", modifiers: [.command]) == [.keyText("é")])
}

@Test(arguments: [
    (Character("a"), PadlinkKey.a),
    (Character("z"), PadlinkKey.z),
    (Character("Q"), PadlinkKey.q),
    (Character("0"), PadlinkKey.digit0),
    (Character("9"), PadlinkKey.digit9),
    (Character("-"), PadlinkKey.minus),
    (Character("="), PadlinkKey.equal),
    (Character("["), PadlinkKey.leftBracket),
    (Character("]"), PadlinkKey.rightBracket),
    (Character("\\"), PadlinkKey.backslash),
    (Character(";"), PadlinkKey.semicolon),
    (Character("'"), PadlinkKey.quote),
    (Character("`"), PadlinkKey.grave),
    (Character(","), PadlinkKey.comma),
    (Character("."), PadlinkKey.period),
    (Character("/"), PadlinkKey.slash),
    (Character(" "), PadlinkKey.space)
])
func charactersMapToPadlinkKeys(pair: (character: Character, key: PadlinkKey)) {
    #expect(KeyRouter.padlinkKey(forCharacter: pair.character) == pair.key)
}

@Test(arguments: [
    (Character("!"), PadlinkKey.digit1),
    (Character("@"), PadlinkKey.digit2),
    (Character("#"), PadlinkKey.digit3),
    (Character("$"), PadlinkKey.digit4),
    (Character("%"), PadlinkKey.digit5),
    (Character("^"), PadlinkKey.digit6),
    (Character("&"), PadlinkKey.digit7),
    (Character("*"), PadlinkKey.digit8),
    (Character("("), PadlinkKey.digit9),
    (Character(")"), PadlinkKey.digit0),
    (Character("_"), PadlinkKey.minus),
    (Character("+"), PadlinkKey.equal),
    (Character("{"), PadlinkKey.leftBracket),
    (Character("}"), PadlinkKey.rightBracket),
    (Character("|"), PadlinkKey.backslash),
    (Character(":"), PadlinkKey.semicolon),
    (Character("\""), PadlinkKey.quote),
    (Character("~"), PadlinkKey.grave),
    (Character("<"), PadlinkKey.comma),
    (Character(">"), PadlinkKey.period),
    (Character("?"), PadlinkKey.slash)
])
func shiftedSymbolsMapToTheirBasePhysicalKey(pair: (character: Character, key: PadlinkKey)) {
    // A shifted symbol sits on the same physical key as its base character,
    // exactly like an uppercase letter sits on the same key as its lowercase
    // form. Without this, Cmd+Shift+3 (screenshot) would have no key to land
    // on and would silently fall back to typing the literal "#".
    #expect(KeyRouter.padlinkKey(forCharacter: pair.character) == pair.key)
}

@Test func shiftedDigitShortcutSendsKeyDownThenKeyUpForTheDigitKey() {
    // Regression test for the macOS screenshot family (Cmd+Shift+3/4/5).
    // "#" is what the iPad keyboard produces for Shift+3, but the shortcut
    // must land on the physical digit-3 key, not fall back to typing "#".
    #expect(
        KeyRouter.messages(forCharacter: "#", modifiers: [.command, .shift]) == [
            .keyCode(key: .digit3, isDown: true, modifiers: [.command, .shift]),
            .keyCode(key: .digit3, isDown: false, modifiers: [.command, .shift])
        ]
    )
}

@Test func controlAloneTakesTheKeyCodePath() {
    #expect(
        KeyRouter.messages(forCharacter: "a", modifiers: [.control]) == [
            .keyCode(key: .a, isDown: true, modifiers: [.control]),
            .keyCode(key: .a, isDown: false, modifiers: [.control])
        ]
    )
}

@Test func optionAloneTakesTheKeyCodePath() {
    #expect(
        KeyRouter.messages(forCharacter: "a", modifiers: [.option]) == [
            .keyCode(key: .a, isDown: true, modifiers: [.option]),
            .keyCode(key: .a, isDown: false, modifiers: [.option])
        ]
    )
}

@Test func functionAloneTakesTheKeyCodePath() {
    #expect(
        KeyRouter.messages(forCharacter: "a", modifiers: [.function]) == [
            .keyCode(key: .a, isDown: true, modifiers: [.function]),
            .keyCode(key: .a, isDown: false, modifiers: [.function])
        ]
    )
}

@Test func unmappedCharacterReturnsNil() {
    #expect(KeyRouter.padlinkKey(forCharacter: "🌍") == nil)
}

@Test func everyPadlinkKeyHasAMacVirtualKeyCode() {
    // Completeness check. Adding a PadlinkKey without a mapping fails here
    // rather than silently typing the wrong thing on the Mac.
    for key in PadlinkKey.allCases {
        let code = MacVirtualKeys.code(for: key)
        #expect(code != MacVirtualKeys.unmapped, "no virtual key code for \(key)")
    }
}

@Test func virtualKeyCodesAreUniqueAcrossAllPadlinkKeys() {
    // A hand-written 60-entry table is exactly the kind of place a
    // copy-pasted code sneaks in. A duplicate here means two different
    // PadlinkKeys resolve to the same macOS key, so a shortcut aimed at one
    // of them can fire the other instead. "Cmd+C" doing something else
    // entirely is the realistic failure mode this guards against.
    var seen: [UInt16: PadlinkKey] = [:]
    for key in PadlinkKey.allCases {
        let code = MacVirtualKeys.code(for: key)
        if let existing = seen[code] {
            Issue.record("\(key) and \(existing) both map to virtual key code \(code)")
        }
        seen[code] = key
    }
}

@Test(arguments: [
    (PadlinkKey.a, UInt16(0x00)),
    (PadlinkKey.c, UInt16(0x08)),
    (PadlinkKey.v, UInt16(0x09)),
    (PadlinkKey.q, UInt16(0x0C)),
    (PadlinkKey.digit1, UInt16(0x12)),
    (PadlinkKey.digit0, UInt16(0x1D)),
    (PadlinkKey.enter, UInt16(0x24)),
    (PadlinkKey.tab, UInt16(0x30)),
    (PadlinkKey.space, UInt16(0x31)),
    (PadlinkKey.delete, UInt16(0x33)),
    (PadlinkKey.escape, UInt16(0x35)),
    (PadlinkKey.arrowLeft, UInt16(0x7B)),
    (PadlinkKey.arrowRight, UInt16(0x7C)),
    (PadlinkKey.arrowDown, UInt16(0x7D)),
    (PadlinkKey.arrowUp, UInt16(0x7E)),
    (PadlinkKey.f1, UInt16(0x7A)),
    (PadlinkKey.f12, UInt16(0x6F))
])
func knownVirtualKeyCodesAreCorrect(pair: (key: PadlinkKey, code: UInt16)) {
    // These come from Apple's HIToolbox Events.h. Getting one wrong means
    // Cmd+C pastes, or worse.
    #expect(MacVirtualKeys.code(for: pair.key) == pair.code)
}
