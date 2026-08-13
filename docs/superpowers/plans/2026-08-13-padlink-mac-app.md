# Padlink macOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Padlink macOS menu bar app, so a command line test client can move the cursor and type on the Mac over an encrypted Wi-Fi connection.

**Architecture:** Two protocol-level additions land in `PadlinkCore` first (a `modifierState` message and `HeldInputState`). Then an XcodeGen-generated macOS app target consumes Core. Inside the app, all decisions live in `MessageRouter` behind an `InputSynthesizing` protocol so they can be tested with a fake, and the only untestable code is a thin `MacInputSynthesizer` that calls `CGEvent`.

**Tech Stack:** Swift 6.2, SwiftUI (`MenuBarExtra`), AppKit (`NSScreen`), Network.framework, Security (Keychain), CoreGraphics (`CGEvent`), CoreImage (QR generation), XcodeGen, swift-testing, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-13-padlink-mac-app-design.md`
**Product spec:** `docs/superpowers/specs/2026-08-13-padlink-design.md`

## Global Constraints

- **Two test commands, and both must pass before a task is complete.**
  - Core: `swift test`, run from `Padlink/`
  - App: `xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`, run from `Padlink/`
- **A stale `.xcodeproj` silently runs zero of your new tests instead of erroring.** Measured on Task 4. After adding any file to `PadlinkMac/` or `PadlinkMacTests/`, run `xcodegen generate`, and then **check the test count went up, not just that the command exited 0**. A green run that never executed your tests is the most dangerous outcome available here, because it looks identical to success. Count them with:

  ```
  xcodebuild test -scheme PadlinkMac -destination 'platform=macOS,arch=arm64' 2>&1 | grep -cE "^Test Case .* passed"
  ```

  Running counts so far: Task 3 left 1 app test, Task 4 left 8.
- `xcode-select` points at `/Applications/Xcode.app`, so no `DEVELOPER_DIR` prefix is needed. If `swift test` ever fails with `no such module 'Testing'`, that changed.
- **`PadlinkCore` must not import** `SwiftUI`, `UIKit`, `AppKit`, `CoreGraphics`, `AVFoundation`, or `CoreImage`. This is why screen clamping lives in the app, not Core.
- Bundle ID `com.hengkysandy.padlink.mac`. Deployment target macOS 15.
- Bonjour service type `_padlink._tcp`. Keychain service `com.hengkysandy.padlink`.
- Protocol version stays `1`. Nothing has shipped.
- `KeyModifiers` bits: 0 shift, 1 control, 2 option, 3 command, 4 function. Bits 5 to 7 reserved, must be zero, decoding rejects otherwise.
- Swift 6 strict concurrency. All public types `Sendable`.
- No `try!`, no `as!`, no force unwrapping outside tests.
- No third-party Swift dependencies. XcodeGen is a build tool, not a dependency.
- **Accepted `NWConnection` instances must be retained** or ARC frees them mid-handshake.
- **`.waiting` is a terminal failure** for a connection attempt; it is where a rejected pre-shared key surfaces.
- Commit messages use no em-dashes.
- The generated `PadlinkMac.xcodeproj` is gitignored. `project.yml` is the source of truth.

---

### Task 0: Spike — Keychain access from an ad-hoc-signed app

**Throwaway.** Output is an answer in `NOTES.md`, not shipped code. `PadlinkCore` shipped no Keychain implementation because an unsigned `swift test` binary cannot use the data protection keychain. The app is a real bundle so it should work, but "should" is the word that preceded the TLS 1.3 mistake.

**Files:**
- Create: `Padlink/KeychainSpike/` (deleted in the final step)

- [ ] **Step 1: Create a throwaway app target**

Create `Padlink/KeychainSpike/project.yml`:

```yaml
name: KeychainSpike
options:
  deploymentTarget:
    macOS: "15.0"
targets:
  KeychainSpike:
    type: application
    platform: macOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.hengkysandy.padlink.keychainspike
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: "YES"
```

Create `Padlink/KeychainSpike/Sources/main.swift`:

```swift
import Foundation
import Security

func probe(useDataProtection: Bool) {
    let label = useDataProtection ? "data protection keychain" : "legacy file keychain"
    let account = "spike-\(useDataProtection ? "dp" : "legacy")"
    let payload = Data("hello".utf8)

    var add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hengkysandy.padlink.spike",
        kSecAttrAccount as String: account,
        kSecValueData as String: payload,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    if useDataProtection { add[kSecUseDataProtectionKeychain as String] = true }

    var deleteQuery = add
    deleteQuery.removeValue(forKey: kSecValueData as String)
    deleteQuery.removeValue(forKey: kSecAttrAccessible as String)
    SecItemDelete(deleteQuery as CFDictionary)

    let addStatus = SecItemAdd(add as CFDictionary, nil)
    print("\(label): SecItemAdd -> \(addStatus) \(addStatus == errSecSuccess ? "OK" : "FAIL")")

    var read = deleteQuery
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let readStatus = SecItemCopyMatching(read as CFDictionary, &out)
    let roundTripped = (out as? Data) == payload
    print("\(label): SecItemCopyMatching -> \(readStatus), round trip \(roundTripped ? "OK" : "FAIL")")

    SecItemDelete(deleteQuery as CFDictionary)
}

probe(useDataProtection: true)
probe(useDataProtection: false)
print("spike done")
```

- [ ] **Step 2: Generate, build, and run it**

```bash
cd Padlink/KeychainSpike && xcodegen generate
xcodebuild -scheme KeychainSpike -configuration Debug -derivedDataPath .build build -quiet
./.build/Build/Products/Debug/KeychainSpike.app/Contents/MacOS/KeychainSpike
```

- [ ] **Step 3: Answer the four questions from the real output**

1. Does `kSecClassGenericPassword` save and load from an ad-hoc-signed bundle?
2. Does `kSecUseDataProtectionKeychain: true` work, or is the legacy keychain required?
3. Did anything prompt for a password?
4. Rebuild (`xcodebuild ... build` again) and re-run. Does access still work, or did the new binary lose it?

Report the verbatim output. If the data protection keychain fails and the legacy one works, **that is the answer** and Task 5 uses the legacy keychain.

- [ ] **Step 4: Record the finding and delete the spike**

Append to `NOTES.md` under `## 2026-08-13 — Spike: Keychain from an ad-hoc-signed app`: which keychain works, the exact status codes, whether a rebuild invalidates access, and the resulting decision for `KeychainPairingStore`.

```bash
rm -rf Padlink/KeychainSpike
git add NOTES.md
git commit -m "Record Keychain spike result"
```

---

### Task 1: `modifierState` message in the wire protocol

**Files:**
- Modify: `Padlink/Sources/PadlinkCore/Protocol/Messages.swift`
- Modify: `Padlink/Sources/PadlinkCore/Protocol/MessageCodec.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift`

**Interfaces:**
- Consumes: `KeyModifiers`, `ClientMessage`, `ByteWriter`, `ByteReader`, `CodecError`.
- Produces: `ClientMessage.modifierState(modifiers: KeyModifiers)`, wire type byte `8`.

Why this exists: holding Command across several Tab presses needs Command to stay down between keystrokes. Attaching modifiers to a `keyCode` message cannot express that. This message reports the **complete current state**, not a delta, so a lost message self-corrects on the next one.

- [ ] **Step 1: Write the failing tests**

Add to `MessageCodecTests.swift`, and add the new case to the existing `allClientMessages` array so it is covered by the round-trip test:

```swift
@Test func modifierStateRoundTrips() throws {
    let message = ClientMessage.modifierState(modifiers: [.command, .shift])
    let encoded = try ClientMessageCodec.encode(message)
    #expect(try ClientMessageCodec.decode(encoded) == message)
}

@Test func modifierStateWithNoModifiersRoundTrips() throws {
    let message = ClientMessage.modifierState(modifiers: [])
    #expect(try ClientMessageCodec.decode(try ClientMessageCodec.encode(message)) == message)
}

@Test func modifierStateUsesTypeByte8() throws {
    let encoded = try ClientMessageCodec.encode(.modifierState(modifiers: [.command]))
    #expect(encoded.first == 8)
}

@Test func modifierStateRejectsReservedBits() {
    // type 8, modifiers 0b0010_0000 (bit 5 is reserved)
    #expect(throws: CodecError.reservedModifierBitsSet(0b0010_0000)) {
        _ = try ClientMessageCodec.decode(Data([8, 0b0010_0000]))
    }
}
```

Also add `.modifierState(modifiers: [.command, .function])` to the `allClientMessages` array.

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && swift test --filter MessageCodec`
Expected: FAIL, `type 'ClientMessage' has no member 'modifierState'`.

- [ ] **Step 3: Implement**

In `Messages.swift`, add to `ClientMessage`:

```swift
    /// The complete current modifier state, reported on its own rather than
    /// attached to a keystroke. This is what lets Command stay held across
    /// several Tab presses, which the macOS app switcher requires.
    ///
    /// It is absolute, not a delta, so a lost message self-corrects on the
    /// next one instead of leaving the two sides permanently disagreeing.
    case modifierState(modifiers: KeyModifiers)
```

In `MessageCodec.swift`, add to `ClientMessageCodec.TypeByte`:

```swift
        case modifierState = 8
```

Add to `encode`:

```swift
        case let .modifierState(modifiers):
            writer.write(TypeByte.modifierState.rawValue)
            writer.write(modifiers.rawValue)
