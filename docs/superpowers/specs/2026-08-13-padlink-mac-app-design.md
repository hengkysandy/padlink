# Padlink macOS app — design spec

**Date:** 2026-08-13
**Status:** approved design, ready for an implementation plan
**Owner:** hengkysandy (personal project, `github.com/hengkysandy/padlink`)
**Builds on:** `docs/superpowers/specs/2026-08-13-padlink-design.md` (the product spec)
**Depends on:** `PadlinkCore`, complete, 95 tests passing

---

## 1. What this builds

The Mac half of Padlink: a menu bar app that advertises itself on the local network, pairs
with an iPad by showing a QR code, and turns the messages it receives into real mouse and
keyboard input.

At the end of this plan you can **move your own cursor and type on your own Mac from a
command line tool**, with no iPad involved. The iPad app is the next plan.

### Why the Mac first

The Mac side owns the riskiest unknown in the whole product: macOS refuses to let any app
synthesize input until the user grants Accessibility permission, and that permission has
awkward behaviour during development. Proving it early removes the biggest risk. It also
means the iPad app is later written against a Mac side that is already known good, so a new
bug is almost certainly in the new code.

### Scope

**In scope**

- Menu bar app with no Dock icon
- Accessibility permission detection and onboarding
- Bonjour advertising and the TLS listener
- QR code pairing, with a 2-minute pairing window
- Keychain storage of pairings
- Full input synthesis: pointer movement, clicks, drag, scroll, both typing paths, and
  standalone modifier keys
- Release-everything when a connection drops
- A command line test client that stands in for the iPad

**Out of scope, deferred deliberately**

- The paired-device list with revoke. Pairing works and persists; managing several pairings
  is convenience, not capability.
- The settings window for sensitivity and scroll direction. Both use defaults. Tuning these
  is much easier after feeling the real thing.
- Active detection of a silently-dead iPad. See section 10.

---

## 2. Protocol change: standalone modifier keys

**This changes `PadlinkCore` and must happen first.**

Today `KeyModifiers` only travels attached to a `keyCode` message. There is no way to say
"Command just went down on its own" or "Command just came up on its own".

That is fine for `Cmd+C`, which is one self-contained keystroke. It breaks the **application
switcher**: holding Command and tapping Tab repeatedly requires Command to stay
continuously held, and with the current format every Tab arrives as an independent event, so
the switcher would open and close on each tap instead of staying up.

### The change

One new client message:

| Message | Fields |
|---|---|
| `modifierState` | modifiers (UInt8 bitfield, same layout as `KeyModifiers`) |

Type byte `8`, continuing the existing client message numbering. It reports the **complete
current modifier state**, not a delta, so a lost message self-corrects on the next one
rather than leaving the two sides permanently disagreeing.

The reserved-bit rule from the existing `keyCode` message applies unchanged: bits 5 to 7
must be zero, and decoding rejects anything else.

**Why now:** nothing has shipped and no other device speaks this protocol, so the wire
format is free to change. After release it would need a version bump and both apps updating
together.

**Protocol version stays at `1`.** It has never been released, so there is no older peer to
stay compatible with.

---

## 3. Architecture

Four units. The rule from the core build still holds: **decisions live in `PadlinkCore`
where they can be tested, OS calls live in the app where they cannot.**

```
Padlink/
├── Package.swift                    PadlinkCore (existing) + PadlinkTestClient (new)
├── Sources/
│   ├── PadlinkCore/
│   │   ├── Input/HeldInputState.swift        NEW: tracks held buttons and modifiers
│   │   └── Protocol/...                      MODIFIED: modifierState message
│   └── PadlinkTestClient/                    NEW: the fake iPad, a CLI executable
├── Tests/PadlinkCoreTests/
├── project.yml                      NEW: XcodeGen source of truth
└── PadlinkMac/                      NEW: the macOS app target
    ├── PadlinkMacApp.swift          @main, MenuBarExtra, windows
    ├── PadlinkService.swift         actor: listener, connection, pairing state
    ├── MacInputSynthesizer.swift    the only file that calls CGEvent
    ├── InputSynthesizing.swift      protocol, so routing can be tested with a fake
    ├── MessageRouter.swift          decoded message to synthesizer call
    ├── AccessibilityStatus.swift    permission check and polling
    ├── KeychainPairingStore.swift   PairingStore backed by the Keychain
    ├── QRCodeImage.swift            payload URL to an NSImage
    └── Views/                       SwiftUI: onboarding, pairing, menu content
```

### `HeldInputState`, and why it goes in Core

It tracks which mouse buttons are down and which modifiers are held, and on disconnect it
produces the exact list of release actions needed.

