// Padlink/PadlinkPad/PadService.swift
import Foundation
import Network
import PadlinkCore

/// Everything that can stop the iPad reaching the Mac, with the sentence that
/// tells the user what to do about it.
///
/// The messages are part of the design, not decoration. Two of the three
/// expensive traps in this app are not "the wrong thing happened", they are
/// "the right thing happened and the user was told the wrong reason", so the
/// wording is pinned by tests.
enum PadFailure: Equatable, Sendable {
    /// Nothing saved. The user has never scanned a code on this iPad.
    case notPaired
    /// Something is saved but cannot be read. A different problem from
    /// `notPaired`, and only one of the two is fixed by pairing again.
    case storeUnreadable(String)
    /// iOS is refusing local network access.
    case localNetworkDenied
    /// Nothing at all is advertising Padlink.
    case macNotFound(serviceName: String)
    /// A Mac is advertising, but not the paired one.
    case wrongMacsOnly(paired: String, seen: [String])
    /// The browser itself broke, for a reason that is not a permission.
    case browserFailed(String)
    /// The connection attempt was refused, almost always a key the Mac no
    /// longer accepts.
    case handshakeRefused(String)
    /// The connection attempt never resolved either way.
    case handshakeTimedOut
    case protocolMismatch(mac: UInt16, pad: UInt16)
    case macReportedError(code: UInt8, message: String)
    case connectionLost(String)

    var message: String {
        switch self {
        case .notPaired:
            return """
                This iPad is not paired with a Mac yet. On your Mac, click the \
                Padlink icon in the menu bar, choose "Pair a device", and scan \
                the code it shows.
                """

        case let .storeUnreadable(detail):
            return """
                This iPad has a saved pairing, but it cannot be read (\(detail)). \
                That is a problem with this iPad's stored copy, not with your Mac \
                or your network. Pair again to replace it.
                """

        case .localNetworkDenied:
            // Must not mention the network. This one is a permission, and
            // sending the user to look at their router wastes their evening.
            return """
                Padlink is not allowed to use the local network, so it cannot see \
                your Mac at all. This is a permission, not a connection problem. \
                Open Settings, then Privacy & Security, then Local Network, and \
                turn Padlink on.
                """

        case let .macNotFound(serviceName):
            // Must not mention Settings. This one really is the network.
            return """
                No Mac called "\(serviceName)" is advertising Padlink. Check that \
                this iPad and your Mac are on the same Wi-Fi network, that your \
                Mac is awake, and that Padlink is running on it.
                """

        case let .wrongMacsOnly(paired, seen):
            let list = seen.map { "\"\($0)\"" }.joined(separator: ", ")
            return """
                Found \(list) on this network, but not "\(paired)", which is the \
                Mac this iPad is paired with. If you renamed that Mac, pair again \
                so this iPad learns its new name.
                """

        case let .browserFailed(detail):
            return "Padlink could not search the local network: \(detail)."

        case let .handshakeRefused(detail):
            return """
                Your Mac refused the connection. The most likely cause is that it \
                no longer holds the pairing this iPad is using, so pair again from \
                the Mac. (\(detail))
                """

        case .handshakeTimedOut:
            // Names the pairing first on purpose. A rejected pre-shared key
            // does not fail cleanly: it leaves the connection waiting and
            // retrying, so it looks exactly like a slow network. Whoever reads
            // this message is otherwise about to spend an hour on their router.
            return """
                Your Mac did not answer in \(Int(PadService.handshakeTimeout)) \
                seconds. The most likely cause is a pairing your Mac no longer \
                accepts: a rejected key makes the connection wait forever instead \
                of failing, which looks just like a slow network. Pair again from \
                the Mac. If you have only just paired, check that the Mac is awake.
                """

        case let .protocolMismatch(mac, pad):
            return """
                Your Mac speaks Padlink protocol version \(mac) and this iPad \
                speaks version \(pad). Update whichever one is older.
                """

        case let .macReportedError(code, message):
            return "Your Mac reported an error: \(message) (code \(code))."

        case let .connectionLost(detail):
            return "The connection to your Mac ended: \(detail)."
        }
    }
}

/// What the iPad is doing, as far as the user is concerned.
enum PadState: Equatable, Sendable {
    case idle
    case searching
    case connecting
    /// `accessibilityGranted` is the Mac's answer in `helloAck`, kept on the
    /// state rather than logged, because when it is false the app works
    /// perfectly and does nothing at all.
    case connected(accessibilityGranted: Bool)
    case failed(PadFailure)

