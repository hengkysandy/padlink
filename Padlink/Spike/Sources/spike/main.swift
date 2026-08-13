import Foundation
import Network

// Spike: find a TLS pre-shared key configuration that Network.framework
// actually completes a handshake with, then check whether one listener can
// hold several PSKs and pick by identity.
//
// tls_ciphersuite_t exposes no PSK ciphersuites, but it is UInt16-backed, so
// the RFC 4279 suites can be built from their raw values.

// Plain PSK. No Diffie-Hellman, so NO forward secrecy.
let TLS_PSK_AES_128_GCM_SHA256 = tls_ciphersuite_t(rawValue: 0x00A8)!
let TLS_PSK_AES_256_GCM_SHA384 = tls_ciphersuite_t(rawValue: 0x00A9)!
let TLS_PSK_CHACHA20_POLY1305 = tls_ciphersuite_t(rawValue: 0xCCAB)!

// PSK with ephemeral Diffie-Hellman. These DO give forward secrecy, which the
// spec promises. RFC 5487 for DHE_PSK, RFC 8442 and RFC 7905 for ECDHE_PSK.
let TLS_DHE_PSK_AES_128_GCM_SHA256 = tls_ciphersuite_t(rawValue: 0x00AA)!
let TLS_DHE_PSK_AES_256_GCM_SHA384 = tls_ciphersuite_t(rawValue: 0x00AB)!
let TLS_ECDHE_PSK_AES_128_GCM_SHA256 = tls_ciphersuite_t(rawValue: 0xD001)!
let TLS_ECDHE_PSK_AES_256_GCM_SHA384 = tls_ciphersuite_t(rawValue: 0xD002)!
let TLS_ECDHE_PSK_CHACHA20_POLY1305 = tls_ciphersuite_t(rawValue: 0xCCAC)!
let TLS_ECDHE_PSK_AES_128_CBC_SHA256 = tls_ciphersuite_t(rawValue: 0xC037)!

struct Config {
    let name: String
    let minVersion: tls_protocol_version_t
    let ciphersuites: [tls_ciphersuite_t]
}

// Ordered best-first. Forward-secret suites are listed before plain PSK, so the
// first working config is the one we should ship.
let configs: [Config] = [
    Config(name: "FS  TLS1.2 + ECDHE_PSK_AES_128_GCM_SHA256",
           minVersion: .TLSv12, ciphersuites: [TLS_ECDHE_PSK_AES_128_GCM_SHA256]),
    Config(name: "FS  TLS1.2 + ECDHE_PSK_AES_256_GCM_SHA384",
           minVersion: .TLSv12, ciphersuites: [TLS_ECDHE_PSK_AES_256_GCM_SHA384]),
    Config(name: "FS  TLS1.2 + ECDHE_PSK_CHACHA20_POLY1305",
           minVersion: .TLSv12, ciphersuites: [TLS_ECDHE_PSK_CHACHA20_POLY1305]),
    Config(name: "FS  TLS1.2 + ECDHE_PSK_AES_128_CBC_SHA256",
           minVersion: .TLSv12, ciphersuites: [TLS_ECDHE_PSK_AES_128_CBC_SHA256]),
    Config(name: "FS  TLS1.2 + DHE_PSK_AES_128_GCM_SHA256",
           minVersion: .TLSv12, ciphersuites: [TLS_DHE_PSK_AES_128_GCM_SHA256]),
    Config(name: "FS  TLS1.2 + DHE_PSK_AES_256_GCM_SHA384",
           minVersion: .TLSv12, ciphersuites: [TLS_DHE_PSK_AES_256_GCM_SHA384]),
    Config(name: "FS  TLS1.2 + all forward-secret PSK suites",
           minVersion: .TLSv12,
           ciphersuites: [TLS_ECDHE_PSK_AES_128_GCM_SHA256,
                          TLS_ECDHE_PSK_CHACHA20_POLY1305,
                          TLS_DHE_PSK_AES_128_GCM_SHA256]),
    Config(name: "no  TLS1.3 + AES_128_GCM_SHA256",
           minVersion: .TLSv13, ciphersuites: [.AES_128_GCM_SHA256]),
    Config(name: "no  TLS1.3 + no explicit ciphersuite",
           minVersion: .TLSv13, ciphersuites: []),
    Config(name: "no  TLS1.2 + PSK_AES_128_GCM_SHA256 (no FS)",
           minVersion: .TLSv12, ciphersuites: [TLS_PSK_AES_128_GCM_SHA256]),
    Config(name: "no  TLS1.2 + PSK_AES_256_GCM_SHA384 (no FS)",
           minVersion: .TLSv12, ciphersuites: [TLS_PSK_AES_256_GCM_SHA384]),
    Config(name: "no  TLS1.2 + PSK_CHACHA20_POLY1305 (no FS)",
           minVersion: .TLSv12, ciphersuites: [TLS_PSK_CHACHA20_POLY1305]),
    Config(name: "??  TLS1.2 + no explicit ciphersuite",
           minVersion: .TLSv12, ciphersuites: [])
]

