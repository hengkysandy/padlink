// Padlink/PadlinkPadTests/KeyboardLayoutTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// A keyboard layout fails quietly. A key with the wrong `PadlinkKey` types the
/// wrong character, a key that is missing simply is not there, and a row that is
/// too wide runs off the screen. None of it crashes, so none of it shows up
/// anywhere except in use.
final class KeyboardLayoutTests: XCTestCase {

    private func allCaps(_ layout: KeyboardLayout) -> [KeyCap] {
        layout.rows.flatMap { $0 }
    }

    private func keys(_ layout: KeyboardLayout) -> [PadlinkKey] {
        allCaps(layout).compactMap {
            if case let .key(key) = $0.action { return key }
            return nil
        }
    }

    // MARK: - The MacBook layout

    /// The point of this layout is that it is the whole keyboard. Anything
    /// missing sends the user back to the typing bar for a character they can
    /// see on the Mac in front of them.
    func testTheMacBookLayoutHasEveryLetter() {
        let letters: [PadlinkKey] = [
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z
        ]
        let present = Set(keys(.macBook))
        for letter in letters {
            XCTAssertTrue(present.contains(letter), "missing \(letter)")
        }
    }

    func testTheMacBookLayoutHasEveryDigit() {
        let digits: [PadlinkKey] = [
            .digit0, .digit1, .digit2, .digit3, .digit4,
            .digit5, .digit6, .digit7, .digit8, .digit9
        ]
        let present = Set(keys(.macBook))
        for digit in digits {
            XCTAssertTrue(present.contains(digit), "missing \(digit)")
        }
    }

