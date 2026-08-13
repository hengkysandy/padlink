# Padlink Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `PadlinkCore`, the shared Swift package holding the wire protocol, framing, TLS pre-shared-key transport, pairing payload, and pure input logic, fully tested under `swift test` with no simulator and no device.

**Architecture:** One SwiftPM package with four source areas: `Protocol` (message types and a hand-written binary codec), `Transport` (Network.framework parameters and a framed connection), `Pairing` (secret generation, QR payload, storage protocol) and `Input` (pointer acceleration and key routing, both pure functions). Nothing in this package imports SwiftUI, UIKit, AppKit, or CoreGraphics event APIs, so the whole thing compiles and tests on the command line.

**Tech Stack:** Swift 6.2, SwiftPM, swift-testing (bundled with the toolchain, no dependency), Network.framework, Security framework.

**Spec:** `docs/superpowers/specs/2026-08-13-padlink-design.md`

## Global Constraints

- Package name `PadlinkCore`. Platforms: `.macOS(.v15)`, `.iOS(.v18)`.
- Swift tools version `6.2`. Strict concurrency is on by default in Swift 6 language mode. All public types must be `Sendable`.
- **No third-party dependencies.** Everything needed is in the Swift toolchain or Apple's SDKs.
- `PadlinkCore` must not import `SwiftUI`, `UIKit`, `AppKit`, `CoreGraphics`, `AVFoundation`, or `CoreImage`. If a task seems to need one, the logic belongs in an app target instead.
- Protocol version constant is `1`.
- Bonjour service type is `_padlink._tcp`. Keychain service string is `com.hengkysandy.padlink`.
- Wire format is big-endian throughout. Frames are a 4-byte big-endian length prefix followed by the payload. Frames larger than 65536 bytes are rejected.
- **Transport security is TLS 1.2 with ECDHE_PSK ciphersuites, pinned explicitly.** Not TLS 1.3. Task 0 measured this: `sec_protocol_options_add_pre_shared_key` is RFC 4279 style and TLS 1.3 fails the handshake with -9858. Pin `0xD001`, `0xCCAC`, and `0x00AA`. Pinning is required, because leaving the ciphersuite list empty also handshakes but can negotiate a plain PSK suite with no forward secrecy.
- **Any code waiting for a connection to become ready must treat `.waiting` as a failure.** Network.framework reports a failed PSK handshake as `.waiting` and then retries forever, never reaching `.failed`.
- **`NWConnection` instances must be retained** for the lifetime of the handshake, including connections accepted by a listener. ARC otherwise frees them mid-handshake and the connection silently never completes.
- `KeyModifiers` bits: 0 shift, 1 control, 2 option, 3 command, 4 function. Bits 5 to 7 are reserved and must be zero on the wire.
- The `key` field on the wire is a **Padlink key ID**, never a macOS virtual key code.
- No `try!`, no `as!`, no force unwrapping outside of tests.
- Every task ends with a commit. Commit messages use no em-dashes.

## Deviations from the spec, decided during planning

1. **The manual base32 pairing code is dropped from v1.** The spec said "the same secret as a 10-character base32 code", which is not possible: 10 base32 characters hold 50 bits and the secret is 256 bits. QR is the only pairing path in v1. If the manual path is built later, the corrected design is a **separate 80-bit secret rendered as 16 base32 characters in four groups of four**, which is short enough to type and far beyond offline brute force.
2. **`KeychainPairingStore` is not built or tested in this plan.** An unsigned `swift test` binary cannot use the data protection keychain. Core defines the `PairingStore` protocol and an in-memory implementation, both tested. The Keychain implementation is built in the app plans where code signing exists.

---

### Task 0: Spike — prove TLS pre-shared keys work, and whether several fit on one listener

This is a **throwaway spike**, not shipped code. Its output is an answer plus a working code snippet that Task 8 copies. Delete the target when the task is done.

**Files:**
- Create: `Padlink/Spike/Package.swift`
- Create: `Padlink/Spike/Sources/spike/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: an answer recorded in `NOTES.md`, and a verified working form of `sec_protocol_options_add_pre_shared_key` that Task 8 uses verbatim.

- [ ] **Step 1: Create the spike package**

```swift
// Padlink/Spike/Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "spike",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "spike")]
)
```

- [ ] **Step 2: Write the spike**

Two paired iPads are simulated by two client connections using two different pre-shared keys, both registered on one listener.

```swift
// Padlink/Spike/Sources/spike/main.swift
import Foundation
import Network

func dispatchData(_ data: Data) -> DispatchData {
    data.withUnsafeBytes { DispatchData(bytes: $0) }
}

func applyPSKs(_ options: NWProtocolTLS.Options, _ psks: [(key: Data, identity: Data)]) {
    let sec = options.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t.AES_128_GCM_SHA256)
    for psk in psks {
        sec_protocol_options_add_pre_shared_key(
            sec,
            dispatchData(psk.key) as __DispatchData,
            dispatchData(psk.identity) as __DispatchData
        )
    }
}

let keyA = Data(repeating: 0xA1, count: 32)
let idA = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
let keyB = Data(repeating: 0xB2, count: 32)
let idB = Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])

let listenerTLS = NWProtocolTLS.Options()
applyPSKs(listenerTLS, [(keyA, idA), (keyB, idB)])
let listenerParams = NWParameters(tls: listenerTLS, tcp: NWProtocolTCP.Options())

let listener = try NWListener(using: listenerParams, on: 0)
var accepted = 0
listener.newConnectionHandler = { connection in
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            accepted += 1
            print("listener: accepted connection \(accepted)")
        }
        if case .failed(let error) = state {
            print("listener: connection failed \(error)")
        }
    }
    connection.start(queue: .main)
}
listener.stateUpdateHandler = { state in
    guard case .ready = state, let port = listener.port else { return }
    print("listener ready on port \(port.rawValue)")

    for (label, psk) in [("A", (keyA, idA)), ("B", (keyB, idB))] {
        let clientTLS = NWProtocolTLS.Options()
        applyPSKs(clientTLS, [psk])
        let params = NWParameters(tls: clientTLS, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: "127.0.0.1", port: port, using: params)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: print("client \(label): READY (handshake succeeded)")
            case .failed(let error): print("client \(label): FAILED \(error)")
            default: break
            }
        }
        connection.start(queue: .main)
    }

    // A third client with a key that was never registered. This must fail.
    let badTLS = NWProtocolTLS.Options()
    applyPSKs(badTLS, [(Data(repeating: 0xCC, count: 32), Data(repeating: 0xDD, count: 8))])
    let badParams = NWParameters(tls: badTLS, tcp: NWProtocolTCP.Options())
    let bad = NWConnection(host: "127.0.0.1", port: port, using: badParams)
    bad.stateUpdateHandler = { state in
        switch state {
        case .ready: print("client BAD: READY  <-- SECURITY PROBLEM, investigate")
        case .failed(let error): print("client BAD: FAILED as expected \(error)")
        default: break
        }
    }
    bad.start(queue: .main)
}
listener.start(queue: .main)

RunLoop.main.run(until: Date().addingTimeInterval(10))
```

- [ ] **Step 3: Run it**

Run: `cd Padlink/Spike && swift run spike`

Read the output and answer three questions:
1. Do clients A and B both reach READY? If yes, several pre-shared keys on one listener work, and v1 can support several paired iPads.
2. Does the BAD client fail? It must. If it reaches READY, stop and investigate before writing any more code.
3. Did `as __DispatchData` compile? If the compiler rejected it, remove the cast and record which form worked.

- [ ] **Step 4: Record the answer**

Append to `NOTES.md` under a `## 2026-08-13 — Spike: TLS-PSK` heading: whether multiple pre-shared keys worked, whether the wrong key was rejected, and the exact working form of the `applyPSKs` function. Task 8 copies that function.

If multiple keys did **not** work, also record that v1 supports exactly one paired iPad, and that `PadlinkTransport.listenerParameters` takes a single `TLSPSK` rather than an array. Task 8 adapts.

- [ ] **Step 5: Delete the spike and commit the finding**

```bash
rm -rf Padlink/Spike
git add NOTES.md
git commit -m "Record TLS pre-shared key spike result"
```

---

### Task 1: Package scaffolding

**Files:**
- Create: `Padlink/Package.swift`
- Create: `Padlink/Sources/PadlinkCore/Padlink.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/PadlinkTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum Padlink { static let protocolVersion: UInt16, static let bonjourServiceType: String, static let keychainService: String }`. Every later task uses these constants.

- [ ] **Step 1: Write the failing test**

```swift
// Padlink/Tests/PadlinkCoreTests/PadlinkTests.swift
import Testing
@testable import PadlinkCore

@Test func exposesProtocolConstants() {
    #expect(Padlink.protocolVersion == 1)
    #expect(Padlink.bonjourServiceType == "_padlink._tcp")
    #expect(Padlink.keychainService == "com.hengkysandy.padlink")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Padlink && swift test`
Expected: FAIL. The package does not exist yet, so this fails at the manifest stage. That still counts as red.

- [ ] **Step 3: Write the manifest and the constants**

```swift
// Padlink/Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PadlinkCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PadlinkCore", targets: ["PadlinkCore"])
    ],
    targets: [
        .target(name: "PadlinkCore"),
        .testTarget(name: "PadlinkCoreTests", dependencies: ["PadlinkCore"])
    ]
)
```

