import Foundation
import Network
import Testing
@testable import PadlinkCore

private func psk(_ byte: UInt8) -> TLSPSK {
    TLSPSK(record: PairingRecord(
        id: PairingID(bytes: Data(repeating: byte, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: byte, count: 32))!,
        peerName: "test",
        serviceName: "Hengky MacBook Air",
        pairedAt: Date()
    ))
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
            switch state {
            case .ready:
                guard resumed.claim() else { return }
                continuation.resume(returning: listener.port!)
            case .failed(let error):
                guard resumed.claim() else { return }
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
            switch state {
            case .ready:
                guard resumed.claim() else { return }
                continuation.resume(returning: true)
            case .failed, .cancelled, .waiting:
                guard resumed.claim() else { return }
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

    let connection = NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PadlinkTransport.connectionParameters(psk: psk(0xA1))
    )
    defer { connection.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resumed = Box(false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard resumed.claim() else { return }
                continuation.resume()
            case .failed(let error):
                guard resumed.claim() else { return }
                continuation.resume(throwing: error)
            case .cancelled, .waiting:
                guard resumed.claim() else { return }
                continuation.resume(throwing: CancellationError())
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    // The pinning test below only proves the constant list is right. This
    // proves the live handshake actually lands on one of those suites, which
    // is what the forward-secrecy promise depends on: that a leaked secret
    // cannot decrypt an old recording.
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
        Issue.record("ready connection has no TLS metadata")
        return
    }
    let security = metadata.securityProtocolMetadata
    let negotiatedSuite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(security)
    #expect(PadlinkTransport.forwardSecretPSKCiphersuites.contains(negotiatedSuite.rawValue))

    let negotiatedVersion = sec_protocol_metadata_get_negotiated_tls_protocol_version(security)
    #expect(negotiatedVersion == .TLSv12)

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
        serviceName: nil,
        pairedAt: Date()
    )
    let converted = TLSPSK(record: record)
    #expect(converted.identity == record.id.bytes)
    #expect(converted.key == record.secret.bytes)
}
