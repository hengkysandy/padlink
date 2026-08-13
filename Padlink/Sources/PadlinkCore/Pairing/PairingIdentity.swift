import Foundation
import Security

public enum PairingError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
    case wrongScheme
    case unsupportedVersion(Int)
    case missingField(String)
    case malformedField(String)
    case notAURL
}

private func randomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
        throw PairingError.randomGenerationFailed(status)
    }
    return Data(bytes)
}

/// Identifies one pairing. Doubles as the TLS pre-shared key identity, which is
/// how the Mac knows which secret to use when several iPads are paired.
public struct PairingID: Sendable, Hashable {
    public static let byteCount = 8
    public let bytes: Data

    /// Skips the length check. Only for callers that already know the length
    /// is correct, such as `generate()`. Untrusted input must go through the
    /// failable `init?(bytes:)` instead.
    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public init?(hexString: String) {
        guard hexString.count == Self.byteCount * 2 else { return nil }
        var data = Data(capacity: Self.byteCount)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.bytes = data
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func generate() throws -> PairingID {
        PairingID(unchecked: try randomBytes(count: byteCount))
    }
}

/// The shared secret used as the TLS 1.2 pre-shared key. 256 bits, so it is
/// safe to use directly with no password-authenticated key exchange.
public struct PairingSecret: Sendable, Hashable {
    public static let byteCount = 32
    public let bytes: Data

    /// Skips the length check. Only for callers that already know the length
    /// is correct, such as `generate()`. Untrusted input must go through the
    /// failable `init?(bytes:)` instead.
    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public static func generate() throws -> PairingSecret {
        PairingSecret(unchecked: try randomBytes(count: byteCount))
    }
}
