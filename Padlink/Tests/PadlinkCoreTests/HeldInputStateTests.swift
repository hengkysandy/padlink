import Testing
@testable import PadlinkCore

@Test func startsEmpty() {
    let state = HeldInputState()
    #expect(state.isEmpty)
    #expect(state.heldButtons.isEmpty)
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
