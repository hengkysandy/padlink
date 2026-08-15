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

**2026-08-14: the end goal is met.** On real hardware, over real Wi-Fi, the iPad
moves the Mac's cursor, types, and left-clicks. Verified by the user, not inferred
from tests. Everything below is hardening and polish, not "make it work".

Branch `worktree-padlink-mac`. Suites: **Core 120, PadlinkMac 102,
PadlinkPadTests 320.**

Every review finding is now fixed and every planned feature is built. What is
left is hand testing on the device, which no test can stand in for.

Not yet exercised by hand:
- [ ] Two-finger scroll, and the whole new gesture set. The simulator physically
      cannot produce a multi-finger gesture, so the iPad is its first real test.
- [ ] Right click (two-finger tap), pinch to zoom, three- and four-finger swipes.
- [ ] The on-screen keyboard, and a locked modifier surviving several keys
      (`Cmd` locked, then `Tab` `Tab` `Tab`).
- [ ] Drag to select text.
- [ ] A real Wi-Fi drop, to confirm the heartbeat notices in ~6s.

The iPad build expires **2026-08-20** (free account, 7 day profile). Re-run
`./padlink pad` to renew.

Then: merge to `main` and push.

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

## 2026-08-14 — iPad plan, tasks 1 and 2 (iOS target, MoveThrottle)

Branch `worktree-padlink-mac`. Plan: `docs/superpowers/plans/2026-08-14-padlink-ipad-app.md`.

Task 1, the iOS target:

- `Padlink/project.yml` gained `PadlinkPad` (application, iOS 18.0) and
  `PadlinkPadTests` (unit test bundle). Both mirror the Mac pair, including
  `GENERATE_INFOPLIST_FILE: "YES"` on the test target, which has no `info:`
  block and fails code signing without it.
- Info.plist keys from the plan: `NSBonjourServices`,
  `NSLocalNetworkUsageDescription`, `NSCameraUsageDescription`,
  `UISupportedInterfaceOrientations~ipad`.
- Three things the plan did not list but the target needs: `UILaunchScreen`
  (without it iOS runs the app letterboxed in phone compatibility mode),
  `TARGETED_DEVICE_FAMILY: "2"` (the plan's orientation key is `~ipad`-suffixed,
  so an iPhone build would inherit no orientations at all), and a `.gitignore`
  line for the generated `Padlink/PadlinkPad/Info.plist`.
- Verified: `xcodebuild -scheme PadlinkPad -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' build`
  reports `** BUILD SUCCEEDED **`. Installed and launched in the simulator; the
  screenshot shows a full-screen placeholder, so the launch screen key works.
- Simulator gotcha: a cold simulator answers install with
  `Application failed preflight checks ... reason: Busy`. Boot it first with
  `xcrun simctl bootstatus <name> -b`. `./padlink test` now does that.

Task 2, `MoveThrottle`:

- `Padlink/PadlinkPad/MoveThrottle.swift`, 17 tests in `PadlinkPadTests`.
- Bounds `dtMicros` to `1...65535` and `dx`/`dy` to the `Int16` range *before*
  any integer conversion, because an out-of-range conversion in Swift traps, and
  a trap in a touch handler kills the app.
- Accumulates sub-pixel remainders, returns `nil` on a no-op move.
- The gap is measured from the last move actually **sent**, not the last event
  seen. Several accumulated events carry combined distance, so they must carry
  combined time, or the Mac's acceleration curve reads the finger as moving
  several times faster than it really was.
- 11 mutations were introduced one at a time and all 11 were caught. Removing
  only the upper gap clamp crashed the test runner with `Fatal error: Double
  value cannot be converted to UInt16 because the result would be greater than
  UInt16.max`, which is the exact crash the type exists to prevent.

Test counts after this work: Core 107, PadlinkMac 49, PadlinkPadTests 18.

Left untracked on purpose: `Padlink/NOTES.md`, a 6-line duplicate stub written
by a session-start hook that ran with the working directory set to `Padlink/`
rather than the repo root. Harmless, but it is not the journal.

## 2026-08-14 — iPad app installed and launching on the physical device

Placeholder only: it shows the app name and the protocol version. No networking yet.
The point was proving the install chain, not the app.