This is pure bookkeeping with no OS calls, so in Core it gets real unit tests with no Mac
and no device. In the app it would sit beside the `CGEvent` calls where nothing can be
tested automatically, and the only way to check it would be to kill a live connection
mid-drag and see whether the `Cmd` key is stuck.

The cost is that Core grows one type only the Mac app uses. That is the same trade already
accepted for `MacVirtualKeys`, and it is worth it for the thing that prevents a stuck
modifier.

### `InputSynthesizing`, and why routing is separated from posting

`MacInputSynthesizer` is deliberately thin and stupid: it contains no decisions, only the
actual `CGEvent` calls. All the decisions (is this a drag or a move, does this text take the
unicode path or the key code path) live in `MessageRouter`, which talks to the
`InputSynthesizing` protocol.

That means the routing logic can be tested with a fake synthesizer that records what it was
asked to do, without moving the real cursor. The untestable surface shrinks to a handful of
one-line functions.

---

## 4. Project structure and build

**XcodeGen generates the Xcode project from `project.yml`.** The generated `.xcodeproj` is
gitignored, so the repository stays plain text and every project change is a readable diff.

Regenerating is one command:

```bash
cd Padlink && xcodegen generate
```

| Setting | Value |
|---|---|
| Bundle ID | `com.hengkysandy.padlink.mac` |
| Deployment target | macOS 15 |
| `LSUIElement` | `true` (no Dock icon, menu bar only) |
| Signing (development) | Sign to run locally, ad-hoc |
| Signing (release) | Developer ID, notarized. Not the Mac App Store, see the product spec section 2. |

`project.yml` declares **two** targets: the app itself and a unit test target for it. The
test target is what section 13's app-level tests run in.

The app depends on the local `PadlinkCore` package by path.

### Two test commands, not one

| What | Command | Run from |
|---|---|---|
| Core tests | `swift test` | `Padlink/` |
| App tests | `xcodebuild test -scheme PadlinkMac -destination 'platform=macOS'` | `Padlink/` |

`swift test` cannot run the app target's tests, because SwiftPM does not know about the
Xcode project. Both must pass before any task is complete.

---

## 5. Accessibility permission

macOS will not deliver synthesized input from an app the user has not explicitly trusted.
This is the single most likely thing to waste a day, so it is designed for rather than
discovered.

### Flow

