// Padlink/PadlinkPadTests/KeyboardEngineTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// The on-screen keyboard's modifier rules, and the messages a tap produces.
///
/// This is the file that matters most in the keyboard feature. A modifier left
/// down on the Mac makes the Mac unusable, and this project has already shipped
/// and fixed that class of bug twice. So the rule here is deliberately narrow:
///
///   - A one-shot modifier never touches the wire as held state. It rides along
///     as a flag on the key event itself, exactly like `KeyRouter` does for a
///     shifted shortcut. Nothing is held, so nothing can stick.
///   - Only a *locked* modifier sends `modifierState`, because only a locked
///     modifier needs the Mac to genuinely hold the key down (Cmd+Tab).
///
/// Every test below that asserts "sends nothing" is asserting that safety
/// property, not an implementation detail.
final class KeyboardEngineTests: XCTestCase {

    private func downUp(_ key: PadlinkKey, _ modifiers: KeyModifiers = []) -> [ClientMessage] {
        [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }

    // MARK: - Ordinary keys

    func testAPlainKeySendsADownAndAMatchingUp() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.press(.key(.a)), downUp(.a))
    }

    /// A down with no up is a key repeating on the Mac until someone notices.
    func testEveryKeyDownHasAMatchingUp() {
        var engine = KeyboardEngine()
        for key in PadlinkKey.allCases {
            let messages = engine.press(.key(key))
            let downs = messages.filter { if case .keyCode(_, true, _) = $0 { return true } else { return false } }
            let ups = messages.filter { if case .keyCode(_, false, _) = $0 { return true } else { return false } }
            XCTAssertEqual(downs.count, ups.count, "\(key) left a key down with no up")
            XCTAssertEqual(downs.count, 1, "\(key) should press exactly once")
        }
    }

    // MARK: - One-shot modifiers

    /// Nothing goes on the wire when a modifier is armed. The Mac learns about
    /// it when the key it modifies arrives.
    func testArmingAModifierSendsNothing() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.press(.modifier(.command)), [])
        XCTAssertEqual(engine.latch(of: .command), .oneShot)
    }

    func testCommandThenCProducesCommandC() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.press(.key(.c)), downUp(.c, [.command]))
    }

    /// The whole point of one-shot: it is gone by the next key, so a forgotten
    /// modifier cannot poison everything typed afterwards.
    func testAOneShotModifierIsGoneByTheNextKey() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.key(.c))
        XCTAssertEqual(engine.press(.key(.v)), downUp(.v))
        XCTAssertEqual(engine.latch(of: .command), .off)
    }

    func testTwoOneShotModifiersCombineOnTheSameKey() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.shift))
        XCTAssertEqual(engine.press(.key(.digit4)), downUp(.digit4, [.command, .shift]))
    }

    /// Tapping an armed modifier a second time is the double tap, so this must
    /// not read as "disarm".
    func testTappingAnArmedModifierLocksIt() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.press(.modifier(.command)), [.modifierState(modifiers: [.command])])
        XCTAssertEqual(engine.latch(of: .command), .locked)
    }

    // MARK: - Locked modifiers

    /// Cmd+Tab+Tab. The app switcher only stays open while Command is really
    /// held, which is the one case that needs `modifierState`.
    func testALockedModifierSurvivesRepeatedKeyPresses() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.press(.key(.tab)), downUp(.tab, [.command]))
        XCTAssertEqual(engine.press(.key(.tab)), downUp(.tab, [.command]))
        XCTAssertEqual(engine.latch(of: .command), .locked)
    }

    /// The Mac already holds it, so repeating the state on every keystroke
    /// would be noise, and noise is what hides a real change.
    func testAKeyPressUnderALockedModifierDoesNotResendTheState() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        let messages = engine.press(.key(.tab))
        XCTAssertFalse(messages.contains { if case .modifierState = $0 { return true } else { return false } })
    }

    func testTappingALockedModifierReleasesItOnTheWire() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.press(.modifier(.command)), [.modifierState(modifiers: [])])
        XCTAssertEqual(engine.latch(of: .command), .off)
    }

    /// A locked modifier and an armed one on the same keystroke. The key
    /// carries both, the armed one is spent, the locked one stays held.
    func testALockedAndAnArmedModifierCombineThenOnlyTheArmedOneClears() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.shift))
        XCTAssertEqual(engine.press(.key(.n)), downUp(.n, [.command, .shift]))
        XCTAssertEqual(engine.latch(of: .command), .locked)
        XCTAssertEqual(engine.latch(of: .shift), .off)
    }

    func testReleasingOneOfTwoLockedModifiersKeepsTheOther() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.option))
        _ = engine.press(.modifier(.option))
        XCTAssertEqual(engine.press(.modifier(.command)), [.modifierState(modifiers: [.option])])
    }

    // MARK: - Caps lock

    /// There is no caps lock in `PadlinkKey` and no caps lock bit in
    /// `KeyModifiers`, so this key locks shift instead. That is what the user
    /// wants from it, and it stays visible and clearable like any other lock.
    func testCapsLockLocksShift() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.press(.capsLock), [.modifierState(modifiers: [.shift])])
        XCTAssertEqual(engine.latch(of: .shift), .locked)
        XCTAssertEqual(engine.press(.key(.a)), downUp(.a, [.shift]))
    }

    func testCapsLockAgainReleasesShift() {
        var engine = KeyboardEngine()
        _ = engine.press(.capsLock)
        XCTAssertEqual(engine.press(.capsLock), [.modifierState(modifiers: [])])
        XCTAssertEqual(engine.latch(of: .shift), .off)
    }

    /// Caps lock goes straight to locked, never through the armed state, or it
    /// would take two taps to do the one thing it is for.
    func testCapsLockLocksEvenWhenShiftIsMerelyArmed() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.shift))
        XCTAssertEqual(engine.press(.capsLock), [.modifierState(modifiers: [.shift])])
        XCTAssertEqual(engine.latch(of: .shift), .locked)
    }

    // MARK: - Clearing, the path that stops a stuck modifier

    func testClearReleasesALockedModifierOnTheWire() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.clearModifiers(), [.modifierState(modifiers: [])])
        XCTAssertEqual(engine.latch(of: .command), .off)
    }

    func testClearDropsAnArmedModifierWithoutTouchingTheWire() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        XCTAssertEqual(engine.clearModifiers(), [])
        XCTAssertEqual(engine.latch(of: .command), .off)
    }

    /// Called on every disconnect, every backgrounding, and every layout
    /// switch, so the common case has to be silent.
    func testClearWithNothingHeldSendsNothing() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.clearModifiers(), [])
    }

    func testClearIsIdempotent() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        _ = engine.clearModifiers()
        XCTAssertEqual(engine.clearModifiers(), [])
    }

    func testClearReleasesEveryLockedModifierAtOnce() {
        var engine = KeyboardEngine()
        for modifier in [KeyModifiers.command, .shift, .control, .option, .function] {
            _ = engine.press(.modifier(modifier))
            _ = engine.press(.modifier(modifier))
        }
        XCTAssertEqual(engine.clearModifiers(), [.modifierState(modifiers: [])])
        XCTAssertTrue(engine.activeModifiers.isEmpty)
    }

    // MARK: - What the screen shows

    /// The indicator is the safety net, so it must report armed and locked
    /// separately: an armed Command disappears by itself, a locked one does not.
    func testActiveModifiersReportsArmedAndLockedTogether() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.command))
        _ = engine.press(.modifier(.shift))
        XCTAssertEqual(engine.activeModifiers, [.command, .shift])
        XCTAssertEqual(engine.lockedModifiers, [.command])
    }

    func testNothingIsActiveOnAFreshEngine() {
        let engine = KeyboardEngine()
        XCTAssertTrue(engine.activeModifiers.isEmpty)
        XCTAssertTrue(engine.lockedModifiers.isEmpty)
        for modifier in [KeyModifiers.command, .shift, .control, .option, .function] {
            XCTAssertEqual(engine.latch(of: modifier), .off)
        }
    }

    /// `hasHeldModifiers` is what the view uses to decide whether to shout.
    /// Armed counts too: an armed Command that the user has forgotten about
    /// still changes what the next tap does.
    func testAnArmedModifierCountsAsSomethingToShow() {
        var engine = KeyboardEngine()
        _ = engine.press(.modifier(.command))
        XCTAssertTrue(engine.hasActiveModifiers)
        _ = engine.press(.key(.a))
        XCTAssertFalse(engine.hasActiveModifiers)
    }
}
