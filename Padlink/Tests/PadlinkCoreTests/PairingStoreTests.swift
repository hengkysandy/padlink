import Foundation
import Testing
@testable import PadlinkCore

private func record(_ byte: UInt8, name: String, serviceName: String? = "Hengky MacBook Air") -> PairingRecord {
    PairingRecord(
        id: PairingID(bytes: Data(repeating: byte, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: byte, count: 32))!,
        peerName: name,
        serviceName: serviceName,
        pairedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
}

@Test func savesAndLoadsARecord() throws {
    let store = InMemoryPairingStore()
    let saved = record(1, name: "iPad Air")
    try store.save(saved)
    #expect(try store.load(id: saved.id) == saved)
    #expect(try store.load(id: saved.id)?.serviceName == "Hengky MacBook Air")
}

@Test func savesAndLoadsARecordWithNoServiceName() throws {
    // The Mac's side of a pairing has no Bonjour service name of its own.
    let store = InMemoryPairingStore()
    let saved = record(7, name: "iPad Pro", serviceName: nil)
    try store.save(saved)
    #expect(try store.load(id: saved.id)?.serviceName == nil)
}

@Test func loadingAnUnknownIDReturnsNil() throws {
    let store = InMemoryPairingStore()
    let unknown = PairingID(bytes: Data(repeating: 9, count: 8))!
    #expect(try store.load(id: unknown) == nil)
}

@Test func savingTheSameIDTwiceReplacesTheRecord() throws {
    let store = InMemoryPairingStore()
    let first = record(2, name: "old name")
    let second = PairingRecord(
        id: first.id,
        secret: first.secret,
        peerName: "new name",
        serviceName: first.serviceName,
        pairedAt: first.pairedAt
    )
    try store.save(first)
    try store.save(second)
    #expect(try store.load(id: first.id)?.peerName == "new name")
    #expect(try store.loadAll().count == 1)
}

@Test func loadsAllRecordsSortedByPairedDate() throws {
    let store = InMemoryPairingStore()
    let newer = PairingRecord(
        id: PairingID(bytes: Data(repeating: 4, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: 4, count: 32))!,
        peerName: "newer",
        serviceName: "Hengky MacBook Air",
        pairedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )
    try store.save(newer)
    try store.save(record(3, name: "older"))

    let all = try store.loadAll()
    #expect(all.map(\.peerName) == ["older", "newer"])
}

@Test func deletesARecord() throws {
    let store = InMemoryPairingStore()
    let saved = record(5, name: "gone soon")
    try store.save(saved)
    try store.delete(id: saved.id)
    #expect(try store.load(id: saved.id) == nil)
    #expect(try store.loadAll().isEmpty)
}

@Test func deletingAnUnknownIDIsNotAnError() throws {
    let store = InMemoryPairingStore()
    try store.delete(id: PairingID(bytes: Data(repeating: 6, count: 8))!)
}
