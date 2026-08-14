// Padlink/PadlinkMac/PadlinkService.swift
import ApplicationServices
import Foundation
import Network
import PadlinkCore
import Security

enum ServiceState: Equatable {
    case idle
    case pairing(expiresAt: Date)
    case connected(deviceName: String)
    case failed(String)
}

/// Owns the listener, the current connection, and the pairing state.
@MainActor
final class PadlinkService: ObservableObject {
    @Published private(set) var state: ServiceState = .idle

    private let store: any PairingStore
    private let router: MessageRouter
    private let macName: String

    private var listener: NWListener?
    private var connection: PadlinkConnection?
    private var watchdog: ConnectionWatchdog?
    private var acceptedKeys: [TLSPSK] = []
    private var candidate: (payload: PairingPayload, psk: TLSPSK)?
    private var pairingTimer: Timer?

    static let pairingWindow: TimeInterval = 120

    init(store: any PairingStore, router: MessageRouter, macName: String) {
        self.store = store
        self.router = router
        self.macName = macName
    }

    // Test hooks. The socket path itself is proven end to end in Task 12.
    var acceptedKeysForTesting: [TLSPSK] { acceptedKeys }
    func reloadAcceptedKeysForTesting() throws { try reloadAcceptedKeys() }

    func start() async {
        do {
            try reloadAcceptedKeys()
            try restartListener()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func stop() {
        pairingTimer?.invalidate()
        pairingTimer = nil
        listener?.cancel()
        listener = nil
        // Captured before nulling out `connection`. `Task { }` only runs once
        // `stop()` returns control to the MainActor, so reading `connection`
        // inside the closure instead of capturing it here would always see
        // nil and never actually cancel anything.
        stopWatchdog()
        let connectionToStop = connection
        connection = nil
        Task { await connectionToStop?.cancel() }
        router.releaseEverything()
    }

    func beginPairing() throws -> PairingPayload {
        do {
            return try makePairingCandidate()
        } catch {
            // Never fail silently here. The menu closes the instant the button
            // is clicked, so without this the user sees nothing happen at all
            // and has nothing to act on. The menu already renders `.failed`.
            candidate = nil
            state = .failed(Self.readable(error))
            throw error
        }
    }

    private func makePairingCandidate() throws -> PairingPayload {
        let payload = PairingPayload(
            pairingID: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            macName: macName,
            serviceName: macName
        )
        let psk = TLSPSK(identity: payload.pairingID.bytes, key: payload.secret.bytes)
        candidate = (payload, psk)

        try reloadAcceptedKeys()
        try restartListener()

        let expiry = Date().addingTimeInterval(Self.pairingWindow)
        state = .pairing(expiresAt: expiry)

        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pairingWindow,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelPairing() }
        }

        return payload
    }

    /// Turns an error into something a person can act on.
    ///
    /// A raw `OSStatus` is a bare number, and the number is the only part that
    /// says what actually went wrong, so it is always kept. The Keychain codes
    /// worth naming are the ones this app can realistically hit.
    static func readable(_ error: Error) -> String {
        guard case let KeychainError.unexpectedStatus(status) = error else {
            return String(describing: error)
        }
        let detail: String
        switch status {
        case errSecMissingEntitlement:
            detail = "the app is not signed for Keychain access"
        case errSecUserCanceled:
            detail = "the Keychain prompt was dismissed"
        case errSecAuthFailed:
            detail = "the Keychain refused access"
        case errSecInteractionNotAllowed:
            detail = "the Keychain is locked"
        default:
            detail = "Keychain error"
        }
        return "\(detail) (\(status))"
    }

    func cancelPairing() {
        pairingTimer?.invalidate()
        pairingTimer = nil
        candidate = nil
        try? reloadAcceptedKeys()
        try? restartListener()
        if case .connected = state {} else { state = .idle }
    }

    /// Stored pairings, plus the pairing candidate while a pairing window is open.
    private func reloadAcceptedKeys() throws {
        var keys = try store.loadAll().map(TLSPSK.init(record:))
        if let candidate { keys.append(candidate.psk) }
        acceptedKeys = keys
    }

