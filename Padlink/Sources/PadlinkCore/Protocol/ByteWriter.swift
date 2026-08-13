// Padlink/Sources/PadlinkCore/Protocol/ByteWriter.swift
import Foundation

/// Big-endian byte writer. Internal on purpose: the wire format is an
/// implementation detail of this package.
struct ByteWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: Int16) {
        write(UInt16(bitPattern: value))
    }

    mutating func write(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: Bool) {
        write(value ? UInt8(1) : UInt8(0))
    }

    /// UInt16 byte-count prefix, then UTF-8.
    mutating func writeString(_ value: String) throws {
        let utf8 = Data(value.utf8)
        guard utf8.count <= Int(UInt16.max) else { throw CodecError.stringTooLong }
        write(UInt16(utf8.count))
        data.append(utf8)
    }
}
