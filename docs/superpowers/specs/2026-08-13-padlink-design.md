# Padlink — design spec

**Date:** 2026-08-13
**Status:** approved design, ready for an implementation plan
**Owner:** hengkysandy (personal project, will push to `github.com/hengkysandy`)

---

## 1. What we are building

An iPad app and a macOS companion app. Both sit on the same Wi-Fi network. The
iPad becomes a trackpad and keyboard that drives the MacBook.

Inspired by "Wingdeck" (Instagram video by surya_diputra). That app also does media
control, a stream deck, and a clock face. **We are deliberately not building those in v1.**

### Hardware and tooling

| Item | Value |
|---|---|
| Host | MacBook Air M5 |
| Client | iPad Air gen 5 (60Hz display, no ProMotion) |
| UI framework | SwiftUI, with UIKit/AppKit where it is needed |
| Toolchain | Xcode (installed), Swift 6.2.4 |
| Apple account | Free Apple ID for now. Paid membership later if testing goes well. |

**Setup step the user must run once.** `xcode-select` currently points at the Command
Line Tools, so no simulator runtimes are visible:

```
sudo xcode-select -s /Applications/Xcode.app
```

### v1 scope

**In scope:** trackpad (move, click, right click, scroll, drag), keyboard (on-screen
and hardware pass-through), QR pairing, encrypted transport, reconnect.

**Out of scope for v1:** media keys, stream deck, clock face, Windows companion,
Android client, multiple paired iPads (see the risk in section 9).

### Naming

| Thing | Value |
|---|---|
| Product name | Padlink (placeholder, easy to change before code exists) |
| Mac bundle ID | `com.hengkysandy.padlink.mac` |
| iPad bundle ID | `com.hengkysandy.padlink.pad` |
| Bonjour service type | `_padlink._tcp` |
| Keychain service | `com.hengkysandy.padlink` |

---

## 2. Distribution constraint (decided, affects everything)

The Mac app posts synthetic input using `CGEvent`. macOS requires the user to grant
**Accessibility** permission for this. A sandboxed Mac App Store app cannot use that
permission in a workable way.

**Therefore:**

- The Mac companion ships as a **Developer ID app, notarized, downloaded from a website**.
  Not the Mac App Store.
- The iPad app can go to the **iOS App Store** normally.

This matches what the original video author did: mobile apps in the App Store and Play
Store, desktop companion on a separate website.

Nothing in v1 depends on a paid membership. Upgrading later changes only signing settings.

---

## 3. Architecture

Three units. The rule: **all logic worth testing lives in a shared package that contains
no platform-specific input code.**

```
first-mobile-app/                  (git repo)
├── CLAUDE.md                      workspace rules (needs updating, see section 10)
├── NOTES.md                       running journal
├── docs/superpowers/specs/        this file
└── Padlink/
    ├── Package.swift              → PadlinkCore, a local Swift package
    ├── Sources/PadlinkCore/
    │   ├── Protocol/              message types, binary codec, frame parser
    │   ├── Transport/             NWListener / NWConnection wrappers, TLS-PSK setup
    │   ├── Pairing/               secret generation, QR payload format, Keychain storage
    │   └── Input/                 pure logic only: pointer acceleration, key routing,
    │                              key code tables
    ├── Tests/PadlinkCoreTests/
    ├── PadlinkMac/                macOS menu bar app
    └── PadlinkPad/                iPadOS app
```

### Why this split

`PadlinkCore` compiles for both iOS and macOS and contains no UI and no `CGEvent`. The
whole protocol, the pairing logic, the acceleration curve, and the key routing rules can
be tested with `swift test` on the command line, with no simulator and no device.

The two app targets stay thin. They own UI, permissions, the camera, and `CGEvent`
posting. Those are the parts that need manual verification anyway.

### Platform-specific pieces and their boundaries

| Concern | Platform-specific part | Testable part in Core |
|---|---|---|
| QR code | Generation (CoreImage, Mac), scanning (AVFoundation, iPad) | The payload format: encode and decode |
| Input synthesis | The `CGEvent` call itself (Mac app) | Acceleration math, key routing rule, key code table |
| Keychain | None, `Security` framework works on both | Storage wrapper with a protocol for test doubles |