func dispatchData(_ data: Data) -> DispatchData {
    data.withUnsafeBytes { DispatchData(bytes: $0) }
}

/// Swift 6 forbids mutating a captured local from a @Sendable closure, so state
/// shared with the Network.framework callbacks lives behind a reference.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

func makeOptions(_ config: Config, psks: [(key: Data, identity: Data)]) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let sec = options.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(sec, config.minVersion)
    for suite in config.ciphersuites {
        sec_protocol_options_append_tls_ciphersuite(sec, suite)
    }
    for psk in psks {
        sec_protocol_options_add_pre_shared_key(
            sec,
            dispatchData(psk.key) as __DispatchData,
            dispatchData(psk.identity) as __DispatchData
        )
    }
    return options
}

let keyA = Data(repeating: 0xA1, count: 32)
let idA = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
let keyB = Data(repeating: 0xB2, count: 32)
let idB = Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
let keyBad = Data(repeating: 0xCC, count: 32)
let idBad = Data(repeating: 0xDD, count: 8)

/// Runs one client against a listener holding `serverPSKs`. Returns whether the
/// handshake reached ready.
func attempt(
    config: Config,
    serverPSKs: [(key: Data, identity: Data)],
    clientPSK: (key: Data, identity: Data)
) -> Bool {
    let queue = DispatchQueue(label: "spike")
    let serverParams = NWParameters(
        tls: makeOptions(config, psks: serverPSKs),
        tcp: NWProtocolTCP.Options()
    )

    guard let listener = try? NWListener(using: serverParams, on: 0) else { return false }
    // Accepted connections must be retained or ARC frees them mid-handshake.
    let held = Box<[NWConnection]>([])
    listener.newConnectionHandler = { connection in
        held.value.append(connection)
        connection.start(queue: queue)
    }

    let ready = DispatchSemaphore(value: 0)
    let portBox = Box<NWEndpoint.Port?>(nil)
    listener.stateUpdateHandler = { state in
        if case .ready = state {
            portBox.value = listener.port
            ready.signal()
        }
        if case .failed = state { ready.signal() }
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 3)
    guard let port = portBox.value else {
        listener.cancel()
        return false
    }

    let clientParams = NWParameters(
        tls: makeOptions(config, psks: [clientPSK]),
        tcp: NWProtocolTCP.Options()
    )
    let client = NWConnection(host: "127.0.0.1", port: port, using: clientParams)

    let done = DispatchSemaphore(value: 0)
    let succeeded = Box(false)
    client.stateUpdateHandler = { state in
        switch state {
        case .ready:
            succeeded.value = true
            done.signal()
        case .failed, .cancelled:
            done.signal()
        case .waiting:
            // Network.framework reports a failed PSK handshake as .waiting and
            // then retries forever. Treat the first waiting as a failure.
            done.signal()
        default:
            break
        }
    }
    client.start(queue: queue)
    _ = done.wait(timeout: .now() + 5)

    client.cancel()
    listener.cancel()
    return succeeded.value
}

print("=== Which configuration completes a PSK handshake at all? ===")
var working: [Config] = []
for config in configs {
    let ok = attempt(config: config, serverPSKs: [(keyA, idA)], clientPSK: (keyA, idA))
    print(String(format: "%-40s %@", (config.name as NSString).utf8String!, ok ? "HANDSHAKE OK" : "failed"))
    if ok { working.append(config) }
}

guard let winner = working.first else {
    print("\nRESULT: no configuration worked. PSK is not usable this way.")
    exit(1)
}

print("\n=== Using \(winner.name) for the remaining questions ===")

let wrongKeyRejected = !attempt(
    config: winner,
    serverPSKs: [(keyA, idA)],
    clientPSK: (keyBad, idBad)
)
print("Q2 wrong key is rejected:      \(wrongKeyRejected ? "YES (good)" : "NO  <-- SECURITY PROBLEM")")

let multiA = attempt(config: winner, serverPSKs: [(keyA, idA), (keyB, idB)], clientPSK: (keyA, idA))
let multiB = attempt(config: winner, serverPSKs: [(keyA, idA), (keyB, idB)], clientPSK: (keyB, idB))
let multiBad = attempt(config: winner, serverPSKs: [(keyA, idA), (keyB, idB)], clientPSK: (keyBad, idBad))
print("Q1 two PSKs on one listener:")
print("   client A: \(multiA ? "OK" : "failed")")
print("   client B: \(multiB ? "OK" : "failed")")
print("   client BAD rejected: \(multiBad ? "NO  <-- SECURITY PROBLEM" : "YES (good)")")

print("\nRESULT")
print("  working config:        \(winner.name)")
print("  multiple PSKs work:    \(multiA && multiB && !multiBad ? "YES" : "NO")")
print("  wrong key rejected:    \(wrongKeyRejected ? "YES" : "NO")")