    func testTheMacBookLayoutHasTheWholeFunctionRow() {
        let functions: [PadlinkKey] = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12
        ]
        let present = Set(keys(.macBook))
        for function in functions {
            XCTAssertTrue(present.contains(function), "missing \(function)")
        }
    }

    func testTheMacBookLayoutHasEveryPunctuationKey() {
        let punctuation: [PadlinkKey] = [
            .minus, .equal, .leftBracket, .rightBracket, .backslash,
            .semicolon, .quote, .grave, .comma, .period, .slash
        ]
        let present = Set(keys(.macBook))
        for mark in punctuation {
            XCTAssertTrue(present.contains(mark), "missing \(mark)")
        }
    }

    func testTheMacBookLayoutHasAllFourArrows() {
        let present = Set(keys(.macBook))
        for arrow in [PadlinkKey.arrowLeft, .arrowRight, .arrowUp, .arrowDown] {
            XCTAssertTrue(present.contains(arrow), "missing \(arrow)")
        }
    }

    /// Every modifier a Mac shortcut can use. Missing one means a whole family
    /// of shortcuts cannot be typed at all.
    func testTheMacBookLayoutHasEveryModifier() {
        let modifiers = allCaps(.macBook).compactMap { cap -> KeyModifiers? in
            if case let .modifier(modifier) = cap.action { return modifier }
            return nil
        }
        for modifier in [KeyModifiers.shift, .control, .option, .command, .function] {
            XCTAssertTrue(modifiers.contains(modifier), "missing \(modifier)")
        }
    }

    // MARK: - Every layout

    /// A zero or negative width divides by zero when the view turns units into
    /// points, and a key nobody can see is a key nobody can press.
    func testEveryKeyHasAPositiveWidth() {
        for layout in KeyboardLayout.allCases {
            for cap in allCaps(layout) {
                XCTAssertGreaterThan(cap.width, 0, "\(layout.title): \(cap.label)")
            }
        }
    }

    func testEveryKeyHasALabel() {
        for layout in KeyboardLayout.allCases {
            for cap in allCaps(layout) {
                XCTAssertFalse(cap.label.isEmpty, "\(layout.title) has an unlabelled key")
            }
        }
    }

    /// The view divides its width by `widthInUnits`, so a zero would divide by
    /// zero and any row wider than it would run off the screen.
    func testWidthInUnitsIsTheWidestRow() {
        for layout in KeyboardLayout.allCases {
            let widest = layout.rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 1
            XCTAssertEqual(layout.widthInUnits, widest, accuracy: 0.0001, layout.title)
            XCTAssertGreaterThan(layout.widthInUnits, 0, layout.title)
        }
    }

    /// The MacBook's rows are drawn as one block, so rows of very different
    /// widths would leave ragged gaps down one side.
    func testTheMacBookRowsAreCloseToTheSameWidth() {
        let widths = KeyboardLayout.macBook.rows.map { $0.reduce(0) { $0 + $1.width } }
        let widest = widths.max() ?? 0
        let narrowest = widths.min() ?? 0
        XCTAssertGreaterThan(narrowest / widest, 0.9)
    }

    /// Every layout is a keyboard. "No keyboard" used to be a layout, and it
    /// was the wrong shape for the question: whether the keyboard is up is
    /// something the user flips while working, so it is a button, not a choice
    /// buried in a picker. An empty layout now would draw a zero-height panel
    /// and a stray gap with no way to explain it.
    func testEveryLayoutHasKeys() {
        for layout in KeyboardLayout.allCases {
            XCTAssertFalse(layout.rows.isEmpty, layout.title)
        }
    }

    /// The compact layout drops keys on purpose, but not the ones a shortcut
    /// needs. Command, Control, Option and Shift are the whole reason to have
    /// an on-screen keyboard rather than only the typing bar.
    func testTheCompactLayoutKeepsTheShortcutModifiers() {
        let modifiers = allCaps(.compact).compactMap { cap -> KeyModifiers? in
            if case let .modifier(modifier) = cap.action { return modifier }
            return nil
        }
        for modifier in [KeyModifiers.shift, .control, .option, .command] {
            XCTAssertTrue(modifiers.contains(modifier), "missing \(modifier)")
        }
    }

    func testTheCompactLayoutHasEveryLetter() {
        let letters: [PadlinkKey] = [
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z
        ]
        let present = Set(keys(.compact))
        for letter in letters {
            XCTAssertTrue(present.contains(letter), "missing \(letter)")
        }
    }

    // MARK: - The picker

    /// The picker stores a raw value, so an unknown one has to fall back rather
    /// than leaving the user with no keyboard and no way to get one back.
    func testAnUnknownStoredLayoutIsNotAValidLayout() {
        XCTAssertNil(KeyboardLayout(rawValue: "somethingElse"))
    }

    func testEveryLayoutHasATitleAndASummary() {
        for layout in KeyboardLayout.allCases {
            XCTAssertFalse(layout.title.isEmpty)
            XCTAssertFalse(layout.summary.isEmpty)
        }
    }

    // MARK: - What a key actually sends

    /// The one test that joins the layout to the wire. Tapping `A` has to send
    /// the `a` key and nothing else.
    func testTappingALetterSendsThatKeyDownAndUp() {
        let cap = allCaps(.macBook).first { $0.label == "A" }
        var engine = KeyboardEngine()
        XCTAssertEqual(
            engine.press(try! XCTUnwrap(cap).action),
            [
                .keyCode(key: .a, isDown: true, modifiers: []),
                .keyCode(key: .a, isDown: false, modifiers: [])
            ]
        )
    }

    /// And the shortcut path, end to end through the layout: tap Command, then
    /// tap C, and the Mac gets Cmd+C.
    func testTappingCommandThenCSendsACopy() {
        let caps = allCaps(.macBook)
        let command = caps.first { $0.action == .modifier(.command) }
        let cKey = caps.first { $0.action == .key(.c) }

        var engine = KeyboardEngine()
        XCTAssertEqual(engine.press(try! XCTUnwrap(command).action), [])
        XCTAssertEqual(
            engine.press(try! XCTUnwrap(cKey).action),
            [
                .keyCode(key: .c, isDown: true, modifiers: .command),
                .keyCode(key: .c, isDown: false, modifiers: .command)
            ]
        )
    }
}