### App shapes

- **Mac:** a menu bar app (`NSStatusItem`), not a Dock app, with a small SwiftUI window
  for pairing and settings. It is a background utility.
- **iPad:** a single full-screen SwiftUI app. Trackpad surface fills the upper area, a
  button bar sits along the bottom, and the keyboard slides up over the lower half.

---

## 4. Pairing and security

### Threat model

The user will type passwords through this. Anyone on the same Wi-Fi (coworking space,
apartment building, hotel) can see the Bonjour advertisement. Requirements:

1. Only paired devices can connect and control the Mac.
2. Nobody can read the traffic, live or from a recording made earlier.

### Mechanism: QR code pairing, then TLS 1.3 with a pre-shared key

1. On the Mac the user clicks "Pair a device". The Mac generates a random 256-bit secret
   using `SecRandomCopyBytes` and shows it as a QR code with the Mac's name.
2. On the iPad the user points the camera at the QR code. The secret is now on both
   devices and **never travelled over the network**.
3. Both sides save the secret in the Keychain.
4. Every connection from then on uses TLS 1.3 with that secret as the pre-shared key,
   via `sec_protocol_options_add_pre_shared_key`.

### Why this choice

- **Safest.** Full entropy from the first moment, so there is no weak PIN to brute-force.
  A person-in-the-middle attack is impossible because the key moved optically, not over
  the air. TLS 1.3 PSK gives mutual authentication and forward secrecy, so a captured
  recording cannot be decrypted later.
- **Easiest for the user.** One action: point the camera.
- **Simplest to build.** This is the non-obvious benefit. A short numeric PIN is too weak
  to use as a key directly, so it would force a PAKE such as SPAKE2 or SRP. That is real
  cryptographic code with real ways to get it wrong. A high-entropy secret means TLS does
  all the cryptography and we write none.

### Rejected alternatives

| Alternative | Why rejected |
|---|---|
| 6-digit PIN | Too weak to use directly as a key. Forces a PAKE implementation. |
| Trust-on-first-use with 6-digit number comparison (like Bluetooth) | Genuinely secure, but needs a confirmation step on the Mac, so the user has to walk to the Mac. More steps for the same result. |

### Fallback for when the camera is unavailable

The Mac shows the same secret as a **10-character base32 code** (about 50 bits), typed by
hand once. Strong enough to use directly, so it still avoids needing a PAKE.

### QR payload format

A URL, chosen for debuggability. At this length the QR code stays low density and scans
instantly.

```
padlink://pair?v=1&id=<16-hex-chars>&k=<base64url 32 bytes>&n=<url-encoded mac name>&s=<bonjour instance name>
```

| Field | Meaning |
|---|---|
| `v` | Payload version. Anything other than `1` is rejected. |
| `id` | Pairing ID, 8 random bytes as hex. Used as the TLS PSK identity. |
| `k` | The 256-bit secret, base64url, unpadded. |
| `n` | The Mac's display name, for the iPad's UI. |
| `s` | Bonjour service instance name, so the iPad knows which Mac to connect to when several are advertising. |

### Extra safety measures

- Pairing mode is a **2-minute window**. Outside it, the Mac accepts only already-paired
  devices. When the window closes without a successful pairing, the candidate secret is
  discarded.
- The Mac keeps a **list of paired devices** with names and pairing dates, and any of them
  can be revoked.
- The Mac shows a **visible menu bar indicator** whenever a device is connected and
  controlling it.

### Keychain storage

| Side | Item |
|---|---|
| iPad | One `kSecClassGenericPassword` per paired Mac. Service `com.hengkysandy.padlink`, account = pairing ID, value = secret. |
| Mac | One per paired iPad, same shape. |

Both use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **This device only**, so the
secret never syncs to iCloud and never leaves the device.

---

## 5. Transport

### Choice: Network.framework, Bonjour discovery, TCP with TLS 1.3

The Mac runs an `NWListener` advertising `_padlink._tcp` over Bonjour. The iPad runs an
`NWBrowser`, finds the Mac by name, and opens an `NWConnection`. Nagle's algorithm is
disabled (`NWProtocolTCP.Options.noDelay = true`) so small packets go out immediately.

### Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Multipeer Connectivity | Much less code, but it chooses its own transport and can fall back to Bluetooth. That would wreck trackpad feel with no way to control or debug it. Its identity model is a display-name string, so a real pairing and revoke story is awkward on top of it. |
| Split UDP for pointer, TCP for keys | A real optimization that removes head-of-line blocking, but premature. On a LAN, TCP with `noDelay` is already fast enough. Revisit only if measurement shows a problem. The current design does not block it. |

### Framing

4-byte big-endian length prefix, then the payload. TCP is a stream, so a single receive
can deliver half a message or three messages at once. A parser in Core handles both.

**A length header above 64KB is rejected and the connection is closed.** Without this, a
hostile peer could make us try to allocate 4GB.

### Message encoding: hand-written binary

First byte is the message type, the rest are fixed-width fields. The message set is small
and fixed, so this is roughly 150 lines with full round-trip tests.

JSON would also work, and the per-message cost would be negligible. Binary was chosen
because the message set is small enough that it is genuinely simple, it is easy to test,
and it avoids deferring the one thing this product is judged on.

### Messages

**From iPad:**

| Message | Fields |
|---|---|
| `hello` | protocol version (UInt16), device name (String) |
| `pointerMove` | dx (Int16), dy (Int16), dtMicros (UInt16) |
| `pointerButton` | button (UInt8), isDown (Bool) |
| `scroll` | dx (Int16), dy (Int16) |
| `keyText` | text (String) |
| `keyCode` | key (UInt16, a Padlink key ID), isDown (Bool), modifiers (UInt8 bitfield) |
| `ping` | seq (UInt32) |

**From Mac:**

| Message | Fields |
|---|---|
| `helloAck` | protocol version (UInt16), accessibilityGranted (Bool) |
| `pong` | seq (UInt32) |
| `error` | code (UInt8), message (String) |

An unknown message type is ignored, not treated as fatal, so a newer iPad app talking to
an older Mac app degrades instead of disconnecting.

**Two field definitions that must not be left to interpretation:**

`modifiers` is a bitfield: bit 0 shift, bit 1 control, bit 2 option, bit 3 command,
bit 4 function. Bits 5 to 7 are reserved and must be zero.

`key` is a **Padlink key ID**, defined by our own enum, **not** a macOS virtual key code.
The Mac maps it to a virtual key code using the table in Core. This keeps the wire format
platform-neutral, which matters if a Windows companion is ever built.

`dtMicros` is the time since the previous `pointerMove`, measured **on the iPad**. The Mac
must not measure this itself, because network jitter would corrupt the speed calculation
that acceleration depends on.

### Send rate

The iPad sends on **every `touchesMoved` call, immediately**. iOS already delivers those
at the display refresh rate, which is 60 per second on an iPad Air 5. Adding a
`CADisplayLink` to coalesce would insert up to another 16ms of latency for no benefit.

### Heartbeat

Ping and pong once per second. Three missed pongs marks the connection dead. Without a
heartbeat, a dead connection can go unnoticed until TCP times out, which can take over a
minute.

---

## 6. Input capture on the iPad

### Trackpad surface

A `UIViewRepresentable` wrapping a custom `UIView` that handles `touchesBegan`,
`touchesMoved`, and `touchesEnded` directly. **Not** a SwiftUI `DragGesture`, which adds
a recognition delay and hides how many fingers are down. Finger count is exactly what the
gesture map needs.

| Gesture | Action |
|---|---|
| One finger move | Pointer move |
| One finger tap | Left click |
| Two finger tap | Right click |
| Two finger move | Scroll |
| Tap, then press and move | Drag |

Plus a **left/right button bar along the bottom**, like a real trackpad. Cheap to build
and it makes dragging far less fiddly than tap-and-a-half.

### Keyboard

The **system keyboard**, received through a hidden view conforming to `UIKeyInput`. Above
it, a custom accessory row holds the keys iOS does not have: `esc`, `tab`, `ctrl`, `opt`,
`cmd`, and arrows.

A fully custom Mac-style keyboard was rejected for v1: it is a large amount of UI work,
and the system keyboard already provides layouts, languages, key repeat, and the emoji
picker.

**Autocorrect, auto-capitalisation, and smart quotes must be turned off**, or the keyboard
will silently rewrite what the user types.