Chain now verified end to end on the real iPad (iPad Air 5, iPadOS 26.5.2):
certificate valid to Aug 2027, device registered with the team, signed device build,
install via `devicectl`, trust gate passed, app launches.

Two things learned that would have cost time later:

- **Building against `generic/platform=iOS` does not register the device with Apple.**
  It fails with "your team has no devices from which to generate a provisioning
  profile". Building against the specific device id registers it and succeeds. Good
  thing to discover with a placeholder rather than a finished app.
- **The "Untrusted Developer" dialog is per certificate, not per app**, and offers only
  Cancel. The trust switch lives in Settings > General > VPN & Device Management. It
  will not reappear for later builds.

Working device install command, for reuse:

```
xcodebuild -scheme PadlinkPad -configuration Debug \
  -destination 'id=<device-id>' -derivedDataPath .build-device \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team> \
  CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-id> \
  .build-device/Build/Products/Debug-iphoneos/PadlinkPad.app
```

Tasks 1 and 2 complete (6ccfcdc): iOS target with all four plist keys, and
`MoveThrottle`, which clamps the `dtMicros` value that would otherwise trap and kill
the app when a finger pauses mid-drag. 11 mutations, all caught, 3 of them killing the
process exactly as the real bug would.

Four more plan defects found by the implementer, the notable one being a missing
`UILaunchScreen` key: without it the app runs letterboxed in phone compatibility mode
on an iPad. My plan's only check for that task was "does it build", which it did,
perfectly, while looking wrong. Caught by taking a screenshot instead of trusting the
build result.

Suites: Core 107, PadlinkMac 49, PadlinkPadTests 18.

## TODO when resuming

1. Tasks 3-5 (MacBrowser, PadPairingStore, PadService) and Task 6 (`TrackpadView`) have
   landed. Reports: `.superpowers/sdd/ipad-task-3-5-report.md`,
   `.superpowers/sdd/ipad-task-6-report.md`.
2. `TrackpadView` is built but not placed in any screen yet. Task 8 wires it to
   `padService.send`.
3. Then Tasks 7-8: QR scanning plus a paste field (the simulator has no camera, so the
   paste field is the development path, not a fallback), and the main screen wiring.
4. Test in the simulator first: it shares the Mac's network so Bonjour works. Then the
   physical iPad for real multi-touch and the camera.
5. Mac app still has unfinished hand checks: click, type, scroll, copy and paste, held
   modifier survival, drag to select, quit with a button held, non-US layout, two
   clients at once. The coordinate check is done and verified by measurement.
6. Then: whole-branch review, merge to main, push.

## 2026-08-14 — iPad plan Tasks 3, 4, 5 (browse, remember, connect)

- `Padlink/PadlinkPad/MacBrowser.swift`: `NWBrowser` wrapper plus `DiscoveryTracker`,
  the pure reducer that decides what the browser's reports mean. Five outcomes, not
  two: idle, searching, otherMacsOnly, found, localNetworkDenied, failed.
- `Padlink/PadlinkPad/PadPairingStore.swift`: Keychain store with
  `kSecUseDataProtectionKeychain` (which the Mac cannot use) and
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `Padlink/PadlinkPad/PadService.swift`: client lifecycle, `PadStateMachine` holds
  every state rule. One read loop over `PadlinkConnection.incoming`, at
  `PadService.swift:536`.
- Suites after: Core 107, PadlinkMac 49, PadlinkPadTests **95** (was 18).
  Command: `./padlink test`.
- 18 mutations applied one at a time, all 18 caught, sources restored byte for byte.
- Plan defects found: Task 4's `kSecAttrAccessibleAfterFirstUnlock` (no
  `ThisDeviceOnly`) would let a device backup restore a working key onto a different
  iPad; Task 5 has no liveness check, so Core's `HeartbeatMonitor` is still dead code
  and a dropped Wi-Fi leaves the state on `.connected`.
- Not verified without hardware: the local network denial itself (the simulator does
  not enforce the permission), real Bonjour discovery, and a real rejected key.
- Report: `.superpowers/sdd/ipad-task-3-5-report.md`.

## 2026-08-14 — iPad plan Task 6 (the trackpad itself)

