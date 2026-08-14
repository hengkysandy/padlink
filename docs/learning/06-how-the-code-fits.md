# How the code fits together

## The shape

```
Padlink/
  Sources/PadlinkCore/       shared library, no UI, no platform input APIs
    Protocol/                wire format, messages, encode and decode
    Transport/               TLS-PSK, connections, framing
    Pairing/                 identity, the QR payload, the store interface
    Input/                   acceleration, key routing, held-input tracking
  PadlinkMac/                the macOS menu bar app
  PadlinkPad/                the iPad app
  Sources/PadlinkTestClient/ a command line client, for testing without an iPad
```

## The one idea worth copying: keep decisions away from the screen

This is the pattern that made the project testable, and it paid off repeatedly.

**Anything that decides something goes in a plain type with no UI import.**
Anything that draws or talks to hardware stays as thin as possible.

Examples:

| Pure and tested | Thin shell around it |
|---|---|
| `TouchInterpreter` (what a gesture means) | `TrackpadView` (receives touches) |
| `MoveThrottle` (clamping and accumulation) | |
| `PadStateMachine` (what state we are in) | `PadService` (owns the socket) |
| `ScanPlan` (what the camera should do) | `QRScanner` (runs the camera) |
| `PadStatus` (state to words) | `TrackpadScreen` (draws it) |
| `KeystrokeTranslator` (key to messages) | `TypingField` (a text field) |

That split is why there are 411 tests and why they run in under a second with no
simulator, no camera, and no network.

It also saved real work: when a session limit killed an agent halfway through,
the decision layer was complete and committed while the views were not written.
Nothing was lost, because the two halves were genuinely independent.

## How the two apps talk

**Discovery.** The Mac advertises `_padlink._tcp` over Bonjour. The iPad browses
for it and matches on the service name saved at pairing time.

**Pairing.** The Mac generates a random 256-bit secret and shows it as a QR code.
The iPad scans it. **The secret never crosses the network**, which is what makes a
man-in-the-middle attack impossible. Both sides store it in their Keychain.

**Encryption.** Every later connection uses that secret as a TLS pre-shared key.
No passwords, no certificates to manage, mutual authentication for free.

Because the secret has high entropy, no PAKE protocol is needed. A 6-digit PIN
would have forced SPAKE2 or SRP, which is real cryptographic code with real ways
to get it wrong.

**Messages.** A 4-byte length prefix then a hand-written binary payload. Frames
over 64KB are rejected, so a hostile peer cannot force a huge allocation.

Keys travel as Padlink key ids, not macOS virtual key codes, so a Windows
companion app stays possible later.

**Protocol version.** Currently 2. Both apps must agree. A mismatch produces a
clear message naming both versions rather than a silent hang.

## Design decisions worth remembering

**Acceleration runs on the Mac, not the iPad.** The iPad cannot know the Mac's
screen geometry. The iPad sends a raw delta plus its own measured time gap,
because measuring that gap on the Mac would let network jitter corrupt the speed
calculation.

**Typing has two paths.** Plain text uses a Unicode string, which is layout
independent and handles accents and emoji. Anything with a modifier, or any
non-printing key, uses real virtual key codes, because `Cmd+C` only works if the
Mac sees key code 8 with the command flag.

**No coalescing of movement.** Send on every touch event. iOS already delivers at
60Hz, so batching would add up to 16ms of latency and buy nothing.

**Release everything when a connection dies.** A connection dying mid-drag must
not leave a held mouse button or modifier on the Mac. This is a stated
requirement, and it is also where the worst bug in the project lived: a superseded
connection failed an identity check and never released, leaving the Mac's left
button stuck down. Fixed, and now tested.

**The heartbeat.** Each side treats roughly 6 seconds of silence as a dead peer.
Without it, a Wi-Fi drop is invisible for the many minutes TCP takes to notice,
and the iPad keeps saying "Connected" while nothing moves.

## Where the state machine lives

`PadStateMachine` is pure. Timers do not change state directly; they emit events
that flow through the machine. That is what keeps the heartbeat from fighting the
reconnection logic, and it means every timing rule is tested with no timers at all.

## The test client

`Sources/PadlinkTestClient` is a command line program that speaks the protocol.

```bash
./padlink paste          # pair using the clipboard
./padlink move 200 0     # move the cursor
./padlink click left
```

It exists so the Mac app could be developed and tested before the iPad app
existed. It is also the fastest way to check whether a problem is in the Mac side
or the iPad side: if the test client can move the cursor, the Mac is fine.
