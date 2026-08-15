# The whole picture, for someone new

How this project was actually built, end to end, in plain English. If you are
coming back to this months later, or you have never shipped an Apple app, start
here. The other files go deeper on one topic each.

## The language: Swift

One language for everything. Swift is Apple's own, so the same code runs on the
Mac and on the iPad. That is what let us write the trackpad logic **once** and
have both apps share it.

Swift 6, with strict concurrency checking on: the compiler refuses to build code
that could have threading bugs. Irritating at first, and it caught real problems.

## The tools

| Tool | What it is for |
|---|---|
| **Xcode** | Apple's big app. Installed, almost never opened |
| **`xcodebuild`** | The command line version of Xcode's build button |
| **XcodeGen** | Writes the Xcode project file for us |
| **SwiftPM** | Swift's package manager, for the shared code |
| **`xcrun devicectl`** | Talks to the physical iPad over the cable |
| **`hdiutil`** | Makes the .dmg |
| **`gh`** | GitHub from the terminal |

### The Xcode app, or the command line?

**Both, in an unusual split.** You must *install* Xcode.app, because it contains
the Swift compiler, the macOS and iOS SDKs, and the simulator. There is no way
around it, and it is a large download.

But its window was never opened. Everything ran through `xcodebuild` in the
terminal. A terminal command is repeatable, its output can be read and quoted,
and it can live in a script. Clicking buttons is none of those things.

One command is needed once per machine, to point the tools at the full Xcode
rather than the smaller Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

Without it, `swift test` fails with `no such module 'Testing'`, because the
Command Line Tools do not ship the testing framework.

### Why XcodeGen

An `.xcodeproj` is a large generated file that nobody can read or merge. So the
settings live in a short, commented `project.yml`, and XcodeGen turns that into
the project:

```bash
xcodegen generate
```

The `.xcodeproj` is **not** in git. It is regenerated whenever it is needed. Every
setting therefore sits next to a comment explaining why it is there. See
[09-starting-a-new-app.md](09-starting-a-new-app.md) for the file itself.

## How the project started

Not by writing code. In order:

1. **Brainstormed** what the app should do, and what it should not.
2. **Wrote a spec**, so the goal was fixed before any code existed.
3. **Wrote a plan**, broken into numbered tasks.
4. **Ran one spike.** A spike is a throwaway experiment that answers a risky
   question. Ours asked whether the Mac app could store a secret in the keychain
   without prompting for the login password on every launch.
5. Then the tasks, one at a time, each with tests.

Step 4 was the best decision in the project. The biggest mistake was doing it
**once**, for one risk, instead of for every risky assumption. See
[08-the-next-app.md](08-the-next-app.md).

## The three pieces of code

```
Padlink/
  Sources/PadlinkCore/   shared brain: no screen code at all
  PadlinkMac/            the Mac app
  PadlinkPad/            the iPad app
```

**`PadlinkCore` is the central idea.** It holds every decision: what counts as a
tap, when two fingers mean scroll rather than zoom, how a message is packed into
bytes. It contains no UIKit and no AppKit, which means no screen code at all.

That is why 379 tests run in 0.2 seconds with no simulator and no device. The two
apps are thin shells: they catch touches, hand them to the brain, and post
whatever it returns.

## Building

```bash
./padlink up     # the Mac app
./padlink pad    # the iPad app
```

`padlink` is a bash script written on day one. Underneath, `up` runs:

```bash
xcodebuild -scheme PadlinkMac -configuration Debug ... build
```

then copies the result into `/Applications` and launches it from there.
**Installing to `/Applications` is deliberate.** The build folder is hidden from
Finder, and macOS needs you to pick the app in a file dialog to grant it
permission. A clean build also deletes the build folder, which silently
invalidates the permission and makes the app look broken.

## Testing

Three suites, because there are three pieces:

```bash
swift test                                 # the shared brain, no simulator
xcodebuild test -scheme PadlinkMac ...     # the Mac app
xcodebuild test -scheme PadlinkPad ...     # the iPad app, in the simulator
```