```

Add to `decode`:

```swift
        case .modifierState:
            let rawModifiers = try reader.readUInt8()
            guard rawModifiers & KeyModifiers.reservedMask.rawValue == 0 else {
                throw CodecError.reservedModifierBitsSet(rawModifiers)
            }
            message = .modifierState(modifiers: KeyModifiers(rawValue: rawModifiers))
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && swift test --filter MessageCodec`
Expected: PASS.

- [ ] **Step 5: Run the full Core suite and commit**

```bash
cd Padlink && swift test
git add Padlink/Sources/PadlinkCore/Protocol Padlink/Tests/PadlinkCoreTests/MessageCodecTests.swift
git commit -m "Add modifierState message so modifiers can be held across keystrokes"
```

---

### Task 2: `HeldInputState` in Core

**Files:**
- Create: `Padlink/Sources/PadlinkCore/Input/HeldInputState.swift`
- Test: `Padlink/Tests/PadlinkCoreTests/HeldInputStateTests.swift`

**Interfaces:**
- Consumes: `PointerButton`, `KeyModifiers`.
- Produces:
  - `public enum ReleaseAction: Equatable, Sendable` with `case button(PointerButton)` and `case modifier(KeyModifiers)`.
  - `public struct HeldInputState: Sendable, Equatable` with `init()`, `var heldButtons: Set<PointerButton>` (get), `var heldModifiers: KeyModifiers` (get), `var isEmpty: Bool`, `mutating func recordButton(_:isDown:)`, `mutating func recordModifiers(_:)`, `mutating func drainReleases() -> [ReleaseAction]`.

This is the type that prevents a stuck Command key. It lives in Core rather than the app because it is pure bookkeeping, so here it gets real tests with no Mac and no device.

`.modifier` carries **one flag per action**, so the synthesizer that consumes it stays dumb and simply posts one key event per action.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/Tests/PadlinkCoreTests/HeldInputStateTests.swift
import Testing
@testable import PadlinkCore

@Test func startsEmpty() {
    let state = HeldInputState()
    #expect(state.isEmpty)
    #expect(state.heldButtons.isEmpty)
    #expect(state.heldModifiers.isEmpty)
}

@Test func tracksAHeldButton() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    #expect(state.heldButtons == [.left])
    #expect(state.isEmpty == false)
    state.recordButton(.left, isDown: false)
    #expect(state.heldButtons.isEmpty)
    #expect(state.isEmpty)
}

@Test func tracksModifiers() {
    var state = HeldInputState()
    state.recordModifiers([.command, .shift])
    #expect(state.heldModifiers == [.command, .shift])
    state.recordModifiers([.command])
    #expect(state.heldModifiers == [.command])
    state.recordModifiers([])
    #expect(state.isEmpty)
}

@Test func drainReturnsButtonsThenModifiers() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    state.recordModifiers([.command])

    let releases = state.drainReleases()
    #expect(releases == [.button(.left), .modifier(.command)])
}

@Test func drainEmitsOneActionPerHeldModifier() {
    var state = HeldInputState()
    state.recordModifiers([.command, .shift, .option])

    let releases = state.drainReleases()
    let modifiers = releases.compactMap { action -> KeyModifiers? in
        if case let .modifier(m) = action { return m }
        return nil
    }
    #expect(Set(modifiers.map(\.rawValue))
        == Set([KeyModifiers.shift, .option, .command].map(\.rawValue)))
    #expect(modifiers.count == 3)
}

@Test func drainClearsTheStateSoASecondDrainIsEmpty() {
    // This is the property that matters: a disconnect during a drag must not
    // release the same button twice if the release path runs more than once.
    var state = HeldInputState()
    state.recordButton(.right, isDown: true)
    state.recordModifiers([.control])

    #expect(state.drainReleases().isEmpty == false)
    #expect(state.drainReleases().isEmpty)
    #expect(state.isEmpty)
}

@Test func drainOnAnEmptyStateProducesNothing() {
    var state = HeldInputState()
    #expect(state.drainReleases().isEmpty)
}

@Test func bothButtonsCanBeHeldAtOnce() {
    var state = HeldInputState()
    state.recordButton(.left, isDown: true)
    state.recordButton(.right, isDown: true)
    #expect(state.heldButtons == [.left, .right])
    #expect(state.drainReleases().count == 2)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && swift test --filter HeldInputState`
Expected: FAIL, `cannot find 'HeldInputState' in scope`.

- [ ] **Step 3: Implement**

```swift
// Padlink/Sources/PadlinkCore/Input/HeldInputState.swift
import Foundation

/// One thing the Mac must undo when a connection ends.
public enum ReleaseAction: Equatable, Sendable {
    case button(PointerButton)
    /// Exactly one modifier flag, so the consumer posts one key event per action.
    case modifier(KeyModifiers)
}

/// Tracks which mouse buttons and modifiers the peer currently has held, so
/// they can all be released when the connection ends.
///
/// Without this, a connection dying mid-drag leaves a stuck Command key and a
/// Mac that behaves strangely until it is rebooted.
///
/// This lives in Core rather than the Mac app because it is pure bookkeeping
/// with no OS calls, so it can be tested with no Mac and no device.
public struct HeldInputState: Sendable, Equatable {
    public private(set) var heldButtons: Set<PointerButton> = []
    public private(set) var heldModifiers: KeyModifiers = []

    public init() {}

    public var isEmpty: Bool {
        heldButtons.isEmpty && heldModifiers.isEmpty
    }

    public mutating func recordButton(_ button: PointerButton, isDown: Bool) {
        if isDown {
            heldButtons.insert(button)
        } else {
            heldButtons.remove(button)
        }
    }

    /// Absolute, not a delta: this replaces the held set entirely.
    public mutating func recordModifiers(_ modifiers: KeyModifiers) {
        heldModifiers = modifiers
    }

    /// Returns everything that must be released, and clears the state so a
    /// second call returns nothing. Buttons come before modifiers, in a fixed
    /// order, so the result is deterministic and testable.
    public mutating func drainReleases() -> [ReleaseAction] {
        var actions: [ReleaseAction] = []

        for button in PointerButton.allCases where heldButtons.contains(button) {
            actions.append(.button(button))
        }

        let allModifiers: [KeyModifiers] = [.shift, .control, .option, .command, .function]
        for modifier in allModifiers where heldModifiers.contains(modifier) {
            actions.append(.modifier(modifier))
        }

        heldButtons.removeAll()
        heldModifiers = []
        return actions
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && swift test --filter HeldInputState`
Expected: PASS, 8 tests.

- [ ] **Step 5: Run the full suite and commit**

```bash
cd Padlink && swift test
git add Padlink/Sources/PadlinkCore/Input/HeldInputState.swift Padlink/Tests/PadlinkCoreTests/HeldInputStateTests.swift
git commit -m "Add HeldInputState so a dropped connection releases held input"
```

---

### Task 3: XcodeGen project and a launching menu bar app

**Files:**
- Create: `Padlink/project.yml`
- Create: `Padlink/PadlinkMac/PadlinkMacApp.swift`
- Create: `Padlink/PadlinkMacTests/ProjectSmokeTests.swift`
- Modify: `.gitignore`
- Generated by XcodeGen, not written by hand: `Padlink/PadlinkMac/Info.plist`, `Padlink/PadlinkMac.xcodeproj`

**Interfaces:**
- Produces: an `xcodebuild`-testable app target named `PadlinkMac` that links `PadlinkCore`.

This task's deliverable is the build system working end to end. Its test is deliberately trivial: it proves the target exists, links Core, and can run tests, which is the thing that actually breaks.

**A build failure the Task 0 spike already hit, so you do not have to.** Its `project.yml` had no `info:` block, so the target had neither a generated Info.plist nor a path to one, and the build failed at code signing.

**Both targets need a plist, by different routes.** `PadlinkMac` gets one from its `info:` block, which makes XcodeGen generate the file at that path. Do not also hand-write it: XcodeGen overwrites it. `PadlinkMacTests` has no `info:` block, so it carries `GENERATE_INFOPLIST_FILE: "YES"` instead and lets Xcode synthesize one. Both are already in the `project.yml` below.

If you still hit a signing or Info.plist error on either target, add `GENERATE_INFOPLIST_FILE: "YES"` to that target's `settings.base` and say so in your report.

- [ ] **Step 1: Ignore the generated project and plist**

Append to `.gitignore`:

```
# Generated by XcodeGen from Padlink/project.yml
*.xcodeproj
Padlink/PadlinkMac/Info.plist
```

- [ ] **Step 2: Write `project.yml`**

```yaml
name: PadlinkMac
options:
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true

packages:
  PadlinkCore:
    path: .

targets:
  PadlinkMac:
    type: application
    platform: macOS
    sources:
      - PadlinkMac
    dependencies:
      - package: PadlinkCore
        product: PadlinkCore
    info:
      path: PadlinkMac/Info.plist
      properties:
        CFBundleName: Padlink
        CFBundleDisplayName: Padlink
        # Menu bar only. No Dock icon, no main window.
        LSUIElement: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.hengkysandy.padlink.mac
        MARKETING_VERSION: "0.1"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        # Ad-hoc signing for local development. Release builds use a
        # Developer ID identity and notarization instead.
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: "YES"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""

  PadlinkMacTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - PadlinkMacTests
    dependencies:
      - target: PadlinkMac
    settings:
      base:
        SWIFT_VERSION: "6.0"
        # A test bundle needs an Info.plist too, and this target has no
        # `info:` block to generate one from. Without this it fails at code
        # signing with "target has no Info.plist". Measured on this task.
        GENERATE_INFOPLIST_FILE: "YES"

schemes:
  PadlinkMac:
    build:
      targets:
        PadlinkMac: all
    test:
      targets:
        - PadlinkMacTests
    run:
      config: Debug
```

- [ ] **Step 3: Write the app**

Do **not** create `Info.plist` by hand. XcodeGen generates it at the path in `project.yml` from the `properties:` block, and would overwrite anything written there.

`Padlink/PadlinkMac/PadlinkMacApp.swift`:

