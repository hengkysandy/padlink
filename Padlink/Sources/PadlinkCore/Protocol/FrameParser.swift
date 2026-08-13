import Foundation

public enum FramingError: Error, Equatable, Sendable {
    /// The peer claimed a frame larger than `FrameParser.maxFrameSize`.
    /// The connection must be closed. Never allocate the claimed size.
    case frameTooLarge(UInt32)
}

public enum Framer {
    /// 4-byte big-endian length prefix, then the payload.
    public static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        var out = Data(capacity: 4 + payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

/// Turns a TCP byte stream back into whole messages. TCP can deliver half a
/// frame or three frames in one read, so both cases must work.
public struct FrameParser: Sendable {
    public static let maxFrameSize = 65_536

    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next whole frame, or nil when more bytes are needed.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        var length: UInt32 = 0
        for offset in 0 ..< 4 {
            length = (length << 8) | UInt32(buffer[buffer.index(start, offsetBy: offset)])
        }

        guard length <= UInt32(Self.maxFrameSize) else {
            throw FramingError.frameTooLarge(length)
        }

        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }

        let payloadStart = buffer.index(start, offsetBy: 4)
        let payloadEnd = buffer.index(start, offsetBy: total)
        let payload = Data(buffer[payloadStart ..< payloadEnd])
        buffer.removeSubrange(start ..< payloadEnd)
        return payload
    }
}