```swift
// Padlink/Sources/PadlinkCore/Padlink.swift
import Foundation

/// Constants shared by both apps.
public enum Padlink {
    /// Bumped only when the wire format changes in a way older peers cannot read.
    public static let protocolVersion: UInt16 = 1
    public static let bonjourServiceType = "_padlink._tcp"
    public static let keychainService = "com.hengkysandy.padlink"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Padlink && swift test`
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Package.swift Padlink/Sources Padlink/Tests
git commit -m "Add PadlinkCore package scaffolding"
```

---

### Task 2: Byte reader and writer

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Protocol/CodecError.swift`
- Create: `Padlink/Sources/PadlinkCore/Protocol/ByteWriter.swift`
- Create: `Padlink/Sources/PadlinkCore/Protocol/ByteReader.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/ByteCodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum CodecError: Error, Equatable` with cases `truncated`, `unknownMessageType(UInt8)`, `unknownKey(UInt16)`, `unknownPointerButton(UInt8)`, `reservedModifierBitsSet(UInt8)`, `invalidUTF8`, `stringTooLong`, `trailingBytes`.
  - `struct ByteWriter` (internal) with `var data: Data`, `mutating func write(_:)` for `UInt8`, `UInt16`, `Int16`, `UInt32`, `Bool`, and `mutating func writeString(_ value: String) throws`.
  - `struct ByteReader` (internal) with `init(_ data: Data)`, `var isAtEnd: Bool`, and throwing `readUInt8`, `readUInt16`, `readInt16`, `readUInt32`, `readBool`, `readString`.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/ByteCodingTests.swift
import Foundation
import Testing
@testable import PadlinkCore

@Test func writesIntegersBigEndian() throws {
    var writer = ByteWriter()
    writer.write(UInt16(0x1234))
    writer.write(UInt32(0xDEADBEEF))
    #expect(Array(writer.data) == [0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF])
}

@Test func roundTripsEveryScalarType() throws {
    var writer = ByteWriter()
    writer.write(UInt8(200))
    writer.write(UInt16(65000))
    writer.write(Int16(-1234))
    writer.write(UInt32(4_000_000_000))
    writer.write(true)
    writer.write(false)
    try writer.writeString("héllo 🌍")

    var reader = ByteReader(writer.data)
    #expect(try reader.readUInt8() == 200)
    #expect(try reader.readUInt16() == 65000)
    #expect(try reader.readInt16() == -1234)
    #expect(try reader.readUInt32() == 4_000_000_000)
    #expect(try reader.readBool() == true)
    #expect(try reader.readBool() == false)
    #expect(try reader.readString() == "héllo 🌍")
    #expect(reader.isAtEnd)
}

@Test func readingPastTheEndThrowsTruncated() {
    var reader = ByteReader(Data([0x01]))
    #expect(throws: CodecError.truncated) {
        _ = try reader.readUInt16()
    }
}

@Test func stringWithLyingLengthThrowsTruncated() {
    // Claims 10 bytes of content but supplies 2.
    var reader = ByteReader(Data([0x00, 0x0A, 0x61, 0x62]))
    #expect(throws: CodecError.truncated) {
        _ = try reader.readString()
    }
}

@Test func invalidUTF8ThrowsInvalidUTF8() {
    // Length 2, then a lone continuation byte pair that is not valid UTF-8.
    var reader = ByteReader(Data([0x00, 0x02, 0xC3, 0x28]))
    #expect(throws: CodecError.invalidUTF8) {
        _ = try reader.readString()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter ByteCoding`
Expected: FAIL, "cannot find 'ByteWriter' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Protocol/CodecError.swift
import Foundation

public enum CodecError: Error, Equatable, Sendable {
    /// The buffer ended before the value did.
    case truncated
    case unknownMessageType(UInt8)
    case unknownKey(UInt16)
    case unknownPointerButton(UInt8)
    /// Bits 5 to 7 of the modifier bitfield must be zero.
    case reservedModifierBitsSet(UInt8)
    case invalidUTF8
    case stringTooLong
    /// The message decoded, but bytes were left over. Treated as corruption.
    case trailingBytes
}
```

```swift
// Padlink/Sources/PadlinkCore/Protocol/ByteWriter.swift
import Foundation

/// Big-endian byte writer. Internal on purpose: the wire format is an
/// implementation detail of this package.
struct ByteWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: Int16) {
        write(UInt16(bitPattern: value))
    }

    mutating func write(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: Bool) {
        write(value ? UInt8(1) : UInt8(0))
    }

    /// UInt16 byte-count prefix, then UTF-8.
    mutating func writeString(_ value: String) throws {
        let utf8 = Data(value.utf8)
        guard utf8.count <= Int(UInt16.max) else { throw CodecError.stringTooLong }
        write(UInt16(utf8.count))
        data.append(utf8)
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Protocol/ByteReader.swift
import Foundation

/// Big-endian byte reader. Every read throws rather than trapping, because
/// the bytes come from the network and cannot be trusted.
struct ByteReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool { index >= data.endIndex }

    private var remaining: Int { data.distance(from: index, to: data.endIndex) }

    mutating func readUInt8() throws -> UInt8 {
        guard index < data.endIndex else { throw CodecError.truncated }
        let byte = data[index]
        index = data.index(after: index)
        return byte
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = try readUInt8()
        let low = try readUInt8()
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            value = (value << 8) | UInt32(try readUInt8())
        }
        return value
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt16())
        guard remaining >= length else { throw CodecError.truncated }
        let end = data.index(index, offsetBy: length)
        let slice = data[index ..< end]
        index = end
        guard let string = String(data: slice, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return string
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter ByteCoding`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Protocol Padlink/Tests/PadlinkCoreTests/ByteCodingTests.swift
git commit -m "Add big-endian byte reader and writer"
```

---

### Task 3: Message types and codec

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Protocol/KeyModifiers.swift`
- Create: `Padlink/Sources/PadlinkCore/Protocol/PadlinkKey.swift`
- Create: `Padlink/Sources/PadlinkCore/Protocol/Messages.swift`
- Create: `Padlink/Sources/PadlinkCore/Protocol/MessageCodec.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift`

**Interfaces:**
- Consumes: `ByteWriter`, `ByteReader`, `CodecError` from Task 2.
- Produces:
  - `public struct KeyModifiers: OptionSet, Sendable, Hashable` with `shift`, `control`, `option`, `command`, `function`, and `static let reservedMask`.
  - `public enum PadlinkKey: UInt16, Sendable, Hashable, CaseIterable`, full case list below.
  - `public enum PointerButton: UInt8, Sendable, Hashable, CaseIterable { case left = 0, right = 1 }`
  - `public enum ClientMessage: Sendable, Equatable` and `public enum ServerMessage: Sendable, Equatable`, cases below.
  - `public enum ClientMessageCodec` and `public enum ServerMessageCodec`, each with `static func encode(_:) throws -> Data` and `static func decode(_:) throws -> Message`.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift
import Foundation
import Testing
@testable import PadlinkCore

private let allClientMessages: [ClientMessage] = [
    .hello(protocolVersion: 1, deviceName: "Hengky's iPad"),
    .pointerMove(dx: -320, dy: 240, dtMicros: 16_666),
    .pointerMove(dx: 0, dy: 0, dtMicros: 0),
    .pointerButton(button: .left, isDown: true),
    .pointerButton(button: .right, isDown: false),
    .scroll(dx: 12, dy: -400),
    .keyText("héllo 🌍"),
    .keyCode(key: .c, isDown: true, modifiers: [.command]),
    .keyCode(key: .f12, isDown: false, modifiers: [.shift, .control, .option, .command, .function]),
    .ping(seq: 4_000_000_000)
]

private let allServerMessages: [ServerMessage] = [
    .helloAck(protocolVersion: 1, accessibilityGranted: true),
    .helloAck(protocolVersion: 1, accessibilityGranted: false),
    .pong(seq: 7),
    .error(code: 3, message: "not paired")
]

@Test(arguments: allClientMessages)
func clientMessagesRoundTrip(message: ClientMessage) throws {
    let encoded = try ClientMessageCodec.encode(message)
    #expect(try ClientMessageCodec.decode(encoded) == message)
}

@Test(arguments: allServerMessages)
func serverMessagesRoundTrip(message: ServerMessage) throws {
    let encoded = try ServerMessageCodec.encode(message)
    #expect(try ServerMessageCodec.decode(encoded) == message)
}

@Test func unknownClientMessageTypeIsReported() {
    #expect(throws: CodecError.unknownMessageType(99)) {
        _ = try ClientMessageCodec.decode(Data([99, 0, 0]))
    }
}

@Test func emptyPayloadIsTruncated() {
    #expect(throws: CodecError.truncated) {
        _ = try ClientMessageCodec.decode(Data())
    }
}

@Test func reservedModifierBitsAreRejected() {
    // keyCode = 6, key = .a (1), isDown = 1, modifiers = 0b1000_0000
    let bytes = Data([6, 0x00, 0x01, 0x01, 0b1000_0000])
    #expect(throws: CodecError.reservedModifierBitsSet(0b1000_0000)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func unknownKeyIdIsRejected() {
    let bytes = Data([6, 0xFF, 0xFE, 0x01, 0x00])
    #expect(throws: CodecError.unknownKey(0xFFFE)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func unknownPointerButtonIsRejected() {
    let bytes = Data([3, 0x09, 0x01])
    #expect(throws: CodecError.unknownPointerButton(9)) {
        _ = try ClientMessageCodec.decode(bytes)
    }
}

@Test func trailingBytesAreRejected() {
    var encoded = try! ClientMessageCodec.encode(.ping(seq: 1))
    encoded.append(0xFF)
    #expect(throws: CodecError.trailingBytes) {
        _ = try ClientMessageCodec.decode(encoded)
    }
}

