// Padlink/PadlinkMac/PadlinkService.swift
import ApplicationServices
import Foundation
import Network
import PadlinkCore
import Security

/// What the read loop did with a message that drives input.
enum InputDisposition: Equatable {
    /// Handed to the synthesizer.
    case routed
    /// The peer tried to drive input before it sent `hello`. Nothing was
    /// synthesized, and the connection must be torn down.
    case rejectedBeforeHandshake
}

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
    @Published private(set) var completedPairings = 0

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

    /// The pre-shared key identities the **running** listener was built for.
    ///
    /// `acceptedKeys` is what this object intends to accept;
    /// `listeningIdentities` is what is really on the socket. They drift apart
    /// whenever a rebuild is skipped or fails, which is exactly the shape of a
    /// pairing key outliving its window, so the two are kept separate and
    /// asserted on separately.
    private(set) var listeningIdentities: [Data] = []

    /// The one key identity a listener built for `keys` can vouch for, or nil
    /// when it can vouch for nothing.
    ///
    /// A listener holding exactly one pre-shared key is proof: a TLS 1.2
    /// pre-shared key handshake against it cannot complete without that key.
    /// Two keys is not proof, because either could have been used, and
    /// Network.framework will not say which. Reporting one of them anyway
    /// would be a check that verifies nothing.
    static func soleIdentity(of keys: [TLSPSK]) -> Data? {
        keys.count == 1 ? keys[0].identity : nil
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
        listeningIdentities = []
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
        do {
            try reloadAcceptedKeys()
            try restartListener()
        } catch {
            // Failing to close the pairing window has to be loud, and it has to
            // fail closed. `reloadAcceptedKeys` assigns nothing when it throws,
            // so `acceptedKeys` would still hold the candidate, and the running
            // listener would still accept it, while the UI reported the window
            // shut. A live pairing key that outlives the window the user
            // believes expired is the worst outcome available here, so drop
            // every key and stop listening instead. Reconnecting a paired iPad
            // then needs a restart of the app, which is visible and recoverable.
            acceptedKeys = []
            listener?.cancel()
            listener = nil
            listeningIdentities = []
            state = .failed("Could not close the pairing window: \(Self.readable(error))")
            return
        }
        if case .connected = state {} else { state = .idle }
    }

    /// Which pre-shared keys the listener will accept.
    ///
    /// While a pairing window is open this is **only** the candidate, not the
    /// stored pairings as well. That exclusivity is what makes the promotion
    /// check in `promoteCandidateIfNeeded` mean anything: Network.framework
    /// offers no way to read the pre-shared key identity an established
    /// `NWConnection` actually negotiated, so the only honest evidence of which
    /// key a peer used is that the listener which accepted it knew exactly one.
    ///
    /// The cost is real and deliberate: for the length of the window an already
    /// paired iPad cannot make a *new* connection. A connection it already has
    /// keeps running, because rebuilding the listener never touches
    /// `self.connection`, and the window now closes the moment the pairing
    /// lands rather than always running the full 120 seconds.
    private func reloadAcceptedKeys() throws {
        if let candidate {
            acceptedKeys = [candidate.psk]
        } else {
            acceptedKeys = try store.loadAll().map(TLSPSK.init(record:))
        }
    }

    /// Pre-shared keys are fixed when `NWParameters` is created, so any change
    /// to the accepted set means a new listener. This only stops the listener
    /// from accepting new inbound connections; any connection already
    /// established keeps running, because rebuilding never touches
    /// `self.connection`.
    private func restartListener() throws {
        listener?.cancel()
        // Cleared first, and restored only once a listener is actually running,
        // so a throw part way through cannot leave this claiming the socket
        // still accepts keys it does not.
        listeningIdentities = []

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
        // Captured now, from the key set this listener is being built for. If
        // that set holds exactly one key, then a peer this listener accepts
        // completed a TLS handshake against that one key and no other, so the
        // pre-shared key identity is implied by which listener let it in.
        // Anything else is ambiguous and reported as nil.
        //
        // This is the only way to know. `sec_protocol_metadata_access_pre_
        // shared_keys` reports the PSKs *configured locally*, not the one
        // negotiated: measured on a two-key loopback listener, the server saw
        // both identities while the client, which had registered one, saw one.
        // Network.framework exposes no other accessor.
        let soleIdentity = Self.soleIdentity(of: acceptedKeys)
        newListener.newConnectionHandler = { [weak self] raw in
            // Retaining is mandatory: without it ARC frees the connection
            // mid-handshake and it silently never completes.
            Task { @MainActor in self?.accept(raw, acceptedIdentity: soleIdentity) }
        }
        newListener.start(queue: .main)
        listener = newListener
        listeningIdentities = acceptedKeys.map(\.identity)
    }

    /// `acceptedIdentity` is the single pre-shared key identity the listener
    /// that accepted this connection was built for, or nil if that listener
    /// accepted more than one key. It travels down the call chain as a
    /// parameter rather than as a stored property on purpose: a superseded
    /// connection's read loop outlives `self.connection`, so a stored value
    /// would describe the wrong session exactly when it matters.
    private func accept(_ raw: NWConnection, acceptedIdentity: Data?) {
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
            await self?.readLoop(wrapped, acceptedIdentity: acceptedIdentity)
        }
    }

    private func readLoop(_ wrapped: PadlinkConnection, acceptedIdentity: Data?) async {
        // Per connection, and deliberately a local rather than a property on
        // self. A superseded connection's read loop outlives `self.connection`,
        // so a stored flag would describe the wrong session exactly when it
        // matters, in the same way `acceptedIdentity` would.
        var helloReceived = false

        readLoop: for await frame in await wrapped.incoming {
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
                helloReceived = true
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
                    promoteCandidateIfNeeded(
                        deviceName: deviceName,
                        acceptedIdentity: acceptedIdentity
                    )
                }

            case let .ping(seq):
                try? await wrapped.send(ServerMessage.pong(seq: seq))

            default:
                guard deliverInput(message, helloReceived: helloReceived) == .routed else {
                    // Closed, not ignored. Ignoring bounds nothing: the
                    // watchdog above counts *any* frame as proof of life, so a
                    // peer that streams pointer messages and never says hello
                    // would hold the single connection slot for as long as it
                    // liked, and `accept()` gives that slot to whoever
                    // connects last. Ignoring would turn "drives input without
                    // a handshake" into "keeps the real iPad out", which is
                    // worse, not better.
                    //
                    // Closing is also what the codebase already does to a peer
                    // that gets the protocol wrong: an oversized frame sets
                    // `CloseReason.framingViolation` and `PadlinkConnection`
                    // cancels the socket there and then. A message arriving
                    // out of order is the same class of fault, so it gets the
                    // same answer.
                    //
                    // Nothing legitimate is broken by this. Both the iPad
                    // (`PadService.runSession`) and the test client send
                    // `hello` as the first frame after `start()`.
                    await wrapped.cancel()
                    // Labelled, because a bare `break` inside a `switch` binds
                    // to the `switch`. Without the label the loop would keep
                    // draining frames the peer had already buffered, and
                    // reject each one again.
                    break readLoop
                }
            }
        }

        let reason = await wrapped.closeReason
        endSession(isCurrentConnection: connection === wrapped, reason: reason)
    }

    /// The read loop's input path, with the socket left out.
    ///
    /// Nothing may drive the cursor or the keyboard until the peer has sent
    /// `hello` on this connection. Without that gate a device can connect on a
    /// pairing candidate's key, never say `hello`, and so never reach
    /// `promoteCandidateIfNeeded`, let the 120 second window expire, and keep
    /// controlling the Mac from a session that was never recorded as a pairing
    /// anywhere. Nothing in the app would list it, and nothing could revoke it.
    ///
    /// It takes a valid pre-shared key to get this far, so this is a paired
    /// device misbehaving rather than an outsider. That is still worth closing:
    /// the handshake is what turns a socket into a session, and what makes the
    /// pairing bookkeeping true.
    ///
    /// Internal rather than private so it can be tested without a socket, in
    /// the same way as `endSession` and `promoteCandidateIfNeeded`.
    func deliverInput(_ message: ClientMessage, helloReceived: Bool) -> InputDisposition {
        guard helloReceived else { return .rejectedBeforeHandshake }
        router.handle(message)
        return .routed
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

    /// Turns the pairing candidate into a stored pairing, but only for the one
    /// device that proved it holds the candidate's own key.
    ///
    /// The check is the whole point. Without it any connection at all promotes
    /// the candidate, so an already-paired iPad merely reconnecting during an
    /// open window turns a secret nobody ever scanned into a permanent stored
    /// credential, and the 120 second window bounds nothing.
    ///
    /// `acceptedIdentity` is the evidence, and it is second-hand on purpose:
    /// there is no first-hand source. It is the single key the accepting
    /// listener was built for, which the peer must have used because a TLS 1.2
    /// pre-shared key handshake against a one-key listener cannot complete any
    /// other way. Comparing it to the *current* candidate also closes the race
    /// where a connection accepted by the previous listener finishes its
    /// handshake after the window has already opened.
    ///
    /// Internal rather than private so it can be tested without a socket, in
    /// the same way as `endSession`.
    func promoteCandidateIfNeeded(deviceName: String, acceptedIdentity: Data?) {
        guard let candidate else { return }
        // Constant-time comparison is not needed: both sides are already known
        // to this process, and an attacker learns nothing from the timing of a
        // check on an identity they themselves supplied.
        guard acceptedIdentity == candidate.psk.identity else { return }

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

        // Announced before the reload, because the QR code on screen is a
        // permanent credential from this moment on whatever happens next. The
        // app watches this to take the window down. A counter rather than a
        // flag, so a second pairing is a second event.
        completedPairings += 1

        do {
            // The listener really does have to be rebuilt now, unlike before.
            // While the window was open it accepted the candidate and nothing
            // else, so every other paired device is locked out until this runs.
            try reloadAcceptedKeys()
            try restartListener()
        } catch {
            // Not a security failure, and nothing is dropped: the key the
            // listener still holds is the pairing that just reached disk, so
            // continuing to accept it is correct. What failed is re-reading the
            // *other* pairings, which means those devices stay locked out.
            // Visible rather than silent, because only the user can decide
            // whether to retry or restart the app.
            state = .failed("Paired, but could not reload pairings: \(Self.readable(error))")
        }
    }
}
