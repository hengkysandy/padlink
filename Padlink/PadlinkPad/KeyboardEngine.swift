// Padlink/PadlinkPad/KeyboardEngine.swift
import Foundation
import PadlinkCore

/// What one key on the on-screen keyboard does when tapped.
enum KeyAction: Equatable {
    /// An ordinary key. Sends a down and a matching up, carrying whatever
    /// modifiers are active.
    case key(PadlinkKey)
    /// A sticky modifier: off, then armed for one keystroke, then locked.
    case modifier(KeyModifiers)
    /// Locks shift, or releases it. See `KeyboardEngine.press` for why this is
    /// not a `PadlinkKey`.
    case capsLock
}

/// How firmly a modifier is being held.
enum ModifierLatch: Equatable {
    case off
    /// Armed. Applies to the next key and then clears itself.
    case oneShot
    /// Held until the user, a disconnect, or a layout change releases it.
    case locked
}

/// The on-screen keyboard's modifier rules, and the messages a tap produces.
///
/// Pure, with no SwiftUI, because this is the part that can make a Mac
/// unusable and a SwiftUI view cannot be tested exhaustively.
///
/// # Why one-shot, with a double tap to lock
///
/// Tapping `command` then `C` has to produce Cmd+C, which rules out "hold the
/// key with a finger": there is only one finger, and it is busy. So a modifier
/// must stick past its own tap. The question is how long.
///
/// Latching (tap on, tap off) is the simple answer and the dangerous one. A
/// `command` tapped by accident stays down forever, and a held Command makes
/// the whole Mac behave strangely.
///
/// One-shot is the safe answer and an incomplete one. It cannot hold Command
/// across several Tab presses, which is what the macOS app switcher needs.
///
/// So: one-shot by default, and a second tap locks. That is exactly how the
/// iOS shift key already behaves, so it needs no teaching. It also needs no
/// timer: the "double tap" is simply a tap on an already-armed modifier, which
/// means there is no timing window to get wrong and no clock to inject.
///
/// # Why an armed modifier never reaches the wire
///
/// An armed modifier rides as a flag on the `keyCode` messages themselves,
/// which is exactly what `KeyRouter` already does for a shifted shortcut. The
/// Mac never posts a real modifier key down for it, so a dropped connection
/// mid-shortcut cannot leave one held.
///
/// Only a *locked* modifier sends `modifierState`, because only a locked
/// modifier needs the Mac to really hold the key. That keeps the one mechanism
/// that can strand a modifier attached to the one state the user chose on
/// purpose and can see on screen.
struct KeyboardEngine: Equatable {
    /// Armed for the next keystroke. Local to the iPad; never held on the Mac.
    private(set) var armedModifiers: KeyModifiers = []
    /// Really held down on the Mac, via `modifierState`.
    private(set) var lockedModifiers: KeyModifiers = []

    /// Everything that will be applied to the next key.
    var activeModifiers: KeyModifiers { armedModifiers.union(lockedModifiers) }

    var hasActiveModifiers: Bool { activeModifiers.isEmpty == false }

    init() {}

    func latch(of modifier: KeyModifiers) -> ModifierLatch {
        if lockedModifiers.contains(modifier) { return .locked }
        if armedModifiers.contains(modifier) { return .oneShot }
        return .off
    }

    mutating func press(_ action: KeyAction) -> [ClientMessage] {
        switch action {
        case let .key(key):
            return pressKey(key)
        case let .modifier(modifier):
            return advanceLatch(modifier)
        case .capsLock:
            // Not a `PadlinkKey`: the protocol has no caps lock, and
            // `KeyModifiers` has no caps lock bit. Locking shift is what the
            // user actually wants from this key, and it stays visible in the
            // modifier indicator and clearable like every other lock.
            return latch(of: .shift) == .locked
                ? setLocked(lockedModifiers.subtracting(.shift))
                : setLocked(lockedModifiers.union(.shift))
        }
    }

    /// Releases everything. Called when the user asks, when the keyboard is put
    /// away, when the app goes to the background, and when the connection
    /// drops.
    mutating func clearModifiers() -> [ClientMessage] {
        armedModifiers = []
        return setLocked([])
    }

    private mutating func pressKey(_ key: PadlinkKey) -> [ClientMessage] {
        let modifiers = activeModifiers
        // Spent. Locked modifiers survive, which is the whole difference.
        armedModifiers = []
        return [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }

    private mutating func advanceLatch(_ modifier: KeyModifiers) -> [ClientMessage] {
        switch latch(of: modifier) {
        case .off:
            armedModifiers.formUnion(modifier)
            // Nothing held on the Mac yet, so nothing to say.
            return []
        case .oneShot:
            armedModifiers.subtract(modifier)
            return setLocked(lockedModifiers.union(modifier))
        case .locked:
            return setLocked(lockedModifiers.subtracting(modifier))
        }
    }

    /// The single place `modifierState` is produced, so there is one line to
    /// read when asking how a modifier could possibly be left held.
    private mutating func setLocked(_ modifiers: KeyModifiers) -> [ClientMessage] {
        guard modifiers != lockedModifiers else { return [] }
        lockedModifiers = modifiers
        return [.modifierState(modifiers: modifiers)]
    }
}
