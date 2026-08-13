// Padlink/Sources/PadlinkCore/Protocol/ByteReader.swift
import Foundation

/// Big-endian byte reader. Every read throws rather than trapping, because
/// the bytes come from the network and cannot be trusted.
struct ByteReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool { index >= data.endIndex }

    private var remaining: Int { data.distance(from: index, to: data.endIndex) }

    mutating func readUInt8() throws -> UInt8 {
        guard index < data.endIndex else { throw CodecError.truncated }
        let byte = data[index]
        index = data.index(after: index)
        return byte
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = try readUInt8()
        let low = try readUInt8()
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            value = (value << 8) | UInt32(try readUInt8())
        }
        return value
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt16())
        guard remaining >= length else { throw CodecError.truncated }
        let end = data.index(index, offsetBy: length)
        let slice = data[index ..< end]
        index = end
        guard let string = String(data: slice, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return string
    }
}
