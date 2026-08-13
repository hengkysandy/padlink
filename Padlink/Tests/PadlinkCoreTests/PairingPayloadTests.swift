import Foundation
import Testing
@testable import PadlinkCore

private func makePayload(
    macName: String = "Hengky's MacBook Air",
    serviceName: String = "Hengky MacBook Air"
) -> PairingPayload {
    PairingPayload(
        pairingID: PairingID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!,
        secret: PairingSecret(bytes: Data(repeating: 0x7F, count: 32))!,
        macName: macName,
        serviceName: serviceName
    )
}

@Test func generatedSecretHasTheRightLength() throws {
    #expect(try PairingSecret.generate().bytes.count == 32)
}

@Test func twoGeneratedSecretsAreNeverEqual() throws {
    let a = try PairingSecret.generate()
    let b = try PairingSecret.generate()
    #expect(a != b)
}

@Test func twoGeneratedPairingIDsAreNeverEqual() throws {
    #expect(try PairingID.generate() != PairingID.generate())
}

@Test func secretRejectsWrongLength() {
    #expect(PairingSecret(bytes: Data(repeating: 0, count: 31)) == nil)
    #expect(PairingSecret(bytes: Data(repeating: 0, count: 33)) == nil)
}

@Test func pairingIDRoundTripsThroughHex() throws {
    let id = PairingID(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]))!
    #expect(id.hexString == "deadbeef00112233")
    #expect(PairingID(hexString: "deadbeef00112233") == id)
    #expect(PairingID(hexString: "DEADBEEF00112233") == id)
}

@Test func pairingIDRejectsBadHex() {
    #expect(PairingID(hexString: "notvalidhexxxxxx") == nil)
    #expect(PairingID(hexString: "deadbeef") == nil)
}

@Test func pairingIDRejectsSignCharacters() {
    // `UInt8("+1", radix: 16)` parses to 1, so without an explicit character
    // check this string would decode as a valid (wrong) id instead of being
    // rejected, and the hex round trip would not be injective.
    #expect(PairingID(hexString: "+1+2+3+4+5+6+7+8") == nil)
}

@Test func payloadRoundTrips() throws {
    let payload = makePayload()
    let parsed = try PairingPayload.parse(payload.urlString)
    #expect(parsed == payload)
}

@Test func payloadRoundTripsWithAwkwardNames() throws {
    let payload = makePayload(
        macName: "Hengky's Mac & iPad = fun?",
        serviceName: "name with spaces"
    )
    #expect(try PairingPayload.parse(payload.urlString) == payload)
}

@Test func payloadURLUsesTheExpectedShape() {
    let url = makePayload().urlString
    #expect(url.hasPrefix("padlink://pair?"))
    #expect(url.contains("v=1"))
    #expect(url.contains("id=0102030405060708"))
    // base64url, unpadded: no plus, no slash, no equals sign.
    let keyToken = url.split(separator: "&").first { $0.hasPrefix("k=") }!
    let key = keyToken.dropFirst("k=".count)
    #expect(!key.contains("+"))
    #expect(!key.contains("/"))
    #expect(!key.contains("="))
}

@Test func parseRejectsWrongScheme() {
    #expect(throws: PairingError.wrongScheme) {
        _ = try PairingPayload.parse("https://example.com/pair?v=1")
    }
}

@Test func parseRejectsUnsupportedVersion() {
    let url = makePayload().urlString.replacingOccurrences(of: "v=1", with: "v=2")
    #expect(throws: PairingError.unsupportedVersion(2)) {
        _ = try PairingPayload.parse(url)
    }
}

@Test func parseRejectsMissingField() {
    let full = makePayload().urlString
    let withoutKey = full
        .split(separator: "&")
        .filter { !$0.hasPrefix("k=") }
        .joined(separator: "&")
    #expect(throws: PairingError.missingField("k")) {
        _ = try PairingPayload.parse(withoutKey)
    }
}

@Test func parseRejectsMalformedSecret() {
    let url = makePayload().urlString
    let broken = url.replacingOccurrences(
        of: url.split(separator: "&").first { $0.hasPrefix("k=") }!,
        with: "k=tooshort"
    )
    #expect(throws: PairingError.malformedField("k")) {
        _ = try PairingPayload.parse(broken)
    }
}

@Test func parseRejectsBase64URLWithRemainderOne() {
    // `decodeBase64URL` correctly rejects a remainder-1 input, but the
    // malformed-secret test above uses "tooshort" (8 characters, remainder
    // 0), which is caught by the length check before padding even matters.
    // Without this test, a padding refactor could silently break remainder 1
    // with nothing failing.
    let url = makePayload().urlString
    let broken = url.replacingOccurrences(
        of: url.split(separator: "&").first { $0.hasPrefix("k=") }!,
        with: "k=aaaaaaaaa"  // 9 characters: length % 4 == 1
    )
    #expect(throws: PairingError.malformedField("k")) {
        _ = try PairingPayload.parse(broken)
    }
}

@Test func parseRejectsGarbage() {
    #expect(throws: (any Error).self) {
        _ = try PairingPayload.parse("this is not a url at all")
    }
}