1. On launch, check `AXIsProcessTrusted()`.
2. If false, show onboarding: what the permission is for, why the app cannot work without
   it, and a button that opens
   `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
3. Poll once per second while onboarding is visible, so the UI updates the moment the switch
   is flipped, with no restart and no "click here when done" button.
4. Report the current state to the iPad in `helloAck`'s `accessibilityGranted` field, so the
   iPad can say "grant Accessibility on your Mac" instead of appearing broken when a finger
   moves and nothing happens.

### Known development annoyance, documented so it is not mistaken for a bug

macOS ties the granted permission to the specific binary. **Every rebuild produces a new
binary, so macOS may drop the permission and ask again.** With ad-hoc signing this can
happen on every single build. It is expected. If it becomes intolerable during development,
a stable signing identity reduces it.

---

## 6. Bonjour advertising and the listener

The Mac runs an `NWListener` using `PadlinkTransport.listenerParameters(psks:)`, seeded with
one `TLSPSK` per stored pairing.

```swift
listener.service = NWListener.Service(
    name: <the Mac's name>,
    type: Padlink.bonjourServiceType   // "_padlink._tcp"
)
```

The service name comes from `Host.current().localizedName`, falling back to
`ProcessInfo.processInfo.hostName`. That same name goes into the QR payload's `s` field, so
the iPad can find this specific Mac among several.

**Accepted connections must be retained**, including by the listener's handler, or ARC frees
them mid-handshake and the connection silently never completes. This was measured during the
core build and is not negotiable.

### The listener is rebuilt whenever the key set changes

Pre-shared keys are fixed when `NWParameters` is created, so the accepted set cannot be
changed on a running listener. Every change to the key set therefore tears the listener down
and recreates it. This happens three times around a pairing: when the pairing window opens
(stored keys plus the candidate), if it closes unpaired (stored keys only), and after a
successful pairing (candidate promoted).

Any live connection is dropped when this happens. That is acceptable, because the user has
deliberately walked over to the Mac to pair. `PadlinkService` owns this rebuild so the rule
lives in one place.

---

## 7. Pairing

### Flow

1. User opens the menu and clicks "Pair a device".
2. The app generates a fresh `PairingID` and `PairingSecret` via `PadlinkCore`, builds a
   `PairingPayload`, and opens the pairing window.
3. The window shows the payload as a **QR code**, and below it the same payload as **small
   selectable text**.
4. The pairing window stays open for **two minutes**, showing a countdown. Opening it
   **rebuilds the listener** with the stored keys plus the candidate key, because
   pre-shared keys are fixed when `NWParameters` is created (see section 6). Closing it
   without a successful pairing rebuilds the listener again without the candidate, and the
   candidate is discarded.
5. On a successful connection using the candidate key, the pairing is written to the
   Keychain and the window closes. The listener is rebuilt once more, now with the
   candidate promoted to a stored key.

### Why the raw URL is shown as text

The test client cannot scan a QR code. Showing the payload as selectable text lets it be
pasted into `padlink-testclient --pair "<url>"`. It is also genuinely useful for debugging
later.

This is not a security weakness. It is the same secret the QR code already encodes, on the
user's own screen, inside a deliberately opened two-minute window.

### Keychain storage

`KeychainPairingStore` implements `PadlinkCore`'s `PairingStore`.

| Attribute | Value |
|---|---|
| Class | `kSecClassGenericPassword` |
| Service | `Padlink.keychainService` (`com.hengkysandy.padlink`) |
| Account | `pairingID.hexString` |
| Value | The whole `PairingRecord` as JSON |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

**This device only**, so the secret never syncs to iCloud and never leaves the Mac.

Storing the record as one JSON value, rather than spreading fields across Keychain
attributes, keeps the mapping trivial and testable. `peerName`, `pairedAt`, and
`serviceName` have no natural Keychain attribute, and inventing one would be worse.

**Risk to resolve first: see section 12.** Keychain behaviour differs between signed and
ad-hoc-signed apps, and that must be measured before the rest of the plan depends on it.

---

## 8. Input synthesis

All `CGEvent` posting goes to `.cghidEventTap`.

### Pointer movement

The app tracks the cursor position itself: read the current location, apply
`PointerAcceleration` from Core to the incoming delta, add, clamp, post.

**Coordinate systems do not match, and getting this wrong flips the cursor vertically.**
`NSScreen.frame` uses a bottom-left origin. `CGEvent` locations use a top-left origin. The
conversion is explicit and tested where it can be.

Clamping uses the union of all screen frames. If the resulting point falls in a gap between
differently sized displays, it snaps to the nearest screen.

### The drag gotcha

While a mouse button is held, movement must be posted as `.leftMouseDragged` or
`.rightMouseDragged`, **not** `.mouseMoved`. Many apps ignore plain moves during a drag, so
text selection and window dragging would simply not work. `HeldInputState` knows which
buttons are down, so `MessageRouter` picks the right event type.

### Clicks

`.leftMouseDown` / `.leftMouseUp` and the right-button equivalents, with
`mouseEventClickState` set so double-clicks are recognised. Two clicks within the system
double-click interval and within a few pixels count as a double click.

### Scrolling

`scrollWheelEvent2Source` with `.pixel` units, giving smooth scrolling rather than notched
jumps. Direction follows a constant for now; the settings toggle is deferred.

### Typing

Two paths. **The choice is made on the iPad, not here.** `KeyRouter` in Core decides, and by
the time a message reaches the Mac the decision is already expressed as which message case
arrived. The Mac only maps each case to the matching `CGEvent` call, and never calls
`KeyRouter` itself.

1. **`.keyText`**, sent when the iPad saw no modifier or shift only, goes through a
   `CGEvent` with virtual key `0` and `keyboardSetUnicodeString`. Layout independent, and
   handles accents, emoji, and non-Latin scripts with no work here.
2. **`.keyCode`**, sent for shortcuts and special keys, uses the real virtual key code from
   `MacVirtualKeys`, with `event.flags` set from the message's modifiers.

This split is why the wire format carries two distinct message types rather than one string:
the layout-dependent decision belongs where the keyboard layout is known.

### Standalone modifiers

A `modifierState` message is compared against the currently held set. For each modifier that
changed, a key event is posted for that modifier's own virtual key, which is what makes
macOS emit the `flagsChanged` event that the app switcher and similar UI depend on.

| Modifier | Virtual key |
|---|---|
| Shift | `0x38` |
| Control | `0x3B` |
| Option | `0x3A` |
| Command | `0x37` |
| Function | `0x3F` |

---

## 9. Release everything on disconnect

When `PadlinkConnection`'s `incoming` stream finishes, for any reason, `HeldInputState`
produces the list of releases and the synthesizer posts them: every held mouse button up,
every held modifier up.

Without this, a connection dying mid-drag leaves a stuck `Cmd` key and a Mac that behaves
strangely until it is rebooted. This is the reason the stream-finishing seam exists in Core.

The same release runs when the app quits, so quitting during a drag cannot strand a button.

`CloseReason` from Core distinguishes a normal disconnect from a framing violation or a
transport failure, and the menu bar shows the difference.

---

## 10. Connection lifecycle

| State | Menu bar shows |
|---|---|
| Accessibility not granted | Warning, opens onboarding |
| No pairings stored | Idle, offers "Pair a device" |
| Paired, waiting | Idle |
| Pairing window open | Countdown |
| Connected | Active indicator, and the connected device's name |

The Mac **replies to `ping` with `pong`** so the iPad can measure round-trip latency and
detect a dead Mac.

**The Mac does not actively detect a silently-dead iPad in this version.** It relies on the
stream finishing and on TCP keepalive, which can take minutes. This is a deliberate
deferral: the iPad owns the heartbeat timers, and the failure mode is a stale "connected"
indicator, not incorrect input. It is recorded here so it is not mistaken for an oversight.

---

## 11. The test client

`PadlinkTestClient`, a command line executable in the same Swift package, standing in for
the iPad until the iPad app exists. It is **not** throwaway: it stays as the tool that
answers "is the Mac wrong or is the iPad wrong" for the life of the project.

```bash
padlink-testclient pair "padlink://pair?v=1&id=..."   # store the pairing
padlink-testclient move 100 0                          # move the cursor right
padlink-testclient click left
padlink-testclient scroll 0 -120
padlink-testclient type "hello world"
padlink-testclient key c --cmd                         # Cmd+C
padlink-testclient hold cmd                            # standalone modifier down
padlink-testclient release cmd
padlink-testclient script <file>                       # a sequence, for repeatable tests
```

It discovers the Mac with `NWBrowser` and connects using
`PadlinkTransport.connectionParameters(psk:)`.

It stores its pairing as JSON in a **gitignored file inside the package directory**, not the
Keychain. It is a development tool, file storage keeps it simple, and it sidesteps the
Keychain question in section 12 entirely. The file holds a real pre-shared key, so
`.gitignore` must cover it before the file can ever be created.

---

## 12. Risk to resolve before the rest of the plan

**Keychain access from an ad-hoc-signed Mac app.**

`PadlinkCore` deliberately shipped no Keychain implementation because an unsigned `swift
test` binary cannot use the data protection keychain. The Mac app is a real signed bundle,
so it should work, but "should" is exactly the word that preceded the TLS 1.3 mistake in the
core build.

**A spike runs first**, exactly like the TLS spike did. It answers:

1. Does `kSecClassGenericPassword` save and load work from an ad-hoc-signed app bundle?
2. Does `kSecUseDataProtectionKeychain: true` work, or is the legacy file keychain required?
3. Does a rebuild invalidate access, the way Accessibility permission does?
4. Does anything prompt the user for a password?

The answers bind section 7. If the data protection keychain needs a paid signing identity,
the fallback is the legacy keychain for development, with a note to revisit before release.

Output is an answer recorded in `NOTES.md`, and throwaway code.

---

## 13. Testing

### Automated in `PadlinkCore` (`swift test`, no device)

| Area | Cases |
|---|---|
| `modifierState` codec | Round trip, reserved bits rejected, unknown bits rejected |
| `HeldInputState` | Buttons and modifiers tracked; release list correct after a drag; release list empty when nothing held; repeated releases are idempotent |

### Automated in the app target (Xcode test target)

Using a fake `InputSynthesizing` that records calls instead of touching the OS:

| Area | Cases |
|---|---|
| `MessageRouter` | Movement while a button is held routes to drag, not move |
| | Plain text takes the unicode path |
| | A modifier combination takes the key code path |
| | `modifierState` posts only the modifiers that actually changed |
| | Disconnect produces exactly the outstanding releases |
| Coordinate conversion | Bottom-left to top-left mapping, including a second display |
| `KeychainPairingStore` | Save, load, load all, delete, and delete of an unknown id |

### Manual, by the owner

Automation cannot answer these, and the plan will state so rather than implying coverage:

- Does the cursor feel right, and is the acceleration sane?
- Does `Cmd+C` then `Cmd+V` actually copy and paste in a real app?
- Does `Cmd+Tab` hold the switcher open?
- Does text selection by dragging work?
- Does the Accessibility onboarding appear, and does the UI update when the switch flips?
- Does typing produce the right characters with a non-US keyboard layout selected?

---

## 14. What this leaves for the iPad plan

- Bonjour discovery and reconnect with backoff
- Camera QR scanning
- The raw-touch trackpad surface and gesture map
- The on-screen keyboard with latching modifiers, which produces the `modifierState`
  messages this plan consumes
- Hardware keyboard pass-through
- Heartbeat timers and the latency readout
- `dtMicros` must be **clamped, not truncated**, before sending. It is a `UInt16` and
  saturates at 65.5ms; truncating a 100ms gap yields 34ms and makes the Mac think the finger
  moved twice as fast as it did.