### Modifier keys latch

Tap `cmd` and it stays armed for the next keystroke, then clears. **Long-press to lock**
it until tapped again. The lock is what makes holding `Cmd` across several `Tab` presses
work, so the macOS app switcher behaves normally.

### Hardware keyboard pass-through

If a physical keyboard is attached to the iPad, `pressesBegan` and `pressesEnded` provide
real `UIKey` values with key codes and modifier flags, forwarded straight through. This is
also the lowest-latency typing path, since no on-screen keyboard is involved.

### iOS Info.plist requirements

| Key | Value |
|---|---|
| `NSLocalNetworkUsageDescription` | Explains why the app talks to the Mac |
| `NSBonjourServices` | `["_padlink._tcp"]` |
| `NSCameraUsageDescription` | Explains that the camera is only used to scan the pairing QR code |

---

## 7. Input synthesis on the Mac

### Pointer movement

The Mac tracks the cursor position itself, adds the accelerated delta, clamps it, then
posts a `CGEvent` to `.cghidEventTap`.

Clamping uses the union of all screen frames. If the resulting point lands in a gap
between differently-sized monitors, it snaps to the nearest screen.

**Gotcha, stated so it is not rediscovered the hard way:** while a mouse button is held,
movement must be posted as `.leftMouseDragged`, not `.mouseMoved`. Many apps ignore plain
moves during a drag, so text selection and window dragging would simply not work.

### Clicks

`.leftMouseDown` and `.leftMouseUp`, with `mouseEventClickState` set so double-clicks are
recognised.

### Scrolling

`scrollWheelEvent2Source` with `.pixel` units, which gives smooth scrolling rather than
notched jumps. Scroll direction is a toggle in settings rather than trying to read the
system's "natural scrolling" preference.

### Typing: two paths

This is the important part of the design.

1. **Plain text** goes through `keyboardSetUnicodeString` on a `CGEvent` with virtual key
   `0`. This types the character correctly regardless of the Mac's active keyboard layout,
   and handles accents, emoji, and non-Latin scripts with no work from us.
2. **Special keys and shortcuts** must use real macOS virtual key codes with modifier flags
   set. `Cmd+C` only copies if the Mac sees key code `8` with the command flag. A unicode
   string would just type the letter "c".

**The routing rule:** anything printable with no modifier, or with only shift, takes path 1.
Everything else takes path 2. This rule and the key code table live in `PadlinkCore` and
are tested.

### Pointer acceleration

A pure function in Core. Fast finger movement covers more screen, slow movement gives
precision.

**Acceleration runs on the Mac, not the iPad.** The iPad sends the raw finger delta plus
its own `dtMicros`, and the Mac applies the curve. The reason is that the iPad does not
know the Mac's screen geometry or pixel density, so it cannot decide how far the cursor
should travel. The sensitivity slider therefore lives in the **Mac's settings window**, so
there is one source of truth and no extra message type. Moving that control to the iPad
later is a single new message, so nothing here blocks it.

Tests assert **properties, not exact numbers**:

- Zero input maps to zero output.
- Sign is preserved on both axes.
- Output magnitude grows with input magnitude.
- x and y behave identically.
- **Output is bounded**, so a timing hiccup cannot teleport the cursor across the screen.

### Release-everything safety requirement

If the connection drops, the iPad app backgrounds, or the Mac app quits **while a mouse
button is held or a modifier is locked**, the Mac must release all of them.

Without this, the user is left with a stuck `Cmd` key and a laptop that behaves strangely.
This is a stated requirement, not an afterthought.

### Accessibility permission is a first-class state

On launch the Mac checks `AXIsProcessTrusted()`. If it is false:

- Show onboarding that explains why the permission is needed.
- A button opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Poll trust status once per second while onboarding is visible.
- **Report `accessibilityGranted: false` in `helloAck`**, so the iPad shows "Grant
  Accessibility on your Mac" instead of silently doing nothing when the user moves a
  finger. That failure mode is otherwise very confusing.

**Known development annoyance:** each rebuild changes the binary, so macOS may re-ask for
the permission. This is expected, not a bug.

---

## 8. Connection lifecycle

### iPad states

```
unpaired → (scan QR) → paired
paired, disconnected → searching → connecting → connected
connected → disconnected(reason) → searching
```