```swift
import SwiftUI
import PadlinkCore

@main
struct PadlinkMacApp: App {
    var body: some Scene {
        MenuBarExtra("Padlink", systemImage: "keyboard") {
            Text("Padlink \(Padlink.protocolVersion)")
            Divider()
            Button("Quit Padlink") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 4: Write the smoke test**

```swift
// Padlink/PadlinkMacTests/ProjectSmokeTests.swift
import XCTest
import PadlinkCore

final class ProjectSmokeTests: XCTestCase {
    /// Proves the app target exists, links PadlinkCore, and can run tests.
    /// The build system is what breaks here, not this assertion.
    func testAppTargetLinksPadlinkCore() {
        XCTAssertEqual(Padlink.protocolVersion, 1)
        XCTAssertEqual(Padlink.bonjourServiceType, "_padlink._tcp")
    }
}
```

- [ ] **Step 5: Generate, then run the test to see it fail before the project exists**

Run this first, before generating, to observe the red state:

```bash
cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet
```

Expected: FAIL, no such scheme, because the project has not been generated.

Then generate and run again:

```bash
cd Padlink && xcodegen generate
xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet
```

Expected: PASS.

- [ ] **Step 6: Confirm Core still builds and commit**

```bash
cd Padlink && swift test
git add .gitignore Padlink/project.yml Padlink/PadlinkMac Padlink/PadlinkMacTests
git commit -m "Add XcodeGen project and a launching menu bar app"
```

---

### Task 4: Screen geometry and coordinate conversion

**Files:**
- Create: `Padlink/PadlinkMac/ScreenGeometry.swift`
- Test: `Padlink/PadlinkMacTests/ScreenGeometryTests.swift`

**Interfaces:**
- Produces: `struct ScreenGeometry` with `init(topLeftFrames: [CGRect])`, `static func topLeftFrames(fromBottomLeft frames: [CGRect], primaryHeight: CGFloat) -> [CGRect]`, and `func clamp(_ point: CGPoint) -> CGPoint`.

**The trap this task exists to defuse:** `NSScreen.frame` uses a **bottom-left** origin. `CGEvent` cursor locations use a **top-left** origin. Getting this wrong flips the cursor vertically, and on a single screen it looks almost plausible, which makes it hard to spot.

Conversion, given the primary screen's height `H`: `topLeftY = H - (bottomLeftY + height)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/PadlinkMacTests/ScreenGeometryTests.swift
import XCTest
@testable import PadlinkMac

final class ScreenGeometryTests: XCTestCase {
    func testPrimaryScreenConvertsToOriginZero() {
        let converted = ScreenGeometry.topLeftFrames(
            fromBottomLeft: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            primaryHeight: 900
        )
        XCTAssertEqual(converted, [CGRect(x: 0, y: 0, width: 1440, height: 900)])
    }

    func testScreenAbovePrimaryGetsNegativeTopLeftY() {
        // A second display sitting above the primary one. In bottom-left
        // coordinates its origin.y is positive; in top-left it is negative.
        let converted = ScreenGeometry.topLeftFrames(
            fromBottomLeft: [
                CGRect(x: 0, y: 0, width: 1440, height: 900),
                CGRect(x: 0, y: 900, width: 1920, height: 1080)
            ],
            primaryHeight: 900
        )
        XCTAssertEqual(converted[1], CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testClampKeepsAPointInsideTheScreen() {
        let geometry = ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        XCTAssertEqual(geometry.clamp(CGPoint(x: 700, y: 400)), CGPoint(x: 700, y: 400))
    }

    func testClampPullsAPointBackOntoTheScreen() {
        let geometry = ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        let clamped = geometry.clamp(CGPoint(x: 5000, y: -200))
        XCTAssertEqual(clamped.x, 1439, accuracy: 1)
        XCTAssertEqual(clamped.y, 0, accuracy: 1)
    }

    func testAPointOnASecondScreenIsLeftAlone() {
        let geometry = ScreenGeometry(topLeftFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        ])
        let point = CGPoint(x: 2000, y: 500)
        XCTAssertEqual(geometry.clamp(point), point)
    }

    func testAPointInTheGapSnapsToTheNearestScreen() {
        // Two screens of different heights side by side leave a gap below the
        // shorter one. A point there belongs to no screen and must snap.
        let geometry = ScreenGeometry(topLeftFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        ])
        let inGap = CGPoint(x: 700, y: 1000)
        let clamped = geometry.clamp(inGap)
        XCTAssertEqual(clamped.x, 700, accuracy: 1)
        XCTAssertEqual(clamped.y, 899, accuracy: 1)
    }

    func testNoScreensReturnsThePointUnchanged() {
        let geometry = ScreenGeometry(topLeftFrames: [])
        let point = CGPoint(x: 10, y: 10)
        XCTAssertEqual(geometry.clamp(point), point)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'ScreenGeometry' in scope`.

- [ ] **Step 3: Implement**

```swift
// Padlink/PadlinkMac/ScreenGeometry.swift
import AppKit
import CoreGraphics

/// Screen layout in `CGEvent` coordinates, and cursor clamping.
///
/// `NSScreen.frame` uses a bottom-left origin. `CGEvent` cursor locations use
/// a top-left origin. Mixing them flips the cursor vertically, and on a single
/// screen the result looks almost plausible, so the conversion is explicit and
/// tested rather than done inline.
struct ScreenGeometry {
    /// Screen frames in top-left (`CGEvent`) coordinates.
    let topLeftFrames: [CGRect]

    init(topLeftFrames: [CGRect]) {
        self.topLeftFrames = topLeftFrames
    }

    /// Reads the current layout from AppKit. Not covered by tests, because it
    /// depends on the machine's real displays; the conversion it delegates to
    /// is tested.
    static func current() -> ScreenGeometry {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else {
            return ScreenGeometry(topLeftFrames: [])
        }
        return ScreenGeometry(
            topLeftFrames: topLeftFrames(
                fromBottomLeft: screens.map(\.frame),
                primaryHeight: primaryHeight
            )
        )
    }

    static func topLeftFrames(
        fromBottomLeft frames: [CGRect],
        primaryHeight: CGFloat
    ) -> [CGRect] {
        frames.map { frame in
            CGRect(
                x: frame.origin.x,
                y: primaryHeight - (frame.origin.y + frame.height),
                width: frame.width,
                height: frame.height
            )
        }
    }

    /// Keeps a point on a real screen. A point already on one is returned
    /// unchanged. A point in a gap between differently sized displays snaps to
    /// the nearest screen rather than being pushed to the union's edge.
    func clamp(_ point: CGPoint) -> CGPoint {
        guard topLeftFrames.isEmpty == false else { return point }

        if topLeftFrames.contains(where: { $0.contains(point) }) {
            return point
        }

        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for frame in topLeftFrames {
            let candidate = CGPoint(
                x: min(max(point.x, frame.minX), frame.maxX - 1),
                y: min(max(point.y, frame.minY), frame.maxY - 1)
            )
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }

        return best
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/ScreenGeometry.swift Padlink/PadlinkMacTests/ScreenGeometryTests.swift
git commit -m "Add screen geometry with explicit bottom-left to top-left conversion"
```

---

### Task 5: `InputSynthesizing` protocol and the `CGEvent` implementation

**Files:**
- Create: `Padlink/PadlinkMac/InputSynthesizing.swift`
- Create: `Padlink/PadlinkMac/MacInputSynthesizer.swift`

**Interfaces:**
- Consumes: `PointerButton`, `KeyModifiers` from Core.
- Produces:

```swift
protocol InputSynthesizing: AnyObject {
    var currentCursorLocation: CGPoint { get }
    func moveCursor(to point: CGPoint, draggingButton: PointerButton?)
    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int)
    func scroll(deltaX: Int32, deltaY: Int32)
    func insertText(_ text: String)
    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers)
    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool)
}
```

This protocol is the seam that makes everything else testable. `MacInputSynthesizer` contains **no decisions**, only OS calls, so the untestable surface is a handful of one-line functions. There is no test for this task: it is the deliberately untestable layer, and Task 6 tests the decisions that drive it.

- [ ] **Step 1: Write the protocol**

```swift
// Padlink/PadlinkMac/InputSynthesizing.swift
import CoreGraphics
import PadlinkCore

/// The seam between decisions and OS calls.
///
/// Everything that decides *what* input to produce lives in `MessageRouter`
/// and talks to this protocol. The only implementation that touches the OS is
/// `MacInputSynthesizer`, which contains no decisions at all. That keeps the
/// untestable surface to a handful of one-line functions and lets the routing
/// be tested with a recording fake.
protocol InputSynthesizing: AnyObject {
    var currentCursorLocation: CGPoint { get }
    func moveCursor(to point: CGPoint, draggingButton: PointerButton?)
    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int)
    func scroll(deltaX: Int32, deltaY: Int32)
    func insertText(_ text: String)
    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers)
    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool)
}
```

- [ ] **Step 2: Write the implementation**

```swift
// Padlink/PadlinkMac/MacInputSynthesizer.swift
import CoreGraphics
import PadlinkCore

/// Posts real input events. No decisions live here on purpose.
final class MacInputSynthesizer: InputSynthesizing {
    /// Virtual key codes for the modifier keys themselves. Posting a key event
    /// for one of these is what makes macOS emit the `flagsChanged` event that
    /// the application switcher and similar UI depend on.
    private static let modifierVirtualKeys: [(KeyModifiers, UInt16)] = [
        (.shift, 0x38),
        (.control, 0x3B),
        (.option, 0x3A),
        (.command, 0x37),
        (.function, 0x3F)
    ]

