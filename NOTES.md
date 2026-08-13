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
- [ ] Finish brainstorming (architectural path, superpowers:brainstorming)
- [ ] Write design spec to `docs/superpowers/specs/`
- [ ] Then implementation plan

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


## 2026-08-13 11:14 — (auto session marker)