- Split into two files, not the one the plan names. `Padlink/PadlinkPad/TouchInterpreter.swift`
  holds every decision and imports no UIKit; `Padlink/PadlinkPad/TrackpadView.swift` is the
  `UIViewRepresentable` shell plus `TrackpadSurface` and `TrackpadCoordinator`.
  `UITouch` cannot be constructed, so a view full of `touchesBegan` is untestable.
- `TouchInterpreter` is a class, so its single `MoveThrottle` (a struct with a sub-pixel
  accumulator) cannot be forked by a copy.
- Thresholds: tap <= 0.25 s and <= 10 points from the furthest point reached;
  tap-then-drag chains within 0.3 s. All three under the Mac's 0.5 s double click
  interval, so a chained drag still selects by word.
- Scroll is natural (content follows the fingers): the centroid delta passes through
  with its sign unchanged on both axes. Own sub-pixel accumulator and own `Int16` clamp,
  because scroll does not go through `MoveThrottle`.
- Any change in the number of fingers ends one gesture and starts another with a fresh
  baseline, and reports no movement of its own. That is what stops the cursor jumping.
- Suites after: Core 107, PadlinkMac 49, PadlinkPadTests **139** (was 95).
  Command: `./padlink test`.
- 14 mutations applied one at a time, all 14 caught, sources restored and verified by
  SHA-256. None were caught by the compiler.
