# Gotchas: every trap we hit

Ordered by how much time each one cost. Each entry gives the **symptom first**,
because that is what you will have when you come back to this.

## Apple platform traps

### The app builds, passes every test, and does nothing

Accessibility permission. macOS accepts synthetic events without it and silently
discards them. See [03-macos-permissions.md](03-macos-permissions.md).

### An iOS view only ever sees one finger

`UIView.isMultipleTouchEnabled` defaults to **false**. Two-finger scrolling cannot
work until you set it, and no error or warning tells you. Every line of scroll
logic can be correct and you still get nothing.

### A two-finger tap registers as a left click

Two fingers essentially never lift in the same event. There is always a moment
where one finger remains, which looks exactly like a short still touch. Without a
guard, every two-finger tap sends a click.

### `UIEvent.allTouches` includes touches from other views

It returns every touch in the event, not just the ones on your view. A finger
resting elsewhere on the screen counts as a second finger and turns a drag into a
scroll. Filter by `$0.view === self`.

### A SwiftUI TextField cannot represent backspace

Diffing the old and new string to recover keystrokes cannot express a deletion,
because a deletion is not a character. Use `UITextField` and its delegate.

And note that `shouldChangeCharactersIn` is **not** called when the field is
empty, so a field that is always empty by design needs a `deleteBackward()`
override instead. We got this wrong in a brief and the implementer caught it.

### iOS quietly rewrites what the user typed

Autocorrection changes words after the fact, autocapitalisation changes letters,
and smart quotes replace `"` with a curly character that is not the key pressed.
All must be disabled on a field that forwards keystrokes.

### An iOS app with no launch screen key runs letterboxed

Without `UILaunchScreen` in the plist, an iPad app runs in iPhone compatibility
mode: a small phone-shaped canvas in the middle of the screen. It still builds and
runs, so "does it build" does not catch it.

### Bonjour finds nothing, forever, with no error

The plist needs `NSBonjourServices` listing the exact service type, and
`NSLocalNetworkUsageDescription`. Without them the browser reports nothing at all
and never errors.

### There is no API to ask whether local network access was granted

The permission prompt only fires when the browser actually starts. So "explain
before asking" means showing your explanation and then starting discovery. You
cannot query the status first. You detect a refusal afterwards, by the specific
error code.

### The QR camera runs perfectly and never detects anything

`metadataObjectTypes` must be set **after** `addOutput`. Set before, the session
has not yet worked out which types the output supports, so the assignment silently
does nothing.

### TLS 1.3 with a pre-shared key does not exist on Apple platforms

`sec_protocol_options_add_pre_shared_key` is RFC 4279 style, which is **TLS 1.2
only**. Every TLS 1.3 attempt failed with error `-9858`. The original design spec
said 1.3 and was simply wrong.

Related: plain PSK has no forward secrecy. The ephemeral suites (`0xD001`,
`0xCCAC`) do, and they work. Pin those.

### The data protection keychain fails from an ad-hoc signed Mac app

`kSecUseDataProtectionKeychain` returns `errSecMissingEntitlement` (-34018).
Works fine on iOS. Works fine on macOS once the app is signed with a real team.

## Shell and tooling traps

### `zsh: parse error near '&'`

A `padlink://` URL contains `&`, which zsh reads as "run in background". Quote the
URL, or use `./padlink paste`.

### "does not contain a scheme named PadlinkMac"

Wrong directory. The app is in the worktree, not on `main`. See
[04-build-and-run.md](04-build-and-run.md).

### "your team has no devices"

You built for a generic iOS device rather than a specific one. Target the iPad by
its id.

### A gitignore pattern with a slash is anchored to the repository root

`Padlink/.padlink-testclient.json` matches only that exact path. The same pattern
with no slash matches at any depth. **This nearly leaked a pairing key into a
public repository**, because the file was written to a different directory than
the pattern expected.

Always verify, never assume:

```bash
git check-ignore -v <the-file>
```

### `Data.write(to:)` creates files as world-readable (0644)

Fine for most things, not for a file holding a pre-shared key. Use
`createFile(atPath:contents:attributes: [.posixPermissions: 0o600])`.

## Swift traps

### `Data("a " + "b".utf8)`

Member access binds tighter than `+`, so `.utf8` attaches only to the second
literal. This does not compile, but formatted across several lines it reads as if
it should.

### Swift traps on integer overflow, which crashes the app

`UInt16(gap)` where the gap exceeds 65535 does not wrap, it kills the process. On
iOS the app just disappears. Every conversion on the input path must clamp
**before** converting.

### An `AsyncStream` supports exactly one iterator

A second consumer does not get a copy. The two split the messages between them,
which looks like random message loss and is miserable to debug.

### A value type copy forks its state

`MoveThrottle` accumulates sub-pixel movement. Copying it silently forks the
accumulator, so it must be owned in exactly one place and mutated in place.

## Process lessons

### Passing tests are not proof the app works

The Mac app passed 49 tests while being completely unusable: the pairing window
opened behind every other window and looked like a dead button. Only hand testing
found it.

### Silent failures must be made loud

Three times, adding a visible message paid for itself immediately: the
Accessibility warning, the pairing failure state, and separating "no saved
pairing" from "saved pairing is corrupt". Each one later explained a real symptom
in seconds instead of an hour.

### Measure, do not eyeball

A cursor move looked like a 2x scaling bug. The arithmetic showed two different
correct mechanisms producing similar-looking numbers by coincidence: acceleration
gain in one case, an output cap in the other. Recording the impression would have
sent us hunting a bug that did not exist.

### Every plan written in this project contained real defects

More than twenty were found by the people implementing them, including a security
error and a missing-key crash. The plans were still worth writing, and the
implementers were still right to check rather than comply.
</content>
</invoke>
