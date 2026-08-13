import Foundation
import Testing
@testable import PadlinkCore

@Test func framesPayloadWithBigEndianLengthPrefix() {
    let framed = Framer.frame(Data([0xAA, 0xBB, 0xCC]))
    #expect(Array(framed) == [0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
}

@Test func readsOneWholeFrame() throws {
    var parser = FrameParser()
    parser.append(Framer.frame(Data([1, 2, 3])))
    #expect(try parser.nextFrame() == Data([1, 2, 3]))
    #expect(try parser.nextFrame() == nil)
}

@Test func readsFrameSplitAcrossTwoAppends() throws {
    var parser = FrameParser()
    let framed = Framer.frame(Data([1, 2, 3, 4, 5]))
    parser.append(framed.prefix(6))
    #expect(try parser.nextFrame() == nil)
    parser.append(framed.suffix(from: 6))
    #expect(try parser.nextFrame() == Data([1, 2, 3, 4, 5]))
}

@Test func readsFrameWhenEvenTheLengthHeaderIsSplit() throws {
    var parser = FrameParser()
    let framed = Framer.frame(Data([9, 9]))
    parser.append(framed.prefix(2))
    #expect(try parser.nextFrame() == nil)
    parser.append(framed.suffix(from: 2))
    #expect(try parser.nextFrame() == Data([9, 9]))
}

@Test func readsThreeFramesFromOneAppend() throws {
    var parser = FrameParser()
    var buffer = Data()
    buffer.append(Framer.frame(Data([1])))
    buffer.append(Framer.frame(Data([2, 2])))
    buffer.append(Framer.frame(Data([3, 3, 3])))
    parser.append(buffer)

    #expect(try parser.nextFrame() == Data([1]))
    #expect(try parser.nextFrame() == Data([2, 2]))
    #expect(try parser.nextFrame() == Data([3, 3, 3]))
    #expect(try parser.nextFrame() == nil)
}

@Test func returnsEmptyFrameForZeroLengthPayload() throws {
    var parser = FrameParser()
    parser.append(Data([0, 0, 0, 0]))
    // The parser stays dumb. An empty payload is the codec's problem, not framing's.
    #expect(try parser.nextFrame() == Data())
}

@Test func rejectsOversizedLengthHeader() {
    var parser = FrameParser()
    // A hostile peer claiming a 4GB frame must not make us allocate anything.
    parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
    #expect(throws: FramingError.frameTooLarge(0xFFFF_FFFF)) {
        _ = try parser.nextFrame()
    }
}

@Test func acceptsFrameExactlyAtTheLimit() throws {
    var parser = FrameParser()
    let payload = Data(repeating: 0x5A, count: FrameParser.maxFrameSize)
    parser.append(Framer.frame(payload))
    #expect(try parser.nextFrame() == payload)
}

@Test func rejectsFrameOneByteOverTheLimit() {
    var parser = FrameParser()
    let oversize = UInt32(FrameParser.maxFrameSize + 1)
    parser.append(Data([
        UInt8(truncatingIfNeeded: oversize >> 24),
        UInt8(truncatingIfNeeded: oversize >> 16),
        UInt8(truncatingIfNeeded: oversize >> 8),
        UInt8(truncatingIfNeeded: oversize)
    ]))
    #expect(throws: FramingError.frameTooLarge(oversize)) {
        _ = try parser.nextFrame()
    }
}
