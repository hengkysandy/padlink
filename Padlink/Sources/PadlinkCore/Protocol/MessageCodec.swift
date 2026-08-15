// Padlink/Sources/PadlinkCore/Protocol/MessageCodec.swift
import Foundation

public enum ClientMessageCodec {
    enum TypeByte: UInt8 {
        case hello = 1
        case pointerMove = 2
        case pointerButton = 3
        case scroll = 4
        case keyText = 5
        case keyCode = 6
        case ping = 7
        case modifierState = 8
        case systemAction = 9
        case pinch = 10
    }

    public static func encode(_ message: ClientMessage) throws -> Data {
        var writer = ByteWriter()
        switch message {
        case let .hello(protocolVersion, deviceName):
            writer.write(TypeByte.hello.rawValue)
            writer.write(protocolVersion)
            try writer.writeString(deviceName)
        case let .pointerMove(dx, dy, dtMicros):
            writer.write(TypeByte.pointerMove.rawValue)
            writer.write(dx)
            writer.write(dy)
            writer.write(dtMicros)
        case let .pointerButton(button, isDown):
            writer.write(TypeByte.pointerButton.rawValue)
            writer.write(button.rawValue)
            writer.write(isDown)
        case let .scroll(dx, dy):
            writer.write(TypeByte.scroll.rawValue)
            writer.write(dx)
            writer.write(dy)
        case let .keyText(text):
            writer.write(TypeByte.keyText.rawValue)
            try writer.writeString(text)
        case let .keyCode(key, isDown, modifiers):
            writer.write(TypeByte.keyCode.rawValue)
            writer.write(key.rawValue)
            writer.write(isDown)
            writer.write(modifiers.rawValue)
        case let .modifierState(modifiers):
            writer.write(TypeByte.modifierState.rawValue)
            writer.write(modifiers.rawValue)
        case let .systemAction(action):
            writer.write(TypeByte.systemAction.rawValue)
            writer.write(action.rawValue)
        case let .pinch(phase, magnification):
            writer.write(TypeByte.pinch.rawValue)
            writer.write(phase.rawValue)
            writer.write(magnification)
        case let .ping(seq):
            writer.write(TypeByte.ping.rawValue)
            writer.write(seq)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ClientMessage {
        var reader = ByteReader(data)
        let rawType = try reader.readUInt8()
        guard let type = TypeByte(rawValue: rawType) else {
            throw CodecError.unknownMessageType(rawType)
        }

        let message: ClientMessage
        switch type {
        case .hello:
            message = .hello(
                protocolVersion: try reader.readUInt16(),
                deviceName: try reader.readString()
            )
        case .pointerMove:
            message = .pointerMove(
                dx: try reader.readInt16(),
                dy: try reader.readInt16(),
                dtMicros: try reader.readUInt16()
            )
        case .pointerButton:
            let rawButton = try reader.readUInt8()
            guard let button = PointerButton(rawValue: rawButton) else {
                throw CodecError.unknownPointerButton(rawButton)
            }
            message = .pointerButton(button: button, isDown: try reader.readBool())
        case .scroll:
            message = .scroll(dx: try reader.readInt16(), dy: try reader.readInt16())
        case .keyText:
            message = .keyText(try reader.readString())
        case .keyCode:
            let rawKey = try reader.readUInt16()
            guard let key = PadlinkKey(rawValue: rawKey) else {
                throw CodecError.unknownKey(rawKey)
            }
            let isDown = try reader.readBool()
            let rawModifiers = try reader.readUInt8()
            guard rawModifiers & KeyModifiers.reservedMask.rawValue == 0 else {
                throw CodecError.reservedModifierBitsSet(rawModifiers)
            }
            message = .keyCode(
                key: key,
                isDown: isDown,
                modifiers: KeyModifiers(rawValue: rawModifiers)
            )
        case .modifierState:
            let rawModifiers = try reader.readUInt8()
            guard rawModifiers & KeyModifiers.reservedMask.rawValue == 0 else {
                throw CodecError.reservedModifierBitsSet(rawModifiers)
            }
            message = .modifierState(modifiers: KeyModifiers(rawValue: rawModifiers))
        case .systemAction:
            let rawAction = try reader.readUInt8()
            // An unknown action is rejected rather than ignored. A newer iPad
            // asking an older Mac for something it cannot do must not look like
            // it worked.
            guard let action = SystemAction(rawValue: rawAction) else {
                throw CodecError.unknownSystemAction(rawAction)
            }
            message = .systemAction(action)
        case .pinch:
            let rawPhase = try reader.readUInt8()
            guard let phase = PinchPhase(rawValue: rawPhase) else {
                throw CodecError.unknownPinchPhase(rawPhase)
            }
            message = .pinch(phase: phase, magnification: try reader.readInt16())
        case .ping:
            message = .ping(seq: try reader.readUInt32())
        }

        guard reader.isAtEnd else { throw CodecError.trailingBytes }
        return message
    }
}

public enum ServerMessageCodec {
    enum TypeByte: UInt8 {
        case helloAck = 128
        case pong = 129
        case error = 130
        case accessibilityChanged = 131
    }

    public static func encode(_ message: ServerMessage) throws -> Data {
        var writer = ByteWriter()
        switch message {
        case let .helloAck(protocolVersion, accessibilityGranted):
            writer.write(TypeByte.helloAck.rawValue)
            writer.write(protocolVersion)
            writer.write(accessibilityGranted)
        case let .pong(seq):
            writer.write(TypeByte.pong.rawValue)
            writer.write(seq)
        case let .error(code, text):
            writer.write(TypeByte.error.rawValue)
            writer.write(code)
            try writer.writeString(text)
        case let .accessibilityChanged(granted):
            writer.write(TypeByte.accessibilityChanged.rawValue)
            writer.write(granted)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ServerMessage {
        var reader = ByteReader(data)
        let rawType = try reader.readUInt8()
        guard let type = TypeByte(rawValue: rawType) else {
            throw CodecError.unknownMessageType(rawType)
        }

        let message: ServerMessage
        switch type {
        case .helloAck:
            message = .helloAck(
                protocolVersion: try reader.readUInt16(),
                accessibilityGranted: try reader.readBool()
            )
        case .pong:
            message = .pong(seq: try reader.readUInt32())
        case .error:
            message = .error(code: try reader.readUInt8(), message: try reader.readString())
        case .accessibilityChanged:
            message = .accessibilityChanged(granted: try reader.readBool())
        }

        guard reader.isAtEnd else { throw CodecError.trailingBytes }
        return message
    }
}
