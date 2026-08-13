import Foundation
import Network

public enum PadlinkTransport: Sendable {
    /// Forward-secret PSK ciphersuites, as raw values.
    ///
    /// `tls_ciphersuite_t` exposes no PSK cases, so these are given by raw value.
    /// Only ephemeral-Diffie-Hellman suites appear here. Plain PSK suites such as
    /// 0x00A8 also complete a handshake but have no forward secrecy, which would
    /// break the promise that a captured recording cannot be decrypted later.
    static let forwardSecretPSKCiphersuites: [UInt16] = [
        0xD001,  // ECDHE_PSK_WITH_AES_128_GCM_SHA256
        0xCCAC,  // ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
        0x00AA   // DHE_PSK_WITH_AES_128_GCM_SHA256
    ]

    /// TLS 1.2 with forward-secret pre-shared keys, and Nagle disabled.
    ///
    /// TLS 1.2, not 1.3. Task 0 measured that `add_pre_shared_key` is RFC 4279
    /// style: every TLS 1.3 configuration failed with -9858.
    ///
    /// The ciphersuites must be pinned. Leaving the list empty still completes
    /// a handshake, but then a plain PSK suite with no forward secrecy can be
    /// negotiated.
    ///
    /// The secret came from a QR code, so it has full entropy and can be used
    /// directly as a pre-shared key. That is what removes the need for a
    /// password-authenticated key exchange.
    static func applyPreSharedKeys(_ options: NWProtocolTLS.Options, _ psks: [TLSPSK]) {
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        for rawValue in forwardSecretPSKCiphersuites {
            guard let suite = tls_ciphersuite_t(rawValue: rawValue) else {
                preconditionFailure(
                    "Ciphersuite 0x\(String(rawValue, radix: 16)) is not representable as tls_ciphersuite_t"
                )
            }
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        for psk in psks {
            let key = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = psk.identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                security,
                key as __DispatchData,
                identity as __DispatchData
            )
        }
    }

    private static func parameters(psks: [TLSPSK]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        applyPreSharedKeys(tls, psks)

        let tcp = NWProtocolTCP.Options()
        // Every pointer move is a small packet. Nagle would buffer them.
        tcp.noDelay = true
        // A backstop, not the real dead-peer detection: Darwin's default
        // probe interval (75s) and probe count (8) put actual TCP-level
        // detection closer to ten minutes even with keepaliveIdle this low.
        // The app-level heartbeat is what actually notices a dead peer in
        // seconds.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2

        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Parameters for the Mac. Every paired device's key is registered.
    public static func listenerParameters(psks: [TLSPSK]) -> NWParameters {
        let parameters = parameters(psks: psks)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Parameters for the iPad. Only this device's own key is used.
    public static func connectionParameters(psk: TLSPSK) -> NWParameters {
        parameters(psks: [psk])
    }
}