All three behind `./padlink test`. Final count at the MVP: **125 + 115 + 379**.

The lesson worth repeating: **green tests are not proof the app works.** Three
features passed every test and were completely dead on the real device.

## Getting the app onto the iPad

A physical cable. No App Store involved.

Once per iPad: turn on **Developer Mode** in Settings, and trust the certificate.
Then four commands, all behind `./padlink pad`:

```bash
xcrun devicectl list devices                         # find the iPad
xcodebuild -scheme PadlinkPad -destination "id=..."  # build for it
xcrun devicectl device install app --device ...      # copy it over
xcrun devicectl device process launch --device ...   # start it
```

**This is why the iPad build expires after 7 days.** A free Apple account gets a
provisioning profile, a file that says "this app may run on this iPad", and Apple
gives free accounts seven days. After that iOS refuses to open it. Re-running
`./padlink pad` issues a new one and pairing survives. A paid account makes it a
year. See [01-apple-signing.md](01-apple-signing.md).

## Turning the Mac app into a .dmg

```bash
./padlink dmg 0.1.0-alpha2
```

Three steps inside:

1. **Build in Release, signed ad-hoc**, meaning no certificate and no Apple
   account involved.
2. **Scan for leaks.** This repository is public, and a normally signed app embeds
   your Apple team id, your real name and your registered device ids in
   `embedded.provisionprofile`. The script aborts the build if it finds any of
   them.
3. **`hdiutil create`** packs the app plus a shortcut to `/Applications` into a
   .dmg, so it installs by dragging.

Then `gh release create` uploads it to GitHub.

**The Mac app never expires.** Ad-hoc signing is a plain hash of the app with no
certificate behind it, so there is nothing that can run out. That is the opposite
of the iPad situation. The cost is that macOS quarantines the download, so each
person has to clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/PadlinkMac.app
```

## How the iPad and the Mac connect

Plain **Wi-Fi**, both on the same network. No Bluetooth, no cloud, no internet.
Four layers:

**Finding each other.** The Mac announces itself with **Bonjour**, Apple's "who is
on this network" system, under the name `_padlink._tcp`. The iPad listens for it.
Neither side needs an IP address typed in by hand.

**Pairing, once.** The Mac shows a **QR code** holding a randomly generated
256-bit secret. The iPad's camera reads it. Both sides store that secret, the Mac
in its keychain and the iPad in its own. It never travels over the network in
readable form.

**The encrypted link.** An ordinary TCP connection wrapped in **TLS**, the same
encryption a bank website uses. Instead of certificates, both ends prove they know
the shared secret. If it does not match, the connection simply fails, so nobody
else on your Wi-Fi can connect.

**The messages.** A tiny custom format. One byte for the type, then the data:

```
type 2  = pointer move  ->  dx, dy, time since the last one
type 3  = button        ->  which one, down or up
type 4  = scroll        ->  dx, dy
type 10 = pinch         ->  phase, how much
```

Deliberately small. A pointer move is 7 bytes, which is why it feels instant.

## How a message becomes a real cursor movement

The Mac receives "move 10 left and 5 down" and calls **`CGEvent`**, a macOS
function that injects an event into the system as if it came from real hardware.
macOS cannot tell the difference.

**This is why the Accessibility permission matters so much.** Without it, macOS
accepts every one of those calls and silently discards them. No error, no crash.
The app looks perfectly connected and nothing moves. That confusion cost hours
twice, which is why the app now shows a large orange banner for exactly that
state. See [03-macos-permissions.md](03-macos-permissions.md).

It is also the wall we hit at the end. macOS will let you inject a click, a
scroll, a keystroke and a pinch, but it **refuses** to let an injected event
trigger one of its own system shortcuts, such as Control and Up for Mission
Control. That is a deliberate security boundary, and it is why a three finger
swipe up opens the Mission Control app directly instead of sending the keystroke.
See [07-gestures-and-keyboard.md](07-gestures-and-keyboard.md).
