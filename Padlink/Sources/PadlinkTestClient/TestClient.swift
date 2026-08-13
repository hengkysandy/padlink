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
    /// The saved pairing exists but cannot be used. Deliberately separate from
    /// `notPaired`: this tool's whole job is telling one kind of failure from
    /// another, so it must not blur two of its own. "You never paired" and
    /// "your saved pairing is broken" send someone looking in different places.
    case corruptState(String)
    case couldNotSave(String)
    case badPayload(String)
    case macNotFound
    case usage

    var description: String {
        switch self {
        case .notPaired:
            return "Not paired. Run: padlink-testclient pair \"<padlink://... url>\""
        case let .corruptState(detail):
            return """
                The saved pairing at \(TestClient.stateURL.path) exists but cannot be \
                used: \(detail).
                This is a problem with the test client's own state, not with the Mac \
                or the network. Pair again to replace it.
                """
        case let .couldNotSave(path):
            return "Could not write the pairing file at \(path)."
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
        let encoded = try JSONEncoder().encode(stored)

        // Created with the mode already applied, rather than written and then
        // narrowed. `Data.write(to:)` creates at 0644, so writing first and
        // calling `chmod` second leaves a window, however brief, in which a real
        // pre-shared key sits on disk readable by every account on this machine.
        // `createFile` applies the mode at open() time, so no such window exists.
        //
        // Verified: `createFile` also reapplies the mode when the file already
        // exists, so a file left at 0644 by an older build is tightened back to
        // 0600 on the next pairing rather than keeping its looser mode.
        guard FileManager.default.createFile(
            atPath: stateURL.path,
            contents: encoded,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw TestClientError.couldNotSave(stateURL.path)
        }

        // Never print the secret itself.
        print("Paired with \(payload.macName). Saved to \(stateURL.path)")
    }

    static func loadPairing() throws -> (psk: TLSPSK, serviceName: String) {
        // Absence is checked on its own, first. Past this point the file exists,
        // so every remaining failure means the saved pairing is broken rather
        // than missing, and each one says which.
        //
        // None of these messages may quote the file's contents, because those
        // contents are the key.
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw TestClientError.notPaired
        }

        guard let data = try? Data(contentsOf: stateURL) else {
            throw TestClientError.corruptState("the file could not be read")
        }
        guard let stored = try? JSONDecoder().decode(StoredPairing.self, from: data) else {
            throw TestClientError.corruptState("the JSON is malformed or has the wrong shape")
        }
        guard let id = PairingID(hexString: stored.id) else {
            throw TestClientError.corruptState("the pairing id is not valid hex")
        }
        guard let secret = PairingSecret(bytes: stored.secret) else {
            throw TestClientError.corruptState(
                "the key is not \(PairingSecret.byteCount) bytes"
            )
        }

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

        // Wait for the Mac's acknowledgement before sending anything else.
        //
        // Sending only proves the bytes reached the local socket. It does not
        // prove the Mac did anything with them. The one failure that matters
        // most here is invisible from this side: without Accessibility
        // permission macOS silently discards every synthesized event, so the
        // commands below would all report success while nothing whatsoever
        // happens on screen. That is the most likely cause of "I ran it and the
        // cursor did not move", and the Mac already tells us in `helloAck`.
        await warnIfMacCannotAct(connection)

        for message in messages {
            try await connection.send(message)
        }
        // Give the Mac a moment to post the events before the socket closes.
        try await Task.sleep(for: .milliseconds(200))
        await connection.cancel()
    }

    /// Reads the Mac's `helloAck` and complains loudly if it reports that
    /// Accessibility is not granted.
    ///
    /// Never throws. A Mac that stays silent is not worth blocking on: the
    /// commands may still work, and the timeout keeps a missing reply from
    /// hanging the tool forever.
    private static func warnIfMacCannotAct(_ connection: PadlinkConnection) async {
        let ack = await withTaskGroup(of: ServerMessage?.self) { group in
            group.addTask {
                for await frame in await connection.incoming {
                    if let message = try? ServerMessageCodec.decode(frame) { return message }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard case let .helloAck(_, accessibilityGranted) = ack else { return }
        guard !accessibilityGranted else { return }

        FileHandle.standardError.write(Data("""
            Warning: the Mac reports that Accessibility permission is NOT granted.
            It will accept these messages and then discard every one of them, so \
            nothing will move or type. This is macOS refusing, not Padlink failing.
            Fix: System Settings > Privacy & Security > Accessibility, then enable \
            PadlinkMac.

            """.utf8))
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
