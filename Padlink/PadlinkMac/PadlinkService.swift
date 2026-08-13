// Padlink/PadlinkMac/PadlinkService.swift
import ApplicationServices
import Foundation
import Network
import PadlinkCore

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
    private var acceptedConnections: [NWConnection] = []
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
        acceptedConnections.removeAll()
        // Captured before nulling out `connection`. `Task { }` only runs once
        // `stop()` returns control to the MainActor, so reading `connection`
        // inside the closure instead of capturing it here would always see
        // nil and never actually cancel anything.
        let connectionToStop = connection
        connection = nil
        Task { await connectionToStop?.cancel() }
        router.releaseEverything()
    }

    func beginPairing() throws -> PairingPayload {
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
    /// to the accepted set means a new listener. Live connections are dropped,
    /// which is acceptable because the user has deliberately started pairing.
    private func restartListener() throws {
        listener?.cancel()
        acceptedConnections.removeAll()

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
        acceptedConnections.append(raw)
        let wrapped = PadlinkConnection(connection: raw)
        connection = wrapped

        Task { [weak self] in
            do {
                try await wrapped.start()
            } catch {
                await MainActor.run { self?.state = .failed(String(describing: error)) }
                return
            }
            await self?.readLoop(wrapped)
        }
    }

    private func readLoop(_ wrapped: PadlinkConnection) async {
        for await frame in await wrapped.incoming {
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
                promoteCandidateIfNeeded(deviceName: deviceName)

            case let .ping(seq):
                try? await wrapped.send(ServerMessage.pong(seq: seq))

            default:
                router.handle(message)
            }
        }

        // The stream finishing is the signal that the connection is gone, and
        // therefore the signal to release any held button or modifier.
        router.releaseEverything()
        let reason = await wrapped.closeReason
        connection = nil
        if case .connected = state {
            state = reason == .framingViolation ? .failed("framing violation") : .idle
        }
    }

    /// A successful connection during a pairing window promotes the candidate
    /// to a stored pairing, and rebuilds the listener once more.
    private func promoteCandidateIfNeeded(deviceName: String) {
        guard let candidate else { return }
        let record = PairingRecord(
            id: candidate.payload.pairingID,
            secret: candidate.payload.secret,
            peerName: deviceName,
            serviceName: candidate.payload.serviceName,
            pairedAt: Date()
        )
        try? store.save(record)

        pairingTimer?.invalidate()
        pairingTimer = nil
        self.candidate = nil
        try? reloadAcceptedKeys()
    }
}
