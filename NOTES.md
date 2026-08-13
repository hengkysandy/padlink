# iPad-as-keyboard-and-trackpad for MacBook (working name: TBD)

Inspired by "Wingdeck" (IG video by surya_diputra). Source transcript:
`/Users/hengkysandy/Downloads/Video by surya_diputra.txt`

Idea: iPad app + macOS companion app, both on the same Wi-Fi. iPad becomes a
keyboard and trackpad that drives the MacBook.

## Hardware / tooling
- MacBook Air M5 (host / companion app)
- iPad Air gen 5 (client app)
- Xcode installed, iOS Simulator 26.5
- SwiftUI

## TODO when resuming
- [x] Finish brainstorming (architectural path, superpowers:brainstorming)
- [x] Write design spec: `docs/superpowers/specs/2026-08-13-padlink-design.md` (committed, a19342d)
- [ ] **User to review the spec**
- [x] Implementation plan for Core: `docs/superpowers/plans/2026-08-13-padlink-core.md`
- [ ] **Execute Plan 1 (PadlinkCore)**, starting with Task 0, the TLS-PSK spike
- [ ] Plan 2 (macOS app) and Plan 3 (iPadOS app), written after Core exists
- [ ] User must run once: `sudo xcode-select -s /Applications/Xcode.app`
- [ ] Decide whether to update project `CLAUDE.md` (it still says this is not a code repo)

## 2026-08-13 — Session 1 start
- Read the video transcript. Confirmed the concept: iOS/Android client + Mac/Windows
  companion, communicating over a single Wi-Fi network. Original app also does media
  control, stream deck, and a clock face. Our scope starts smaller.
- Started brainstorming. Classified as **architectural** (new project, two apps,
  network protocol, security-sensitive pairing).

## 2026-08-13 11:12 — (auto session marker)

## 2026-08-13 — Decisions locked (brainstorming)

**Environment**
- Xcode.app is installed but `xcode-select -p` points at `/Library/Developer/CommandLineTools`.
  Needs a one-time `sudo xcode-select -s /Applications/Xcode.app` (user must run it).
  No simulator runtimes visible until that switch happens. Swift 6.2.4 available.

**Decided**
1. **v1 scope:** trackpad + keyboard only. No media keys, no stream deck, no clock.
   Reason: prove low-latency input over Wi-Fi first. The rest is easy to add after.
2. **Apple account:** free Apple ID for now. iPad installs expire every 7 days.
   Paid membership later if the tests go well. Design must not depend on paid-only entitlements.
3. **Code location:** inside this folder. Will `git init` here.
4. **Transport:** Network.framework. Mac runs `NWListener` advertising over Bonjour,
   iPad uses `NWBrowser` + `NWConnection`. TCP with `noDelay = true`.
   - Rejected Multipeer Connectivity: it can silently fall back to Bluetooth, which
     would wreck trackpad feel with no way to control it.
   - Rejected split UDP/TCP: real optimization, but premature. Revisit only if measured.
5. **Pairing + security:** QR code pairing, then TLS 1.3 with a pre-shared key.
   - Mac generates a random 256-bit secret, shows it as a QR code.
   - iPad scans it with the camera. Secret never crosses the network, so no MITM is possible.
   - Both store it in Keychain. Every later connection uses it as the TLS 1.3 PSK
     (`sec_protocol_options_add_pre_shared_key`). Mutual auth + forward secrecy for free.
   - Key benefit: high-entropy secret means **no PAKE needed**. A 6-digit PIN would have
     forced SPAKE2/SRP, which is real crypto code with real ways to get it wrong.
   - Fallback: same secret shown as a 10-char base32 code (~50 bits) to type by hand.
   - Extras: pairing mode is a 2-minute window; paired-device list with revoke;
     visible indicator on the Mac while a device is controlling it.
   - Rejected trust-on-first-use with 6-digit number comparison: secure, but needs a
     confirm step on the Mac, so more steps for the same result.

