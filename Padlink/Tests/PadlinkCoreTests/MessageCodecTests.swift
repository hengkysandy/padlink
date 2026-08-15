// Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift
import Foundation
import Testing
@testable import PadlinkCore

private let allClientMessages: [ClientMessage] = [
    .hello(protocolVersion: 1, deviceName: "Hengky's iPad"),
    .pointerMove(dx: -320, dy: 240, dtMicros: 16_666),
    .pointerMove(dx: 0, dy: 0, dtMicros: 0),
    .pointerButton(button: .left, isDown: true),
    .pointerButton(button: .right, isDown: false),
    .scroll(dx: 12, dy: -400),
    .keyText("héllo 🌍"),
    .keyCode(key: .c, isDown: true, modifiers: [.command]),
    .keyCode(key: .f12, isDown: false, modifiers: [.shift, .control, .option, .command, .function]),
    .modifierState(modifiers: [.command, .function]),
    .systemAction(.missionControl),
    .pinch(phase: .began, magnification: 0),
    .pinch(phase: .changed, magnification: -32_000),
    .ping(seq: 4_000_000_000)
]

private let allServerMessages: [ServerMessage] = [
    .helloAck(protocolVersion: 1, accessibilityGranted: true),
    .helloAck(protocolVersion: 1, accessibilityGranted: false),
    .pong(seq: 7),
    .error(code: 3, message: "not paired"),
    .accessibilityChanged(granted: true),
    .accessibilityChanged(granted: false)
]

@Test(arguments: allClientMessages)
func clientMessagesRoundTrip(message: ClientMessage) throws {
    let encoded = try ClientMessageCodec.encode(message)
    #expect(try ClientMessageCodec.decode(encoded) == message)
}

@Test(arguments: allServerMessages)
func serverMessagesRoundTrip(message: ServerMessage) throws {
    let encoded = try ServerMessageCodec.encode(message)
    #expect(try ServerMessageCodec.decode(encoded) == message)
}

@Test func modifierStateRoundTrips() throws {
    let message = ClientMessage.modifierState(modifiers: [.command, .shift])
    let encoded = try ClientMessageCodec.encode(message)
    #expect(try ClientMessageCodec.decode(encoded) == message)
}

@Test func modifierStateWithNoModifiersRoundTrips() throws {
    let message = ClientMessage.modifierState(modifiers: [])
    #expect(try ClientMessageCodec.decode(try ClientMessageCodec.encode(message)) == message)
}

@Test func modifierStateUsesTypeByte8() throws {
    let encoded = try ClientMessageCodec.encode(.modifierState(modifiers: [.command]))
    #expect(encoded.first == 8)
}

@Test(arguments: PinchPhase.allCases)
func everyPinchPhaseRoundTrips(phase: PinchPhase) throws {
    let message = ClientMessage.pinch(phase: phase, magnification: 250)
    #expect(try ClientMessageCodec.decode(try ClientMessageCodec.encode(message)) == message)
}

@Test func anUnknownPinchPhaseIsRejected() throws {
    #expect(throws: CodecError.unknownPinchPhase(99)) {
        try ClientMessageCodec.decode(Data([10, 99, 0, 0]))
    }
}

@Test func systemActionUsesTypeByte9() throws {
    let encoded = try ClientMessageCodec.encode(.systemAction(.missionControl))
    #expect(encoded.first == 9)
}

/// An action this Mac has never heard of is rejected, not skipped. A newer iPad
/// asking for something the Mac cannot do must not look as though it worked.
@Test func anUnknownSystemActionIsRejected() throws {
    let encoded = Data([9, 200])
    #expect(throws: CodecError.unknownSystemAction(200)) {
        try ClientMessageCodec.decode(encoded)
    }
}

/// Every action must survive the wire. A new case added without a codec change
/// would fail here rather than in someone's hand.
@Test(arguments: SystemAction.allCases)
func everySystemActionRoundTrips(action: SystemAction) throws {
    let message = ClientMessage.systemAction(action)
    #expect(try ClientMessageCodec.decode(try ClientMessageCodec.encode(message)) == message)
}

@Test func modifierStateRejectsReservedBits() {
    // type 8, modifiers 0b0010_0000 (bit 5 is reserved)
    #expect(throws: CodecError.reservedModifierBitsSet(0b0010_0000)) {
        _ = try ClientMessageCodec.decode(Data([8, 0b0010_0000]))
    }
}