    var currentCursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveCursor(to point: CGPoint, draggingButton: PointerButton?) {
        // While a button is held, movement MUST be posted as a drag. Many apps
        // ignore plain moves during a drag, so text selection and window
        // dragging would silently not work.
        let type: CGEventType
        let button: CGMouseButton
        switch draggingButton {
        case .left:
            type = .leftMouseDragged
            button = .left
        case .right:
            type = .rightMouseDragged
            button = .right
        case nil:
            type = .mouseMoved
            button = .left
        }

        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:
            type = isDown ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case .right:
            type = isDown ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        }

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: cgButton
        )
        // Without this, macOS never recognises a double click.
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        // Pixel units give smooth scrolling rather than notched jumps.
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    func insertText(_ text: String) {
        // Virtual key 0 plus a unicode string types the character correctly
        // whatever keyboard layout the Mac is set to, and handles accents,
        // emoji, and non-Latin scripts with no mapping table.
        var utf16 = Array(text.utf16)
        guard utf16.isEmpty == false else { return }

        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
            else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(virtualCode),
            keyDown: isDown
        ) else { return }
        event.flags = Self.cgFlags(from: modifiers)
        event.post(tap: .cghidEventTap)
    }

    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool) {
        guard let entry = Self.modifierVirtualKeys.first(where: { $0.0 == modifier }) else { return }
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(entry.1),
            keyDown: isDown
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func cgFlags(from modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, the existing tests still pass and the new files compile.

- [ ] **Step 4: Commit**

```bash
git add Padlink/PadlinkMac/InputSynthesizing.swift Padlink/PadlinkMac/MacInputSynthesizer.swift
git commit -m "Add the input synthesis seam and its CGEvent implementation"
```

---

### Task 6: `MessageRouter`

**Files:**
- Create: `Padlink/PadlinkMac/MessageRouter.swift`
- Create: `Padlink/PadlinkMacTests/RecordingSynthesizer.swift`
- Test: `Padlink/PadlinkMacTests/MessageRouterTests.swift`

**Interfaces:**
- Consumes: `InputSynthesizing`, `ScreenGeometry`, and from Core: `ClientMessage`, `HeldInputState`, `ReleaseAction`, `PointerAcceleration`, `MacVirtualKeys`, `KeyModifiers`, `PointerButton`.

**`KeyRouter` is deliberately absent from that list.** It decides between the unicode path and the key code path, but that decision happens on the **iPad**, before the message is sent. By the time the Mac receives a message the choice is already expressed as `.keyText` versus `.keyCode`, so `MessageRouter` only maps each case to the matching synthesizer call. The Mac never calls `KeyRouter`; the test client in Task 12 does, because it stands in for the iPad.
- Produces: `final class MessageRouter` with `init(synthesizer: any InputSynthesizing, geometry: ScreenGeometry, acceleration: PointerAcceleration = .default)`, `func handle(_ message: ClientMessage)`, `func releaseEverything()`, and `private(set) var held: HeldInputState`.

This is where every decision lives, and therefore where the real tests are.

- [ ] **Step 1: Write the recording fake**

```swift
// Padlink/PadlinkMacTests/RecordingSynthesizer.swift
import CoreGraphics
import PadlinkCore
@testable import PadlinkMac

/// Records what it was asked to do instead of touching the OS, so routing
/// decisions can be tested without moving the real cursor.
final class RecordingSynthesizer: InputSynthesizing {
    enum Call: Equatable {
        case move(to: CGPoint, dragging: PointerButton?)
        case button(PointerButton, isDown: Bool, at: CGPoint, clickCount: Int)
        case scroll(deltaX: Int32, deltaY: Int32)
        case insertText(String)
        case key(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers)
        case modifierKey(KeyModifiers, isDown: Bool)
    }

    private(set) var calls: [Call] = []
    var cursorLocation = CGPoint(x: 100, y: 100)

    var currentCursorLocation: CGPoint { cursorLocation }

    func moveCursor(to point: CGPoint, draggingButton: PointerButton?) {
        calls.append(.move(to: point, dragging: draggingButton))
        cursorLocation = point
    }

    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int) {
        calls.append(.button(button, isDown: isDown, at: point, clickCount: clickCount))
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        calls.append(.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    func insertText(_ text: String) {
        calls.append(.insertText(text))
    }

    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers) {
        calls.append(.key(virtualCode: virtualCode, isDown: isDown, modifiers: modifiers))
    }

    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool) {
        calls.append(.modifierKey(modifier, isDown: isDown))
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Padlink/PadlinkMacTests/MessageRouterTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

final class MessageRouterTests: XCTestCase {
    private var synthesizer: RecordingSynthesizer!
    private var router: MessageRouter!

    override func setUp() {
        super.setUp()
        synthesizer = RecordingSynthesizer()
        router = MessageRouter(
            synthesizer: synthesizer,
            geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        )
    }

    func testPointerMoveWithNoButtonHeldIsAMove() {
        router.handle(.pointerMove(dx: 10, dy: 0, dtMicros: 16_666))
        guard case let .move(_, dragging) = synthesizer.calls.first else {
            return XCTFail("expected a move, got \(synthesizer.calls)")
        }
        XCTAssertNil(dragging)
    }

    func testPointerMoveWhileAButtonIsHeldIsADrag() {
        // The gotcha this test exists for: many apps ignore plain moves during
        // a drag, so text selection and window dragging would silently break.
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.pointerMove(dx: 10, dy: 0, dtMicros: 16_666))

        guard case let .move(_, dragging) = synthesizer.calls.last else {
            return XCTFail("expected a move, got \(synthesizer.calls)")
        }
        XCTAssertEqual(dragging, .left)
    }

    func testPointerMoveIsClampedToTheScreen() {
        synthesizer.cursorLocation = CGPoint(x: 1439, y: 400)
        router.handle(.pointerMove(dx: 32_000, dy: 0, dtMicros: 16_666))

        guard case let .move(point, _) = synthesizer.calls.first else {
            return XCTFail("expected a move")
        }
        XCTAssertLessThanOrEqual(point.x, 1439)
    }

    func testPlainTextTakesTheUnicodePath() {
        router.handle(.keyText("hello"))
        XCTAssertEqual(synthesizer.calls, [.insertText("hello")])
    }

    func testAKeyCodeMessageTakesTheVirtualKeyPath() {
        router.handle(.keyCode(key: .c, isDown: true, modifiers: [.command]))
        XCTAssertEqual(
            synthesizer.calls,
            [.key(virtualCode: MacVirtualKeys.code(for: .c), isDown: true, modifiers: [.command])]
        )
    }

    func testScrollIsForwarded() {
        router.handle(.scroll(dx: 3, dy: -120))
        XCTAssertEqual(synthesizer.calls, [.scroll(deltaX: 3, deltaY: -120)])
    }

    func testModifierStatePostsOnlyWhatChanged() {
        router.handle(.modifierState(modifiers: [.command]))
        XCTAssertEqual(synthesizer.calls, [.modifierKey(.command, isDown: true)])

        // Adding shift must not re-post command.
        router.handle(.modifierState(modifiers: [.command, .shift]))
        XCTAssertEqual(synthesizer.calls.last, .modifierKey(.shift, isDown: true))
        XCTAssertEqual(synthesizer.calls.count, 2)

        // Dropping command must release only command.
        router.handle(.modifierState(modifiers: [.shift]))
        XCTAssertEqual(synthesizer.calls.last, .modifierKey(.command, isDown: false))
        XCTAssertEqual(synthesizer.calls.count, 3)
    }

    func testRepeatingTheSameModifierStatePostsNothing() {
        router.handle(.modifierState(modifiers: [.command]))
        let countAfterFirst = synthesizer.calls.count
        router.handle(.modifierState(modifiers: [.command]))
        XCTAssertEqual(synthesizer.calls.count, countAfterFirst)
    }

    func testReleaseEverythingReleasesAHeldButtonAndModifier() {
        // This is the stuck-Command-key case.
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.modifierState(modifiers: [.command]))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        let releases = Array(synthesizer.calls.dropFirst(countBefore))
        XCTAssertTrue(releases.contains(where: {
            if case .button(.left, isDown: false, _, _) = $0 { return true }
            return false
        }))
        XCTAssertTrue(releases.contains(.modifierKey(.command, isDown: false)))
    }

    func testReleaseEverythingTwiceDoesNothingTheSecondTime() {
        router.handle(.pointerButton(button: .left, isDown: true))
        router.releaseEverything()
        let countAfterFirst = synthesizer.calls.count

        router.releaseEverything()
        XCTAssertEqual(synthesizer.calls.count, countAfterFirst)
    }

    func testReleaseEverythingWithNothingHeldPostsNothing() {
        router.releaseEverything()
        XCTAssertTrue(synthesizer.calls.isEmpty)
    }

    func testTwoQuickClicksAreReportedAsADoubleClick() {
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.pointerButton(button: .left, isDown: false))
        router.handle(.pointerButton(button: .left, isDown: true))

        guard case let .button(_, _, _, clickCount) = synthesizer.calls.last else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(clickCount, 2)
    }

    func testHelloAndPingAreIgnoredByTheRouter() {
        // These are handled by the service, not by input synthesis.
        router.handle(.hello(protocolVersion: 1, deviceName: "test"))
        router.handle(.ping(seq: 1))
        XCTAssertTrue(synthesizer.calls.isEmpty)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'MessageRouter' in scope`.

- [ ] **Step 4: Implement**

```swift
// Padlink/PadlinkMac/MessageRouter.swift
import CoreGraphics
import Foundation
import PadlinkCore

/// Turns decoded messages into synthesizer calls.
///
/// Every decision lives here rather than in `MacInputSynthesizer`, so it can
/// be tested with a recording fake and no real cursor movement.
final class MessageRouter {
    private let synthesizer: any InputSynthesizing
    private var geometry: ScreenGeometry
    private let acceleration: PointerAcceleration

    private(set) var held = HeldInputState()

    /// Double-click bookkeeping. macOS only recognises a double click when the
    /// event carries a click state above 1.
    private var lastClickTime: Date?
    private var lastClickButton: PointerButton?
    private var clickCount = 1
    private static let doubleClickInterval: TimeInterval = 0.5

    init(
        synthesizer: any InputSynthesizing,
        geometry: ScreenGeometry,
        acceleration: PointerAcceleration = .default
    ) {
        self.synthesizer = synthesizer
        self.geometry = geometry
        self.acceleration = acceleration
    }

    /// Called when displays are added, removed, or rearranged.
    func updateGeometry(_ geometry: ScreenGeometry) {
        self.geometry = geometry
    }

    func handle(_ message: ClientMessage) {
        switch message {
        case let .pointerMove(dx, dy, dtMicros):
            handlePointerMove(dx: dx, dy: dy, dtMicros: dtMicros)

        case let .pointerButton(button, isDown):
            handleButton(button, isDown: isDown)

        case let .scroll(dx, dy):
            synthesizer.scroll(deltaX: Int32(dx), deltaY: Int32(dy))

        case let .keyText(text):
            synthesizer.insertText(text)

        case let .keyCode(key, isDown, modifiers):
            synthesizer.postKey(
                virtualCode: MacVirtualKeys.code(for: key),
                isDown: isDown,
                modifiers: modifiers
            )

        case let .modifierState(modifiers):
            handleModifierState(modifiers)

        case .hello, .ping:
            // Owned by PadlinkService, not by input synthesis.
            break
        }
    }

    /// Releases every held button and modifier. Runs when the connection ends
    /// and when the app quits, so a drop mid-drag cannot leave a stuck key.
    func releaseEverything() {
        let point = synthesizer.currentCursorLocation
        for action in held.drainReleases() {
            switch action {
            case let .button(button):
                synthesizer.setButton(button, isDown: false, at: point, clickCount: 1)
            case let .modifier(modifier):
                synthesizer.postModifierKey(modifier, isDown: false)
            }
        }
    }

    private func handlePointerMove(dx: Int16, dy: Int16, dtMicros: UInt16) {
        let accelerated = acceleration.accelerate(
            dx: Double(dx),
            dy: Double(dy),
            dtSeconds: Double(dtMicros) / 1_000_000
        )

        let current = synthesizer.currentCursorLocation
        let target = geometry.clamp(CGPoint(
            x: current.x + accelerated.dx,
            y: current.y + accelerated.dy
        ))

        // Deterministic order, so a left and right button held at once always
        // drags with the same one.
        let dragging = held.heldButtons.contains(.left)
            ? PointerButton.left
            : (held.heldButtons.contains(.right) ? .right : nil)

        synthesizer.moveCursor(to: target, draggingButton: dragging)
    }

    private func handleButton(_ button: PointerButton, isDown: Bool) {
        if isDown {
            let now = Date()
            if let last = lastClickTime,
               lastClickButton == button,
               now.timeIntervalSince(last) < Self.doubleClickInterval {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickButton = button
        }

        held.recordButton(button, isDown: isDown)
        synthesizer.setButton(
            button,
            isDown: isDown,
            at: synthesizer.currentCursorLocation,
            clickCount: clickCount
        )
    }

    private func handleModifierState(_ modifiers: KeyModifiers) {
        let previous = held.heldModifiers
        let all: [KeyModifiers] = [.shift, .control, .option, .command, .function]

        for modifier in all {
            let wasHeld = previous.contains(modifier)
            let isHeld = modifiers.contains(modifier)
            guard wasHeld != isHeld else { continue }
            synthesizer.postModifierKey(modifier, isDown: isHeld)
        }

        held.recordModifiers(modifiers)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 13 new tests plus the existing ones.

- [ ] **Step 6: Commit**

```bash
git add Padlink/PadlinkMac/MessageRouter.swift Padlink/PadlinkMacTests/RecordingSynthesizer.swift Padlink/PadlinkMacTests/MessageRouterTests.swift
git commit -m "Add MessageRouter with the drag, typing, and modifier decisions"
```

---

### Task 7: Accessibility permission status

**Files:**
- Create: `Padlink/PadlinkMac/AccessibilityStatus.swift`
- Test: `Padlink/PadlinkMacTests/AccessibilityStatusTests.swift`

**Interfaces:**
- Produces: `@MainActor final class AccessibilityStatus: ObservableObject` with `init(checker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }, pollInterval: TimeInterval = 1.0)`, `@Published private(set) var isTrusted: Bool`, `func refresh()`, `func startPolling()`, `func stopPolling()`, `func openSystemSettings()`.

macOS will not deliver synthesized input from an untrusted app. The check is injected so the polling behaviour can be tested without changing real system permissions.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/PadlinkMacTests/AccessibilityStatusTests.swift
import XCTest
@testable import PadlinkMac

@MainActor
final class AccessibilityStatusTests: XCTestCase {
    func testReadsTheInitialValueFromTheChecker() {
        let status = AccessibilityStatus(checker: { true })
        XCTAssertTrue(status.isTrusted)
    }

    func testReportsUntrustedWhenTheCheckerSaysSo() {
        let status = AccessibilityStatus(checker: { false })
        XCTAssertFalse(status.isTrusted)
    }

    func testRefreshPicksUpAChange() {
        // The real case: the user flips the switch in System Settings while
        // the app is running, and the UI must update without a restart.
        let granted = LockedFlag(false)
        let status = AccessibilityStatus(checker: { granted.value })
        XCTAssertFalse(status.isTrusted)

        granted.value = true
        status.refresh()
        XCTAssertTrue(status.isTrusted)
    }

    func testPollingPicksUpAChangeWithoutAnExplicitRefresh() {
        let granted = LockedFlag(false)
        let status = AccessibilityStatus(checker: { granted.value }, pollInterval: 0.01)
        status.startPolling()
        granted.value = true

        let updated = expectation(description: "isTrusted becomes true")
        Task { @MainActor in
            for _ in 0 ..< 200 where status.isTrusted == false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if status.isTrusted { updated.fulfill() }
        }
        wait(for: [updated], timeout: 5)
        status.stopPolling()
    }
}

/// Small thread-safe box, because the checker closure is @Sendable.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'AccessibilityStatus' in scope`.

- [ ] **Step 3: Implement**

```swift
// Padlink/PadlinkMac/AccessibilityStatus.swift
import AppKit
import ApplicationServices
import Foundation

/// Whether macOS trusts this app to synthesize input.
///
/// Without this permission every posted `CGEvent` is silently dropped, which
/// looks exactly like a broken app. The check is injected so the polling
/// behaviour can be tested without changing real system permissions.
@MainActor
final class AccessibilityStatus: ObservableObject {
    @Published private(set) var isTrusted: Bool

    private let checker: @Sendable () -> Bool
    private let pollInterval: TimeInterval
    private var timer: Timer?

    init(
        checker: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        pollInterval: TimeInterval = 1.0
    ) {
        self.checker = checker
        self.pollInterval = pollInterval
        self.isTrusted = checker()
    }

    func refresh() {
        let current = checker()
        if current != isTrusted {
            isTrusted = current
        }
    }

    /// Polls so the UI updates the moment the user flips the switch in System
    /// Settings, with no restart and no "click here when done" button.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 4 new tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/AccessibilityStatus.swift Padlink/PadlinkMacTests/AccessibilityStatusTests.swift
git commit -m "Add Accessibility permission status with polling"
```

---

### Task 8: `KeychainPairingStore`

**Files:**
- Create: `Padlink/PadlinkMac/KeychainPairingStore.swift`
- Test: `Padlink/PadlinkMacTests/KeychainPairingStoreTests.swift`

**Interfaces:**
- Consumes: `PairingStore`, `PairingRecord`, `PairingID`, `PairingSecret`, `Padlink.keychainService` from Core.
- Produces: `final class KeychainPairingStore: PairingStore` with `init(service: String = Padlink.keychainService)`.

**Task 0's spike has run, and its answer is binding:** `kSecUseDataProtectionKeychain: true` **fails** from an ad-hoc-signed bundle with `errSecMissingEntitlement` (-34018). The legacy file keychain works, returns status 0 in both directions, and is unaffected by a rebuild. So that flag is **not set** anywhere in this task.

When a paid Developer ID identity and a keychain-access-group entitlement exist, the data protection keychain becomes available and is the better choice. That is a release-time change, not a development one, and it is recorded in `NOTES.md`.

**The record is encoded as JSON through a private DTO, not by making `PairingRecord` itself `Codable`.** A public `Codable` conformance on a type holding a 256-bit pre-shared key invites it being serialised somewhere it should not be. The DTO keeps that ability private to this file.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/PadlinkMacTests/KeychainPairingStoreTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

final class KeychainPairingStoreTests: XCTestCase {
    private var store: KeychainPairingStore!
    private let testService = "com.hengkysandy.padlink.tests"

    override func setUpWithError() throws {
        store = KeychainPairingStore(service: testService)
        try store.deleteAll()
    }

    override func tearDownWithError() throws {
        try store.deleteAll()
    }

    private func record(_ byte: UInt8, name: String, serviceName: String? = "Test Mac") throws -> PairingRecord {
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: byte, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: byte, count: 32)))
        return PairingRecord(
            id: id,
            secret: secret,
            peerName: name,
            serviceName: serviceName,
            pairedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    func testSavesAndLoadsARecord() throws {
        let saved = try record(1, name: "iPad Air")
        try store.save(saved)
        XCTAssertEqual(try store.load(id: saved.id), saved)
    }

    func testTheSecretSurvivesTheRoundTripExactly() throws {
        // The whole product rests on this being byte-for-byte correct.
        let saved = try record(0xAB, name: "iPad")
        try store.save(saved)
        let loaded = try XCTUnwrap(try store.load(id: saved.id))
        XCTAssertEqual(loaded.secret.bytes, saved.secret.bytes)
    }

    func testLoadingAnUnknownIDReturnsNil() throws {
        let unknown = try XCTUnwrap(PairingID(bytes: Data(repeating: 9, count: 8)))
        XCTAssertNil(try store.load(id: unknown))
    }

    func testSavingTheSameIDTwiceReplaces() throws {
        let first = try record(2, name: "old name")
        try store.save(first)
        let second = PairingRecord(
            id: first.id,
            secret: first.secret,
            peerName: "new name",
            serviceName: first.serviceName,
            pairedAt: first.pairedAt
        )
        try store.save(second)

        XCTAssertEqual(try store.load(id: first.id)?.peerName, "new name")
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testLoadAllReturnsOldestFirst() throws {
        let older = try record(3, name: "older")
        let newerID = try XCTUnwrap(PairingID(bytes: Data(repeating: 4, count: 8)))
        let newerSecret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 4, count: 32)))
        let newer = PairingRecord(
            id: newerID,
            secret: newerSecret,
            peerName: "newer",
            serviceName: nil,
            pairedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        try store.save(newer)
        try store.save(older)

        XCTAssertEqual(try store.loadAll().map(\.peerName), ["older", "newer"])
    }

    func testANilServiceNameSurvives() throws {
        let saved = try record(5, name: "no service", serviceName: nil)
        try store.save(saved)
        XCTAssertNil(try store.load(id: saved.id)?.serviceName)
    }

    func testDeleteRemovesARecord() throws {
        let saved = try record(6, name: "gone")
        try store.save(saved)
        try store.delete(id: saved.id)
        XCTAssertNil(try store.load(id: saved.id))
    }

    func testDeletingAnUnknownIDIsNotAnError() throws {
        let unknown = try XCTUnwrap(PairingID(bytes: Data(repeating: 7, count: 8)))
        XCTAssertNoThrow(try store.delete(id: unknown))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'KeychainPairingStore' in scope`.

- [ ] **Step 3: Implement**

```swift
// Padlink/PadlinkMac/KeychainPairingStore.swift
import Foundation
import PadlinkCore
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedStoredRecord
}

