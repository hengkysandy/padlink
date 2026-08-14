# Padlink

Turn an iPad into a trackpad and keyboard for a Mac, over Wi-Fi.

Two apps talk to each other on the same network: the iPad sends finger movement and
keystrokes, the Mac turns them into real input events. Pairing is done by scanning a QR
code, so the shared secret never travels over the network.

> ### Status: the shared core is built. The apps are not.
>
> **There is nothing to install on an iPad or a Mac yet.** This repository currently
> contains `PadlinkCore`, the shared Swift package that both apps will be built on: the
> wire protocol, the encrypted transport, the pairing format, and the input maths.
>
> What you can do today is **build it and run its 95 tests** on a Mac. That is covered
> below. The two apps are the next two pieces of work.

---

## Why the core came first

Everything in `PadlinkCore` runs under `swift test` with no simulator, no device, and no
code signing. That is deliberate. The parts of this product that are easy to get subtly
wrong (a wire format, a TLS configuration, a key code table) are all here and all tested,
while the parts that need a human looking at a screen (does the cursor feel right, did the
permission dialog appear) are left in the app layer where they belong.

The package contains no UI and no platform input code. It does not import SwiftUI, UIKit,
AppKit, CoreGraphics, AVFoundation, or CoreImage.

---

## Requirements

| Item | Needed |
|---|---|
| A Mac | Any Apple Silicon Mac running macOS 15 or later |
| Xcode | Installed. The tests need it (see the note below) |
| Apple Developer account | **Not needed** for the core. Needed later for the apps |
| An iPad | **Not needed yet.** Nothing runs on it at this stage |

### The one environment gotcha

`swift-testing` ships with Xcode, **not** with the Command Line Tools. If `xcode-select`
points at the Command Line Tools, `swift test` fails with `no such module 'Testing'`, which
looks like a broken checkout but is not.

Check which one you are on:

```bash
xcode-select -p
```

If it prints `/Library/Developer/CommandLineTools`, you have two options. Either set the
toolchain permanently (needs your password, and you will want this anyway once the apps
exist):

```bash
sudo xcode-select -s /Applications/Xcode.app
```

Or override it per command, with no password and no global change:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The instructions below use the override, so they work either way.

---

## Build and test

```bash
git clone https://github.com/hengkysandy/padlink.git
cd padlink/Padlink

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected result:

```
Build complete!
✔ Test run with 95 tests in 0 suites passed
```

Run one area at a time with `--filter`:

```bash
# Wire protocol
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MessageCodec
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FrameParser

# Encrypted transport (opens real TLS connections on loopback)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter Transport
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PadlinkConnection

# Pairing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PairingPayload