@Test func unknownClientMessageTypeIsReported() {
    #expect(throws: CodecError.unknownMessageType(99)) {
        _ = try ClientMessageCodec.decode(Data([99, 0, 0]))
    }
}

/// The forwards-compatibility guarantee, from the iPad's side.
///
/// A newer Mac may send a server message this build has never heard of. Both
/// consumers of `ServerMessageCodec` use `try?` and skip what they cannot
/// decode, so the only requirement is that decode throws rather than crashing
/// or returning nonsense. Nothing tested this before: the client direction had
/// this test and the server direction did not.
@Test func unknownServerMessageTypeIsReportedRatherThanCrashing() {
    #expect(throws: CodecError.unknownMessageType(200)) {
        _ = try ServerMessageCodec.decode(Data([200, 1, 2, 3]))
    }
}

/// A server type byte that is one past the last known one, which is exactly
/// what the next protocol version will look like on this build's wire.
@Test func theNextServerMessageTypeDecodesAsUnknownRatherThanAsAKnownCase() {
    #expect(throws: CodecError.unknownMessageType(132)) {
        _ = try ServerMessageCodec.decode(Data([132, 1]))
    }
}

@Test func accessibilityChangedUsesTypeByte131() throws {
    // On the wire. Reusing an existing byte would make an old peer decode this
    // as something else entirely.
    let encoded = try ServerMessageCodec.encode(.accessibilityChanged(granted: true))
    #expect(encoded.first == 131)
    #expect(encoded.count == 2)
}

@Test func accessibilityChangedRejectsTrailingBytes() {
    var encoded = try! ServerMessageCodec.encode(.accessibilityChanged(granted: false))
    encoded.append(0xFF)
    #expect(throws: CodecError.trailingBytes) {
        _ = try ServerMessageCodec.decode(encoded)
    }
}

@Test func serverMessageTypeBytesAreStable() throws {
    // These are on the wire. Changing one silently breaks older peers.
    #expect(try ServerMessageCodec.encode(.helloAck(protocolVersion: 1, accessibilityGranted: true)).first == 128)
    #expect(try ServerMessageCodec.encode(.pong(seq: 1)).first == 129)
    #expect(try ServerMessageCodec.encode(.error(code: 1, message: "x")).first == 130)
}

@Test func emptyPayloadIsTruncated() {
    #expect(throws: CodecError.truncated) {
        _ = try ClientMessageCodec.decode(Data())
    }
}

@Test func reservedModifierBitsAreRejected() {
    // keyCode = 6, key = .a (1), isDown = 1, modifiers = 0b1000_0000
    let bytes = Data([6, 0x00, 0x01, 0x01, 0b1000_0000])
    #expect(throws: CodecError.reservedModifierBitsSet(0b1000_0000)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func unknownKeyIdIsRejected() {
    let bytes = Data([6, 0xFF, 0xFE, 0x01, 0x00])
    #expect(throws: CodecError.unknownKey(0xFFFE)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func unknownPointerButtonIsRejected() {
    let bytes = Data([3, 0x09, 0x01])
    #expect(throws: CodecError.unknownPointerButton(9)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func trailingBytesAreRejected() {
    var encoded = try! ClientMessageCodec.encode(.ping(seq: 1))
    encoded.append(0xFF)
    #expect(throws: CodecError.trailingBytes) {
        _ = try ClientMessageCodec.decode(encoded)
    }
}

@Test func padlinkKeyRawValuesAreStable() {
    // These are on the wire. Changing one silently breaks older peers.
    #expect(PadlinkKey.a.rawValue == 1)
    #expect(PadlinkKey.z.rawValue == 26)
    #expect(PadlinkKey.digit0.rawValue == 30)
    #expect(PadlinkKey.space.rawValue == 70)
    #expect(PadlinkKey.f1.rawValue == 100)
}

// MARK: - KeyModifiers.isTextSafe
//
// isTextSafe is public API introduced by this task, but nothing in the
// brief's message round trips exercises it directly. Its first real
// consumer is Task 6, so we pin its behavior here.

@Test func emptyModifiersIsTextSafe() {
    #expect(KeyModifiers().isTextSafe)
}

@Test func shiftAloneIsTextSafe() {
    #expect(KeyModifiers.shift.isTextSafe)
}

@Test func commandAloneIsNotTextSafe() {
    #expect(!KeyModifiers.command.isTextSafe)
}

@Test func shiftPlusAnotherModifierIsNotTextSafe() {
    #expect(!KeyModifiers([.shift, .control]).isTextSafe)
}
