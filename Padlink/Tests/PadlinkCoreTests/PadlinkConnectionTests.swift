import Foundation
import Network
import Testing
@testable import PadlinkCore

private let sharedPSK = TLSPSK(
    identity: Data(repeating: 0x0F, count: 8),
    key: Data(repeating: 0xF0, count: 32)
)

/// Swift 6 forbids mutating a captured local from a @Sendable state handler,
/// and accepted connections must be retained or ARC frees them mid-handshake.
/// This box covers both needs. Same shape as Task 9's TransportTests.swift.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Brings up a listener and one connected client, both wrapped.
private func connectedPair() async throws -> (
    server: PadlinkConnection,
    client: PadlinkConnection,
    listener: NWListener
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

    return (server, client, listener)
}

@Test func aClientMessageArrivesWholeAtTheServer() async throws {
    let (server, client, listener) = try await connectedPair()
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
    let (server, client, listener) = try await connectedPair()
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
    let (server, client, listener) = try await connectedPair()
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
    let (server, client, listener) = try await connectedPair()
    defer { listener.cancel() }

    let sent = ServerMessage.helloAck(protocolVersion: 1, accessibilityGranted: false)
    try await server.send(sent)

    var iterator = await client.incoming.makeAsyncIterator()
    let frame = await iterator.next()
    #expect(try ServerMessageCodec.decode(#require(frame)) == sent)

    await client.cancel()
    await server.cancel()
}
