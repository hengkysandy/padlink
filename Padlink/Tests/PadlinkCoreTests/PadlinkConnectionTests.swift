import Foundation
import Network
import Testing
@testable import PadlinkCore

private let sharedPSK = TLSPSK(
    identity: Data(repeating: 0x0F, count: 8),
    key: Data(repeating: 0xF0, count: 32)
)

/// Brings up a listener and one connected client, both wrapped. Also returns
/// the raw client `NWConnection` so tests can write bytes directly to the
/// wire, bypassing `Framer`, to exercise error paths `PadlinkConnection`
/// itself never produces.
private func connectedPair() async throws -> (
    server: PadlinkConnection,
    client: PadlinkConnection,
    listener: NWListener,
    rawClient: NWConnection
) {
    let listener = try NWListener(
        using: PadlinkTransport.listenerParameters(psks: [sharedPSK]),
        on: 0
    )

    let serverBox = AsyncStream<NWConnection>.makeStream()
    listener.newConnectionHandler = { serverBox.continuation.yield($0) }

    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
        let resumed = Box(false)
        listener.stateUpdateHandler = { state in
            guard !resumed.value else { return }
            switch state {
            case .ready:
                resumed.value = true
                continuation.resume(returning: listener.port!)
            case .failed(let error):
                resumed.value = true
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: .global())
    }

    let rawClient = NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PadlinkTransport.connectionParameters(psk: sharedPSK)
    )
    let client = PadlinkConnection(connection: rawClient)

    // `client.start()` cannot be awaited to completion before the server side
    // is started. A TLS handshake needs both peers pumping I/O, and
    // NWConnection only does that once `.start(queue:)` runs, so awaiting the
    // client first would leave its ClientHello unanswered forever. Starting it
    // concurrently lets the listener's accept, this call, and the server's
    // start all proceed together.
    async let clientStart: Void = client.start()

    var iterator = serverBox.stream.makeAsyncIterator()
    guard let rawServer = await iterator.next() else {
        throw CancellationError()
    }
    let server = PadlinkConnection(connection: rawServer)
    try await server.start()
    try await clientStart

    return (server, client, listener, rawClient)
}

/// Awaits the first element from `stream`, or `nil` if `timeoutSeconds`
/// elapses first.
///
/// The outer optional distinguishes "timed out" (`nil`) from "got a result"
/// (`.some`); the inner optional is `iterator.next()`'s own result, where
/// `nil` means the stream finished. Used so a regression that leaves
/// `incoming` hanging fails the test instead of stalling the whole suite.
private func firstElement(
    from stream: AsyncStream<Data>,
    timeoutSeconds: Double
) async -> Data?? {
    let resumed = Box(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Data??, Never>) in
        Task {
            var iterator = stream.makeAsyncIterator()
            let value = await iterator.next()
            guard !resumed.value else { return }
            resumed.value = true
            continuation.resume(returning: .some(value))
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !resumed.value else { return }
            resumed.value = true
            continuation.resume(returning: .none)
        }
    }
}

@Test func aClientMessageArrivesWholeAtTheServer() async throws {
    let (server, client, listener, _) = try await connectedPair()
    defer { listener.cancel() }

    let sent = ClientMessage.keyCode(key: .c, isDown: true, modifiers: [.command])
    try await client.send(sent)

    var iterator = await server.incoming.makeAsyncIterator()
    let frame = await iterator.next()
    #expect(try ClientMessageCodec.decode(#require(frame)) == sent)

    await client.cancel()
    await server.cancel()
}

@Test func manyMessagesArriveInOrder() async throws {
    // Proves the framing survives the stream being chopped up by TCP.
    let (server, client, listener, _) = try await connectedPair()
    defer { listener.cancel() }

    let sent = (0 ..< 200).map {
        ClientMessage.pointerMove(dx: Int16($0), dy: Int16(-$0), dtMicros: 16_666)
    }
    for message in sent {
        try await client.send(message)
    }

    var received: [ClientMessage] = []
    var iterator = await server.incoming.makeAsyncIterator()
    while received.count < sent.count, let frame = await iterator.next() {
        received.append(try ClientMessageCodec.decode(frame))
    }
    #expect(received == sent)

    await client.cancel()
    await server.cancel()
}

@Test func theIncomingStreamFinishesWhenThePeerDisconnects() async throws {
    // This is the release-everything seam. When this stream ends, the Mac must
    // release every held mouse button and modifier, or the user is left with a
    // stuck Cmd key.
    let (server, client, listener, _) = try await connectedPair()
    defer { listener.cancel() }

    try await client.send(.pointerButton(button: .left, isDown: true))

    var iterator = await server.incoming.makeAsyncIterator()
    _ = await iterator.next()

    await client.cancel()

    // The stream must finish rather than hang forever.
    let finished = await iterator.next()
    #expect(finished == nil)

    await server.cancel()
}

@Test func aServerMessageArrivesWholeAtTheClient() async throws {
    let (server, client, listener, _) = try await connectedPair()
    defer { listener.cancel() }

    let sent = ServerMessage.helloAck(protocolVersion: 1, accessibilityGranted: false)
    try await server.send(sent)

    var iterator = await client.incoming.makeAsyncIterator()
    let frame = await iterator.next()
    #expect(try ServerMessageCodec.decode(#require(frame)) == sent)

    await client.cancel()
    await server.cancel()
}

@Test func aFramingErrorFinishesTheIncomingStream() async throws {
    // This is the third route to the release-everything seam, alongside a
    // peer disconnect and a local cancel. A hostile or broken peer that sends
    // an oversized length prefix must also finish `incoming`, or the Mac
    // never releases a held button when a malformed peer wedges the wire.
    let (server, client, listener, rawClient) = try await connectedPair()
    defer { listener.cancel() }

    // 65537, one byte over FrameParser.maxFrameSize (65536), written directly
    // to the wire as a raw 4-byte big-endian length prefix. `Framer.frame`
    // never produces an oversized prefix itself, so the only way to exercise
    // this path through a real NWConnection is to bypass it.
    let oversizedLengthPrefix = Data([0x00, 0x01, 0x00, 0x01])
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        rawClient.send(content: oversizedLengthPrefix, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }

    let stream = await server.incoming
    let result = await firstElement(from: stream, timeoutSeconds: 5)

    switch result {
    case .some(.none):
        break  // The stream finished, as required.
    case .some(.some):
        Issue.record("expected the stream to finish on an oversized frame, but it yielded data")
    case .none:
        Issue.record("timed out waiting for the stream to finish; the framing-error path may not be closing the connection")
    }

    await client.cancel()
    await server.cancel()
}