    /// True for `.connected` whatever accessibility answer it carries.
    /// Comparing against `.connected(accessibilityGranted: true)` would be
    /// wrong exactly when accessibility is the thing that went wrong.
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The banner the UI must show above everything else while connected.
    ///
    /// Without Accessibility permission macOS accepts every synthesized event
    /// and silently discards it. The iPad sends, the Mac replies, nothing
    /// moves, and every visible signal says the connection is fine, because it
    /// is. This exact confusion already cost real time in this project with the
    /// command line client.
    var accessibilityWarning: String? {
        guard case let .connected(granted) = self, granted == false else { return nil }
        return """
            Your Mac has not granted Accessibility permission to Padlink, so macOS \
            will throw away everything this iPad sends. Nothing will move or type \
            until you fix it. On the Mac: System Settings, then Privacy & Security, \
            then Accessibility, then turn PadlinkMac on.
            """
    }
}

/// Everything that can change `PadState`.
enum PadEvent: Equatable, Sendable {
    /// There is no point starting: no pairing, or an unreadable one.
    case cannotStart(PadFailure)
    case searchStarted
    case discovered(NWEndpoint)
    case discoveryFailed(PadFailure)
    /// `PadlinkConnection.start()` threw.
    case connectFailed(String)
    case handshakeTimedOut
    case received(ServerMessage)
    case disconnected(CloseReason?)
    case stopped
}

/// The pure state machine behind `PadService`.
///
/// Every rule about what state the app is in lives here, where it can be
/// tested without a socket, a Mac, or a network. `PadService` owns the I/O and
/// does no deciding of its own.
///
/// Most of these rules exist because events arrive late. A handshake timer
/// fires just after the handshake succeeded; a browser callback lands after the
/// browser was cancelled; a frame arrives from a connection that has already
/// been replaced. Each of those, unguarded, tears down something that is
/// working.
struct PadStateMachine {
    private(set) var state: PadState = .idle

    init() {}

    mutating func apply(_ event: PadEvent) {
        switch event {
        case let .cannotStart(failure):
            state = .failed(failure)

        case .searchStarted:
            state = .searching

        case .discovered:
            // Only while searching. The browser is cancelled the moment a Mac
            // is found, but a callback already on the queue still arrives, and
            // restarting the connection dance from `.connected` would drop a
            // working session.
            guard state == .searching else { return }
            state = .connecting

        case let .discoveryFailed(failure):
            guard state == .searching else { return }
            state = .failed(failure)

        case let .connectFailed(detail):
            guard state == .connecting else { return }
            state = .failed(.handshakeRefused(detail))

        case .handshakeTimedOut:
            // The timer is cancelled when the ack arrives, but cancellation
            // races with firing. Without this guard a timer that loses the race
            // by a millisecond tears down a live connection.
            guard state == .connecting else { return }
            state = .failed(.handshakeTimedOut)

        case let .received(message):
            apply(message)

        case let .disconnected(reason):
            guard state == .connecting || state.isConnected else { return }
            state = Self.stateAfterClose(reason)

        case .stopped:
            state = .idle
        }
    }

    private mutating func apply(_ message: ServerMessage) {
        switch message {
        case let .helloAck(protocolVersion, accessibilityGranted):
            // Only answers a handshake we are actually waiting for. A stray
            // frame arriving in any other state must not fabricate a
            // connection, and a second ack must not reset the accessibility
            // flag the first one reported.
            guard state == .connecting else { return }
            guard protocolVersion == Padlink.protocolVersion else {
                state = .failed(.protocolMismatch(
                    mac: protocolVersion,
                    pad: Padlink.protocolVersion
                ))
                return
            }
            state = .connected(accessibilityGranted: accessibilityGranted)

        case .pong:
            break

        case let .error(code, message):
            guard state == .connecting || state.isConnected else { return }
            state = .failed(.macReportedError(code: code, message: message))
        }
    }

    private static func stateAfterClose(_ reason: CloseReason?) -> PadState {
        switch reason {
        case .cancelled:
            // We asked for it. Showing an error for a disconnect the app
            // itself requested is how a clean shutdown looks like a fault.
            return .idle
        case .peerClosed:
            return .failed(.connectionLost("your Mac closed the connection"))
        case .framingViolation:
            return .failed(.connectionLost("your Mac sent a frame Padlink could not read"))
        case let .transportFailed(detail):
            return .failed(.connectionLost(detail))
        case nil:
            return .failed(.connectionLost("the connection ended without saying why"))
        }
    }
}

