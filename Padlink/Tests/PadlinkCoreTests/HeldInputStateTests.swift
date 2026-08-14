import Testing
@testable import PadlinkCore

@Test func startsEmpty() {
    let state = HeldInputState()
    #expect(state.isEmpty)
    #expect(state.heldButtons.isEmpty)
    #expect(state.heldKeys.isEmpty)
    #expect(state.heldModifiers.isEmpty)
}

@Test func tracksAHeldButton() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    #expect(state.heldButtons == [.left])
    #expect(state.isEmpty == false)
    state.recordButton(.left, isDown: false)
    #expect(state.heldButtons.isEmpty)
    #expect(state.isEmpty)
}

@Test func tracksModifiers() {
    var state = HeldInputState()
    state.recordModifiers([.command, .shift])
    #expect(state.heldModifiers == [.command, .shift])
    state.recordModifiers([.command])
    #expect(state.heldModifiers == [.command])
    state.recordModifiers([])
    #expect(state.isEmpty)
}

@Test func drainReturnsButtonsThenModifiers() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    state.recordModifiers([.command])

    let releases = state.drainReleases()
    #expect(releases == [.button(.left), .modifier(.command)])
}

@Test func drainEmitsOneActionPerHeldModifier() {
    var state = HeldInputState()
    state.recordModifiers([.command, .shift, .option])

    let releases = state.drainReleases()
    let modifiers = releases.compactMap { action -> KeyModifiers? in
        if case let .modifier(m) = action { return m }
        return nil
    }
    #expect(Set(modifiers.map(\.rawValue))
        == Set([KeyModifiers.shift, .option, .command].map(\.rawValue)))
    #expect(modifiers.count == 3)
}

@Test func drainClearsTheStateSoASecondDrainIsEmpty() {
    // This is the property that matters: a disconnect during a drag must not
    // release the same button twice if the release path runs more than once.
    var state = HeldInputState()
    state.recordButton(.right, isDown: true)
    state.recordModifiers([.control])

    #expect(state.drainReleases().isEmpty == false)
    #expect(state.drainReleases().isEmpty)
    #expect(state.isEmpty)
}

@Test func drainOnAnEmptyStateProducesNothing() {
    var state = HeldInputState()
    #expect(state.drainReleases().isEmpty)
}

@Test func bothButtonsCanBeHeldAtOnce() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    state.recordButton(.right, isDown: true)
    #expect(state.heldButtons == [.left, .right])
    #expect(state.drainReleases().count == 2)
}

// MARK: - Held key codes
//
// A key down and its matching key up are two separate frames. A connection
// dying between them leaves that key held down at the HID level, so the Mac
// repeats the character with nothing left to stop it.

@Test func tracksAHeldKey() {
    var state = HeldInputState()
    state.recordKey(.a, isDown: true)
    #expect(state.heldKeys == [.a])
    #expect(state.isEmpty == false)
    state.recordKey(.a, isDown: false)
    #expect(state.heldKeys.isEmpty)
    #expect(state.isEmpty)
}

@Test func drainReleasesAHeldKey() {
    var state = HeldInputState()
    state.recordKey(.a, isDown: true)
    #expect(state.drainReleases() == [.key(.a)])
}

@Test func drainReturnsButtonsThenKeysThenModifiers() {
    // Keys come before modifiers on purpose. Releasing Command first would
    // leave a bare Tab still down and repeating; releasing Tab first cannot.
    var state = HeldInputState()
    state.recordModifiers([.command])
    state.recordKey(.tab, isDown: true)
    state.recordButton(.left, isDown: true)

    #expect(state.drainReleases() == [.button(.left), .key(.tab), .modifier(.command)])
}

@Test func drainClearsHeldKeysSoASecondDrainIsEmpty() {
    var state = HeldInputState()
    state.recordKey(.a, isDown: true)

    #expect(state.drainReleases().isEmpty == false)
    #expect(state.drainReleases().isEmpty)
    #expect(state.isEmpty)
}

@Test func severalKeysCanBeHeldAtOnceAndDrainInAStableOrder() {
    var state = HeldInputState()
    state.recordKey(.z, isDown: true)
    state.recordKey(.a, isDown: true)
    state.recordKey(.tab, isDown: true)

    // Set iteration order is not stable between runs, so the drain has to
    // impose `PadlinkKey.allCases` order rather than hand back whatever order
    // the Set happens to hold. Without that, this test flakes.
    #expect(state.drainReleases() == [.key(.a), .key(.z), .key(.tab)])
}

@Test func aKeyThePeerReleasedIsNotDrainedAgain() {
    var state = HeldInputState()
    state.recordKey(.a, isDown: true)
    state.recordKey(.a, isDown: false)
    #expect(state.drainReleases().isEmpty)
}