@Test func padlinkKeyRawValuesAreStable() {
    // These are on the wire. Changing one silently breaks older peers.
    #expect(PadlinkKey.a.rawValue == 1)
    #expect(PadlinkKey.z.rawValue == 26)
    #expect(PadlinkKey.digit0.rawValue == 30)
    #expect(PadlinkKey.space.rawValue == 70)
    #expect(PadlinkKey.f1.rawValue == 100)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter MessageCodec`
Expected: FAIL, "cannot find 'ClientMessage' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Protocol/KeyModifiers.swift
import Foundation

/// Wire bitfield. Bits 5 to 7 are reserved and must be zero.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1 << 0)
    public static let control  = KeyModifiers(rawValue: 1 << 1)
    public static let option   = KeyModifiers(rawValue: 1 << 2)
    public static let command  = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    public static let reservedMask = KeyModifiers(rawValue: 0b1110_0000)

    /// True when only shift is set, or nothing is set. This is the condition
    /// that lets text go through the layout-independent unicode path.
    public var isTextSafe: Bool {
        subtracting(.shift).isEmpty
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Protocol/PadlinkKey.swift
import Foundation

/// A platform-neutral key identity. These raw values travel on the wire, so
/// they must never change. Gaps between groups leave room to add keys later.
public enum PadlinkKey: UInt16, Sendable, Hashable, CaseIterable {
    // Letters, 1 to 26
    case a = 1, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digit row, 30 to 39
    case digit0 = 30, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9

    // Punctuation, 50 to 60
    case minus = 50, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, grave, comma, period, slash

    // Named keys, 70 to 83
    case space = 70, enter, tab, escape, delete, forwardDelete
    case arrowLeft, arrowRight, arrowUp, arrowDown
    case home, end, pageUp, pageDown

    // Function row, 100 to 111
    case f1 = 100, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}
```

```swift
// Padlink/Sources/PadlinkCore/Protocol/Messages.swift
import Foundation

public enum PointerButton: UInt8, Sendable, Hashable, CaseIterable {
    case left = 0
    case right = 1
}

/// Sent by the iPad.
public enum ClientMessage: Sendable, Equatable {
    case hello(protocolVersion: UInt16, deviceName: String)
    /// Raw finger delta in points, plus the time since the previous move as
    /// measured on the iPad. The Mac must not measure this itself, because
    /// network jitter would corrupt the speed used for acceleration.
    case pointerMove(dx: Int16, dy: Int16, dtMicros: UInt16)
    case pointerButton(button: PointerButton, isDown: Bool)
    case scroll(dx: Int16, dy: Int16)
    /// Text to insert, layout-independent. Used when no modifier beyond shift is active.
    case keyText(String)
    case keyCode(key: PadlinkKey, isDown: Bool, modifiers: KeyModifiers)
    case ping(seq: UInt32)
}

/// Sent by the Mac.
public enum ServerMessage: Sendable, Equatable {
    case helloAck(protocolVersion: UInt16, accessibilityGranted: Bool)
    case pong(seq: UInt32)
    case error(code: UInt8, message: String)
}
```

```swift
// Padlink/Sources/PadlinkCore/Protocol/MessageCodec.swift
import Foundation

public enum ClientMessageCodec {
    enum TypeByte: UInt8 {
        case hello = 1
        case pointerMove = 2
        case pointerButton = 3
        case scroll = 4
        case keyText = 5
        case keyCode = 6
        case ping = 7
    }

    public static func encode(_ message: ClientMessage) throws -> Data {
        var writer = ByteWriter()
        switch message {
        case let .hello(protocolVersion, deviceName):
            writer.write(TypeByte.hello.rawValue)
            writer.write(protocolVersion)
            try writer.writeString(deviceName)
        case let .pointerMove(dx, dy, dtMicros):
            writer.write(TypeByte.pointerMove.rawValue)
            writer.write(dx)
            writer.write(dy)
            writer.write(dtMicros)
        case let .pointerButton(button, isDown):
            writer.write(TypeByte.pointerButton.rawValue)
            writer.write(button.rawValue)
            writer.write(isDown)
        case let .scroll(dx, dy):
            writer.write(TypeByte.scroll.rawValue)
            writer.write(dx)
            writer.write(dy)
        case let .keyText(text):
            writer.write(TypeByte.keyText.rawValue)
            try writer.writeString(text)
        case let .keyCode(key, isDown, modifiers):
            writer.write(TypeByte.keyCode.rawValue)
            writer.write(key.rawValue)
            writer.write(isDown)
            writer.write(modifiers.rawValue)
        case let .ping(seq):
            writer.write(TypeByte.ping.rawValue)
            writer.write(seq)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ClientMessage {
        var reader = ByteReader(data)
        let rawType = try reader.readUInt8()
        guard let type = TypeByte(rawValue: rawType) else {
            throw CodecError.unknownMessageType(rawType)
        }

        let message: ClientMessage
        switch type {
        case .hello:
            message = .hello(
                protocolVersion: try reader.readUInt16(),
                deviceName: try reader.readString()
            )
        case .pointerMove:
            message = .pointerMove(
                dx: try reader.readInt16(),
                dy: try reader.readInt16(),
                dtMicros: try reader.readUInt16()
            )
        case .pointerButton:
            let rawButton = try reader.readUInt8()
            guard let button = PointerButton(rawValue: rawButton) else {
                throw CodecError.unknownPointerButton(rawButton)
            }
            message = .pointerButton(button: button, isDown: try reader.readBool())
        case .scroll:
            message = .scroll(dx: try reader.readInt16(), dy: try reader.readInt16())
        case .keyText:
            message = .keyText(try reader.readString())
        case .keyCode:
            let rawKey = try reader.readUInt16()
            guard let key = PadlinkKey(rawValue: rawKey) else {
                throw CodecError.unknownKey(rawKey)
            }
            let isDown = try reader.readBool()
            let rawModifiers = try reader.readUInt8()
            guard rawModifiers & KeyModifiers.reservedMask.rawValue == 0 else {
                throw CodecError.reservedModifierBitsSet(rawModifiers)
            }
            message = .keyCode(
                key: key,
                isDown: isDown,
                modifiers: KeyModifiers(rawValue: rawModifiers)
            )
        case .ping:
            message = .ping(seq: try reader.readUInt32())
        }

        guard reader.isAtEnd else { throw CodecError.trailingBytes }
        return message
    }
}

public enum ServerMessageCodec {
    enum TypeByte: UInt8 {
        case helloAck = 128
        case pong = 129
        case error = 130
    }

    public static func encode(_ message: ServerMessage) throws -> Data {
        var writer = ByteWriter()
        switch message {
        case let .helloAck(protocolVersion, accessibilityGranted):
            writer.write(TypeByte.helloAck.rawValue)
            writer.write(protocolVersion)
            writer.write(accessibilityGranted)
        case let .pong(seq):
            writer.write(TypeByte.pong.rawValue)
            writer.write(seq)
        case let .error(code, text):
            writer.write(TypeByte.error.rawValue)
            writer.write(code)
            try writer.writeString(text)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ServerMessage {
        var reader = ByteReader(data)
        let rawType = try reader.readUInt8()
        guard let type = TypeByte(rawValue: rawType) else {
            throw CodecError.unknownMessageType(rawType)
        }

        let message: ServerMessage
        switch type {
        case .helloAck:
            message = .helloAck(
                protocolVersion: try reader.readUInt16(),
                accessibilityGranted: try reader.readBool()
            )
        case .pong:
            message = .pong(seq: try reader.readUInt32())
        case .error:
            message = .error(code: try reader.readUInt8(), message: try reader.readString())
        }

        guard reader.isAtEnd else { throw CodecError.trailingBytes }
        return message
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter MessageCodec`
Expected: PASS. The two parameterised tests expand to 14 cases, plus 7 single tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Protocol Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift
git commit -m "Add Padlink message types and binary codec"
```

---

### Task 4: Frame parser

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Protocol/FrameParser.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/FrameParserTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks except `Data`.
- Produces:
  - `public struct FrameParser: Sendable` with `static let maxFrameSize = 65536`, `init()`, `mutating func append(_ bytes: Data)`, `mutating func nextFrame() throws -> Data?`.
  - `public enum FramingError: Error, Equatable, Sendable { case frameTooLarge(UInt32) }`
  - `public enum Framer { public static func frame(_ payload: Data) -> Data }`

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/FrameParserTests.swift
import Foundation
import Testing
@testable import PadlinkCore

@Test func framesPayloadWithBigEndianLengthPrefix() {
    let framed = Framer.frame(Data([0xAA, 0xBB, 0xCC]))
    #expect(Array(framed) == [0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
}

@Test func readsOneWholeFrame() throws {
    var parser = FrameParser()
    parser.append(Framer.frame(Data([1, 2, 3])))
    #expect(try parser.nextFrame() == Data([1, 2, 3]))
    #expect(try parser.nextFrame() == nil)
}

@Test func readsFrameSplitAcrossTwoAppends() throws {
    var parser = FrameParser()
    let framed = Framer.frame(Data([1, 2, 3, 4, 5]))
    parser.append(framed.prefix(6))
    #expect(try parser.nextFrame() == nil)
    parser.append(framed.suffix(from: 6))
    #expect(try parser.nextFrame() == Data([1, 2, 3, 4, 5]))
}

@Test func readsFrameWhenEvenTheLengthHeaderIsSplit() throws {
    var parser = FrameParser()
    let framed = Framer.frame(Data([9, 9]))
    parser.append(framed.prefix(2))
    #expect(try parser.nextFrame() == nil)
    parser.append(framed.suffix(from: 2))
    #expect(try parser.nextFrame() == Data([9, 9]))
}

@Test func readsThreeFramesFromOneAppend() throws {
    var parser = FrameParser()
    var buffer = Data()
    buffer.append(Framer.frame(Data([1])))
    buffer.append(Framer.frame(Data([2, 2])))
    buffer.append(Framer.frame(Data([3, 3, 3])))
    parser.append(buffer)

    #expect(try parser.nextFrame() == Data([1]))
    #expect(try parser.nextFrame() == Data([2, 2]))
    #expect(try parser.nextFrame() == Data([3, 3, 3]))
    #expect(try parser.nextFrame() == nil)
}

@Test func returnsEmptyFrameForZeroLengthPayload() throws {
    var parser = FrameParser()
    parser.append(Data([0, 0, 0, 0]))
    // The parser stays dumb. An empty payload is the codec's problem, not framing's.
    #expect(try parser.nextFrame() == Data())
}

@Test func rejectsOversizedLengthHeader() {
    var parser = FrameParser()
    // A hostile peer claiming a 4GB frame must not make us allocate anything.
    parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
    #expect(throws: FramingError.frameTooLarge(0xFFFF_FFFF)) {
        _ = try parser.nextFrame()
    }
}

@Test func acceptsFrameExactlyAtTheLimit() throws {
    var parser = FrameParser()
    let payload = Data(repeating: 0x5A, count: FrameParser.maxFrameSize)
    parser.append(Framer.frame(payload))
    #expect(try parser.nextFrame() == payload)
}

@Test func rejectsFrameOneByteOverTheLimit() {
    var parser = FrameParser()
    let oversize = UInt32(FrameParser.maxFrameSize + 1)
    parser.append(Data([
        UInt8(truncatingIfNeeded: oversize >> 24),
        UInt8(truncatingIfNeeded: oversize >> 16),
        UInt8(truncatingIfNeeded: oversize >> 8),
        UInt8(truncatingIfNeeded: oversize)
    ]))
    #expect(throws: FramingError.frameTooLarge(oversize)) {
        _ = try parser.nextFrame()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter FrameParser`
Expected: FAIL, "cannot find 'Framer' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Protocol/FrameParser.swift
import Foundation

public enum FramingError: Error, Equatable, Sendable {
    /// The peer claimed a frame larger than `FrameParser.maxFrameSize`.
    /// The connection must be closed. Never allocate the claimed size.
    case frameTooLarge(UInt32)
}

public enum Framer {
    /// 4-byte big-endian length prefix, then the payload.
    public static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        var out = Data(capacity: 4 + payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

/// Turns a TCP byte stream back into whole messages. TCP can deliver half a
/// frame or three frames in one read, so both cases must work.
public struct FrameParser: Sendable {
    public static let maxFrameSize = 65_536

    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next whole frame, or nil when more bytes are needed.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        var length: UInt32 = 0
        for offset in 0 ..< 4 {
            length = (length << 8) | UInt32(buffer[buffer.index(start, offsetBy: offset)])
        }

        guard length <= UInt32(Self.maxFrameSize) else {
            throw FramingError.frameTooLarge(length)
        }

        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }

        let payloadStart = buffer.index(start, offsetBy: 4)
        let payloadEnd = buffer.index(start, offsetBy: total)
        let payload = Data(buffer[payloadStart ..< payloadEnd])
        buffer.removeSubrange(start ..< payloadEnd)
        return payload
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter FrameParser`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Protocol/FrameParser.swift Padlink/Tests/PadlinkCoreTests/FrameParserTests.swift
git commit -m "Add length-prefixed frame parser with oversize rejection"
```

---

### Task 5: Pointer acceleration

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Input/PointerAcceleration.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/PointerAccelerationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct PointerAcceleration: Sendable, Equatable` with public properties `sensitivity`, `baseGain`, `speedGain`, `maxGain`, `maxOutputPerEvent`, a memberwise-style `init` with defaults, `static let `default``, and `func accelerate(dx: Double, dy: Double, dtSeconds: Double) -> (dx: Double, dy: Double)`.

- [ ] **Step 1: Write the failing tests**

Note for the implementer: these test **properties**, not exact numbers. That is deliberate. Exact numbers would have to change every time the curve is tuned, and they would tell you nothing about whether the curve is correct.

```swift
// Padlink/Tests/PadlinkCoreTests/PointerAccelerationTests.swift
import Foundation
import Testing
@testable import PadlinkCore

private let frame = 1.0 / 60.0

@Test func zeroInputProducesZeroOutput() {
    let out = PointerAcceleration.default.accelerate(dx: 0, dy: 0, dtSeconds: frame)
    #expect(out.dx == 0)
    #expect(out.dy == 0)
}

@Test(arguments: [
    (2.0, 3.0), (-2.0, 3.0), (2.0, -3.0), (-2.0, -3.0)
])
func signIsPreservedOnBothAxes(input: (dx: Double, dy: Double)) {
    let out = PointerAcceleration.default.accelerate(
        dx: input.dx, dy: input.dy, dtSeconds: frame
    )
    #expect(out.dx.sign == input.dx.sign)
    #expect(out.dy.sign == input.dy.sign)
}

@Test func outputGrowsWithInput() {
    let accel = PointerAcceleration.default
    let small = accel.accelerate(dx: 1, dy: 0, dtSeconds: frame)
    let medium = accel.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    let large = accel.accelerate(dx: 20, dy: 0, dtSeconds: frame)
    #expect(small.dx < medium.dx)
    #expect(medium.dx < large.dx)
}

@Test func axesBehaveIdentically() {
    let accel = PointerAcceleration.default
    let horizontal = accel.accelerate(dx: 7, dy: 0, dtSeconds: frame)
    let vertical = accel.accelerate(dx: 0, dy: 7, dtSeconds: frame)
    #expect(abs(horizontal.dx - vertical.dy) < 1e-9)
    #expect(horizontal.dy == 0)
    #expect(vertical.dx == 0)
}

@Test func fasterMovementCoversMoreDistanceForTheSameDelta() {
    let accel = PointerAcceleration.default
    let slow = accel.accelerate(dx: 10, dy: 0, dtSeconds: 0.100)
    let fast = accel.accelerate(dx: 10, dy: 0, dtSeconds: 0.004)
    #expect(fast.dx > slow.dx)
}

@Test func outputIsBoundedSoTheCursorCannotTeleport() {
    let accel = PointerAcceleration.default
    // A huge delta with an absurdly small time gap. This is what a timing
    // hiccup after the app is backgrounded looks like.
    let out = accel.accelerate(dx: 30_000, dy: 30_000, dtSeconds: 0.000_001)
    let magnitude = (out.dx * out.dx + out.dy * out.dy).squareRoot()
    #expect(magnitude <= accel.maxOutputPerEvent + 1e-9)
}

@Test(arguments: [0.0, -1.0, .infinity, .nan])
func degenerateTimeGapsNeverProduceNaNOrInfinity(dt: Double) {
    let out = PointerAcceleration.default.accelerate(dx: 5, dy: 5, dtSeconds: dt)
    #expect(out.dx.isFinite)
    #expect(out.dy.isFinite)
}

@Test func sensitivityScalesTheResult() {
    var slow = PointerAcceleration.default
    slow.sensitivity = 0.5
    var fast = PointerAcceleration.default
    fast.sensitivity = 2.0
    let a = slow.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    let b = fast.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    #expect(b.dx > a.dx)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter PointerAcceleration`
Expected: FAIL, "cannot find 'PointerAcceleration' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Input/PointerAcceleration.swift
import Foundation

/// Turns a raw finger delta into a cursor delta.
///
/// This runs on the Mac, not the iPad, because only the Mac knows its screen
/// geometry. The iPad supplies the delta and its own measured time gap.
public struct PointerAcceleration: Sendable, Equatable {
    /// User-facing multiplier. 1.0 is neutral.
    public var sensitivity: Double
    /// Gain applied even when the finger is barely moving.
    public var baseGain: Double
    /// Extra gain per point-per-second of finger speed.
    public var speedGain: Double
    /// Ceiling on gain, so very fast flicks stay controllable.
    public var maxGain: Double
    /// Hard ceiling on the distance one event may move the cursor.
    /// This is what stops a timing hiccup teleporting the cursor.
    public var maxOutputPerEvent: Double

    public init(
        sensitivity: Double = 1.0,
        baseGain: Double = 1.0,
        speedGain: Double = 0.0018,
        maxGain: Double = 6.0,
        maxOutputPerEvent: Double = 400
    ) {
        self.sensitivity = sensitivity
        self.baseGain = baseGain
        self.speedGain = speedGain
        self.maxGain = maxGain
        self.maxOutputPerEvent = maxOutputPerEvent
    }

    public static let `default` = PointerAcceleration()

    /// Smallest time gap we will believe. Anything smaller is a measurement
    /// artefact, and dividing by it would produce an enormous speed.
    private static let minimumDT = 0.001

    public func accelerate(
        dx: Double,
        dy: Double,
        dtSeconds: Double
    ) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return (0, 0) }

        let magnitude = (dx * dx + dy * dy).squareRoot()
        guard magnitude > 0 else { return (0, 0) }

        // A non-finite or non-positive gap means "we do not know", so fall
        // back to the smallest believable gap rather than producing infinity.
        let dt = (dtSeconds.isFinite && dtSeconds > Self.minimumDT)
            ? dtSeconds
            : Self.minimumDT

        let speed = magnitude / dt
        let gain = min(baseGain + speedGain * speed, maxGain)

        var outX = dx * gain * sensitivity
        var outY = dy * gain * sensitivity

        let outMagnitude = (outX * outX + outY * outY).squareRoot()
        if outMagnitude > maxOutputPerEvent {
            let scale = maxOutputPerEvent / outMagnitude
            outX *= scale
            outY *= scale
        }

        return (outX, outY)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter PointerAcceleration`
Expected: PASS. Two parameterised tests expand to 8 cases, plus 6 single tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Input Padlink/Tests/PadlinkCoreTests/PointerAccelerationTests.swift
git commit -m "Add pointer acceleration with bounded output"
```

---

### Task 6: Key routing and the macOS virtual key table

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Input/KeyRouter.swift`
- Create: `Padlink/Sources/PadlinkCore/Input/MacVirtualKeys.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/KeyRoutingTests.swift`

**Interfaces:**
- Consumes: `PadlinkKey`, `KeyModifiers`, `ClientMessage` from Task 3.
- Produces:
  - `public enum KeyRouter` with `static func messages(forCharacter character: Character, modifiers: KeyModifiers) -> [ClientMessage]` and `static func padlinkKey(forCharacter character: Character) -> PadlinkKey?`.

Why `messages` returns an array: a shortcut needs a key **down** and a matching key **up**. Sending only the down event would leave the key held on the Mac forever. The text path needs one message, the key code path needs two, so the return type is a list either way.
  - `public enum MacVirtualKeys` with `static func code(for key: PadlinkKey) -> UInt16`.

Background for the implementer: there are two ways to type on macOS. Plain text goes through `keyboardSetUnicodeString`, which works no matter which keyboard layout the Mac is set to. Shortcuts must use real virtual key codes, because `Cmd+C` only copies when the Mac sees key code 8 with the command flag. The routing rule below decides which path a keystroke takes. The Mac app in a later plan consumes both.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/KeyRoutingTests.swift
import Foundation
import Testing
@testable import PadlinkCore

@Test func plainTextGoesThroughTheUnicodePath() {
    #expect(KeyRouter.messages(forCharacter: "a", modifiers: []) == [.keyText("a")])
}

@Test func shiftedTextStillGoesThroughTheUnicodePath() {
    // Shift is already baked into the character the iPad keyboard produced.
    #expect(KeyRouter.messages(forCharacter: "A", modifiers: [.shift]) == [.keyText("A")])
}

@Test func commandShortcutSendsKeyDownThenKeyUp() {
    // Both are required. A down with no up leaves the key held on the Mac.
    #expect(
        KeyRouter.messages(forCharacter: "c", modifiers: [.command]) == [
            .keyCode(key: .c, isDown: true, modifiers: [.command]),
            .keyCode(key: .c, isDown: false, modifiers: [.command])
        ]
    )
}

@Test func uppercaseShortcutCharacterMapsToTheSameKey() {
    #expect(
        KeyRouter.messages(forCharacter: "C", modifiers: [.command, .shift]) == [
            .keyCode(key: .c, isDown: true, modifiers: [.command, .shift]),
            .keyCode(key: .c, isDown: false, modifiers: [.command, .shift])
        ]
    )
}

@Test func unmappableCharacterWithAModifierFallsBackToText() {
    // There is no Padlink key for "é", so the modifier cannot be applied.
    // Falling back to text is the honest outcome: the user gets the character.
    #expect(KeyRouter.messages(forCharacter: "é", modifiers: [.command]) == [.keyText("é")])
}

@Test(arguments: [
    (Character("a"), PadlinkKey.a),
    (Character("z"), PadlinkKey.z),
    (Character("Q"), PadlinkKey.q),
    (Character("0"), PadlinkKey.digit0),
    (Character("9"), PadlinkKey.digit9),
    (Character("-"), PadlinkKey.minus),
    (Character("="), PadlinkKey.equal),
    (Character("["), PadlinkKey.leftBracket),
    (Character("]"), PadlinkKey.rightBracket),
    (Character("\\"), PadlinkKey.backslash),
    (Character(";"), PadlinkKey.semicolon),
    (Character("'"), PadlinkKey.quote),
    (Character("`"), PadlinkKey.grave),
    (Character(","), PadlinkKey.comma),
    (Character("."), PadlinkKey.period),
    (Character("/"), PadlinkKey.slash),
    (Character(" "), PadlinkKey.space)
])
func charactersMapToPadlinkKeys(pair: (character: Character, key: PadlinkKey)) {
    #expect(KeyRouter.padlinkKey(forCharacter: pair.character) == pair.key)
}

@Test func unmappedCharacterReturnsNil() {
    #expect(KeyRouter.padlinkKey(forCharacter: "🌍") == nil)
}

@Test func everyPadlinkKeyHasAMacVirtualKeyCode() {
    // Completeness check. Adding a PadlinkKey without a mapping fails here
    // rather than silently typing the wrong thing on the Mac.
    for key in PadlinkKey.allCases {
        let code = MacVirtualKeys.code(for: key)
        #expect(code != MacVirtualKeys.unmapped, "no virtual key code for \(key)")
    }
}

@Test(arguments: [
    (PadlinkKey.a, UInt16(0x00)),
    (PadlinkKey.c, UInt16(0x08)),
    (PadlinkKey.v, UInt16(0x09)),
    (PadlinkKey.q, UInt16(0x0C)),
    (PadlinkKey.digit1, UInt16(0x12)),
    (PadlinkKey.digit0, UInt16(0x1D)),
    (PadlinkKey.enter, UInt16(0x24)),
    (PadlinkKey.tab, UInt16(0x30)),
    (PadlinkKey.space, UInt16(0x31)),
    (PadlinkKey.delete, UInt16(0x33)),
    (PadlinkKey.escape, UInt16(0x35)),
    (PadlinkKey.arrowLeft, UInt16(0x7B)),
    (PadlinkKey.arrowRight, UInt16(0x7C)),
    (PadlinkKey.arrowDown, UInt16(0x7D)),
    (PadlinkKey.arrowUp, UInt16(0x7E)),
    (PadlinkKey.f1, UInt16(0x7A)),
    (PadlinkKey.f12, UInt16(0x6F))
])
func knownVirtualKeyCodesAreCorrect(pair: (key: PadlinkKey, code: UInt16)) {
    // These come from Apple's HIToolbox Events.h. Getting one wrong means
    // Cmd+C pastes, or worse.
    #expect(MacVirtualKeys.code(for: pair.key) == pair.code)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter KeyRouting`
Expected: FAIL, "cannot find 'KeyRouter' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Input/KeyRouter.swift
import Foundation

/// Decides how a keystroke should reach the Mac.
///
/// Rule: plain text, or text with only shift, takes the layout-independent
/// unicode path. Anything with control, option, command, or function must take
/// the virtual key code path, because shortcuts are positional. `Cmd+C` only
/// copies when the Mac sees the C key code, not the letter "c".
public enum KeyRouter {
    private static let characterMap: [Character: PadlinkKey] = {
        var map: [Character: PadlinkKey] = [:]

        let letters: [(Character, PadlinkKey)] = [
            ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e), ("f", .f),
            ("g", .g), ("h", .h), ("i", .i), ("j", .j), ("k", .k), ("l", .l),
            ("m", .m), ("n", .n), ("o", .o), ("p", .p), ("q", .q), ("r", .r),
            ("s", .s), ("t", .t), ("u", .u), ("v", .v), ("w", .w), ("x", .x),
            ("y", .y), ("z", .z)
        ]
        for (character, key) in letters {
            map[character] = key
            // Uppercase maps to the same physical key.
            for upper in String(character).uppercased() {
                map[upper] = key
            }
        }

        let digits: [(Character, PadlinkKey)] = [
            ("0", .digit0), ("1", .digit1), ("2", .digit2), ("3", .digit3),
            ("4", .digit4), ("5", .digit5), ("6", .digit6), ("7", .digit7),
            ("8", .digit8), ("9", .digit9)
        ]
        for (character, key) in digits { map[character] = key }

        let punctuation: [(Character, PadlinkKey)] = [
            ("-", .minus), ("=", .equal), ("[", .leftBracket), ("]", .rightBracket),
            ("\\", .backslash), (";", .semicolon), ("'", .quote), ("`", .grave),
            (",", .comma), (".", .period), ("/", .slash), (" ", .space)
        ]
        for (character, key) in punctuation { map[character] = key }

        return map
    }()

    /// The physical key a character sits on, for a US ANSI layout. Nil when
    /// the character has no fixed physical position, such as an emoji or an
    /// accented letter.
    public static func padlinkKey(forCharacter character: Character) -> PadlinkKey? {
        characterMap[character]
    }

    /// Builds the messages the iPad should send for a typed character.
    ///
    /// The text path is one message. The key code path is two, a down and a
    /// matching up, because a down with no up leaves the key held on the Mac.
    public static func messages(
        forCharacter character: Character,
        modifiers: KeyModifiers
    ) -> [ClientMessage] {
        if modifiers.isTextSafe {
            return [.keyText(String(character))]
        }
        guard let key = padlinkKey(forCharacter: character) else {
            // No physical position for this character, so the modifier cannot
            // be applied. Sending the text at least delivers the character.
            return [.keyText(String(character))]
        }
        return [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Input/MacVirtualKeys.swift
import Foundation

/// Padlink key identity to macOS virtual key code.
///
/// Values come from Apple's HIToolbox `Events.h` (`kVK_*` constants). They are
/// positional, not character based, which is exactly what shortcuts need.
/// This table lives in Core rather than the Mac app so it can be tested for
/// completeness without a simulator.
public enum MacVirtualKeys {
    /// Returned when a key has no mapping. The completeness test asserts this
    /// is never returned for any `PadlinkKey`.
    public static let unmapped: UInt16 = 0xFFFF

    public static func code(for key: PadlinkKey) -> UInt16 {
        switch key {
        case .a: return 0x00
        case .b: return 0x0B
        case .c: return 0x08
        case .d: return 0x02
        case .e: return 0x0E
        case .f: return 0x03
        case .g: return 0x05
        case .h: return 0x04
        case .i: return 0x22
        case .j: return 0x26
        case .k: return 0x28
        case .l: return 0x25
        case .m: return 0x2E
        case .n: return 0x2D
        case .o: return 0x1F
        case .p: return 0x23
        case .q: return 0x0C
        case .r: return 0x0F
        case .s: return 0x01
        case .t: return 0x11
        case .u: return 0x20
        case .v: return 0x09
        case .w: return 0x0D
        case .x: return 0x07
        case .y: return 0x10
        case .z: return 0x06

        case .digit0: return 0x1D
        case .digit1: return 0x12
        case .digit2: return 0x13
        case .digit3: return 0x14
        case .digit4: return 0x15
        case .digit5: return 0x17
        case .digit6: return 0x16
        case .digit7: return 0x1A
        case .digit8: return 0x1C
        case .digit9: return 0x19

        case .minus: return 0x1B
        case .equal: return 0x18
        case .leftBracket: return 0x21
        case .rightBracket: return 0x1E
        case .backslash: return 0x2A
        case .semicolon: return 0x29
        case .quote: return 0x27
        case .grave: return 0x32
        case .comma: return 0x2B
        case .period: return 0x2F
        case .slash: return 0x2C

        case .space: return 0x31
        case .enter: return 0x24
        case .tab: return 0x30
        case .escape: return 0x35
        case .delete: return 0x33
        case .forwardDelete: return 0x75
        case .arrowLeft: return 0x7B
        case .arrowRight: return 0x7C
        case .arrowUp: return 0x7E
        case .arrowDown: return 0x7D
        case .home: return 0x73
        case .end: return 0x77
        case .pageUp: return 0x74
        case .pageDown: return 0x79

        case .f1: return 0x7A
        case .f2: return 0x78
        case .f3: return 0x63
        case .f4: return 0x76
        case .f5: return 0x60
        case .f6: return 0x61
        case .f7: return 0x62
        case .f8: return 0x64
        case .f9: return 0x65
        case .f10: return 0x6D
        case .f11: return 0x67
        case .f12: return 0x6F
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter KeyRouting`
Expected: PASS. Two parameterised tests expand to 34 cases, plus 6 single tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Input Padlink/Tests/PadlinkCoreTests/KeyRoutingTests.swift
git commit -m "Add key routing rule and macOS virtual key table"
```

---

### Task 7: Pairing identity, secret, and QR payload

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Pairing/PairingIdentity.swift`
- Create: `Padlink/Sources/PadlinkCore/Pairing/PairingPayload.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/PairingPayloadTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct PairingID: Sendable, Hashable` with `static let byteCount = 8`, `let bytes: Data`, `init?(bytes:)`, `init?(hexString:)`, `var hexString: String`, `static func generate() throws -> PairingID`.
  - `public struct PairingSecret: Sendable, Hashable` with `static let byteCount = 32`, `let bytes: Data`, `init?(bytes:)`, `static func generate() throws -> PairingSecret`.
  - `public struct PairingPayload: Sendable, Equatable` with `static let version = 1`, fields `pairingID`, `secret`, `macName`, `serviceName`, `var urlString: String`, `static func parse(_ text: String) throws -> PairingPayload`.
  - `public enum PairingError: Error, Equatable, Sendable`.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/PairingPayloadTests.swift
import Foundation
import Testing
@testable import PadlinkCore

private func makePayload(
    macName: String = "Hengky's MacBook Air",
    serviceName: String = "Hengky MacBook Air"
) -> PairingPayload {
    PairingPayload(
        pairingID: PairingID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!,
        secret: PairingSecret(bytes: Data(repeating: 0x7F, count: 32))!,
        macName: macName,
        serviceName: serviceName
    )
}

@Test func generatedSecretHasTheRightLength() throws {
    #expect(try PairingSecret.generate().bytes.count == 32)
}

@Test func twoGeneratedSecretsAreNeverEqual() throws {
    let a = try PairingSecret.generate()
    let b = try PairingSecret.generate()
    #expect(a != b)
}

@Test func twoGeneratedPairingIDsAreNeverEqual() throws {
    #expect(try PairingID.generate() != PairingID.generate())
}

@Test func secretRejectsWrongLength() {
    #expect(PairingSecret(bytes: Data(repeating: 0, count: 31)) == nil)
    #expect(PairingSecret(bytes: Data(repeating: 0, count: 33)) == nil)
}

@Test func pairingIDRoundTripsThroughHex() throws {
    let id = PairingID(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]))!
    #expect(id.hexString == "deadbeef00112233")
    #expect(PairingID(hexString: "deadbeef00112233") == id)
    #expect(PairingID(hexString: "DEADBEEF00112233") == id)
}

@Test func pairingIDRejectsBadHex() {
    #expect(PairingID(hexString: "notvalidhexxxxxx") == nil)
    #expect(PairingID(hexString: "deadbeef") == nil)
}

@Test func payloadRoundTrips() throws {
    let payload = makePayload()
    let parsed = try PairingPayload.parse(payload.urlString)
    #expect(parsed == payload)
}

@Test func payloadRoundTripsWithAwkwardNames() throws {
    let payload = makePayload(
        macName: "Hengky's Mac & iPad = fun?",
        serviceName: "name with spaces"
    )
    #expect(try PairingPayload.parse(payload.urlString) == payload)
}

@Test func payloadURLUsesTheExpectedShape() {
    let url = makePayload().urlString
    #expect(url.hasPrefix("padlink://pair?"))
    #expect(url.contains("v=1"))
    #expect(url.contains("id=0102030405060708"))
    // base64url, unpadded: no plus, no slash, no equals sign.
    let key = url.split(separator: "&").first { $0.hasPrefix("k=") }!
    #expect(!key.contains("+"))
    #expect(!key.contains("/"))
    #expect(!key.contains("="))
}

@Test func parseRejectsWrongScheme() {
    #expect(throws: PairingError.wrongScheme) {
        _ = try PairingPayload.parse("https://example.com/pair?v=1")
    }
}

@Test func parseRejectsUnsupportedVersion() {
    let url = makePayload().urlString.replacingOccurrences(of: "v=1", with: "v=2")
    #expect(throws: PairingError.unsupportedVersion(2)) {
        _ = try PairingPayload.parse(url)
    }
}

@Test func parseRejectsMissingField() {
    let full = makePayload().urlString
    let withoutKey = full
        .split(separator: "&")
        .filter { !$0.hasPrefix("k=") }
        .joined(separator: "&")
    #expect(throws: PairingError.missingField("k")) {
        _ = try PairingPayload.parse(withoutKey)
    }
}

@Test func parseRejectsMalformedSecret() {
    let url = makePayload().urlString
    let broken = url.replacingOccurrences(
        of: url.split(separator: "&").first { $0.hasPrefix("k=") }!,
        with: "k=tooshort"
    )
    #expect(throws: PairingError.malformedField("k")) {
        _ = try PairingPayload.parse(broken)
    }
}

@Test func parseRejectsGarbage() {
    #expect(throws: (any Error).self) {
        _ = try PairingPayload.parse("this is not a url at all")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter PairingPayload`
Expected: FAIL, "cannot find 'PairingID' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Pairing/PairingIdentity.swift
import Foundation
import Security

public enum PairingError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
    case wrongScheme
    case unsupportedVersion(Int)
    case missingField(String)
    case malformedField(String)
    case notAURL
}

private func randomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
        throw PairingError.randomGenerationFailed(status)
    }
    return Data(bytes)
}

/// Identifies one pairing. Doubles as the TLS pre-shared key identity, which is
/// how the Mac knows which secret to use when several iPads are paired.
public struct PairingID: Sendable, Hashable {
    public static let byteCount = 8
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public init?(hexString: String) {
        guard hexString.count == Self.byteCount * 2 else { return nil }
        var data = Data(capacity: Self.byteCount)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.bytes = data
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func generate() throws -> PairingID {
        PairingID(bytes: try randomBytes(count: byteCount))!
    }
}

/// The shared secret used as the TLS 1.3 pre-shared key. 256 bits, so it is
/// safe to use directly with no password-authenticated key exchange.
public struct PairingSecret: Sendable, Hashable {
    public static let byteCount = 32
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public static func generate() throws -> PairingSecret {
        PairingSecret(bytes: try randomBytes(count: byteCount))!
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Pairing/PairingPayload.swift
import Foundation

/// What the QR code carries. The secret travels optically, never over the
/// network, which is what makes a person-in-the-middle attack impossible.
public struct PairingPayload: Sendable, Equatable {
    public static let version = 1
    public static let scheme = "padlink"

    public let pairingID: PairingID
    public let secret: PairingSecret
    /// Shown in the iPad's UI.
    public let macName: String
    /// Bonjour service instance name, so the iPad picks the right Mac when
    /// several are advertising.
    public let serviceName: String

    public init(
        pairingID: PairingID,
        secret: PairingSecret,
        macName: String,
        serviceName: String
    ) {
        self.pairingID = pairingID
        self.secret = secret
        self.macName = macName
        self.serviceName = serviceName
    }

    public var urlString: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "id", value: pairingID.hexString),
            URLQueryItem(name: "k", value: Self.base64URL(secret.bytes)),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "s", value: serviceName)
        ]
        return components.string ?? ""
    }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard let components = URLComponents(string: text) else {
            throw PairingError.notAURL
        }
        guard components.scheme == scheme else { throw PairingError.wrongScheme }

        let items = components.queryItems ?? []
        func value(_ name: String) throws -> String {
            guard let found = items.first(where: { $0.name == name })?.value,
                  !found.isEmpty
            else { throw PairingError.missingField(name) }
            return found
        }

        guard let rawVersion = Int(try value("v")) else {
            throw PairingError.malformedField("v")
        }
        guard rawVersion == version else {
            throw PairingError.unsupportedVersion(rawVersion)
        }

        guard let pairingID = PairingID(hexString: try value("id")) else {
            throw PairingError.malformedField("id")
        }
        guard let keyBytes = decodeBase64URL(try value("k")),
              let secret = PairingSecret(bytes: keyBytes)
        else {
            throw PairingError.malformedField("k")
        }

        return PairingPayload(
            pairingID: pairingID,
            secret: secret,
            macName: try value("n"),
            serviceName: try value("s")
        )
    }

    // Base64url, unpadded. Padding and the plus and slash characters would
    // need percent-encoding inside a URL, which makes the QR code denser.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: standard)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter PairingPayload`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Pairing Padlink/Tests/PadlinkCoreTests/PairingPayloadTests.swift
git commit -m "Add pairing identity, secret generation, and QR payload format"
```

---

### Task 8: Pairing store protocol and in-memory implementation

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Pairing/PairingStore.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/PairingStoreTests.swift`

**Interfaces:**
- Consumes: `PairingID`, `PairingSecret` from Task 7.
- Produces:
  - `public struct PairingRecord: Sendable, Equatable` with `id`, `secret`, `peerName`, `pairedAt`.
  - `public protocol PairingStore: Sendable` with `func save(_:) throws`, `func load(id:) throws -> PairingRecord?`, `func loadAll() throws -> [PairingRecord]`, `func delete(id:) throws`.
  - `public final class InMemoryPairingStore: PairingStore, @unchecked Sendable`.

The real `KeychainPairingStore` is deliberately **not** built here. An unsigned `swift test` binary cannot use the data protection keychain, so it would be untestable at this layer. It is built in the app plans, against this protocol.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/PairingStoreTests.swift
import Foundation
import Testing
@testable import PadlinkCore

private func record(_ byte: UInt8, name: String) -> PairingRecord {
    PairingRecord(
        id: PairingID(bytes: Data(repeating: byte, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: byte, count: 32))!,
        peerName: name,
        pairedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
}

@Test func savesAndLoadsARecord() throws {
    let store = InMemoryPairingStore()
    let saved = record(1, name: "iPad Air")
    try store.save(saved)
    #expect(try store.load(id: saved.id) == saved)
}

@Test func loadingAnUnknownIDReturnsNil() throws {
    let store = InMemoryPairingStore()
    let unknown = PairingID(bytes: Data(repeating: 9, count: 8))!
    #expect(try store.load(id: unknown) == nil)
}

@Test func savingTheSameIDTwiceReplacesTheRecord() throws {
    let store = InMemoryPairingStore()
    let first = record(2, name: "old name")
    let second = PairingRecord(
        id: first.id,
        secret: first.secret,
        peerName: "new name",
        pairedAt: first.pairedAt
    )
    try store.save(first)
    try store.save(second)
    #expect(try store.load(id: first.id)?.peerName == "new name")
    #expect(try store.loadAll().count == 1)
}

@Test func loadsAllRecordsSortedByPairedDate() throws {
    let store = InMemoryPairingStore()
    let newer = PairingRecord(
        id: PairingID(bytes: Data(repeating: 4, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: 4, count: 32))!,
        peerName: "newer",
        pairedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )
    try store.save(newer)
    try store.save(record(3, name: "older"))

    let all = try store.loadAll()
    #expect(all.map(\.peerName) == ["older", "newer"])
}

@Test func deletesARecord() throws {
    let store = InMemoryPairingStore()
    let saved = record(5, name: "gone soon")
    try store.save(saved)
    try store.delete(id: saved.id)
    #expect(try store.load(id: saved.id) == nil)
    #expect(try store.loadAll().isEmpty)
}

@Test func deletingAnUnknownIDIsNotAnError() throws {
    let store = InMemoryPairingStore()
    try store.delete(id: PairingID(bytes: Data(repeating: 6, count: 8))!)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter PairingStore`
Expected: FAIL, "cannot find 'InMemoryPairingStore' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Pairing/PairingStore.swift
import Foundation

public struct PairingRecord: Sendable, Equatable {
    public let id: PairingID
    public let secret: PairingSecret
    /// The other device's name, shown in the paired-devices list.
    public let peerName: String
    public let pairedAt: Date

    public init(id: PairingID, secret: PairingSecret, peerName: String, pairedAt: Date) {
        self.id = id
        self.secret = secret
        self.peerName = peerName
        self.pairedAt = pairedAt
    }
}

/// Where pairings live. The apps supply a Keychain-backed implementation.
/// Core supplies an in-memory one so the rest of the package can be tested
/// without code signing.
public protocol PairingStore: Sendable {
    func save(_ record: PairingRecord) throws
    func load(id: PairingID) throws -> PairingRecord?
    /// Oldest pairing first.
    func loadAll() throws -> [PairingRecord]
    /// Deleting an unknown id is not an error.
    func delete(id: PairingID) throws
}

public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PairingID: PairingRecord] = [:]

    public init() {}

    public func save(_ record: PairingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        records[record.id] = record
    }

    public func load(id: PairingID) throws -> PairingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[id]
    }

    public func loadAll() throws -> [PairingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func delete(id: PairingID) throws {
        lock.lock()
        defer { lock.unlock() }
        records[id] = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter PairingStore`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Pairing/PairingStore.swift Padlink/Tests/PadlinkCoreTests/PairingStoreTests.swift
git commit -m "Add pairing store protocol and in-memory implementation"
```

---

### Task 9: TLS pre-shared key transport parameters

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Transport/TLSPSK.swift`
- Create: `Padlink/Sources/PadlinkCore/Transport/PadlinkTransport.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/TransportTests.swift`

**Interfaces:**
- Consumes: `PairingRecord`, `PairingID`, `PairingSecret` from Tasks 7 and 8. **The `applyPSKs` body recorded in Task 0 step 4.**
- Produces:
  - `public struct TLSPSK: Sendable, Equatable` with `let identity: Data`, `let key: Data`, `init(record: PairingRecord)`.
  - `public enum PadlinkTransport` with `static func listenerParameters(psks: [TLSPSK]) -> NWParameters` and `static func connectionParameters(psk: TLSPSK) -> NWParameters`.

**Task 0 is done. Its findings bind this task:**

- **TLS 1.2, not TLS 1.3.** Every TLS 1.3 configuration failed with -9858.
- **Pin the ECDHE_PSK ciphersuites explicitly**, or a non-forward-secret plain PSK suite can be negotiated.
- **Several pre-shared keys on one listener do work**, and TLS picks the right one by identity. So `listenerParameters` keeps its array parameter and there is no single-key fallback.
- **A rejected handshake surfaces as `.waiting`, not `.failed`.** The test helper below depends on this.
- **Retain every `NWConnection`**, including accepted ones, or ARC frees them mid-handshake.

- [ ] **Step 1: Write the failing tests**

These are real integration tests. They open a real listener on a real loopback port and complete a real TLS handshake. They are slower than the other tests, which is expected.

```swift
// Padlink/Tests/PadlinkCoreTests/TransportTests.swift
import Foundation
import Network
import Testing
@testable import PadlinkCore

private func psk(_ byte: UInt8) -> TLSPSK {
    TLSPSK(record: PairingRecord(
        id: PairingID(bytes: Data(repeating: byte, count: 8))!,
        secret: PairingSecret(bytes: Data(repeating: byte, count: 32))!,
        peerName: "test",
        pairedAt: Date()
    ))
}

/// Swift 6 forbids mutating a captured local from a @Sendable state handler,
/// and accepted connections must be retained or ARC frees them mid-handshake.
/// This box covers both needs.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Starts a listener and returns its port, plus the box retaining accepted
/// connections. The caller cancels the listener and must keep the box alive.
private func startListener(
    psks: [TLSPSK]
) async throws -> (NWListener, NWEndpoint.Port, Box<[NWConnection]>) {
    let listener = try NWListener(using: PadlinkTransport.listenerParameters(psks: psks), on: 0)
    let accepted = Box<[NWConnection]>([])
    listener.newConnectionHandler = { connection in
        // Retaining is mandatory. Without this the handshake never completes.
        accepted.value.append(connection)
        connection.start(queue: .global())
    }

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
    return (listener, port, accepted)
}

/// True when the handshake reached ready, false when it was rejected.
///
/// `.waiting` counts as rejection. Network.framework reports a failed PSK
/// handshake as `.waiting` and then retries forever, so a helper that only
/// watched for `.failed` would hang instead of returning false.
private func handshakeSucceeds(psk clientPSK: TLSPSK, port: NWEndpoint.Port) async -> Bool {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: port,
        using: PadlinkTransport.connectionParameters(psk: clientPSK)
    )
    defer { connection.cancel() }

    return await withCheckedContinuation { continuation in
        let resumed = Box(false)
        connection.stateUpdateHandler = { state in
            guard !resumed.value else { return }
            switch state {
            case .ready:
                resumed.value = true
                continuation.resume(returning: true)
            case .failed, .cancelled, .waiting:
                resumed.value = true
                continuation.resume(returning: false)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

@Test func matchingPreSharedKeyCompletesTheHandshake() async throws {
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xA1), port: port))
    _ = accepted  // keep the retaining box alive to the end of the test
}

@Test func mismatchedPreSharedKeyIsRejected() async throws {
    // This is the test that proves a stranger on the same Wi-Fi cannot connect.
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xEE), port: port) == false)
    _ = accepted
}

@Test func listenerAcceptsEveryPairedDevice() async throws {
    // Task 0 measured that several PSKs on one listener work and TLS picks the
    // right one by identity. This test locks that behaviour in.
    let (listener, port, accepted) = try await startListener(psks: [psk(0xA1), psk(0xB2)])
    defer { listener.cancel() }
    #expect(await handshakeSucceeds(psk: psk(0xA1), port: port))
    #expect(await handshakeSucceeds(psk: psk(0xB2), port: port))
    #expect(await handshakeSucceeds(psk: psk(0xCC), port: port) == false)
    _ = accepted
}

@Test func onlyForwardSecretCiphersuitesArePinned() {
    // Plain PSK suites (0x00A8, 0x00A9, 0xCCAB) complete a handshake but give
    // no forward secrecy. If one ever appears in this list, a captured
    // recording becomes decryptable once the secret leaks.
    let pinned = PadlinkTransport.forwardSecretPSKCiphersuites.map(\.rawValue)
    #expect(pinned.isEmpty == false)
    for plainPSK: UInt16 in [0x00A8, 0x00A9, 0xCCAB] {
        #expect(pinned.contains(plainPSK) == false)
    }
}

@Test func tcpNoDelayIsEnabled() {
    // Nagle's algorithm buffers small packets. Every pointer move is a small
    // packet, so leaving it on would add latency to exactly the wrong thing.
    let parameters = PadlinkTransport.connectionParameters(psk: psk(0xA1))
    let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    #expect(tcp?.noDelay == true)
}

@Test func pskCarriesThePairingIDAsItsIdentity() {
    let record = PairingRecord(
        id: PairingID(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))!,
        secret: PairingSecret(bytes: Data(repeating: 0x33, count: 32))!,
        peerName: "iPad",
        pairedAt: Date()
    )
    let converted = TLSPSK(record: record)
    #expect(converted.identity == record.id.bytes)
    #expect(converted.key == record.secret.bytes)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter Transport`
Expected: FAIL, "cannot find 'PadlinkTransport' in scope".

- [ ] **Step 3: Write the implementation**

Copy the `applyPreSharedKeys` body from what Task 0 proved works. The version below is the expected form.

```swift
// Padlink/Sources/PadlinkCore/Transport/TLSPSK.swift
import Foundation

/// A pairing expressed the way TLS wants it. The pairing ID becomes the
/// pre-shared key identity, which is how the Mac picks the right secret when
/// several iPads are paired.
public struct TLSPSK: Sendable, Equatable {
    public let identity: Data
    public let key: Data

    public init(identity: Data, key: Data) {
        self.identity = identity
        self.key = key
    }

    public init(record: PairingRecord) {
        self.identity = record.id.bytes
        self.key = record.secret.bytes
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Transport/PadlinkTransport.swift
import Foundation
import Network

public enum PadlinkTransport {
    /// Forward-secret PSK ciphersuites. `tls_ciphersuite_t` exposes no PSK
    /// cases, but it is UInt16-backed, so they are built by raw value.
    ///
    /// Only ephemeral-Diffie-Hellman suites appear here. Plain PSK suites such
    /// as 0x00A8 also work but have no forward secrecy, which would break the
    /// spec's promise that a captured recording cannot be decrypted later.
    static let forwardSecretPSKCiphersuites: [tls_ciphersuite_t] = [
        tls_ciphersuite_t(rawValue: 0xD001)!,  // ECDHE_PSK_WITH_AES_128_GCM_SHA256
        tls_ciphersuite_t(rawValue: 0xCCAC)!,  // ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
        tls_ciphersuite_t(rawValue: 0x00AA)!   // DHE_PSK_WITH_AES_128_GCM_SHA256
    ]

    /// TLS 1.2 with forward-secret pre-shared keys, and Nagle disabled.
    ///
    /// TLS 1.2, not 1.3. Task 0 measured that `add_pre_shared_key` is RFC 4279
    /// style: every TLS 1.3 configuration failed with -9858.
    ///
    /// The ciphersuites must be pinned. Leaving the list empty still completes
    /// a handshake, but then a plain PSK suite with no forward secrecy can be
    /// negotiated.
    ///
    /// The secret came from a QR code, so it has full entropy and can be used
    /// directly as a pre-shared key. That is what removes the need for a
    /// password-authenticated key exchange.
    static func applyPreSharedKeys(_ options: NWProtocolTLS.Options, _ psks: [TLSPSK]) {
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        for suite in forwardSecretPSKCiphersuites {
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        for psk in psks {
            let key = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = psk.identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                security,
                key as __DispatchData,
                identity as __DispatchData
            )
        }
    }

    private static func parameters(psks: [TLSPSK]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        applyPreSharedKeys(tls, psks)

        let tcp = NWProtocolTCP.Options()
        // Every pointer move is a small packet. Nagle would buffer them.
        tcp.noDelay = true
        // Notice a dead peer in seconds rather than minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2

        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Parameters for the Mac. Every paired device's key is registered.
    public static func listenerParameters(psks: [TLSPSK]) -> NWParameters {
        let parameters = parameters(psks: psks)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Parameters for the iPad. Only this device's own key is used.
    public static func connectionParameters(psk: TLSPSK) -> NWParameters {
        parameters(psks: [psk])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter Transport`
Expected: PASS, 5 tests. These take a few seconds because real handshakes happen.

If `as __DispatchData` fails to compile, remove the cast (Task 0 recorded which form works). If `listenerAcceptsEveryPairedDevice` fails, apply the single-key fallback described at the top of this task.

- [ ] **Step 5: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Transport Padlink/Tests/PadlinkCoreTests/TransportTests.swift
git commit -m "Add TLS pre-shared key transport parameters"
```

---

### Task 10: Framed connection with heartbeat and release-on-drop

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Transport/PadlinkConnection.swift`
- Create: `Padlink/Sources/PadlinkCore/Transport/HeartbeatMonitor.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/HeartbeatMonitorTests.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/PadlinkConnectionTests.swift`

**Interfaces:**
- Consumes: `FrameParser`, `Framer`, `ClientMessageCodec`, `ServerMessageCodec`, `PadlinkTransport`, `TLSPSK`.
- Produces:
  - `public struct HeartbeatMonitor: Sendable` with `init(missedLimit: Int = 3)`, `mutating func recordPingSent()`, `mutating func recordPongReceived()`, `var missedCount: Int`, `var isDead: Bool`.
  - `public actor PadlinkConnection` with `init(connection: NWConnection)`, `func start() async throws`, `func send(_ message: ClientMessage) async throws`, `func send(_ message: ServerMessage) async throws`, `var incoming: AsyncStream<Data>`, `func cancel()`.

Design note for the implementer: `PadlinkConnection` deliberately hands out **decoded frames as `Data`**, not typed messages. The Mac decodes them as `ClientMessage` and the iPad decodes them as `ServerMessage`, so the connection itself stays direction-agnostic and both apps share one implementation.

The "release everything on drop" requirement is met by the connection's `incoming` stream **finishing**. Whoever consumes the stream must run its release routine when the stream ends. That is the seam, and the Mac app plan implements the actual key and button release.

**Two Swift 6 concurrency notes for this task.** The `var resumed = false` locals shown below are captured by `@Sendable` state handlers, which Swift 6 rejects. Use the same `Box` reference type defined in Task 9's tests (move it into the test target's shared scope, or redeclare it here). The same applies to any local a Network.framework callback mutates. Task 9's tests already carry a working copy.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/HeartbeatMonitorTests.swift
import Testing
@testable import PadlinkCore

@Test func startsAlive() {
    let monitor = HeartbeatMonitor()
    #expect(monitor.isDead == false)
    #expect(monitor.missedCount == 0)
}

@Test func aPongClearsTheMissedCount() {
    var monitor = HeartbeatMonitor()
    monitor.recordPingSent()
    monitor.recordPingSent()
    #expect(monitor.missedCount == 2)
    monitor.recordPongReceived()
    #expect(monitor.missedCount == 0)
    #expect(monitor.isDead == false)
}

@Test func threeMissedPongsMarkTheConnectionDead() {
    var monitor = HeartbeatMonitor()
    monitor.recordPingSent()
    monitor.recordPingSent()
    #expect(monitor.isDead == false)
    monitor.recordPingSent()
    #expect(monitor.isDead)
}

@Test func theLimitIsConfigurable() {
    var monitor = HeartbeatMonitor(missedLimit: 1)
    monitor.recordPingSent()
    #expect(monitor.isDead)
}
```

```swift
// Padlink/Tests/PadlinkCoreTests/PadlinkConnectionTests.swift
import Foundation
import Network
import Testing
@testable import PadlinkCore

private let sharedPSK = TLSPSK(
    identity: Data(repeating: 0x0F, count: 8),
    key: Data(repeating: 0xF0, count: 32)
)

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
        var resumed = false
        listener.stateUpdateHandler = { state in
            guard !resumed else { return }
            switch state {
            case .ready:
                resumed = true
                continuation.resume(returning: listener.port!)
            case .failed(let error):
                resumed = true
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
    try await client.start()

    var iterator = serverBox.stream.makeAsyncIterator()
    guard let rawServer = await iterator.next() else {
        throw CancellationError()
    }
    let server = PadlinkConnection(connection: rawServer)
    try await server.start()

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Padlink && swift test --filter "Heartbeat|PadlinkConnection"`
Expected: FAIL, "cannot find 'HeartbeatMonitor' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// Padlink/Sources/PadlinkCore/Transport/HeartbeatMonitor.swift
import Foundation

/// Counts unanswered pings. Without this, a dead connection sits unnoticed
/// until TCP gives up, which can take over a minute.
public struct HeartbeatMonitor: Sendable {
    public let missedLimit: Int
    public private(set) var missedCount = 0

    public init(missedLimit: Int = 3) {
        self.missedLimit = missedLimit
    }

    public mutating func recordPingSent() {
        missedCount += 1
    }

    public mutating func recordPongReceived() {
        missedCount = 0
    }

    public var isDead: Bool {
        missedCount >= missedLimit
    }
}
```

```swift
// Padlink/Sources/PadlinkCore/Transport/PadlinkConnection.swift
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
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: ConnectionError.notReady)
                case .waiting(let error):
                    // A rejected pre-shared key surfaces here, not in .failed,
                    // and Network.framework then retries forever. Without this
                    // case the connection attempt hangs instead of throwing.
                    resumed = true
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Padlink && swift test --filter "Heartbeat|PadlinkConnection"`
Expected: PASS, 8 tests.

- [ ] **Step 5: Run the whole suite**

Run: `cd Padlink && swift test`
Expected: PASS, everything, roughly 90 test cases once parameterised tests expand.

- [ ] **Step 6: Commit**

```bash
git add Padlink/Sources/PadlinkCore/Transport Padlink/Tests/PadlinkCoreTests
git commit -m "Add framed connection with heartbeat monitor and disconnect signal"
```

---

### Task 11: Update the spec and close out the plan

**Files:**
- Modify: `docs/superpowers/specs/2026-08-13-padlink-design.md`
- Modify: `NOTES.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Fix the impossible base32 fallback in the spec**

In section 4, replace the "Fallback for when the camera is unavailable" block with:

```markdown
### Fallback for when the camera is unavailable

**Not in v1.** An earlier draft said the Mac would show "the same secret as a
10-character base32 code". That is not possible: 10 base32 characters hold 50
bits and the secret is 256 bits.

If this path is built later, the corrected design is a **separate 80-bit secret
shown as 16 base32 characters in four groups of four**. Short enough to type
once, and far beyond offline brute force.
```

- [ ] **Step 2: Record what the spike found**

In section 9, replace the "Known risk to resolve early" text with what Task 0 actually proved: whether several pre-shared keys work on one listener, and therefore whether v1 supports one iPad or several.

- [ ] **Step 3: Update NOTES.md**

Append a `## 2026-08-13 — PadlinkCore complete` entry recording: the test count, the spike result, and that the Keychain store is still to be built in the app plans.

- [ ] **Step 4: Update CLAUDE.md**

The file still says this directory "is NOT a code repo — there's no app to ship". Replace that with a description of the hybrid: `NOTES.md` is the running journal, and `Padlink/` is a real codebase. Keep the existing rules about never logging secrets and asking before destructive commands.

- [ ] **Step 5: Verify the whole suite one more time and commit**

```bash
cd Padlink && swift test
cd .. && git add -A
git commit -m "Update spec and workspace notes after PadlinkCore"
```

---

## What comes after this plan

`PadlinkCore` is then a tested, dependency-free package. Two plans follow, written once the real API exists:

**Plan 2, macOS app:** Xcode project setup, menu bar app, Accessibility permission onboarding, `KeychainPairingStore`, `NWListener` service advertising, QR code generation and the pairing window, the paired-devices list with revoke, `CGEvent` synthesis for pointer/click/drag/scroll and both typing paths, and the release-everything routine wired to the `incoming` stream finishing.

**Plan 3, iPadOS app:** Xcode target, `NWBrowser` discovery and reconnect with backoff, camera QR scanning, `KeychainPairingStore`, the raw-touch trackpad surface and its gesture map, the button bar, the system keyboard with its accessory row and latching modifiers, hardware keyboard pass-through, and the round-trip latency readout.

Both then need the manual verification pass from spec section 10, on your real MacBook Air and iPad Air.
