import Foundation
import Network

/// The underlying error is stored as text rather than as `any Error`, because
/// `any Error` is not Sendable and this type crosses actor boundaries.
public enum ConnectionError: Error, Equatable, Sendable {
    case notReady
    case failed(String)
    /// The encoded payload is larger than `FrameParser.maxFrameSize`. Sending
    /// it anyway would produce a frame the receiving peer's `FrameParser`
    /// rejects as `FramingError.frameTooLarge`, which the peer cannot tell
    /// apart from a hostile connection and answers by tearing the connection
    /// down. Caught here, before the frame is ever sent.
    case messageTooLarge(Int)
}

/// Why a `PadlinkConnection` is gone, so a consumer can tell a normal
/// disconnect apart from a hostile peer or a network failure and show the
/// right message (for example "Mac asleep or unreachable" versus a rejected
/// pre-shared key).
public enum CloseReason: Equatable, Sendable {
    /// The peer closed the connection normally (TCP FIN, no error).
    case peerClosed
    /// The peer sent a frame larger than `FrameParser.maxFrameSize`. Treated
    /// as hostile or broken, never as a normal disconnect.
    case framingViolation
    /// `NWConnection` reported `.failed` or `.waiting` with the given
    /// description. `.waiting` is included because a rejected pre-shared key
    /// surfaces there, not in `.failed`.
    case transportFailed(String)
    /// A local caller invoked `cancel()`.
    case cancelled
}

/// A framed message connection over an `NWConnection`.
///
/// It hands out whole frames as `Data` rather than typed messages, because the
/// Mac decodes `ClientMessage` and the iPad decodes `ServerMessage`. Staying
/// direction-agnostic lets both apps share this one implementation.
///
/// The `NWConnection` passed to `init` must be retained by the caller for the
/// lifetime of the connection, including one a listener's
/// `newConnectionHandler` accepted. `PadlinkConnection` does not do this for
/// you: ARC will free an unretained `NWConnection` mid-handshake and the
/// connection will silently never complete.
public actor PadlinkConnection {
    private let connection: NWConnection
    private var parser = FrameParser()
    private let queue = DispatchQueue(label: "com.hengkysandy.padlink.connection")

    private var continuation: AsyncStream<Data>.Continuation?
    private let stream: AsyncStream<Data>

    /// Why the connection ended, or nil while it is still live. Set before
    /// `incoming` finishes, on every termination path.
    public private(set) var closeReason: CloseReason?

    public init(connection: NWConnection) {
        self.connection = connection
        var capturedContinuation: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    /// Whole frames from the peer. **The stream finishing means the connection
    /// is gone**, which is the signal to release every held key and button.
    ///
    /// `AsyncStream` supports exactly one iterator: a second consumer would
    /// split frames between them rather than each seeing every frame. Only
    /// one consumer may iterate this stream.
    public var incoming: AsyncStream<Data> { stream }

    public func start() async throws {
        try await waitUntilReady()
        installPostReadyStateHandler()
        receiveLoop()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Box(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                case .cancelled:
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: ConnectionError.notReady)
                case .waiting(let error):
                    // A rejected pre-shared key surfaces here, not in .failed,
                    // and Network.framework then retries forever. Without this
                    // case the connection attempt hangs instead of throwing.
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Replaces the `waitUntilReady` handler once the connection is ready, so
    /// a later `.failed` or `.waiting` is observed instead of being swallowed
    /// by that handler's own "already resumed" guard. This is the only source
    /// of `closeReason` for a failure that Network.framework reports through
    /// `stateUpdateHandler` rather than through the receive completion.
    private func installPostReadyStateHandler() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handlePostReadyState(state) }
        }
    }

    private func handlePostReadyState(_ state: NWConnection.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            guard closeReason == nil else { return }
            closeReason = .transportFailed(String(describing: error))
            finish()
            connection.cancel()
        default:
            break
        }
    }

    // Not `nonisolated`. `NWConnection` is not Sendable, so touching it from a
    // nonisolated context fails under Swift 6 strict concurrency. Keeping this
    // actor-isolated means only the @Sendable completion closure crosses out,
    // and it hops straight back in through a Task.
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: (any Error)?) {
        if let data, !data.isEmpty {
            parser.append(data)
            do {
                while let frame = try parser.nextFrame() {
                    continuation?.yield(frame)
                }
            } catch {
                // An oversized frame means the peer is broken or hostile.
                if closeReason == nil { closeReason = .framingViolation }
                finish()
                connection.cancel()
                return
            }
        }

        if isComplete || error != nil {
            if closeReason == nil {
                closeReason = error.map { .transportFailed(String(describing: $0)) } ?? .peerClosed
            }
            finish()
            connection.cancel()
            return
        }

        receiveLoop()
    }

    public func send(_ message: ClientMessage) async throws {
        try await sendFrame(ClientMessageCodec.encode(message))
    }

    public func send(_ message: ServerMessage) async throws {
        try await sendFrame(ServerMessageCodec.encode(message))
    }

    private func sendFrame(_ payload: Data) async throws {
        guard payload.count <= FrameParser.maxFrameSize else {
            throw ConnectionError.messageTooLarge(payload.count)
        }
        let framed = Framer.frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func cancel() {
        if closeReason == nil { closeReason = .cancelled }
        finish()
        connection.cancel()
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }
}
