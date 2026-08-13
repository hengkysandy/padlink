// Padlink/Sources/PadlinkTestClient/TestClient.swift
import Foundation
import Network
import PadlinkCore

struct StoredPairing: Codable {
    let id: String
    let secret: Data
    let serviceName: String
}

enum TestClientError: Error, CustomStringConvertible {
    case notPaired
    case badPayload(String)
    case macNotFound
    case usage

    var description: String {
        switch self {
        case .notPaired:
            return "Not paired. Run: padlink-testclient pair \"<padlink://... url>\""
        case let .badPayload(detail):
            return "Could not read the pairing URL: \(detail)"
        case .macNotFound:
            return "No Padlink Mac found on this network within 10 seconds."
        case .usage:
            return """
                Usage:
                  padlink-testclient pair "<padlink://pair?...>"
                  padlink-testclient move <dx> <dy>
                  padlink-testclient click <left|right>
                  padlink-testclient scroll <dx> <dy>
                  padlink-testclient type "<text>"
                  padlink-testclient key <letter> [--cmd] [--shift] [--opt] [--ctrl]
                  padlink-testclient hold <cmd|shift|opt|ctrl>
                  padlink-testclient release
                """
        }
    }
}

/// Guards a continuation so exactly one caller resumes it.
///
/// Core has `Box.claim()`, which does the same thing, but `Box` is `internal`
/// and this executable is not a `@testable` consumer. Widening Core's API for a
/// development tool would be the wrong trade, so the few lines are repeated
/// here instead.
private final class ClaimFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true only to the first caller.
    ///
    /// The test and the set happen under **one** lock acquisition. Two
    /// acquisitions would leave a gap in which the browser callback and the
    /// timeout could both resume the continuation, which is undefined
    /// behaviour.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

enum TestClient {
    /// Deliberately the home directory, not the current directory. The file holds a
    /// real pre-shared key and this repository is public, so it must never be able
    /// to land inside the working tree no matter where the binary is run from.
    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".padlink-testclient.json")
    }

    static func pair(urlString: String) throws {
        let payload: PairingPayload
        do {
            payload = try PairingPayload.parse(urlString)
        } catch {
            throw TestClientError.badPayload(String(describing: error))
        }

        let stored = StoredPairing(
            id: payload.pairingID.hexString,
            secret: payload.secret.bytes,
            serviceName: payload.serviceName
        )
        try JSONEncoder().encode(stored).write(to: stateURL)
        // The default file mode is 0644, which leaves a real pre-shared key
        // readable by every account on the machine. Narrow it to owner-only.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
        // Never print the secret itself.
        print("Paired with \(payload.macName). Saved to \(stateURL.path)")
    }

    static func loadPairing() throws -> (psk: TLSPSK, serviceName: String) {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode(StoredPairing.self, from: data),
              let id = PairingID(hexString: stored.id),
              let secret = PairingSecret(bytes: stored.secret)
        else { throw TestClientError.notPaired }

        return (TLSPSK(identity: id.bytes, key: secret.bytes), stored.serviceName)
    }

    /// Finds the Mac by Bonjour, connects, sends the messages, then closes.
    static func send(_ messages: [ClientMessage]) async throws {
        let (psk, serviceName) = try loadPairing()
        let endpoint = try await findMac(named: serviceName)

        let raw = NWConnection(
            to: endpoint,
            using: PadlinkTransport.connectionParameters(psk: psk)
        )
        let connection = PadlinkConnection(connection: raw)
        try await connection.start()

        try await connection.send(ClientMessage.hello(
            protocolVersion: Padlink.protocolVersion,
            deviceName: "padlink-testclient"
        ))
        for message in messages {
            try await connection.send(message)
        }
        // Give the Mac a moment to post the events before the socket closes.
        try await Task.sleep(for: .milliseconds(200))
        await connection.cancel()
    }

    private static func findMac(named serviceName: String) async throws -> NWEndpoint {
        let browser = NWBrowser(
            for: .bonjour(type: Padlink.bonjourServiceType, domain: nil),
            using: .init()
        )
        defer { browser.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ClaimFlag()
            browser.browseResultsChangedHandler = { results, _ in
                let exact = results.first { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return name == serviceName
                    }
                    return false
                }
                guard let match = exact ?? results.first else { return }
                guard resumed.claim() else { return }
                // The whole point of this tool is telling "the Mac is wrong" apart
                // from "the iPad is wrong". Falling back to a different Mac in
                // silence would produce a bare TLS failure with no explanation, so
                // say plainly when the chosen service is not the paired one.
                if exact == nil, case let .service(name, _, _, _) = match.endpoint {
                    // The parentheses matter. Member access binds tighter than
                    // `+`, so `a + b.utf8` would ask for String + UTF8View.
                    FileHandle.standardError.write(Data((
                        "Warning: paired service \"\(serviceName)\" not found. "
                        + "Falling back to \"\(name)\", whose key will probably not match.\n"
                    ).utf8))
                }
                continuation.resume(returning: match.endpoint)
            }
            browser.start(queue: .global())

            Task {
                try? await Task.sleep(for: .seconds(10))
                guard resumed.claim() else { return }
                continuation.resume(throwing: TestClientError.macNotFound)
            }
        }
    }
}
