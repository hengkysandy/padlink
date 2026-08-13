// Padlink/Tests/PadlinkCoreTests/ByteCodingTests.swift
import Foundation
import Testing
@testable import PadlinkCore

@Test func writesIntegersBigEndian() throws {
    var writer = ByteWriter()
    writer.write(UInt16(0x1234))
    writer.write(UInt32(0xDEADBEEF))
    #expect(Array(writer.data) == [0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF])
}

@Test func roundTripsEveryScalarType() throws {
    var writer = ByteWriter()
    writer.write(UInt8(200))
    writer.write(UInt16(65000))
    writer.write(Int16(-1234))
    writer.write(UInt32(4_000_000_000))
    writer.write(true)
    writer.write(false)
    try writer.writeString("héllo 🌍")

    var reader = ByteReader(writer.data)
    #expect(try reader.readUInt8() == 200)
    #expect(try reader.readUInt16() == 65000)
    #expect(try reader.readInt16() == -1234)
    #expect(try reader.readUInt32() == 4_000_000_000)
    #expect(try reader.readBool() == true)
    #expect(try reader.readBool() == false)
    #expect(try reader.readString() == "héllo 🌍")
    #expect(reader.isAtEnd)
}

@Test func readingPastTheEndThrowsTruncated() {
    var reader = ByteReader(Data([0x01]))
    #expect(throws: CodecError.truncated) {
        _ = try reader.readUInt16()
    }
}

@Test func stringWithLyingLengthThrowsTruncated() {
    // Claims 10 bytes of content but supplies 2.
    var reader = ByteReader(Data([0x00, 0x0A, 0x61, 0x62]))
    #expect(throws: CodecError.truncated) {
        _ = try reader.readString()
    }
}

@Test func invalidUTF8ThrowsInvalidUTF8() {
    // Length 2, then a lone continuation byte pair that is not valid UTF-8.
    var reader = ByteReader(Data([0x00, 0x02, 0xC3, 0x28]))
    #expect(throws: CodecError.invalidUTF8) {
        _ = try reader.readString()
    }
}