/// A `PairingStore` backed by the Keychain.
///
/// The whole record is stored as one JSON value rather than spread across
/// Keychain attributes, because `peerName`, `pairedAt`, and `serviceName` have
/// no natural attribute and inventing one would be worse.
///
/// The JSON encoding lives in a private DTO rather than by making
/// `PairingRecord` itself `Codable`. A public `Codable` conformance on a type
/// holding a 256-bit pre-shared key invites it being serialised somewhere it
/// should not be.
final class KeychainPairingStore: PairingStore {
    private let service: String

    init(service: String = Padlink.keychainService) {
        self.service = service
    }

    private struct StoredRecord: Codable {
        let secret: Data
        let peerName: String
        let pairedAt: Date
        let serviceName: String?
    }

    private func baseQuery(account: String?) -> [String: Any] {
        // Deliberately NOT setting kSecUseDataProtectionKeychain. The Task 0
        // spike measured that it fails from an ad-hoc-signed bundle with
        // errSecMissingEntitlement (-34018). The legacy file keychain works
        // and survives rebuilds. Revisit when a Developer ID identity and a
        // keychain-access-group entitlement exist.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func save(_ record: PairingRecord) throws {
        let stored = StoredRecord(
            secret: record.secret.bytes,
            peerName: record.peerName,
            pairedAt: record.pairedAt,
            serviceName: record.serviceName
        )
        let data = try JSONEncoder().encode(stored)

        // Replace rather than add, so saving the same id twice does not
        // produce a duplicate item.
        SecItemDelete(baseQuery(account: record.id.hexString) as CFDictionary)

        var add = baseQuery(account: record.id.hexString)
        add[kSecValueData as String] = data
        // This device only, so the secret never syncs to iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func load(id: PairingID) throws -> PairingRecord? {
        var query = baseQuery(account: id.hexString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.malformedStoredRecord }

        return try decode(data, id: id)
    }