**Hard constraint found**
- The Mac app must post synthetic input via `CGEvent`, which needs **Accessibility**
  permission. Sandboxed Mac App Store apps cannot use it usefully. So the Mac companion
  ships as a notarized **Developer ID** app from a website, not the Mac App Store.
  The iPad app can go to the iOS App Store normally. (Same as the video author did.)

## 2026-08-13 — Spec written

- `git init` done in this folder. Added `.gitignore` for Xcode/Swift.
- Working name **Padlink**. Personal project, not Arthanexa.
  Bundle IDs `com.hengkysandy.padlink.mac` / `.pad`. Bonjour type `_padlink._tcp`.
- Design spec committed: `docs/superpowers/specs/2026-08-13-padlink-design.md`

**Later decisions, on top of the ones above**
6. **Module split:** shared `PadlinkCore` SwiftPM package (protocol, transport, pairing,
   pure input logic) + two thin app targets. Core has no UI and no `CGEvent`, so the whole
   testable surface runs under `swift test` with no simulator and no device.
7. **Wire format:** 4-byte big-endian length prefix, hand-written binary payload.
   Frames over 64KB are rejected (stops a hostile peer forcing a huge allocation).
   `key` on the wire is a Padlink key ID, not a macOS virtual key code, so a Windows
   companion stays possible later.
8. **Send rate corrected mid-design:** send on every `touchesMoved`, no `CADisplayLink`
   coalescing. iOS already delivers at 60Hz on an iPad Air 5, so coalescing would only
   add up to 16ms of latency for nothing.
9. **Typing has two paths.** Plain text uses `keyboardSetUnicodeString` (layout-independent,
   handles accents/emoji). Anything with a non-shift modifier, or a non-printing key, uses
   real virtual key codes, because `Cmd+C` only works if the Mac sees key code 8 + cmd flag.
10. **Acceleration runs on the Mac**, not the iPad. The iPad cannot know the Mac's screen
    geometry. The iPad sends raw delta plus its own `dtMicros`, because measuring dt on the
    Mac would let network jitter corrupt the speed calculation.
11. **Hardware keyboard pass-through is in v1** (`pressesBegan`/`pressesEnded`). It is also
    the lowest-latency typing path since no on-screen keyboard is involved.
12. **Release-everything on drop** is a stated requirement. A connection dying mid-drag must
    not leave a stuck `Cmd` key or held mouse button on the Mac.

**Gotchas captured so we do not rediscover them**
- While a mouse button is held, movement must be posted as `.leftMouseDragged`, not
  `.mouseMoved`, or text selection and window dragging silently do not work.
- Autocorrect, auto-capitalisation, and smart quotes must be off on the iPad keyboard.
- Each Mac rebuild changes the binary, so macOS may re-ask for Accessibility. Expected.
- Expected end-to-end latency is roughly 20 to 40ms vs about 10ms for a real trackpad.
  A 2.4GHz or congested network is the main thing that would make it feel bad.

**Open risk (spike first in the implementation plan)**
- Can one `NWListener` hold several TLS pre-shared keys and pick by PSK identity?
  `sec_protocol_options_add_pre_shared_key` should allow multiple calls, unverified.
  Fallback: v1 supports exactly one paired iPad. The pairing ID is already in the QR
  payload and Keychain schema, so nothing needs redesigning later.

## 2026-08-13 — Spike result: TLS-PSK (Task 0)

**The spec was wrong about TLS 1.3. This is the headline finding.**

`sec_protocol_options_add_pre_shared_key` is RFC 4279 style, which is **TLS 1.2 only**.
Every TLS 1.3 configuration failed the handshake with error -9858. The SDK header for
`sec_protocol_options_set_tls_pre_shared_key_identity_hint` cites RFC 4279 directly,
and `tls_ciphersuite_t` exposes no PSK suites at all.

