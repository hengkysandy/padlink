// Padlink/PadlinkPadTests/HardwareKeyboardTests.swift
import XCTest
import UIKit
import PadlinkCore
@testable import PadlinkPad

/// A keyboard attached to the iPad, driving the Mac.
///
/// The dangerous half is the modifiers. Everything else types a wrong letter at
/// worst; a stranded `Cmd` makes the whole Mac behave strangely with nothing on
/// the iPad to explain it.
final class HardwareKeyboardTests: XCTestCase {

    private func down(
        _ state: inout HardwareKeyboardState,
        _ usage: UIKeyboardHIDUsage,
        _ characters: String = ""
    ) -> [ClientMessage] {
        state.handle(usage: usage, characters: characters, isDown: true)
    }

    private func up(
        _ state: inout HardwareKeyboardState,
        _ usage: UIKeyboardHIDUsage,
        _ characters: String = ""
    ) -> [ClientMessage] {
        state.handle(usage: usage, characters: characters, isDown: false)
    }

    // MARK: - Ordinary keys

    /// The whole feature in one test: press a key, the Mac gets that key.
    func testAKeyPressSendsTheKeyDownAndTheReleaseSendsTheUp() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboardA, "a"), [
            .keyCode(key: .a, isDown: true, modifiers: [])
        ])
        XCTAssertEqual(up(&state, .keyboardA, "a"), [
            .keyCode(key: .a, isDown: false, modifiers: [])
        ])
    }

    /// The down and the up are sent as they happen and nothing is synthesized
    /// in between, so the key is genuinely held on the Mac and the Mac's own
    /// key repeat takes over. UIKit delivers no repeats of its own, so this is
    /// the only thing that makes holding a key work at all.
    func testHoldingAKeyLeavesItDownOnTheMac() {
        var state = HardwareKeyboardState()
        let messages = down(&state, .keyboardE, "e")
        XCTAssertEqual(messages, [.keyCode(key: .e, isDown: true, modifiers: [])])
        // No release until the physical release arrives.
        XCTAssertEqual(messages.count, 1)
    }

    /// The character the iPad produced is deliberately ignored for a key that
    /// has a physical position. The Mac applies its own keyboard layout to the
    /// key code, which is the point: a Mac set to Dvorak should produce Dvorak,
    /// whatever is printed on the iPad's keys.
    func testTheCharacterIsIgnoredWhenTheKeyHasAPosition() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboardQ, "'"), [
            .keyCode(key: .q, isDown: true, modifiers: [])
        ])
    }

    /// HID numbers the digit row 1 to 9 and then 0, the order printed on the
    /// keys rather than the order they count in. Getting this wrong shifts
    /// every digit by one and is invisible in a quick test of "does typing
    /// work".
    func testTheDigitRowMapsInKeyCapOrderAndNotCountingOrder() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboard1, "1"), [
            .keyCode(key: .digit1, isDown: true, modifiers: [])
        ])
        XCTAssertEqual(down(&state, .keyboard0, "0"), [
            .keyCode(key: .digit0, isDown: true, modifiers: [])
        ])
        XCTAssertEqual(down(&state, .keyboard9, "9"), [
            .keyCode(key: .digit9, isDown: true, modifiers: [])
        ])
    }

    func testEveryLetterHasAPosition() {
        let letters: [UIKeyboardHIDUsage] = [
            .keyboardA, .keyboardB, .keyboardC, .keyboardD, .keyboardE, .keyboardF,
            .keyboardG, .keyboardH, .keyboardI, .keyboardJ, .keyboardK, .keyboardL,
            .keyboardM, .keyboardN, .keyboardO, .keyboardP, .keyboardQ, .keyboardR,
            .keyboardS, .keyboardT, .keyboardU, .keyboardV, .keyboardW, .keyboardX,
            .keyboardY, .keyboardZ
        ]
        for usage in letters {
            XCTAssertNotNil(HardwareKeyboardState.key(for: usage), "\(usage)")
        }
    }

    func testTheKeysThatMakeAKeyboardUsableAllMap() {
        let essential: [UIKeyboardHIDUsage] = [
            .keyboardSpacebar, .keyboardReturnOrEnter, .keyboardTab, .keyboardEscape,
            .keyboardDeleteOrBackspace, .keyboardDeleteForward,
            .keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow,
            .keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
            .keyboardHyphen, .keyboardEqualSign, .keyboardOpenBracket,
            .keyboardCloseBracket, .keyboardBackslash, .keyboardSemicolon,
            .keyboardQuote, .keyboardGraveAccentAndTilde, .keyboardComma,
            .keyboardPeriod, .keyboardSlash
        ]
        for usage in essential {
            XCTAssertNotNil(HardwareKeyboardState.key(for: usage), "\(usage)")
        }
    }

    // MARK: - Modifiers

    /// A modifier really is held down on the Mac, not attached as a flag to one
    /// keystroke. `Cmd` across three presses of `Tab` has to keep the app
    /// switcher open, and a flag on each separate keystroke opens and closes it
    /// three times.
    func testAModifierIsHeldOnTheMacRatherThanAttachedToOneKey() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboardLeftGUI), [
            .modifierState(modifiers: .command)
        ])
        XCTAssertEqual(down(&state, .keyboardTab), [
            .keyCode(key: .tab, isDown: true, modifiers: .command)
        ])
        XCTAssertEqual(up(&state, .keyboardTab), [
            .keyCode(key: .tab, isDown: false, modifiers: .command)
        ])
        // Still held, so the switcher is still open.
        XCTAssertEqual(state.heldModifiers, .command)
        XCTAssertEqual(up(&state, .keyboardLeftGUI), [
            .modifierState(modifiers: [])
        ])
    }

    func testLeftAndRightModifiersAreTheSameFlag() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftShift)
        XCTAssertEqual(state.heldModifiers, .shift)
        // Right shift down while left is held changes nothing, so it says
        // nothing. A second `modifierState` here would be noise on the wire.
        XCTAssertEqual(down(&state, .keyboardRightShift), [])
    }

    func testSeveralModifiersStack() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftGUI)
        _ = down(&state, .keyboardLeftShift)
        XCTAssertEqual(state.heldModifiers, [.command, .shift])
        XCTAssertEqual(down(&state, .keyboardS, "s"), [
            .keyCode(key: .s, isDown: true, modifiers: [.command, .shift])
        ])
    }

    /// `modifierState` is absolute, so releasing one modifier has to report
    /// what is still held rather than an empty set.
    func testReleasingOneModifierKeepsTheOthers() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftGUI)
        _ = down(&state, .keyboardLeftShift)
        XCTAssertEqual(up(&state, .keyboardLeftShift), [
            .modifierState(modifiers: .command)
        ])
    }

    /// The state is computed from the event, never read from
    /// `UIKey.modifierFlags`. The flags describe the moment the event was
    /// created, and whether they still contain a modifier that is in the middle
    /// of being released is not something worth depending on.
    func testReleasingAModifierThatWasNeverHeldSaysNothing() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(up(&state, .keyboardLeftControl), [])
        XCTAssertTrue(state.heldModifiers.isEmpty)
    }

    // MARK: - Giving modifiers back

    /// The worst failure this type can cause. A `Cmd` held on the Mac while the
    /// user is looking at another app turns their next keystroke into a
    /// shortcut, with nothing anywhere to say why.
    func testReleaseAllGivesEveryHeldModifierBack() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftGUI)
        _ = down(&state, .keyboardLeftAlt)
        XCTAssertEqual(state.releaseAll(), [.modifierState(modifiers: [])])
        XCTAssertTrue(state.heldModifiers.isEmpty)
    }

    /// Called from the same place that releases a held mouse button, which runs
    /// whether or not anything was held, so the common case has to be silent.
    func testReleaseAllSaysNothingWhenNothingIsHeld() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(state.releaseAll(), [])
    }

    func testReleaseAllIsIdempotent() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftShift)
        _ = state.releaseAll()
        XCTAssertEqual(state.releaseAll(), [])
    }

    // MARK: - Keys with no position

    /// A key the protocol has no code for still types, by sending the character
    /// the iPad's own layout produced. This is the path for anything the map
    /// does not name.
    func testAKeyWithNoPositionSendsItsCharacter() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboardF13, "é"), [.keyText("é")])
    }

    /// Text has no release, so the up must send nothing. Sending it twice types
    /// the character twice.
    func testAKeyWithNoPositionSendsNothingOnRelease() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardF13, "é")
        XCTAssertEqual(up(&state, .keyboardF13, "é"), [])
    }

    /// `Cmd` plus a character the Mac cannot place is not a shortcut anybody
    /// meant. Inserting the text instead would type a stray letter into
    /// whatever happens to be focused on the Mac.
    func testAKeyWithNoPositionIsDroppedWhileAModifierIsHeld() {
        var state = HardwareKeyboardState()
        _ = down(&state, .keyboardLeftGUI)
        XCTAssertEqual(down(&state, .keyboardF13, "é"), [])
    }

    func testAKeyWithNoPositionAndNoCharacterSendsNothing() {
        var state = HardwareKeyboardState()
        XCTAssertEqual(down(&state, .keyboardF13, ""), [])
    }
}
