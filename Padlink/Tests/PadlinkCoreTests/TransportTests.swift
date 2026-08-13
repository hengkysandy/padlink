import Foundation
import Network
import Testing
@testable import PadlinkCore

private func psk(_ byte: UInt8) -> TLSPSK {
    TLSPSK(record: PairingRecord(
        id: PairingID(bytes: Data(repeating: byte, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: byte, count: 32))!,
        peerName: "test",
        pairedAt: Date()
    ))
}

/// Swift 6 forbids mutating a captured local from a @Sendable state handler,
/// and accepted connections must be retained or ARC frees them mid-handshake.
/// This box covers both needs.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Starts a listener and returns its port, plus the box retaining accepted
/// connections. The caller cancels the listener and must keep the box alive.
private func startListener(
    psks: [TLSPSK]
) async throws -> (NWListener, NWEndpoint.Port, Box<[NWConnection]>) {
    let listener = try NWListener(using: PadlinkTransport.listenerParameters(psks: psks), on: 0)
    let accepted = Box<[NWConnection]>([])
    listener.newConnectionHandler = { connection in
        // Retaining is mandatory. Without this the handshake never completes.
        accepted.value.append(connection)
        connection.start(queue: .global())
    }

    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
        let resumed = Box(false)
        listener.stateUpdateHandler = { state in
            guard !resumed.value else { return }
            switch state {
            case .ready:
                resumed.value = true
                continuation.resume(returning: listener.port!)
            case .failed(let error):
                resumed.value = true
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: .global())
    }
    return (listener, port, accepted)
}

/// True when the handshake reached ready, false when it was rejected.
///
/// `.waiting` counts as rejection. Network.framework reports a failed PSK
/// handshake as `.waiting` and then retries forever, so a helper that only
/// watched for `.failed` would hang instead of returning false.
private func handshakeSucceeds(psk clientPSK: TLSPSK, port: NWEndpoint.Port) async -> Bool {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PadlinkTransport.connectionParameters(psk: clientPSK)
    )
    defer { connection.cancel() }

    return await withCheckedContinuation { continuation in
        let resumed = Box(false)
        connection.stateUpdateHandler = { state in
            guard !resumed.value else { return }
            switch state {
            case .ready:
                resumed.value = true
                continuation.resume(returning: true)
            case .failed, .cancelled, .waiting:
                resumed.value = true
                continuation.resume(returning: false)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

@Test func matchingPreSharedKeyCompletesTheHandshake() async throws {
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xA1), port: port))
    _ = accepted  // keep the retaining box alive to the end of the test
}

@Test func mismatchedPreSharedKeyIsRejected() async throws {
    // This is the test that proves a stranger on the same Wi-Fi cannot connect.
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xEE), port: port) == false)
    _ = accepted
}

@Test func listenerAcceptsEveryPairedDevice() async throws {
    // Task 0 measured that several PSKs on one listener work and TLS picks the
    // right one by identity. This test locks that behaviour in.
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1), psk(0xB2)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xA1), port: port))
    #expect(await handshakeSucceeds(psk: psk(0xB2), port: port))
    #expect(await handshakeSucceeds(psk: psk(0xCC), port: port) == false)
    _ = accepted
}

@Test func onlyForwardSecretCiphersuitesArePinned() {
    // Plain PSK suites (0x00A8, 0x00A9, 0xCCAB) complete a handshake but give
    // no forward secrecy. If one ever appears in this list, a captured
    // recording becomes decryptable once the secret leaks.
    let pinned = PadlinkTransport.forwardSecretPSKCiphersuites
    #expect(pinned.isEmpty == false)
    #expect(Set(pinned) == Set<UInt16>([0xD001, 0xCCAC, 0x00AA]))
    for plainPSK: UInt16 in [0x00A8, 0x00A9, 0xCCAB] {
        #expect(pinned.contains(plainPSK) == false)
    }
}

@Test func tcpNoDelayIsEnabled() {
    // Nagle's algorithm buffers small packets. Every pointer move is a small
    // packet, so leaving it on would add latency to exactly the wrong thing.
    let parameters = PadlinkTransport.connectionParameters(psk: psk(0xA1))
    let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    #expect(tcp?.noDelay == true)
}

@Test func pskCarriesThePairingIDAsItsIdentity() {
    let record = PairingRecord(
        id: PairingID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!,
        secret: PairingSecret(bytes: Data(repeating: 0x33, count: 32))!,
        peerName: "iPad",
        pairedAt: Date()
    )
    let converted = TLSPSK(record: record)
    #expect(converted.identity == record.id.bytes)
    #expect(converted.key == record.secret.bytes)
}