- Defects found: `UIView.isMultipleTouchEnabled` defaults to false, so without setting it
  two-finger scroll never happens at all (missing from the brief's trap list); a
  two-finger tap lifts one finger first, so the leftover finger would left-click unless
  it is marked not tap-eligible; `ClientMessage.scroll` needs its own clamp, which the
  plan only discusses for `pointerMove`. Also fixed in my own shell: `UIEvent.allTouches`
  lists touches from other views, which would turn a drag into a scroll.
- Not verifiable without hardware: real multi-touch (the simulator's Option-key gesture
  is a symmetric pinch, whose centroid barely moves), the scroll sign, and whether
  `touchesCancelled` fires when the app backgrounds mid-drag.
- Report: `.superpowers/sdd/ipad-task-6-report.md`.

## 2026-08-14 — Tasks 7 and 8: the iPad's views

Built the SwiftUI/UIKit shells over the already-committed decision layer. All new,
all untracked except `PadlinkPadApp.swift`:

- `PadlinkPad/QRScanner.swift`: `AVCaptureSession` + `AVCaptureMetadataOutput`.
  `metadataObjectTypes` is set **after** `addOutput` (before it, the preview runs and
  never detects anything). `startRunning()` runs on a private serial queue.
  De-duplicates repeat reads of the same code; stops on the first success and in
  `dismantleUIView`.
- `PadlinkPad/PairingScreen.swift`: driven by `ScanPlan.step(...)`. Paste field is
  first and prominent when there is no camera.
- `PadlinkPad/LocalNetworkNoticeScreen.swift`
- `PadlinkPad/TrackpadScreen.swift`: `TrackpadView`, `PadStatus` header, typing bar.
- `PadlinkPad/TypingField.swift`: `UITextField` subclass. Backspace goes through a
  `deleteBackward()` override, not the delegate: UIKit does not call
  `shouldChangeCharactersIn` when there is nothing to delete, and this field is always
  empty. All rewrite traits off (autocorrect, autocaps, smart quotes/dashes, inline
  prediction, math completion, Writing Tools).
- `PadlinkPad/PadlinkPadApp.swift`: placeholder replaced; owns `AppModel`, switches on
  `screen`, wires `scenePhase`.
- `PadlinkPadTests/TypingFieldTests.swift`: 12 tests, only over real new logic.

Verified:
- `xcodebuild -scheme PadlinkPad -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' build`: succeeds, no warnings.
- Installed and launched with `xcrun simctl install/launch booted com.hengkysandy.padlink.pad`.
  Shows the pairing screen, still alive after 4 s, no crash.
- Suites: Core 107, PadlinkMac 49, PadlinkPadTests 219 (was 207).
- 6 mutations on the new tests, all killed.
- Screenshotted the notice screen and the trackpad screen (warning and error states)
  by temporarily forcing `RootView`'s switch and `TrackpadScreen.status`. **Both
  overrides have been reverted**; the tree holds no debug state.

Found while screenshotting: the trackpad surface is `secondarySystemBackground`, which
is the same grey as `systemGroupedBackground` in light mode, so the one thing the user
is meant to touch was invisible. Root background changed to `systemBackground`, and the
trackpad now has a rounded border and a hint label.

## TODO when resuming (tasks 7/8)
- Nothing is committed yet. `git status` shows 5 new files plus `PadlinkPadApp.swift`.
- Still to do: write `.superpowers/sdd/ipad-task-7-8-views-report.md` and commit.
- Not verified: the camera path end to end, the local network prompt, and pairing by
  paste (the simulator cannot be tapped from the CLI). All need a device or a person.

## 2026-08-14 10:37 — (auto session marker)

## 2026-08-14 — Heartbeat, live Accessibility, and a stuck mouse button

Branch `worktree-padlink-mac`. Full write-up: `.superpowers/sdd/heartbeat-report.md`.

- Test counts: Core 107 -> 114, Mac 49 -> 66, iPad 219 -> 231. `cd Padlink && ./padlink test`.
- **Protocol version bumped 1 -> 2.** Not for the new message type (unknown type
  bytes already throw and both consumers skip them), but for the heartbeat: a v2
  Mac now expects traffic every ~2s and a v1 iPad never pings, so a v1 iPad would
  be killed every 6 seconds.
- **Heartbeat wired in.** iPad pings every 2s; `HeartbeatMonitor` lives inside
  `PadStateMachine` so a missed ping flows through as `PadEvent.pingSent` instead
  of a timer mutating state. Pongs come through the one existing `incoming`
  iterator. New failure `PadFailure.macStoppedAnswering` with its own wording.
- **Mac watches for silence instead of pinging back.** New `ConnectionWatchdog`
  (2s tick, 3 missed = dead). Any inbound frame counts, and `noteFrameReceived()`
  runs before decode so a newer iPad is not declared dead for an unknown message.
- **`ServerMessage.accessibilityChanged(granted:)`, type byte 131.** iPad updates
  `PadState` live, so the orange banner clears when the user grants the permission
  and appears if it is revoked mid-session.
- **Critical bug found by a parallel review, verified and fixed.**
  `PadlinkService.readLoop` had its identity guard above `router.releaseEverything()`.
  `router` is one instance for the process, and `accept()` swaps `connection`
  synchronously, so a superseded loop ALWAYS returned early and never released.
  Wi-Fi drop mid-drag + reconnect = left mouse button stuck down at the HID level.
  Extracted `endSession(isCurrentConnection:reason:)` and moved the release above
  the guard.
- **Second real defect:** `AccessibilityStatus.startPolling()` was only called from
  the onboarding window's `onAppear`. That window is suppressed at launch, so the
  permission was in practice read once at startup and never again. Polling now runs
  for the life of the app, from `PadlinkMacApp.init()`. Without this fix the
  accessibility feature would have shipped dead.
- **Not fixed, reported:** the Mac does NOT reject a protocol mismatch (it
  discards the client version in `hello`); only the iPad does, from `helloAck`.
  And held key codes are still untracked in `MessageRouter`, so a stuck letter key
  cannot be released (modifiers are fine, they use the absolute `modifierState`).
- 26 mutations run, one at a time, all caught, every restore verified by SHA-256.

## 2026-08-14 — IT WORKS. iPad drives the Mac, on real hardware.

The stated end goal, met: "my ipad can connect to macbook and control keyboard
and touchpad". User confirmed cursor movement, typing, and left click on the
physical iPad Air 5 over Wi-Fi.

**What real hardware proved that the simulator could not:** Bonjour discovery
over actual Wi-Fi, the TLS-PSK handshake, camera QR scanning, and the pairing
key surviving in the iPad Keychain.

**Three failures hit on the way, all diagnosed correctly and none of them bugs
in the app:**

1. *Protocol version mismatch.* The iPad build carried protocol v2 (heartbeat
   work), the running Mac app was a v1 binary. The app said so in plain words
   naming both versions. Fixed by rebuilding both from one snapshot. Lesson:
   while an agent holds the tree dirty, build **both** apps back to back or
   they silently diverge.

2. *Repeated Mac keychain password prompts.* Not keychain locking (checked:
   `no-timeout`, unlocked). The pairing item was first written by an **ad-hoc
   signed** build; macOS binds each item's ACL to the creating identity, so the
   now team-signed app was a stranger to its own data. Fix: "Always Allow" once.
   Durable fix queued (task 41): data protection keychain, now possible because
   the ad-hoc blocker is gone.

3. *Accessibility toggle showed ON while the Mac reported denied.* Each
   `./padlink up` does `rm -rf` + `cp -R`, orphaning the grant.
   `tccutil reset Accessibility com.hengkysandy.padlink.mac` reported success
   **three times**, one stale record per rebuild, while the UI showed a single
   toggle. Fix: reset, relaunch, re-add.

**Payoff worth remembering:** the orange "Connected, but your Mac is ignoring
it" banner did its job. Without it this would have looked like a dead app with
a healthy connection, which is the single most confusing failure in this
project and had already cost time twice.

Suites verified independently after the heartbeat commit: Core 114,
PadlinkMac 66, PadlinkPadTests 231. Commits: 3278f92 (heartbeat + live
accessibility + the Critical stuck-button fix), d0b8265 (`./padlink pad`).

## 2026-08-14 12:11 — (auto session marker)

## 2026-08-14 — Pairing lifecycle security pass (branch-review I2–I5)

Commit `011a47a`. Full write-up: `.superpowers/sdd/pairing-security-report.md`.

- **I2 (any connection promotes the candidate).** Measured first: Network.framework
  cannot report the negotiated PSK identity. `sec_protocol_metadata_access_pre_shared_keys`
  returns the keys configured *locally* (two-key loopback listener saw both after a
  one-key handshake). The server-side PSK selection block does carry the offered
  identity but is shared across connections, so correlating it is a race. Fix: a
  pairing window's listener accepts only the candidate key, and each connection
  carries the single identity its listener was built for down through `accept` and
  `readLoop`. Cost: a paired iPad cannot make a *new* connection while a window is
  open.
- **I3.** `PadlinkService.completedPairings` (published counter, bumped only after
  `store.save` succeeds) closes the QR window.
- **I4.** Auto-copy on "Pair a device" removed. The button in `PairingView` is now
  the only writer, via `PairingClipboard`, which marks `org.nspasteboard.ConcealedType`
  and clears on close unless the user copied something else. The old comment's
  "single-use" and "expires in 120 seconds" were both false.
- **I5.** `cancelPairing` fails closed and loud instead of `try?`. New
  `listeningIdentities` records what the running listener was *really* built for.
- 12 mutations, all caught, restores SHA-256 verified.
- Suites: Core 114, PadlinkPadTests 231, PadlinkMac 90 run / 88 pass.

### TODO when resuming
- `./padlink test` cannot build the Mac target: the new `PadlinkMac.entitlements`
  needs a provisioning profile and the `test)` branch is the only one that does not
  pass `"${SIGNING[@]}"`. Add it.
- `KeychainPairingStoreTests.testLoadingAMalformedRecordThrowsMalformedStoredRecordNotADecodingError`
  fails: its raw `SecItemAdd` was not given `kSecUseDataProtectionKeychain` when the
  store was. Two failing assertions, one test.
- A peer can drive input without ever sending `hello`. `readLoop`'s `default:` branch
  has no handshake guard.
- **Two agents were editing this worktree at once today.** Do not do that again.

## 2026-08-14 12:56 — (auto session marker)

## 2026-08-14 — Salvaged four killed agents, then finished the feature work

**Session limit killed all four parallel agents mid-task.** Their worktrees
survived, so nothing was lost. Three had complete work, one had 21 lines of test
helpers and was discarded.

- `agent-a1cb729a6ad6f7876` (held keys + handshake gate). Reported "my restore
  helper replaced an empty string" before dying. Confirmed: `HeldInputState.swift`
  had gone from 62 lines to 4044, with `        heldKeys.removeAll()` woven
  between every single character of the file. Tests and the router change were
  untouched, and they fully specified the intended behaviour, so the fix was
  `git checkout` the one file and re-apply by hand rather than un-mangle it.
- `agent-ab8b8190cd88b97a7` (QR scanner data race). Complete. Extracted
  `ScanCodeFilter`, moved the callbacks to `@MainActor`, confined the session to
  its queue with `dispatchPrecondition`.
- `agent-aac6c329cdb78d7cc` (keyboard engine). Complete, engine only, no view.
- `agent-a30b3c4444709e1c6` (gestures). Nothing usable. Redone by hand.

Merged all three into `worktree-padlink-mac`, then built the rest directly.

**Lesson recorded:** an agent's own last message understated what it had done in
two of the four cases. Reading the worktree beat trusting the report.

### What shipped

- Held key codes are tracked and released, so a drop mid-keystroke cannot leave
  a letter repeating on the Mac.
- Input now requires `hello` on the connection. A peer that skips it gets the
  socket closed, not ignored: ignoring would let it hold the single connection
  slot forever and keep the real iPad out.
- Gestures: two-finger tap right clicks, pinch zooms, three- and four-finger
  swipes, momentum scrolling. macOS has no public API for synthesizing a real
  pinch or swipe, so a zoom is Command-scroll and a swipe is a keyboard
  shortcut. No protocol change needed.
- On-screen keyboard with three layouts, MacBook as the default, remembered
  across launches.

### Two bugs the tests caught in the new gesture code

- A third finger landing ended the two-finger gesture with no travel and no time
  elapsed, which looks exactly like a tap. Every three-finger swipe would have
  opened a context menu before it started.
- A scroll paused before lifting kept the speed it had a second earlier and
  coasted away on it, because a still finger still produces `.moved` events.

### Two more found by asking where a locked modifier could outlive its display

- Backgrounding does not close the connection (`PadService` only makes a note),
  so a locked Command stayed held on the Mac while the user was in another app.
- Switching to the "Trackpad only" layout removed the keyboard while the Mac was
  still holding what it had locked, with nothing left to tap to release it.

### Housekeeping

- All seven `docs/learning/*.md` files ended with two lines of stray tool markup
  (`</content>` and `</invoke>`) from how they were written last session.
  Stripped. Added `07-gestures-and-keyboard.md`.

## 2026-08-14 — Hand testing on the iPad, and what it overturned

First real multi-finger test on hardware. Two features were dead, and neither
was findable from the code.

- **Three finger swipes did nothing.** Not a bug in the gesture code. iPadOS
  reserves three finger swipes for undo/redo/copy/paste, that recognizer lives
  on the window, and when it recognizes it **cancels** the touches the view was
  tracking. So the swipe arrived as `touchesCancelled` and the interpreter
  correctly did nothing. Fixed with
  `editingInteractionConfiguration = .none` on the trackpad view.
  Four and five finger swipes cannot be reclaimed at all; they need the user to
  turn off "Four and Five Finger Gestures" in Settings.
- **Drag to select did nothing.** `dragChainWindow` was 300ms, which is faster
  than people move. Raised to 450ms, still under the Mac's 500ms double click
  interval. `tapMaxDuration` 0.25s to 0.3s for the same reason.

**Both passed every unit test.** The tests hand the interpreter events directly,
and on the device those events never arrived. Recorded in `05-gotchas.md` as the
argument for hand testing even when coverage looks complete.

### Layout, reworked on user feedback

- Keyboard now sits **above** the trackpad, matching the MacBook itself. It was
  the wrong way round.
- Hiding the keyboard is a **button**, not a layout. "Trackpad only" was the
  wrong shape for the question: which keyboard is a set-once choice, whether it
  is on screen is flipped constantly. `KeyboardLayout` is two cases now.
- The full width typing field is gone, moved behind a button. It was the only
  way to type before the keyboard existed; now it is the second way, and it was
  taking a permanent stripe the trackpad needed.
- The trackpad shows the **live finger count** while more than one finger is
  down. Added because a multi-finger gesture that does nothing gives no clue
  whether the fingers were seen at all.

## 2026-08-14 21:20 — (auto session marker)

## 2026-08-15 — Hand test: only click, right click and scroll work

User on the iPad: "all gesture not work, on ipad touchpad it only work with left
click and right click and scroll, thats all". So broken: pinch zoom, three-finger
swipe, four-finger swipe, drag to select, momentum.

Followed systematic-debugging. Two root causes found and fixed, both for zoom.
Nothing guessed at for the rest.

### Root cause 1 (iPad): the spread was half the pinch

- `TouchInterpreter.spread(of:)` returned the **mean distance from the centroid**,
  which for two fingers is exactly half the distance between them.
- `decide(travel:spreadChange:)` compares that directly against the centroid's
  **full** travel, and ties go to `.scroll`.
- Anchor a thumb, move one finger by D: separation grows by D so the old measure
  grew by D/2, and the centroid moves by D/2. Exactly equal. Always a scroll.
- A pinch could only zoom when both fingers moved the same amount, holding the
  centroid still. **Every existing zoom test did exactly that**, which is how the
  bug survived a full suite.
- Fix: `spread` returns `2 * mean`, so it is the real separation. Zoom scale
  `0.25` to `0.125` so the product, and the feel, are unchanged.
- Two new tests (`testAPinchWithOneFingerAnchoredStillZooms`, and the inward one)
  fail before the fix and pass after. Confirmed by running them.

### Root cause 2 (Mac): the scroll carried no modifier flags

- A zoom is Command held across a scroll. `MacInputSynthesizer.scroll` created a
  `CGEvent` and never set `flags`.
- macOS reads the Command flag **off the scroll event itself**, so a Command that
  was genuinely held still produced an ordinary scroll.
- Fix: `InputSynthesizing.scroll` now takes `modifiers`, `MessageRouter` passes
  `held.heldModifiers`, and the synthesizer sets `event.flags`.

### Still no root cause: three fingers, four fingers, drag

Not guessed at. Added instrumentation instead, so one hand test tells the three
silent failures apart:

- `TouchInterpreter.Activity` (`idle`, `pointer`, `deciding`, `scroll`, `zoom`,
  `multi(fingers:fired:)`, `cancelled`), shown under the finger count on the
  trackpad.
- Reads **"cancelled by iPadOS"** in orange if the system confiscates the touches,
  which is invisible from the chair and looks identical to the feature not
  existing.
- The readout is now reported only when it **changes**. It writes SwiftUI state and
  was firing on every touch event, asking SwiftUI to re-evaluate the whole screen
  up to 120 times a second during a drag.

Suites after: **Core 120, Mac 108, iPad 372**, all passing. Commit `ff0a157`,
pushed to `main`. Both apps rebuilt and deployed.

### Transport question (Wi-Fi vs Bluetooth)

Checked `PadlinkTransport.parameters`:
- `tcp.noDelay = true` already set, which is the single biggest win for a stream
  of tiny packets.
- `includePeerToPeer = false` set explicitly on both ends. Turning it on enables
  AWDL, a direct device-to-device link that skips the router. Real tradeoff: it
  time-slices the Wi-Fi radio, so it can cut median latency and raise jitter.
- `serviceClass` not set. Setting it marks the traffic for the interactive Wi-Fi
  queue. Cheap, low risk, not yet done.

Bluetooth would be worse, not better. BLE's connection interval (iOS negotiates
15 to 30ms, floor 7.5ms) is a latency floor above what Wi-Fi already delivers, and
the throughput is far too low for a stream of pointer moves. Classic SPP is not
available to third-party iOS apps without MFi hardware.

