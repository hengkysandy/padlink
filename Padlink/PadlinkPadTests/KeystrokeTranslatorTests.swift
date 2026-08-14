// Padlink/PadlinkPadTests/KeystrokeTranslatorTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// Typing, translated.
///
/// A software keyboard does exactly three things to a text field: it inserts a
/// string, it deletes backwards, and it presses return. Everything the user
/// types has to survive being turned into those three and back again, which is
/// what this file checks.
///
/// Nothing here diffs one string against another. A diff cannot represent a
/// deletion, because a deletion is not a `Character`, and `KeyRouter` has
/// nothing to give for one.
final class KeystrokeTranslatorTests: XCTestCase {

    private func deleteKey() -> [ClientMessage] {
        [
            .keyCode(key: .delete, isDown: true, modifiers: []),
            .keyCode(key: .delete, isDown: false, modifiers: [])
        ]
    }

    private func enterKey() -> [ClientMessage] {
        [
            .keyCode(key: .enter, isDown: true, modifiers: []),
            .keyCode(key: .enter, isDown: false, modifiers: [])
        ]
    }

    // MARK: - Inserting

    func testALetterBecomesOneTextMessage() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("a")), [.keyText("a")])
    }

    /// The case the user typed is the case the Mac gets. Shift is already
    /// baked into the character iOS hands over, so there is no modifier to
    /// send, and re-deriving one would be a second chance to get it wrong.
    func testACapitalLetterKeepsItsCase() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("A")), [.keyText("A")])
    }

    /// A paste, or a hardware keyboard delivering several characters at once.
    /// Order is the whole meaning of a word.
    func testAMultiCharacterInsertBecomesOneMessagePerCharacterInOrder() {
        XCTAssertEqual(
            KeystrokeTranslator.messages(for: .insert("hey")),
            [.keyText("h"), .keyText("e"), .keyText("y")]
        )
    }

    /// Nothing typed, nothing sent. iOS calls the insert path with an empty
    /// string in a few places, and an empty `keyText` on the Mac is a keystroke
    /// with no key in it.
    func testInsertingNothingSendsNothing() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("")), [])
    }

    /// One emoji is one `Character` in Swift even when it is several scalars,
    /// and `keyText` carries unicode straight through. Splitting a skin tone
    /// modifier off its emoji would send two broken halves.
    func testAnEmojiSurvivesAsASingleMessage() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("👍🏽")), [.keyText("👍🏽")])
    }

    /// An accented letter has no fixed physical key on a US layout, so the
    /// text path is the only one that can carry it. `KeyRouter` already knows
    /// this; the point of the test is that nothing here gets in its way.
    func testAnAccentedLetterGoesThroughAsText() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("é")), [.keyText("é")])
    }

    // MARK: - Keys that act rather than type

    /// Return is not the newline character.
    ///
    /// The Mac types text by posting a unicode string on virtual key zero. A
    /// unicode newline inserts a line break in a text editor, but it does not
    /// submit a form, run a shell command, or open a Spotlight result, which is
    /// what the return key is for. It has to be the real key.
    func testReturnSendsTheEnterKeyAndNotANewlineCharacter() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .returnKey), enterKey())
    }

    /// A pasted string containing a line break means the same thing.
    func testANewlineInsideAnInsertBecomesTheEnterKey() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .insert("\n")), enterKey())
    }

    func testATabInsideAnInsertBecomesTheTabKey() {
        XCTAssertEqual(
            KeystrokeTranslator.messages(for: .insert("\t")),
            [
                .keyCode(key: .tab, isDown: true, modifiers: []),
                .keyCode(key: .tab, isDown: false, modifiers: [])
            ]
        )
    }

    func testTextAroundANewlineIsKeptInOrder() {
        XCTAssertEqual(
            KeystrokeTranslator.messages(for: .insert("a\nb")),
            [.keyText("a")] + enterKey() + [.keyText("b")]
        )
    }

    // MARK: - Deleting

    /// The reason this type exists. Backspace is not a character, so no amount
    /// of comparing the field's old text to its new text can produce it.
    func testBackspaceSendsTheDeleteKeyDownAndUp() {
        XCTAssertEqual(KeystrokeTranslator.messages(for: .deleteBackward), deleteKey())
    }

    /// A key held down on the Mac is a key that repeats forever. Every key this
    /// translator sends down must come back up in the same batch.
    func testNoKeyIsEverLeftHeldDown() {
        let strokes: [Keystroke] = [
            .insert("a"), .insert("a\tb\nc"), .insert(""), .deleteBackward, .returnKey
        ]
        for stroke in strokes {
            var held = 0
            for message in KeystrokeTranslator.messages(for: stroke) {
                if case let .keyCode(_, isDown, _) = message {
                    held += isDown ? 1 : -1
                }
            }
            XCTAssertEqual(held, 0, "\(stroke) left a key down")
        }
    }
}
