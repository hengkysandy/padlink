// Padlink/PadlinkPadTests/TypingFieldTests.swift
import AVFoundation
import UIKit
import XCTest
@testable import PadlinkPad

/// The only part of the view layer that decides anything.
///
/// The screens themselves are drawing, and drawing is not worth a test. These
/// two are different: which UIKit callback a key press arrives through, and
/// which text-input traits are off, are both silent when they are wrong. A
/// broken backspace does nothing at all, and a re-enabled autocorrect makes the
/// Mac type a different word from the one on the iPad's screen.
@MainActor
final class TypingFieldTests: XCTestCase {

    private var strokes: [Keystroke] = []

    private func coordinator() -> TypingFieldCoordinator {
        strokes = []
        return TypingFieldCoordinator(onKeystroke: { [weak self] in self?.strokes.append($0) })
    }

    // MARK: - The delegate

    func testTypedTextIsReportedInOneGoAndNeverKept() {
        let field = TypingTextField(frame: .zero)
        let sut = coordinator()

        let keep = sut.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "a"
        )

        XCTAssertEqual(strokes, [.insert("a")])
        // False, or the field would hold text: backspace would then stop
        // calling `deleteBackward`, and whatever was typed for the Mac would be
        // sitting readable on the iPad's screen.
        XCTAssertFalse(keep)
    }

    func testAPasteArrivesAsOneInsertNotOnePerCharacter() {
        let field = TypingTextField(frame: .zero)
        let sut = coordinator()

        _ = sut.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "hello"
        )

        XCTAssertEqual(strokes, [.insert("hello")])
    }

    func testAnEmptyReplacementIsADeleteRatherThanAnEmptyInsert() {
        let field = TypingTextField(frame: .zero)
        let sut = coordinator()

        // How UIKit reports a deletion: the range it would remove, and nothing
        // to put in its place. Reading this as `.insert("")` would send nothing
        // at all and backspace would look broken.
        _ = sut.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 1),
            replacementString: ""
        )

        XCTAssertEqual(strokes, [.deleteBackward])
    }

    func testDeletingASelectionIsOnePressNotOnePerCharacter() {
        let field = TypingTextField(frame: .zero)
        let sut = coordinator()

        _ = sut.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 7),
            replacementString: ""
        )

        XCTAssertEqual(strokes, [.deleteBackward])
    }

    func testReturnIsAKeyAndNeverEntersTheField() {
        let field = TypingTextField(frame: .zero)
        let sut = coordinator()

        let submit = sut.textFieldShouldReturn(field)

        XCTAssertEqual(strokes, [.returnKey])
        XCTAssertFalse(submit)
    }

    // MARK: - Backspace on an empty field

    func testBackspaceOnAnEmptyFieldIsStillReported() {
        // The reason `TypingTextField` exists. UIKit does not call
        // `shouldChangeCharactersIn` when there is nothing to delete, and this
        // field is deliberately always empty, so without the `deleteBackward`
        // override backspace would silently do nothing forever.
        let field = TypingTextField(frame: .zero)
        var deletes = 0
        field.onDeleteFromEmpty = { deletes += 1 }

        field.deleteBackward()

        XCTAssertEqual(deletes, 1)
    }

    func testBackspaceIsNotReportedTwiceWhenTheFieldHasText() {
        // The delegate covers a field with text in it. If the override fired
        // there as well, one press would delete two characters on the Mac.
        let field = TypingTextField(frame: .zero)
        field.text = "ab"
        var deletes = 0
        field.onDeleteFromEmpty = { deletes += 1 }

        field.deleteBackward()

        XCTAssertEqual(deletes, 0)
    }

    // MARK: - What iOS is not allowed to rewrite (trap E)

    func testTheFieldNeverRewritesWhatWasTyped() {
        let field = TypingTextField(frame: .zero)

        // Each of these silently changes the characters that reach the Mac.
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertEqual(field.spellCheckingType, .no)
        // Straight quotes and double hyphens have to survive: they end up in
        // shell commands and in code.
        XCTAssertEqual(field.smartQuotesType, .no)
        XCTAssertEqual(field.smartDashesType, .no)
        XCTAssertEqual(field.smartInsertDeleteType, .no)
        // Both of these insert text nobody pressed.
        XCTAssertEqual(field.inlinePredictionType, .no)
        XCTAssertEqual(field.mathExpressionCompletionType, .no)
        XCTAssertEqual(field.writingToolsBehavior, .none)
    }
}

/// The one line of `AVFoundation` that `ScanPlan` depends on.
final class CameraPermissionTests: XCTestCase {

    func testAuthorizedIsGranted() {
        XCTAssertEqual(CameraPermission(.authorized), .granted)
    }

    func testNotDeterminedIsNotDetermined() {
        XCTAssertEqual(CameraPermission(.notDetermined), .notDetermined)
    }

    func testDeniedIsDenied() {
        XCTAssertEqual(CameraPermission(.denied), .denied)
    }

    func testRestrictedCountsAsDenied() {
        // A device under parental controls or an MDM profile. The user cannot
        // change it from inside this app, which is the same situation as a
        // refusal, so it gets the same answer and the same "paste instead"
        // route out.
        XCTAssertEqual(CameraPermission(.restricted), .denied)
    }
}
