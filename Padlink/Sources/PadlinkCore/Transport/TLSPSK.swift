import Foundation

/// A pairing expressed the way TLS wants it. The pairing ID becomes the
/// pre-shared key identity, which is how the Mac picks the right secret when
/// several iPads are paired.
public struct TLSPSK: Sendable, Equatable {
    public let identity: Data
    public let key: Data

    public init(identity: Data, key: Data) {
        self.identity = identity
        self.key = key
    }

    public init(record: PairingRecord) {
        self.identity = record.id.bytes
        self.key = record.secret.bytes
    }
}
