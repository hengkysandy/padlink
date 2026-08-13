import Foundation
import Network

/// The underlying error is stored as text rather than as `any Error`, because
/// `any Error` is not Sendable and this type crosses actor boundaries.
public enum ConnectionError: Error, Equatable, Sendable {
    case notReady
    case failed(String)
}

/// A framed message connection over an `NWConnection`.
///
/// It hands out whole frames as `Data` rather than typed messages, because the
/// Mac decodes `ClientMessage` and the iPad decodes `ServerMessage`. Staying
/// direction-agnostic lets both apps share this one implementation.
public actor PadlinkConnection {
    private let connection: NWConnection
    private var parser = FrameParser()
    private let queue = DispatchQueue(label: "com.hengkysandy.padlink.connection")

    private var continuation: AsyncStream<Data>.Continuation?
    private let stream: AsyncStream<Data>

    public init(connection: NWConnection) {
        self.connection = connection
        var capturedContinuation: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    /// Whole frames from the peer. **The stream finishing means the connection
    /// is gone**, which is the signal to release every held key and button.
    public var incoming: AsyncStream<Data> { stream }

    public func start() async throws {
        try await waitUntilReady()
        receiveLoop()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Box(false)
            connection.stateUpdateHandler = { state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.value = true
                    continuation.resume()
                case .failed(let error):
                    resumed.value = true
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                case .cancelled:
                    resumed.value = true
                    continuation.resume(throwing: ConnectionError.notReady)
                case .waiting(let error):
                    // A rejected pre-shared key surfaces here, not in .failed,
                    // and Network.framework then retries forever. Without this
                    // case the connection attempt hangs instead of throwing.
                    resumed.value = true
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
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
                finish()
                connection.cancel()
                return
            }
        }

        if isComplete || error != nil {
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
        finish()
        connection.cancel()
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }
}