**Second finding: plain PSK has no forward secrecy.** The first working config found
was `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8), which has no Diffie-Hellman. The spec
promises "a captured recording cannot be decrypted later", and plain PSK breaks that
promise. Tested the ephemeral variants and they work, so forward secrecy is kept.

### What works (measured, not assumed)

| Config | Result |
|---|---|
| TLS 1.3, any ciphersuite | **fails**, -9858 handshake failed |
| TLS 1.2 + `ECDHE_PSK_AES_128_GCM_SHA256` (0xD001) | OK, forward secret |
| TLS 1.2 + `ECDHE_PSK_AES_256_GCM_SHA384` (0xD002) | OK, forward secret |
| TLS 1.2 + `ECDHE_PSK_CHACHA20_POLY1305` (0xCCAC) | OK, forward secret |
| TLS 1.2 + `ECDHE_PSK_AES_128_CBC_SHA256` (0xC037) | OK, forward secret |
| TLS 1.2 + `DHE_PSK_AES_128_GCM_SHA256` (0x00AA) | OK, forward secret |
| TLS 1.2 + `PSK_AES_128_GCM_SHA256` (0x00A8) | OK, **no forward secrecy** |
| TLS 1.2 + no explicit ciphersuite | OK, **but may negotiate plain PSK** |

**Decision: TLS 1.2 with the ECDHE_PSK suites pinned explicitly.** Pinning is not
optional. Leaving the ciphersuite list empty also completes a handshake, but then a
non-forward-secret suite can be negotiated.

`tls_ciphersuite_t` has no PSK cases, but it is `UInt16`-backed, so the suites are
built by raw value: `tls_ciphersuite_t(rawValue: 0xD001)!`.

### Answers to the three spike questions

1. **Several PSKs on one listener: YES.** Registered keys A and B on one `NWListener`;
   both clients connected and TLS picked the right secret by identity. So v1 can
   support several paired iPads. No fallback needed.
2. **Wrong key rejected: YES.** A client with an unregistered key never reaches ready.
3. **`as __DispatchData` compiles.** Keep the cast.

### Two code-level gotchas found the hard way

- **`NWConnection` instances must be retained.** ARC frees them the moment the local
  goes out of scope, and the handshake never completes. Applies to accepted connections
  on the listener side too. The original plan code had this bug.
- **A failed PSK handshake reports as `.waiting`, not `.failed`**, and Network.framework
  then retries forever. Any code waiting for a terminal state must treat `.waiting` as
  a failure or it hangs.
- Swift 6 strict concurrency forbids mutating a captured local from the `@Sendable`
  state handlers. State shared with Network.framework callbacks needs a reference box.

## 2026-08-13 — Plan 1 written (PadlinkCore)

`docs/superpowers/plans/2026-08-13-padlink-core.md`, 12 tasks, all TDD.

Split into three plans instead of one. Plan 1 is `PadlinkCore` only, because the
app plans have to name real Core function signatures, and writing them against a
guessed API would produce a plan that is wrong before it is executed.
Plan 2 (macOS app) and Plan 3 (iPadOS app) get written after Core is verified.

**Spec errors found while planning, both fixed in Plan 1 Task 11**
1. The manual base32 fallback was impossible. The spec said "the same secret as a
   10-character base32 code", but 10 base32 characters hold 50 bits and the secret
   is 256 bits. **Dropped from v1.** If built later: a separate 80-bit secret as
   16 base32 characters in four groups.
2. `KeychainPairingStore` cannot be tested in Core. An unsigned `swift test` binary
   has no access to the data protection keychain. Core defines the `PairingStore`
   protocol plus an in-memory implementation; the Keychain one is built in the app
   plans where code signing exists.

**Design gaps found while writing the code, fixed in the plan**
- `KeyRouter` originally returned one message for a shortcut. A key down with no
  matching key up leaves the key held on the Mac. Now returns `[ClientMessage]`:
  one message for text, two (down then up) for the key code path.
- `ConnectionError.failed(any Error)` cannot be `Sendable`. Stores a String now.
- TCP options live on `defaultProtocolStack.transportProtocol`, not
  `.internetProtocol`. The noDelay test was checking the wrong thing.
- `receiveLoop` cannot be `nonisolated`. `NWConnection` is not Sendable, so Swift 6
  strict concurrency rejects touching it from outside the actor.

**Task order**
0. Spike: does `sec_protocol_options_add_pre_shared_key` work, and do several keys
   fit on one listener? Throwaway code, deleted after. Answer goes here in NOTES.
1. Package scaffolding
2. Byte reader and writer
3. Message types and codec
4. Frame parser
5. Pointer acceleration
6. Key routing and macOS virtual key table
7. Pairing identity, secret, QR payload
8. Pairing store protocol and in-memory store
9. TLS pre-shared key transport parameters (real loopback handshake tests)
10. Framed connection, heartbeat, disconnect signal
11. Update spec, NOTES, and CLAUDE.md


## 2026-08-13 11:14 — (auto session marker)

## 2026-08-13 — PadlinkCore complete

- **90 tests passing**, `swift test` from `Padlink/`. Includes real TLS 1.2 PSK
  handshakes over loopback, not just unit-level codec and framing tests.
- **`KeychainPairingStore` is still to be built**, deferred to the app plans (Plan 2
  and Plan 3). An unsigned `swift test` binary has no access to the data protection
  keychain, so it cannot be tested inside Core. Core ships the `PairingStore`
  protocol plus an in-memory implementation for tests and for the app plans to
  build against.
- **`HeartbeatMonitor` is built and tested, but deliberately not wired into
  `PadlinkConnection`.** The apps own the ping timers, because the connection layer
  should not own timing. Heartbeat pings are not yet active over the wire.
- **Carry-forward warning (corrected):** ordinary string interpolation
  (`"\(record)"`) and `String(reflecting: record)` are safe. Swift's default
  reflection prints `Data` as its byte count, so both print
  `PairingSecret(bytes: 32 bytes)`, not the key bytes. Verified by running it,
  not assumed.
  The real leak paths are narrower: `dump(record)`, which walks into the
  `Data` contents, and any code that reaches into `secret.bytes` and formats
  it directly (hex, base64) into a log line. Neither `PairingRecord` nor
  `PairingSecret` should ever be passed to `dump()`, and app code must never
  format `secret.bytes` into a log line, since the project `CLAUDE.md`
  forbids logging secrets regardless of what the type itself does.
  Adding an explicit `CustomStringConvertible` to both types is still worth
  doing as cheap defence in depth before any app-layer logging exists, even
  though it is not fixing an active leak in ordinary interpolation.

## 2026-08-13 13:51 — (auto session marker)

## 2026-08-13 — Spike: Keychain from an ad-hoc-signed app

- **Legacy file keychain works. Data protection keychain does not.**
  `SecItemAdd` with `kSecUseDataProtectionKeychain: true` returns
  `-34018` (`errSecMissingEntitlement`). Without that key (legacy keychain),
  `SecItemAdd` and `SecItemCopyMatching` both return `0` and the payload
  round trips correctly.
- Ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) carries no entitlements, so the
  data protection keychain refuses the request outright. The legacy
  file-based keychain does not require that entitlement, so it works from
  an unsigned-for-distribution but still-real bundle.
- No password or GUI prompt appeared on either path. Both runs completed
  non-interactively with exit code 0.
- Rebuilt the binary from a clean `.build` directory and re-ran: identical
  result, same status codes for both paths. A rebuild does not change the
  outcome for either keychain (the legacy keychain is not entitlement- or
  binary-identity-gated in this setup).
- **Decision for Task 8 (`KeychainPairingStore`): do not set
  `kSecUseDataProtectionKeychain: true`. Use the legacy file keychain.**
- Brief defect found: the `project.yml` in the task brief was missing
  `GENERATE_INFOPLIST_FILE: "YES"`. Without it, `xcodebuild` fails code
  signing with "Cannot code sign because the target does not have an
  Info.plist file." Added that setting to get a build; not otherwise
  material to the Keychain finding.
- Spike code deleted after recording this result, per plan.

## 2026-08-13 15:02 — (auto session marker)
# Padlink

## TODO when resuming


## 2026-08-14 00:57 — (auto session marker)

## 2026-08-14 — First working end to end run

The Mac app is driven successfully by the command line client. This is the first
time anything outside the process moved the cursor.

- `./padlink paste` paired: "Paired with hengky's MacBook Air."
- `./padlink move 200 0` moved the cursor right. Confirmed by eye, repeated 4 times.
- No Accessibility warning printed, so the Mac reported permission granted through
  `helloAck`. The warning path added in Task 12 stayed correctly silent.

Three real defects found by hand, all in my plan rather than in the implementations:

1. **The pairing window never came to the front.** `LSUIElement: true` makes this an
   accessory app, and macOS never activates those on its own. `openWindow` created the
   window behind everything, unfocused, which from the user's side was identical to the
   button doing nothing. Fixed with `NSApplication.shared.activate()` in a `showWindow`
   helper, applied to the onboarding window too, which had the same latent bug.
2. **`beginPairing` failures were swallowed silently.** Predicted by the Task 11
   reviewer as a thing to check by hand here, and worth checking even though the real
   cause turned out to be different: the service now sets `.failed` with a readable
   message, which the menu already rendered.
3. **The pairing URL text drew on top of the Cancel button.** Wrapped to three lines
   without reporting its height to the layout. Replaced with a "Copy pairing code"
   button: at a size that fits the window the URL was unreadable anyway, and nobody
   retypes a 32 byte key.

Usability changes made while unblocking the run:

- The pairing URL is copied to the clipboard on "Pair a device", so pairing never
  depends on a window being visible. Clipboard is readable by other apps; accepted
  because the key is single use and expires in 120 seconds.
- Added `Padlink/padlink`, one script for build, launch, test, pair, and every client
  command, so the worktree path and branch stop being something to remember.
- `./padlink paste` pairs straight from the clipboard. The raw URL contains `&`, which
  zsh parses as "run in background", so pasting it by hand fails with a parse error.

Note for the iPad plan: scanning the QR with an iPad reports "no usable data found".
That is correct and expected. Nothing on iPadOS claims the `padlink://` scheme until the
Padlink iPad app exists.