    /// Two passes on purpose. Asking for `kSecReturnData` and
    /// `kSecReturnAttributes` together with `kSecMatchLimitAll` fails with
    /// `errSecParam` (-50) on the legacy file keychain this app uses. Measured
    /// on Task 8 with a standalone script, and distinct from the -34018
    /// entitlement failure the Task 0 spike found.
    ///
    /// So: enumerate the accounts with an attributes-only query, then fetch
    /// each record's data through the single-item `load` path.
    func loadAll() throws -> [PairingRecord] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { throw KeychainError.malformedStoredRecord }

        var records: [PairingRecord] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = PairingID(hexString: account),
                  let record = try load(id: id)
            else { continue }
            records.append(record)
        }
        return records.sorted { $0.pairedAt < $1.pairedAt }
    }

    func delete(id: PairingID) throws {
        let status = SecItemDelete(baseQuery(account: id.hexString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Test support: removes every item under this store's service.
    func deleteAll() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func decode(_ data: Data, id: PairingID) throws -> PairingRecord {
        let stored = try JSONDecoder().decode(StoredRecord.self, from: data)
        guard let secret = PairingSecret(bytes: stored.secret) else {
            throw KeychainError.malformedStoredRecord
        }
        return PairingRecord(
            id: id,
            secret: secret,
            peerName: stored.peerName,
            serviceName: stored.serviceName,
            pairedAt: stored.pairedAt
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 8 new tests.

If these fail with `errSecMissingEntitlement` (-34018), a `kSecUseDataProtectionKeychain` entry has crept back in. It must not be there; see the note at the top of this task.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/KeychainPairingStore.swift Padlink/PadlinkMacTests/KeychainPairingStoreTests.swift
git commit -m "Add Keychain-backed pairing store"
```

---

### Task 9: QR code image from a pairing payload

**Files:**
- Create: `Padlink/PadlinkMac/QRCodeImage.swift`
- Test: `Padlink/PadlinkMacTests/QRCodeImageTests.swift`

**Interfaces:**
- Consumes: `PairingPayload` from Core.
- Produces: `enum QRCodeImage` with `static func make(from text: String, sideLength: CGFloat) -> NSImage?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Padlink/PadlinkMacTests/QRCodeImageTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

final class QRCodeImageTests: XCTestCase {
    func testProducesAnImageForAPairingPayload() throws {
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        let payload = PairingPayload(
            pairingID: id,
            secret: secret,
            macName: "Hengky's MacBook Air",
            serviceName: "Hengky MacBook Air"
        )

        let image = try XCTUnwrap(QRCodeImage.make(from: payload.urlString, sideLength: 240))
        XCTAssertEqual(image.size.width, 240, accuracy: 1)
        XCTAssertEqual(image.size.height, 240, accuracy: 1)
    }

    func testEmptyTextProducesNoImage() {
        XCTAssertNil(QRCodeImage.make(from: "", sideLength: 240))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'QRCodeImage' in scope`.

- [ ] **Step 3: Implement**

```swift
// Padlink/PadlinkMac/QRCodeImage.swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeImage {
    /// Renders text as a QR code. The generator produces a tiny image, so it
    /// is scaled up with nearest-neighbour sampling to keep the squares sharp.
    static func make(from text: String, sideLength: CGFloat) -> NSImage? {
        guard text.isEmpty == false else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction: enough tolerance for a screen-to-camera scan
        // without making the code denser than it needs to be.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // The generator's output is square, so one axis determines the scale.
        let scale = sideLength / output.extent.width
        // `.samplingNearest()` is load-bearing and easy to omit. CIImage's
        // default sampling for a geometry operation is linear, which softens
        // the module edges during rasterisation and makes the code scan
        // slowly or not at all. Measured on Task 9.
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: sideLength, height: sideLength))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 2 new tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/QRCodeImage.swift Padlink/PadlinkMacTests/QRCodeImageTests.swift
git commit -m "Add QR code rendering for the pairing payload"
```

---

### Task 10: `PadlinkService`

**Files:**
- Create: `Padlink/PadlinkMac/PadlinkService.swift`
- Test: `Padlink/PadlinkMacTests/PadlinkServiceTests.swift`

**Interfaces:**
- Consumes: `PadlinkTransport`, `PadlinkConnection`, `TLSPSK`, `PairingStore`, `PairingPayload`, `ClientMessageCodec`, `ServerMessage`, `CloseReason` from Core; `MessageRouter`, `KeychainPairingStore` from the app.
- Produces: `@MainActor final class PadlinkService: ObservableObject` with `init(store: any PairingStore, router: MessageRouter, macName: String)`, `@Published private(set) var state: ServiceState`, `func start() async`, `func beginPairing() throws -> PairingPayload`, `func cancelPairing()`, `func stop()`.
- Produces: `enum ServiceState: Equatable` with `idle`, `pairing(expiresAt: Date)`, `connected(deviceName: String)`, `failed(String)`.

**The listener is rebuilt whenever the key set changes.** Pre-shared keys are fixed when `NWParameters` is created, so the accepted set cannot change on a running listener. This happens three times around a pairing: when pairing opens, if it closes unpaired, and after a successful pairing.

- [ ] **Step 1: Write the failing tests**

These test the parts that do not need a live socket. The socket path is proven end to end in Task 12.

```swift
// Padlink/PadlinkMacTests/PadlinkServiceTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

@MainActor
final class PadlinkServiceTests: XCTestCase {
    private func makeService(store: any PairingStore = InMemoryPairingStore()) -> PadlinkService {
        PadlinkService(
            store: store,
            router: MessageRouter(
                synthesizer: RecordingSynthesizer(),
                geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
            ),
            macName: "Test Mac"
        )
    }

    func testStartsIdle() {
        XCTAssertEqual(makeService().state, .idle)
    }

    func testBeginPairingProducesAPayloadNamingThisMac() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(payload.macName, "Test Mac")
        XCTAssertEqual(payload.serviceName, "Test Mac")
    }

    func testBeginPairingMovesToThePairingState() throws {
        let service = makeService()
        _ = try service.beginPairing()
        guard case .pairing = service.state else {
            return XCTFail("expected pairing, got \(service.state)")
        }
    }

    func testTwoPairingAttemptsProduceDifferentSecrets() throws {
        let service = makeService()
        let first = try service.beginPairing()
        service.cancelPairing()
        let second = try service.beginPairing()
        XCTAssertNotEqual(first.secret.bytes, second.secret.bytes)
        XCTAssertNotEqual(first.pairingID.bytes, second.pairingID.bytes)
    }

    func testCancelPairingReturnsToIdleAndDiscardsTheCandidate() throws {
        let service = makeService()
        _ = try service.beginPairing()
        service.cancelPairing()
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.acceptedKeysForTesting.isEmpty)
    }

    func testPairingAddsTheCandidateToTheAcceptedKeys() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(
            service.acceptedKeysForTesting.map(\.identity),
            [payload.pairingID.bytes]
        )
    }

    func testStoredPairingsBecomeAcceptedKeys() throws {
        let store = InMemoryPairingStore()
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        try store.save(PairingRecord(
            id: id,
            secret: secret,
            peerName: "iPad",
            serviceName: nil,
            pairedAt: Date()
        ))

        let service = makeService(store: store)
        try service.reloadAcceptedKeysForTesting()
        XCTAssertEqual(service.acceptedKeysForTesting.map(\.identity), [id.bytes])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: FAIL, `cannot find 'PadlinkService' in scope`.

- [ ] **Step 3: Implement**

```swift
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
        // Capture before nulling. `Task { }` only runs once `stop()` returns
        // control to the main actor, so reading `connection` inside the
        // closure would always see nil and never cancel the live connection,
        // leaving the socket open after quit. Measured on Task 10.
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet`
Expected: PASS, 7 new tests.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/PadlinkService.swift Padlink/PadlinkMacTests/PadlinkServiceTests.swift
git commit -m "Add PadlinkService owning the listener, pairing, and connection"
```

---

### Task 11: Menu bar and pairing UI

**Files:**
- Create: `Padlink/PadlinkMac/Views/MenuContentView.swift`
- Create: `Padlink/PadlinkMac/Views/PairingView.swift`
- Create: `Padlink/PadlinkMac/Views/AccessibilityOnboardingView.swift`
- Modify: `Padlink/PadlinkMac/PadlinkMacApp.swift`

**Interfaces:**
- Consumes: `PadlinkService`, `ServiceState`, `AccessibilityStatus`, `QRCodeImage`.

UI has no automated tests here; it is verified by hand in Task 13. Keep the views thin: they read published state and call service methods, nothing more.

**A timer trap Task 7 flagged, which lands here.** `AccessibilityStatus.startPolling()` schedules a default-mode `Timer`. A default-mode timer **pauses while a native `NSMenu` is tracking**, so if the onboarding content ends up inside menu-tracked UI, the polling stalls exactly while the user is looking at it, and the window would not update when they flip the switch. The onboarding below is a separate `Window` scene rather than menu content, so this should not arise. If it does, the fix is to schedule with `RunLoop.current.add(timer, forMode: .common)` in `startPolling()`. Verify by hand in Task 13 that the onboarding window updates without a restart.

- [ ] **Step 1: Write the onboarding view**

```swift
// Padlink/PadlinkMac/Views/AccessibilityOnboardingView.swift
import SwiftUI

struct AccessibilityOnboardingView: View {
    @ObservedObject var status: AccessibilityStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Padlink needs Accessibility permission")
                .font(.headline)
            Text("""
                macOS does not let an app move the cursor or type until you \
                allow it. Without this, Padlink connects but nothing happens \
                when you move your finger.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Privacy & Security settings") {
                status.openSystemSettings()
            }

            Text("This window updates on its own once you turn Padlink on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
    }
}
```

- [ ] **Step 2: Write the pairing view**

```swift
// Padlink/PadlinkMac/Views/PairingView.swift
import SwiftUI
import PadlinkCore

struct PairingView: View {
    let payload: PairingPayload
    let expiresAt: Date
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan this with your iPad")
                .font(.headline)

            if let image = QRCodeImage.make(from: payload.urlString, sideLength: 240) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                // Reachable if the payload exceeds the QR generator's capacity,
                // which a very long Mac name can cause. Never leave the pairing
                // window blank with no explanation.
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Could not make a QR code for this Mac's name.")
                        .font(.callout)
                    Text("Use the text below to pair instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 240, height: 240)
            }

            Text(timerInterval: Date() ... expiresAt, countsDown: true)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Shown as text because the command line test client cannot scan a
            // QR code. Same secret, own screen, deliberately opened window.
            Text(payload.urlString)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
                .frame(width: 300)

            Button("Cancel", action: onCancel)
        }
        .padding(20)
    }
}
```

- [ ] **Step 3: Write the menu content and wire the app**

```swift
// Padlink/PadlinkMac/Views/MenuContentView.swift
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var service: PadlinkService
    @ObservedObject var accessibility: AccessibilityStatus
    let onPair: () -> Void
    let onShowOnboarding: () -> Void

    var body: some View {
        if accessibility.isTrusted == false {
            Button("Accessibility permission needed", action: onShowOnboarding)
            Divider()
        }

        switch service.state {
        case .idle:
            Text("Not connected")
        case .pairing:
            Text("Waiting for a device to pair")
        case let .connected(deviceName):
            Text("Connected: \(deviceName)")
        case let .failed(message):
            Text("Problem: \(message)")
        }

        Divider()
        Button("Pair a device", action: onPair)
        Divider()
        Button("Quit Padlink") { NSApplication.shared.terminate(nil) }
    }
}
```

Replace `PadlinkMacApp.swift` with:

```swift
import SwiftUI
import PadlinkCore

@main
struct PadlinkMacApp: App {
    @StateObject private var accessibility = AccessibilityStatus()
    @StateObject private var service: PadlinkService
    @State private var pairing: PairingPayload?
    @State private var pairingExpiry = Date()

    // SwiftUI `Window` scenes open through these environment actions, not
    // through a boolean. An earlier draft declared a `showOnboarding` flag,
    // set it, and never read it, so clicking the menu items opened nothing.
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        let router = MessageRouter(
            synthesizer: MacInputSynthesizer(),
            geometry: ScreenGeometry.current()
        )
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        _service = StateObject(wrappedValue: PadlinkService(
            store: KeychainPairingStore(),
            router: router,
            macName: macName
        ))
    }

    var body: some Scene {
        MenuBarExtra("Padlink", systemImage: menuIcon) {
            MenuContentView(
                service: service,
                accessibility: accessibility,
                onPair: startPairing,
                onShowOnboarding: { openWindow(id: "onboarding") }
            )
            // Without this the app launches, shows an icon, and silently does
            // nothing: no listener, no Bonjour advertisement, no pairing.
            .task { await service.start() }
        }

        Window("Pair a device", id: "pairing") {
            if let pairing {
                PairingView(payload: pairing, expiresAt: pairingExpiry) {
                    service.cancelPairing()
                    self.pairing = nil
                    dismissWindow(id: "pairing")
                }
            }
        }
        .windowResizability(.contentSize)

        Window("Accessibility", id: "onboarding") {
            AccessibilityOnboardingView(status: accessibility)
        }
        .windowResizability(.contentSize)
    }

    private var menuIcon: String {
        if case .connected = service.state { return "keyboard.fill" }
        return "keyboard"
    }

    private func startPairing() {
        do {
            let payload = try service.beginPairing()
            pairing = payload
            pairingExpiry = Date().addingTimeInterval(PadlinkService.pairingWindow)
            // The window has to be opened explicitly. Setting `pairing` only
            // populates the scene's content.
            openWindow(id: "pairing")
        } catch {
            pairing = nil
        }
    }
}
```

**The Quit button must stop the service, not just terminate.** `MenuContentView`'s quit action calls `service.stop()` first, so a connection dying with a modifier held releases it rather than leaving the key stuck on the user's Mac until they reboot. Terminating without that call skips the whole release-everything path this project built.

- [ ] **Step 4: Build and confirm the existing tests still pass**

```bash
cd Padlink && xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet
```

Expected: PASS, no new tests, nothing broken.

- [ ] **Step 5: Commit**

```bash
git add Padlink/PadlinkMac/Views Padlink/PadlinkMac/PadlinkMacApp.swift
git commit -m "Add menu bar, pairing, and Accessibility onboarding UI"
```

---

### Task 12: `PadlinkTestClient`

**Files:**
- Modify: `Padlink/Package.swift`
- Create: `Padlink/Sources/PadlinkTestClient/main.swift`
- Create: `Padlink/Sources/PadlinkTestClient/TestClient.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `PadlinkTransport`, `PadlinkConnection`, `PairingPayload`, `ClientMessage`, `Padlink.bonjourServiceType` from Core.
- Produces: an executable `padlink-testclient`.

This stands in for the iPad, and stays as the tool that answers "is the Mac wrong or is the iPad wrong" for the life of the project.

It stores its pairing as JSON holding a **real 32-byte pre-shared key**. This repository
is public, so two independent protections apply and both are required:

1. The file lives in the user's home directory, outside the working tree entirely, so
   `git add` can never reach it.
2. `.gitignore` still carries an un-anchored pattern, so a stray copy anywhere in the
   tree is ignored too.

- [ ] **Step 1: Ignore the pairing file first**

Append to `.gitignore`:

```
# Test client pairing state. Holds a real pre-shared key.
# No slash, so this matches at any depth, not just the repo root.
.padlink-testclient.json
```

The pattern must have **no slash in it**. A pattern containing a slash is anchored to
the repo root. An earlier draft of this plan wrote `Padlink/.padlink-testclient.json`,
which would have missed the file entirely whenever the binary was run from any working
directory other than `Padlink/`, and the key would have been committed to a public
repository.

- [ ] **Step 2: Add the executable target**

In `Padlink/Package.swift`, add to `products`:

```swift
        .executable(name: "padlink-testclient", targets: ["PadlinkTestClient"])
```

and to `targets`:

```swift
        .executableTarget(name: "PadlinkTestClient", dependencies: ["PadlinkCore"])
```

- [ ] **Step 3: Write the client**

```swift
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
    case badPayload(String)
    case macNotFound
    case usage

    var description: String {
        switch self {
        case .notPaired:
            return "Not paired. Run: padlink-testclient pair \"<padlink://... url>\""
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
        try JSONEncoder().encode(stored).write(to: stateURL)
        // Never print the secret itself.
        print("Paired with \(payload.macName). Saved to \(stateURL.path)")
    }

    static func loadPairing() throws -> (psk: TLSPSK, serviceName: String) {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode(StoredPairing.self, from: data),
              let id = PairingID(hexString: stored.id),
              let secret = PairingSecret(bytes: stored.secret)
        else { throw TestClientError.notPaired }

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
        for message in messages {
            try await connection.send(message)
        }
        // Give the Mac a moment to post the events before the socket closes.
        try await Task.sleep(for: .milliseconds(200))
        await connection.cancel()
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
                    FileHandle.standardError.write(Data(
                        "Warning: paired service \"\(serviceName)\" not found. "
                        + "Falling back to \"\(name)\", whose key will probably not match.\n"
                    .utf8))
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
```

Core's `Box` is `internal`, so this executable cannot see it. Add this small local type to the same file rather than making `Box` public: this is a development tool, and widening Core's API for it would be wrong.

The test and set happen under **one** lock acquisition. Two acquisitions would let the browser callback and the timeout both resume the continuation, which is undefined behaviour.

```swift
/// Guards a continuation so exactly one caller resumes it.
private final class ClaimFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true only to the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
```


```swift
// Padlink/Sources/PadlinkTestClient/main.swift
import Foundation
import PadlinkCore

func modifiers(from arguments: [String]) -> KeyModifiers {
    var result: KeyModifiers = []
    if arguments.contains("--cmd") { result.insert(.command) }
    if arguments.contains("--shift") { result.insert(.shift) }
    if arguments.contains("--opt") { result.insert(.option) }
    if arguments.contains("--ctrl") { result.insert(.control) }
    return result
}

func modifier(named name: String) -> KeyModifiers? {
    switch name {
    case "cmd": return .command
    case "shift": return .shift
    case "opt": return .option
    case "ctrl": return .control
    default: return nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let command = arguments.first else { throw TestClientError.usage }

    switch command {
    case "pair":
        guard arguments.count >= 2 else { throw TestClientError.usage }
        try TestClient.pair(urlString: arguments[1])

    case "move":
        guard arguments.count >= 3,
              let dx = Int16(arguments[1]), let dy = Int16(arguments[2])
        else { throw TestClientError.usage }
        try await TestClient.send([.pointerMove(dx: dx, dy: dy, dtMicros: 16_666)])
        print("Sent: move \(dx) \(dy)")

    case "click":
        let button: PointerButton = arguments.count >= 2 && arguments[1] == "right" ? .right : .left
        try await TestClient.send([
            .pointerButton(button: button, isDown: true),
            .pointerButton(button: button, isDown: false)
        ])
        print("Sent: \(button) click")

    case "scroll":
        guard arguments.count >= 3,
              let dx = Int16(arguments[1]), let dy = Int16(arguments[2])
        else { throw TestClientError.usage }
        try await TestClient.send([.scroll(dx: dx, dy: dy)])
        print("Sent: scroll \(dx) \(dy)")

    case "type":
        guard arguments.count >= 2 else { throw TestClientError.usage }
        try await TestClient.send([.keyText(arguments[1])])
        print("Sent: type \(arguments[1].count) characters")

    case "key":
        guard arguments.count >= 2,
              let character = arguments[1].first,
              let key = KeyRouter.padlinkKey(forCharacter: character)
        else { throw TestClientError.usage }
        let mods = modifiers(from: arguments)
        try await TestClient.send([
            .keyCode(key: key, isDown: true, modifiers: mods),
            .keyCode(key: key, isDown: false, modifiers: mods)
        ])
        print("Sent: key \(character) with modifiers \(mods.rawValue)")

    case "hold":
        guard arguments.count >= 2, let mod = modifier(named: arguments[1])
        else { throw TestClientError.usage }
        try await TestClient.send([.modifierState(modifiers: mod)])
        print("Sent: hold \(arguments[1]). This connection closes, so run `release` next.")

    case "release":
        try await TestClient.send([.modifierState(modifiers: [])])
        print("Sent: release all modifiers")

    default:
        throw TestClientError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
```

- [ ] **Step 4: Build it**

```bash
cd Padlink && swift build --product padlink-testclient
swift test
```

Expected: builds, and the Core suite still passes with its **full existing count**.
Report the actual number of tests that ran. An exit code of 0 alone is not evidence.

- [ ] **Step 5: Verify the secret cannot be committed**

This is not optional. Run, from the repo root:

```bash
printf '{"id":"aabbccdd00112233","secret":"AAAA","serviceName":"x"}' > .padlink-testclient.json
git check-ignore -v .padlink-testclient.json
git status --porcelain | grep padlink-testclient || echo "NOT LISTED (correct)"
rm .padlink-testclient.json
```

Expected: `git check-ignore` prints the matching `.gitignore` rule, and `git status`
does **not** list the file. If `git check-ignore` exits non-zero, the pattern is wrong
and the task is not done.

- [ ] **Step 6: Commit**

```bash
git add .gitignore Padlink/Package.swift Padlink/Sources/PadlinkTestClient
git commit -m "Add the command line test client that stands in for the iPad"
```

Confirm with `git status --porcelain` that nothing named `padlink-testclient.json` was
committed.

---

### Task 13: End to end verification and documentation

**Files:**
- Modify: `NOTES.md`
- Modify: `README.md`

This task has no automated tests. It is where a human confirms the things automation cannot reach, and where the result is written down honestly.

- [ ] **Step 1: Run everything**

```bash
cd Padlink
swift test
xcodebuild test -scheme PadlinkMac -destination 'platform=macOS' -quiet
```

Both must pass. Record the counts.

- [ ] **Step 2: Launch the app and grant permission**

```bash
cd Padlink && xcodebuild -scheme PadlinkMac -configuration Debug -derivedDataPath .build build -quiet
open .build/Build/Products/Debug/PadlinkMac.app
```

Confirm: a keyboard icon appears in the menu bar, there is no Dock icon, and the menu offers Accessibility onboarding. Grant the permission and confirm the menu updates without a restart.

- [ ] **Step 3: Pair the test client**

Click "Pair a device". Copy the `padlink://` text under the QR code, then:

```bash
cd Padlink && swift run padlink-testclient pair "<paste the url>"
```

Confirm the pairing window closes and the menu shows a connected device.

- [ ] **Step 4: Walk the manual checklist**

Run each and record pass or fail with what actually happened:

```bash
swift run padlink-testclient move 200 0        # cursor moves right
swift run padlink-testclient move 0 200        # cursor moves DOWN, not up
swift run padlink-testclient click left        # clicks where the cursor is
swift run padlink-testclient scroll 0 -120     # scrolls a scrollable window
swift run padlink-testclient type "hello"      # types into a focused text field
swift run padlink-testclient key c --cmd       # copies selected text
swift run padlink-testclient key v --cmd       # pastes it
swift run padlink-testclient hold cmd          # app switcher opens and STAYS open
swift run padlink-testclient release           # switcher closes
```

**The vertical direction check in the second command is the one most likely to fail**, because it is where a bottom-left versus top-left coordinate mistake shows up.

Also confirm by hand:

- Dragging selects text, rather than only moving the cursor.
- Quitting the app while a button is held does not leave a stuck button.
- With a non-US keyboard layout selected, `type` still produces the right characters.

**Second-connection supersession**, which has no unit test because it needs two racing sockets. Task 10 added a guard so a dying connection's cleanup cannot clear state belonging to its live successor. Verify by hand:

1. Pair and connect the test client, and confirm the menu bar shows connected.
2. Start a second client run while the first is still connected.
3. The menu bar must still show connected, naming the newer device, rather than dropping to "not connected".
4. Input from the newer client must still work.

The failure this checks for is the menu bar reading "not connected" while the cursor is still being driven, which would be confusing rather than obviously broken.

- [ ] **Step 3 fallback: if pairing fails**

Check, in this order: is the Mac's Bonjour service visible (`dns-sd -B _padlink._tcp`), did the listener actually start, and was the pairing URL pasted whole. A rejected pre-shared key surfaces as `.waiting`, not `.failed`, so a hanging connection means a key mismatch rather than a crash.

- [ ] **Step 5: Write the results down**

Append to `NOTES.md` under `## 2026-08-13 — Mac app complete`: both test counts, the manual checklist results including anything that failed, the Keychain spike's answer, and anything left for the iPad plan.

Update `README.md`:

- Change the status block: the Mac app now exists, the iPad app does not.
- Add how to build and run the Mac app, and how to use the test client.
- Move the modifier-message gap out of "known gaps", since this plan closed it.
- Keep the honest statement that there is still nothing to install on an iPad.

- [ ] **Step 6: Commit**

```bash
git add NOTES.md README.md
git commit -m "Record Mac app completion and manual verification results"
```

---

## What this leaves for the iPad plan

- Bonjour discovery and reconnect with backoff, which is pure logic and should live in Core so it can be tested
- Camera QR scanning
- The raw-touch trackpad surface and its gesture map
- The on-screen keyboard with latching modifiers, which produces the `modifierState` messages this plan consumes
- Hardware keyboard pass-through
- Heartbeat timers and the round-trip latency readout
- **`dtMicros` must be clamped, not truncated.** It is a `UInt16` saturating at 65.5ms; truncating a 100ms gap yields 34ms and makes the Mac think the finger moved twice as fast as it did.
