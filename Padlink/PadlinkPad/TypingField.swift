// Padlink/PadlinkPad/TypingField.swift
import SwiftUI
import UIKit

/// A text field that keeps no text and reports every key instead.
///
/// The override is the whole reason this subclass exists. UIKit calls
/// `textField(_:shouldChangeCharactersIn:replacementString:)` with an empty
/// string when a delete would remove something, and **does not call it at all
/// when there is nothing to remove**. This field is deliberately always empty,
/// so that delegate call never happens and backspace would silently do nothing.
/// `deleteBackward()` is `UIKeyInput`, and it is called on every press whatever
/// the field contains.
///
/// The usual workaround, parking a placeholder character in the field so there
/// is always something to delete, breaks the moment the user taps to put the
/// caret in front of it.
final class TypingTextField: UITextField {
    /// A backspace pressed with nothing in the field, which is every backspace.
    var onDeleteFromEmpty: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        borderStyle = .roundedRect
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        clearButtonMode = .never

        // Trap: iOS does not send what was typed, it sends what it decided the
        // user meant.
        //
        // Autocorrection rewrites a word *after* its letters have already gone
        // to the Mac, so the two end up holding different text. Autocapitalisation
        // changes which letter arrives. Smart quotes turn a straight " into a
        // curly one, which is a different character and breaks any shell command
        // or line of code it lands in; smart dashes do the same to --. Inline
        // prediction and math completion (iOS 18 turns "2+2=" into "4") both
        // insert text nobody pressed, and Writing Tools rewrites whole
        // sentences.
        //
        // Every one of them is off. Padlink is a keyboard, and a keyboard sends
        // the key that was pressed.
        //
        // Set here rather than in `makeUIView` so a test can hold them in
        // place: this is a silent corruption, so a regression would show up as
        // the Mac occasionally typing the wrong thing rather than as anything
        // failing.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none

        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func deleteBackward() {
        // Only when empty, so this can never double up with the delegate's own
        // deletion path if the field ever does hold text.
        if (text ?? "").isEmpty {
            onDeleteFromEmpty?()
        }
        super.deleteBackward()
    }
}

@MainActor
final class TypingFieldCoordinator: NSObject, UITextFieldDelegate {
    var onKeystroke: (Keystroke) -> Void
    /// Tells SwiftUI the keyboard opened or closed, whoever caused it.
    var reportFocus: (Bool) -> Void = { _ in }

    init(onKeystroke: @escaping (Keystroke) -> Void) {
        self.onKeystroke = onKeystroke
    }

    func reportDeleteBackward() {
        onKeystroke(.deleteBackward)
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            // A deletion of `range.length` characters. Unreachable while the
            // field is kept empty, which is why `TypingTextField` overrides
            // `deleteBackward`. Kept because one press has to stay one press:
            // a user who selects a word and deletes it means one backspace to
            // the Mac's text field, not one per letter, and the Mac has the
            // same selection to remove.
            onKeystroke(.deleteBackward)
        } else {
            // Everything else, in one go: one character from a tap, several
            // from a paste or a fast hardware keyboard.
            onKeystroke(.insert(string))
        }

        // Never true, for two reasons. The field has to stay empty so that
        // `deleteBackward` keeps firing. And nothing typed here is anyone's
        // business: a password meant for the Mac would otherwise sit in plain
        // text on the iPad's screen for as long as the app was open.
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Return is a key, not a character. `KeystrokeTranslator` sends the
        // real key code, which submits a form or runs a command rather than
        // inserting a newline.
        onKeystroke(.returnKey)
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        reportFocus(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        reportFocus(false)
    }
}

/// Where typing goes, for SwiftUI.
struct TypingField: UIViewRepresentable {
    /// Two-way: set it to open or close the keyboard, and it is set back when
    /// the user opens or closes the keyboard themselves.
    @Binding var isActive: Bool
    var placeholder: String
    var onKeystroke: (Keystroke) -> Void

    func makeCoordinator() -> TypingFieldCoordinator {
        TypingFieldCoordinator(onKeystroke: onKeystroke)
    }

    func makeUIView(context: Context) -> TypingTextField {
        // Everything about how the field behaves is set in its own initialiser,
        // where a test can reach it.
        let field = TypingTextField(frame: .zero)
        field.delegate = context.coordinator

        let coordinator = context.coordinator
        field.onDeleteFromEmpty = { coordinator.reportDeleteBackward() }

        return field
    }

    func updateUIView(_ field: TypingTextField, context: Context) {
        // Refreshed every rebuild: SwiftUI throws this struct away on each
        // state change, so the closures captured at coordinator time go stale.
        context.coordinator.onKeystroke = onKeystroke
        context.coordinator.reportFocus = { active in
            // Compared before writing. Resigning first responder below happens
            // *during* a view update and calls straight back into here, and
            // writing state during a view update is the one thing SwiftUI will
            // not have. When this app caused the change, the binding already
            // holds the new value, so there is nothing to write.
            if isActive != active { isActive = active }
        }
        field.placeholder = placeholder

        if isActive, field.isFirstResponder == false {
            field.becomeFirstResponder()
        } else if isActive == false, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }
}