## 2026-08-15 11:06 — (auto session marker)

## 2026-08-15 — The readout paid for itself in one test

User reported back from the iPad:
- "2 finger show 2 zoom" → the pinch decision now works. Root cause 1 confirmed fixed.
- "3 finger swipe show 3 swipe, but no action" → **decisive**. The iPad sees three
  fingers, fires the swipe, and sends the keystroke. So touch handling was never
  the problem, and both earlier hypotheses (touches cancelled by iPadOS, third
  finger landing outside the view) are dead.
- "single finger click always stuck at right click" → new, and the thread to pull.
- "latency is better now".

### Root cause 3: every multi-finger gesture ended in a right click

- A hand lifts as 3 → 2 → 1 → 0. The two finger moment on the way *out* is a brand
  new `TwoFinger` with `startedAt = now` and `maxTravel = 0`.
- `wasTap` therefore passed: undecided ✓, `remainingCount < 2` ✓, elapsed ~0.03s ✓,
  travel 0 ✓. **Right click, on every three and four finger gesture.**
- `remainingCount < 2` only guards the way *up* (a third finger landing). Nobody
  guarded the way down.
- Explains all three symptoms at once: Control+Up opens Mission Control and the
  stray right click dismisses it ~50ms later ("no action"); a context menu left
  open swallows every following tap ("single finger stuck at right click").

