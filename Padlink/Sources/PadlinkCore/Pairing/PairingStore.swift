import Foundation

public struct PairingRecord: Sendable, Equatable {
    public let id: PairingID
    public let secret: PairingSecret
    /// The other device's name, shown in the paired-devices list.
    public let peerName: String
    public let pairedAt: Date

    public init(id: PairingID, secret: PairingSecret, peerName: String, pairedAt: Date) {
        self.id = id
        self.secret = secret
        self.peerName = peerName
        self.pairedAt = pairedAt
    }
}

/// Where pairings live. The apps supply a Keychain-backed implementation.
/// Core supplies an in-memory one so the rest of the package can be tested
/// without code signing.
public protocol PairingStore: Sendable {
    func save(_ record: PairingRecord) throws
    func load(id: PairingID) throws -> PairingRecord?
    /// Oldest pairing first.
    func loadAll() throws -> [PairingRecord]
    /// Deleting an unknown id is not an error.
    func delete(id: PairingID) throws
}

public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PairingID: PairingRecord] = [:]

    public init() {}

    public func save(_ record: PairingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        records[record.id] = record
    }

    public func load(id: PairingID) throws -> PairingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[id]
    }

    public func loadAll() throws -> [PairingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func delete(id: PairingID) throws {
        lock.lock()
        defer { lock.unlock() }
        records[id] = nil
    }
}