    /// Pre-shared keys are fixed when `NWParameters` is created, so any change
    /// to the accepted set means a new listener. This only stops the listener
    /// from accepting new inbound connections; any connection already
    /// established keeps running, because rebuilding never touches
    /// `self.connection`.
    private func restartListener() throws {
        listener?.cancel()

        guard acceptedKeys.isEmpty == false else {
            listener = nil
            return
        }

        let newListener = try NWListener(
            using: PadlinkTransport.listenerParameters(psks: acceptedKeys)
        )
        newListener.service = NWListener.Service(
            name: macName,
            type: Padlink.bonjourServiceType
        )
        newListener.newConnectionHandler = { [weak self] raw in
            // Retaining is mandatory: without it ARC frees the connection
            // mid-handshake and it silently never completes.
            Task { @MainActor in self?.accept(raw) }
        }
        newListener.start(queue: .main)
        listener = newListener
    }

    private func accept(_ raw: NWConnection) {
        // Only one controlling device at a time. A second connection is most
        // often the same device reconnecting after a Wi-Fi drop or a sleep
        // and wake, before its old socket has finished dying, so the old
        // connection is torn down in favour of the new one rather than
        // rejecting the new one. Rejecting would leave the user stuck if the
        // old socket is a zombie that never fails on its own.
        if let existing = connection {
            Task { await existing.cancel() }
        }

        let wrapped = PadlinkConnection(connection: raw)
        connection = wrapped

        // One watchdog per connection, started before the handshake. A peer
        // that completes TLS and then goes silent without ever saying `hello`
        // would otherwise hold the single connection slot forever.
        stopWatchdog()
        let newWatchdog = ConnectionWatchdog { [weak self] in
            // Identity-checked here rather than inside `peerWentSilent`, so
            // that method stays a plain "the peer is gone, clean up" and can
            // be tested without a socket.
            guard let self, self.connection === wrapped else { return }
            self.peerWentSilent()
        }
        newWatchdog.start()
        watchdog = newWatchdog

        Task { [weak self] in
            do {
                try await wrapped.start()
            } catch {
                await MainActor.run {
                    // A superseded connection's cancellation surfaces here as
                    // a thrown error (PadlinkConnection.waitUntilReady's
                    // .cancelled case). Only report it if this connection is
                    // still the current one, or a dying predecessor's
                    // cancellation overwrites the live successor's already-
                    // published state.
                    guard self?.connection === wrapped else { return }
                    self?.state = .failed(String(describing: error))
                }
                return
            }
            await self?.readLoop(wrapped)
        }
    }

    private func readLoop(_ wrapped: PadlinkConnection) async {
        for await frame in await wrapped.incoming {
            // A successor may have superseded this connection while a frame
            // was already sitting in the stream's buffer. Stop processing as
            // soon as that is true, rather than only at the end of the loop,
            // so a stale buffered frame cannot drive input or overwrite
            // state through the successor's now-current session.
            guard connection === wrapped else { break }

            // Before decoding, and outside the `try?`. A frame this build
            // cannot read still proves the peer is alive and still talking,
            // and a newer iPad may send message types this build has never
            // heard of. Counting only decodable frames would let a newer peer
            // be declared dead for speaking a dialect we do not know.
            watchdog?.noteFrameReceived()

            guard let message = try? ClientMessageCodec.decode(frame) else { continue }

            switch message {
            case let .hello(_, deviceName):
                state = .connected(deviceName: deviceName)
                // Reported so the iPad can say "grant Accessibility on your
                // Mac" instead of appearing broken when nothing happens.
                try? await wrapped.send(ServerMessage.helloAck(
                    protocolVersion: Padlink.protocolVersion,
                    accessibilityGranted: AXIsProcessTrusted()
                ))
                // Re-checked after the `await` above: a successor may have
                // taken over during the send, and promoting writes `state`
                // on a save failure. An `if` here, rather than `guard ...
                // break`, avoids binding the `break` to the `switch` instead
                // of the `for` loop; skipping the call is all that is
                // needed, since nothing else in this case depends on it.
                if connection === wrapped {
                    promoteCandidateIfNeeded(deviceName: deviceName)
                }

            case let .ping(seq):
                try? await wrapped.send(ServerMessage.pong(seq: seq))

            default:
                router.handle(message)
            }
        }

        let reason = await wrapped.closeReason
        endSession(isCurrentConnection: connection === wrapped, reason: reason)
    }