Still to verify by hand: the down-not-up coordinate check, click, type, scroll, copy and
paste, held modifier survival, drag to select, quit with a button held, non-US layout,
and two clients at once.

## 2026-08-14 — Coordinate check verified by measurement

Measured rather than eyeballed: read the cursor position, sent the move, read it
again. `NSEvent.mouseLocation` is bottom-left origin, so the script prints the
top-left equivalent too, to remove any chance of misreading the sign.

- `move 0 200`: topLeftY 405 -> 805. Increasing top-left Y is downward. Correct.
- `move 10 0`: x 378 -> 398. Increasing x is rightward. Correct.

Both moves appeared to be amplified exactly 2x, which looked like a Retina point
versus pixel scaling bug. It was not, and the arithmetic shows two different
mechanisms that coincidentally agreed:

- `move 10 0`: 10px in 16.7ms is 600 px/s. gain = 1.0 + 0.0018*600 = 2.08.
  Output 10 * 2.08 = 20.8. Measured 20.
- `move 0 200`: 12000 px/s, so gain hits its 6.0 ceiling giving 1200, which then
  hits the separate `maxOutputPerEvent` cap of 400. Measured 400.

Lesson worth keeping: a suspicious round number is a reason to check the formula,
not a reason to assume a bug. I nearly recorded a scaling defect that does not
exist.

Signing and install changes made this session:

- Ad-hoc signing was the root cause of Accessibility permission dropping on every
  rebuild, because the signature changed each time. Now signed with a real Apple
  Development identity, verified with `codesign -dvvv`: TeamIdentifier matches the
  configured team and the chain reaches Apple Root CA. The team id lives in a
  gitignored `.padlink-team`, confirmed with `git check-ignore`.
- The app is installed to `/Applications` and launched from there. Running from
  the build directory had two problems: it sits inside two dot-folders, so Finder
  will not show it in the Accessibility file picker at all, and a clean build
  deletes it, which silently invalidates the permission later.

Still to verify by hand: click, type, scroll, copy and paste, held modifier
survival, drag to select, quit with a button held, non-US layout, two clients at
once.