Fix: `TwoFinger.tapEligible`, fed by a new `fingersOnlyAdded` flag.

Neither simpler rule works, and this is worth remembering:
- "started from rest" is **too strict**: the two fingers of a real tap land
  milliseconds apart, so a genuine two finger tap arrives as 1 then 2.
- "two fingers down and still" is **too loose**: that is exactly the lifting case.
- The separator is the **direction the finger count is travelling**, which nothing
  in the type recorded.

Verified properly: the three new tests were run with the guard removed (all three
fail) and with it (all pass). Not assumed.

Suites: **Core 120, Mac 108, iPad 377.** Commit `1e5ff36`, pushed. iPad redeployed.

### Still open

- Whether the Mac acts on Control+Up at all. Could not test from here: the test
  client hung waiting for a connection (not paired, and the Mac takes one peer at
  a time). Added arrow key support to `./padlink key` for when it can be paired.
- If the swipe still does nothing with the stray right click gone, the next
  suspect is that `stroke()` puts modifiers only on the key event's flags and
  never posts a real Control key down. Some macOS symbolic hotkeys want the
  modifier genuinely held.
- Drag to select, and momentum, both still unverified by hand.

## 2026-08-15 11:15 — (auto session marker)

## 2026-08-15 — Why the swipes cannot work: measured, not guessed