/// The iPad's side of the conversation: load the pairing, find the Mac,
/// connect, say hello, and stay connected.
///
/// Mirrors the Mac's `PadlinkService` in shape. All the deciding is in
/// `PadStateMachine`, `DiscoveryTracker`, and the two static functions below,
/// which is what makes any of this testable.
@MainActor
final class PadService: ObservableObject {
    @Published private(set) var state: PadState = .idle

    /// The paired Mac's display name, for the UI. Nil until a pairing loads.
    private(set) var pairedMacName: String?

    /// How long to browse before giving up. Matches the test client's ten
    /// seconds, which has been enough on this network every time.
    nonisolated static let searchTimeout: TimeInterval = 10
    /// How long to wait for TLS plus `helloAck`. On a LAN this is nearly
    /// instant, so a long wait means something is wrong rather than slow.
    ///
    /// It exists because a rejected pre-shared key has no clean failure: the
    /// connection sits waiting and retrying. Without a deadline, a wrong key is
    /// indistinguishable from a slow network, forever.
    nonisolated static let handshakeTimeout: TimeInterval = 8

    private let store: any PairingStore
    private let deviceName: String

    private var machine = PadStateMachine()
    private var pairing: PairingRecord?
    private var browser: MacBrowser?
    private var connection: PadlinkConnection?
    private var sessionTask: Task<Void, Never>?
    private var searchTimeoutTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var lastDiscovery: MacDiscovery = .idle
    private var wasBackgrounded = false

    /// Serialises outbound messages. Firing each send off in its own detached
    /// task would let two pointer moves race into the actor in either order,
    /// and a cursor that jitters backwards is a bug nobody would think to look
    /// for here.
    private var sendChain: Task<Void, Never> = Task {}

    init(store: any PairingStore, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
    }

    // MARK: - Pure decisions

    /// The Bonjour instance name to look for. A pairing saved without one
    /// falls back to the Mac's display name, which is what `PadlinkService`
    /// advertises when the two are the same.
    nonisolated static func serviceName(for record: PairingRecord) -> String {
        record.serviceName ?? record.peerName
    }

    /// Turns "we stopped looking" plus whatever the browser last saw into the
    /// right failure.
    ///
    /// The important case is the denial. It reaches the timeout looking exactly
    /// like nothing being found, and laundering it into `macNotFound` here
    /// would undo the work `DiscoveryTracker` did to keep them apart.
    nonisolated static func searchTimeoutFailure(
        pairedServiceName: String,
        lastSeen: MacDiscovery
    ) -> PadFailure {
        switch lastSeen {
        case .localNetworkDenied:
            return .localNetworkDenied
        case let .otherMacsOnly(names):
            return .wrongMacsOnly(paired: pairedServiceName, seen: names)
        case let .failed(detail):
            return .browserFailed(detail)
        case .idle, .searching, .found:
            return .macNotFound(serviceName: pairedServiceName)
        }
    }

    /// Whether returning to the foreground should rebuild the connection.
    ///
    /// iOS suspends a backgrounded app and tears its sockets down without
    /// telling it, so a `.connected` state that survived a background trip is
    /// usually a lie. A momentary deactivation (Control Centre, a notification
    /// banner) does not suspend anything, and reconnecting there would drop a
    /// working connection for nothing.
    nonisolated static func shouldReconnect(wasBackgrounded: Bool, state: PadState) -> Bool {
        if wasBackgrounded { return true }
        switch state {
        case .connecting, .connected:
            return false
        case .idle, .searching, .failed:
            return true
        }
    }

    // MARK: - Lifecycle