# Input maths
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PointerAcceleration
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeyRouting
```

The `Transport` and `PadlinkConnection` tests are real integration tests. They bring up an
`NWListener` on a loopback port and complete genuine TLS handshakes, including proving that
a wrong key is rejected. They take a few milliseconds longer than the rest, which is normal.

---

## What is in the package

```
Padlink/Sources/PadlinkCore/
├── Protocol/     message types, binary codec, length-prefixed framing
├── Transport/    TLS pre-shared key parameters, framed connection actor, heartbeat
├── Pairing/      secret generation, QR payload format, pairing store protocol
└── Input/        pointer acceleration, key routing rule, macOS virtual key table
```

About 1,100 lines of source and 95 tests.

### Protocol

A hand-written big-endian binary format. Each frame is a 4-byte length prefix followed by
the payload; frames over 64KB are rejected without allocating.

The iPad sends `hello`, `pointerMove`, `pointerButton`, `scroll`, `keyText`, `keyCode`,
`ping`. The Mac replies `helloAck`, `pong`, `error`.

Key identities on the wire are **Padlink key IDs, not macOS key codes**, so a Windows
companion stays possible later.

### Transport

TLS 1.2 with ECDHE_PSK ciphersuites, pinned explicitly to `0xD001`, `0xCCAC`, `0x00AA`.

Not TLS 1.3. Apple's `sec_protocol_options_add_pre_shared_key` is RFC 4279 style and TLS 1.2
only; every TLS 1.3 configuration fails the handshake with error `-9858`. This was measured,
not assumed, and the finding is recorded in `NOTES.md`.

The pinning is a security requirement rather than a preference: leaving the ciphersuite list
empty also completes a handshake, but can then negotiate a plain PSK suite with **no forward
secrecy**. A test reads the negotiated suite off a live connection to prove this holds.

`PadlinkConnection` is an actor handing out whole frames as `Data`, so the Mac decodes them
as `ClientMessage` and the iPad as `ServerMessage` from one shared implementation. Its
`incoming` stream **finishing** is the signal that the connection is gone, and therefore the
signal to release any held mouse button or locked modifier.

### Pairing

The Mac generates a random 256-bit secret with `SecRandomCopyBytes` and shows it as a QR
code. The iPad scans it. The secret travels optically and never over the network, which is
what makes a person-in-the-middle attack impossible.

The high entropy is load-bearing: it is why no password-authenticated key exchange (SPAKE2,
SRP) is needed, so TLS does all the cryptography and this project writes none.

The payload is a URL:

```
padlink://pair?v=1&id=<16 hex>&k=<base64url>&n=<mac name>&s=<bonjour instance>
```

### Input

`PointerAcceleration` turns a raw finger delta into a cursor delta. It runs on the Mac,
because only the Mac knows its screen geometry, and takes the time gap measured on the iPad,
because measuring it on the Mac would let network jitter corrupt the speed.

`KeyRouter` decides between two ways of typing on macOS. Plain text goes through
`keyboardSetUnicodeString`, which is layout-independent and handles accents and emoji.
Shortcuts must use real virtual key codes, because `Cmd+C` only copies when the Mac sees key
code 8. Shifted symbols fold onto their base physical key, so `Cmd+Shift+3` takes a
screenshot rather than typing `#`.

---

## Design documents

- `docs/superpowers/specs/2026-08-13-padlink-design.md`: the design and why each choice was
  made, including the alternatives that were rejected
- `docs/superpowers/plans/2026-08-13-padlink-core.md`: the implementation plan this was
  built from
- `NOTES.md`: the running journal, including measured findings and known gaps

---

## Not built yet

**macOS app.** Menu bar app, Accessibility permission onboarding, Keychain storage, Bonjour
advertising, QR generation and the pairing window, and `CGEvent` synthesis for pointer,
click, drag, scroll, and both typing paths.

**iPadOS app.** Bonjour discovery and reconnect, camera QR scanning, Keychain storage, the
raw-touch trackpad surface, the on-screen keyboard with latching modifiers, hardware keyboard
pass-through, and a live latency readout.

### Known gaps to close in those apps

- **Heartbeat is not wired.** `HeartbeatMonitor` is built and tested but not connected to
  `PadlinkConnection`, because the apps own the ping timers. Nothing sends pings yet.
- **No standalone modifier message.** `modifiers` only rides along with a `keyCode` message,
  so releasing a locked `Cmd` on its own sends nothing. Decide this before release: adding a
  message type is nearly free now and expensive later.
- **Keychain store.** Core ships the `PairingStore` protocol and an in-memory implementation.
  The real Keychain one belongs in the apps, where code signing exists.
- **Do not log `secret.bytes`.** Ordinary string interpolation is safe (it prints the byte
  count), but `dump()` or explicitly formatting the bytes as hex or base64 would put the
  pre-shared key in a log file.

---

## Distribution, when the apps exist

The Mac app must post synthetic input with `CGEvent`, which requires **Accessibility**
permission. A sandboxed Mac App Store app cannot use that permission workably, so the Mac
companion will ship as a notarized **Developer ID** app from a website. The iPad app can go
to the App Store normally.

---

## Expected performance

| Stage | Cost |
|---|---|
| Touch sample to delivery | up to 16ms |
| Encode and send | under 1ms |
| Wi-Fi round trip on 5GHz | 1 to 5ms |
| Decode and post the event | under 1ms |
| Mac draws the new position | up to 16ms |
| **Total** | **roughly 20 to 40ms** |

A built-in trackpad is around 10ms, so this will feel slightly soft but well inside usable.
The main thing that would make it feel bad is a 2.4GHz or congested network.

---

## Licence

Not yet chosen.