Question from the user: is this a limitation, should we drop it? Answered with
seven experiments run directly on the Mac (`AXIsProcessTrusted()` returned true,
so this process could post real events). Scratch tools are in the session
scratchpad, not committed.

| Experiment | Result |
|---|---|
| Post a mouse move, read back the cursor position | **works** |
| `postModifierKey` technique, then read `CGEventSource.flagsState` | **COMMAND HELD**, so it works |
| Same via a real `.flagsChanged` event | also works, so the current technique was never the problem |
| Command+A then Command+C into TextEdit, then `pbpaste` | **works**, clipboard got the file contents |
| Command+Shift+3 (system hotkey) | **no screenshot file created** |
| Control+Up (system hotkey, Mission Control) | **does not open** |
| `open -a "Mission Control"` | **opens**, confirmed in a screenshot |
| Event tap reading back a flagged scroll | delivered as `flags=[command]`, both pixel and line units |

### The finding

**macOS does not let a synthesized `CGEvent` trigger a system level symbolic
hotkey.** Ordinary application shortcuts work perfectly (Command+A, Command+C).
Anything the WindowServer or Dock owns does not.

So this is not a bug in Padlink and no amount of work on the keystroke path will
fix it. What it kills:

- Three fingers up (Mission Control, Control+Up). **Has a workaround**: launch
  `/System/Applications/Mission Control.app`. Proven to work.
- Three fingers down (App Exposé, Control+Down). No app to launch. No workaround
  found.
- Four fingers left and right (switch spaces, Control+Left/Right). No public API.
  Dead.

What still should work, and was probably tested in the wrong app:

- Three fingers left and right (Command+[ and Command+]) are **ordinary app
  shortcuts**, so they work. They need an app with back and forward, so Safari or
  Finder, not a text editor.
- **Zoom is being sent correctly.** The tap readback proves the Command flag
  arrives on the scroll. It will zoom in Safari, Chrome and Finder. It will not
  zoom in Preview, which wants a real `NSEvent.magnify`, and macOS has no public
  API to synthesize one. That constraint was already in the design doc.

### Housekeeping from the experiments

- The clipboard was overwritten and then cleared.
- Preview was opened and closed again.
- The mouse cursor was moved.
- `/tmp/padlink-probe.txt` was created and deleted.