    func start() {
        teardown()

        let record: PairingRecord?
        do {
            // Newest pairing wins. The iPad pairs with one Mac at a time, and
            // if an old record is still around, the one the user just scanned
            // is the one they meant.
            record = try store.loadAll().last
        } catch {
            apply(.cannotStart(.storeUnreadable(String(describing: error))))
            return
        }

        guard let record else {
            apply(.cannotStart(.notPaired))
            return
        }

        pairing = record
        pairedMacName = record.peerName
        lastDiscovery = .idle
        apply(.searchStarted)

        let name = Self.serviceName(for: record)
        let newBrowser = MacBrowser(serviceName: name)
        newBrowser.onChange = { [weak self] discovery in
            self?.handle(discovery)
        }
        newBrowser.start()
        browser = newBrowser

        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.searchTimeout))
            guard Task.isCancelled == false, let self else { return }
            self.stopBrowsing()
            self.apply(.discoveryFailed(Self.searchTimeoutFailure(
                pairedServiceName: name,
                lastSeen: self.lastDiscovery
            )))
        }
    }

    func stop() {
        teardown()
        apply(.stopped)
    }

    func applicationDidEnterBackground() {
        wasBackgrounded = true
    }

    func applicationDidBecomeActive() {
        let reconnect = Self.shouldReconnect(wasBackgrounded: wasBackgrounded, state: state)
        wasBackgrounded = false
        guard reconnect else { return }
        start()
    }

    /// Sends a message, if there is a connection to send it on.
    ///
    /// Fire and forget by design: the trackpad produces these faster than any
    /// caller could await them, and a dropped move is corrected by the next one
    /// a few milliseconds later.
    func send(_ message: ClientMessage) {
        guard case .connected = state, let connection else { return }
        // Chained, not detached. Two independent tasks would enter the
        // connection actor in whichever order the scheduler chose, so a burst
        // of pointer moves could arrive out of order and drag the cursor
        // backwards.
        let previous = sendChain
        sendChain = Task {
            await previous.value
            try? await connection.send(message)
        }
    }

    // MARK: - Discovery

    private func handle(_ discovery: MacDiscovery) {
        lastDiscovery = discovery

        switch discovery {
        case let .found(endpoint):
            stopBrowsing()
            apply(.discovered(endpoint))
            connect(to: endpoint)

        case .localNetworkDenied:
            // Reported the moment it is known rather than at the timeout.
            // Waiting ten seconds to say "you turned this off in Settings"
            // helps nobody, and the browser will never recover on its own.
            stopBrowsing()
            apply(.discoveryFailed(.localNetworkDenied))

        case let .failed(detail):
            stopBrowsing()
            apply(.discoveryFailed(.browserFailed(detail)))

        case .idle, .searching, .otherMacsOnly:
            // Still looking. `otherMacsOnly` is not yet a failure: the paired
            // Mac may still be waking up and about to appear. It becomes the
            // failure message if the timeout arrives with it still true.
            break
        }
    }

    private func stopBrowsing() {
        searchTimeoutTask?.cancel()
        searchTimeoutTask = nil
        browser?.onChange = nil
        browser?.cancel()
        browser = nil
    }

    // MARK: - The connection

    private func connect(to endpoint: NWEndpoint) {
        guard let pairing else { return }

        let raw = NWConnection(
            to: endpoint,
            using: PadlinkTransport.connectionParameters(psk: TLSPSK(record: pairing))
        )
        let wrapped = PadlinkConnection(connection: raw)
        connection = wrapped

        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard Task.isCancelled == false, let self else { return }
            guard self.connection === wrapped else { return }
            self.apply(.handshakeTimedOut)
            self.teardownConnection()
        }

        sessionTask = Task { [weak self] in
            await self?.runSession(wrapped)
        }
    }

    /// The one and only consumer of `PadlinkConnection.incoming`.
    ///
    /// `incoming` is an `AsyncStream`, which supports exactly one iterator: a
    /// second consumer would split frames between the two rather than each
    /// seeing every frame, which looks like random message loss and is
    /// miserable to diagnose. There is one `for await` over it in this app, and
    /// it is here.
    private func runSession(_ wrapped: PadlinkConnection) async {
        do {
            try await wrapped.start()
        } catch {
            // A superseded connection's cancellation surfaces here as a thrown
            // error, so only report it if this connection is still the current
            // one. Otherwise a dying predecessor overwrites its successor's
            // state.
            guard connection === wrapped else { return }
            cancelHandshakeTimeout()
            apply(.connectFailed(String(describing: error)))
            connection = nil
            return
        }

        try? await wrapped.send(ClientMessage.hello(
            protocolVersion: Padlink.protocolVersion,
            deviceName: deviceName
        ))

        for await frame in await wrapped.incoming {
            guard connection === wrapped else { break }
            guard let message = try? ServerMessageCodec.decode(frame) else { continue }
            if case .helloAck = message { cancelHandshakeTimeout() }
            apply(.received(message))
        }

        let reason = await wrapped.closeReason
        guard connection === wrapped else { return }
        cancelHandshakeTimeout()
        connection = nil
        apply(.disconnected(reason))
    }

    private func cancelHandshakeTimeout() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
    }

    private func teardownConnection() {
        cancelHandshakeTimeout()
        sessionTask?.cancel()
        sessionTask = nil
        // Captured before clearing, for the same reason the Mac's `stop()`
        // does: the Task body runs after this function returns, so reading
        // `self.connection` inside it would always see nil.
        let dying = connection
        connection = nil
        Task { await dying?.cancel() }
    }

    private func teardown() {
        stopBrowsing()
        teardownConnection()
    }

    private func apply(_ event: PadEvent) {
        machine.apply(event)
        state = machine.state
    }
}