    /// The tail of a read loop: a connection has ended, for any reason.
    ///
    /// `isCurrentConnection` is false when a successor has already replaced
    /// `self.connection` while this loop was still dying. That is the common
    /// case, not a rare one: `accept()` swaps the connection synchronously, and
    /// a Wi-Fi drop leaves the old socket with no FIN to end its stream, so the
    /// old loop usually ends *after* its replacement is already live.
    func endSession(isCurrentConnection: Bool, reason: CloseReason?) {
        // Unconditional, and above the identity guard. `MessageRouter.held` is
        // one instance for the whole process, not one per connection, so a
        // button left held by a dying session is not "the successor's" to keep:
        // it belongs to nobody, and nothing else will ever let it go.
        //
        // The cost is that if the successor has already pressed a button by
        // now, this posts a release the successor did not ask for. That is one
        // dropped click, and the iPad's next button-down fixes it. The other
        // way round leaves a mouse button stuck down at the HID level, which
        // makes the Mac's own trackpad drag too and cannot be undone from
        // inside the app. Take the recoverable failure.
        router.releaseEverything()

        // Per-connection, so identity-checked. Clearing these for a session
        // that is already gone would wipe out the live successor's state.
        guard isCurrentConnection else { return }
        stopWatchdog()
        connection = nil
        if case .connected = state {
            state = reason == .framingViolation ? .failed("framing violation") : .idle
        }
    }

    /// The iPad stopped answering the heartbeat.
    ///
    /// Reached from the watchdog, never from a frame. Tears the connection
    /// down so the listener is free for the reconnect that usually follows a
    /// Wi-Fi drop, and releases held input first, because that is the whole
    /// reason for noticing quickly.
    func peerWentSilent() {
        router.releaseEverything()
        stopWatchdog()
        let dying = connection
        connection = nil
        if case .connected = state { state = .idle }
        Task { await dying?.cancel() }
    }

    /// Tells the connected iPad that the Accessibility answer changed.
    ///
    /// `helloAck` reports it once, at handshake time. Without this the iPad
    /// keeps showing whatever was true then, so granting the permission leaves
    /// the orange warning up, and revoking it leaves a green "Connected" over
    /// a session in which nothing works.
    ///
    /// Fire and forget, and harmless with no connection: the poller behind it
    /// runs for the life of the app whether or not an iPad is attached.
    func accessibilityChanged(granted: Bool) {
        guard let connection else { return }
        Task { try? await connection.send(ServerMessage.accessibilityChanged(granted: granted)) }
    }

    private func stopWatchdog() {
        watchdog?.stop()
        watchdog = nil
    }

    /// A successful connection during a pairing window promotes the candidate
    /// to a stored pairing. No listener rebuild is needed: the promoted
    /// record carries the same id and secret as the candidate already
    /// accepted by the running listener, so the set of keys it will accept
    /// does not actually change.
    private func promoteCandidateIfNeeded(deviceName: String) {
        guard let candidate else { return }
        let record = PairingRecord(
            id: candidate.payload.pairingID,
            secret: candidate.payload.secret,
            peerName: deviceName,
            serviceName: candidate.payload.serviceName,
            pairedAt: Date()
        )

        do {
            try store.save(record)
        } catch {
            // The device is connected right now, over the candidate's key,
            // which the running listener still accepts. But this pairing did
            // not reach disk, so the candidate is kept rather than cleared:
            // clearing it here would let a later listener rebuild (any
            // pairing attempt, or a restart) silently reject a device the
            // user believes is already paired. Surfacing `.failed` instead
            // of leaving `.connected` standing means the failure is visible
            // and the user can retry pairing.
            state = .failed("Could not save pairing: \(error)")
            return
        }

        pairingTimer?.invalidate()
        pairingTimer = nil
        self.candidate = nil
        try? reloadAcceptedKeys()
    }
}