Discovery is event-driven. When the Mac wakes and re-advertises on Bonjour, the iPad
reconnects immediately rather than polling. Connection failures against a Mac that *is*
advertising back off at 0.5s, 1s, 2s, 4s, capped at 5s.

`NWPathMonitor` watches for the iPad changing Wi-Fi network or losing it entirely.

### Mac states

| State | Behaviour |
|---|---|
| `idle` | Listener running, accepts only already-paired devices |
| `pairing` | 2-minute window, also accepts one new candidate secret |
| `connected` | A device is attached, menu bar indicator is visible |

### Failures and what the user sees

| Failure | Behaviour |
|---|---|
| Mac sleeps | Connection drops, iPad shows "Mac asleep or unreachable", retries automatically |
| Wrong pre-shared key | TLS handshake fails, connection closed, no data flows. The Mac stays quiet rather than acting as a probe oracle. |
| Accessibility not granted | Reported in `helloAck`, iPad shows a clear instruction |
| Heartbeat missed 3 times | Connection marked dead, release-everything runs, iPad returns to `searching` |
| Oversized frame header | Connection closed immediately |

### Latency budget

| Stage | Cost |
|---|---|
| Touch sample to `touchesMoved` delivery | up to 16ms |
| Encode and send | under 1ms |
| Wi-Fi round trip on 5GHz | 1 to 5ms |
| Decode and post `CGEvent` | under 1ms |
| Mac draws the new cursor position | up to 16ms |
| **Total** | **roughly 20 to 40ms** |

A built-in trackpad is around 10ms, so this will feel slightly soft but well inside
"fine". The main thing that would make it feel bad is a 2.4GHz or congested network.

**The iPad app shows a live round-trip latency readout**, derived from ping and pong, so
this is measured rather than guessed.

---

## 9. Known risk to resolve early

**Multiple pre-shared keys on one listener.** With more than one paired iPad, the Mac's
listener must hold several pre-shared keys and let TLS pick the right one by PSK identity.
`sec_protocol_options_add_pre_shared_key` should support being called more than once, but
this is **not yet verified**.

The implementation plan starts with a small spike to prove it.

**Fallback if it does not work:** v1 supports exactly one paired iPad, which covers the
actual use case. Multi-device becomes a v2 problem. The pairing ID is already in the QR
payload and the Keychain schema, so nothing has to be redesigned later.

---

## 10. Testing strategy

### Unit tests (swift-testing, in `PadlinkCore`, run by `swift test`, no simulator)

| Area | Cases |
|---|---|
| Codec | Every message type round-trips. Unknown message type is ignored, not fatal. |
| Framer | Partial frame, frame split across reads, several frames in one buffer, zero-length frame, oversized length header rejected |
| Pointer acceleration | The five properties listed in section 7 |
| Key routing | The unicode-vs-keycode decision rule across a table of inputs |
| Key code table | Every key in our enum maps to a valid macOS virtual key code |
| QR payload | Round trip, malformed input rejected, wrong version rejected |
| Pairing secret | Is 32 bytes long, and two generated secrets are never equal |

### Integration tests (macOS host, loopback, run by `swift test`)

| Case | Assertion |
|---|---|
| Matching pre-shared key | Handshake succeeds, a message round-trips |
| Mismatched pre-shared key | Handshake fails, no data flows |
| Heartbeat timeout | Connection is marked dead |
| Drop with a button held | Release-everything routine runs |

### Manual verification (real hardware, cannot be automated)

- Feel and measured latency on the real iPad and MacBook.
- `CGEvent` behaviour inside real apps: text selection, window dragging, `Cmd+Tab`,
  `Cmd+C` and `Cmd+V`.
- Permission prompts on both platforms.
- Typing with the Mac set to a non-US keyboard layout.

---

## 11. Workspace rule change needed

The project `CLAUDE.md` currently says:

> This directory is a self-contained named conversation ... It is NOT a code repo —
> there's no app to ship.

That stops being true. `CLAUDE.md` should be updated to describe a hybrid: `NOTES.md`
stays the running journal, and `Padlink/` is a real codebase with its own rules.

This change is pending the owner's approval and is not part of the implementation plan.
