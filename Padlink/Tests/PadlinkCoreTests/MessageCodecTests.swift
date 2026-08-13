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
    .ping(seq: 4_000_000_000)
]

private let allServerMessages: [ServerMessage] = [
    .helloAck(protocolVersion: 1, accessibilityGranted: true),
    .helloAck(protocolVersion: 1, accessibilityGranted: false),
    .pong(seq: 7),
    .error(code: 3, message: "not paired")
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

@Test func unknownClientMessageTypeIsReported() {
    #expect(throws: CodecError.unknownMessageType(99)) {
        _ = try ClientMessageCodec.decode(Data([99, 0, 0]))
    }
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
