import Foundation

public struct PairingRecord: Sendable, Equatable {
    public let id: PairingID
    public let secret: PairingSecret
    /// The other device's name, shown in the paired-devices list.
    public let peerName: String
    /// The Bonjour service instance name the iPad used to find this Mac, from
    /// `PairingPayload.serviceName`. Lets the iPad reconnect to the same Mac
    /// after a restart when several Macs are advertising. Nil on the Mac's
    /// side of the pairing, since a paired iPad has no Bonjour service name
    /// of its own.
    public let serviceName: String?
    public let pairedAt: Date

    public init(
        id: PairingID,
        secret: PairingSecret,
        peerName: String,
        serviceName: String?,
        pairedAt: Date
    ) {
        self.id = id
        self.secret = secret
        self.peerName = peerName
        self.serviceName = serviceName
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
