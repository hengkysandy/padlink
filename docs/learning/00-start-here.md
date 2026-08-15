# Padlink: start here

This folder is the "how do I actually do this" guide, written for someone who has
never shipped an Apple app before. It is separate from `docs/superpowers/`, which
holds the design specs and implementation plans.

`NOTES.md` in the repository root is the running journal: what happened, in order,
with dates. This folder is the opposite: what to **do**, organised by topic, with
no story attached.

## The urgent thing

**Your iPad app stops working on 2026-08-20.** It is signed with a free Apple
account, and Apple gives those a 7 day life. When it dies, the app will refuse to
open with a message about the developer no longer being trusted.

The fix takes 2 minutes: plug the iPad in and run `./padlink pad` again. Nothing
is lost, and pairing survives.

Full explanation in [01-apple-signing.md](01-apple-signing.md).

## The files

| File | What it answers |
|---|---|
| [01-apple-signing.md](01-apple-signing.md) | Certificates, team id, provisioning profiles, what expires and when, free vs paid account |
| [02-ipad-setup.md](02-ipad-setup.md) | Developer Mode, trusting the certificate, installing to the device |
| [03-macos-permissions.md](03-macos-permissions.md) | Accessibility permission, the keychain password prompts, why both keep coming back |
| [04-build-and-run.md](04-build-and-run.md) | The `padlink` script, the git worktree, XcodeGen, running the tests |
| [05-gotchas.md](05-gotchas.md) | Every trap we hit, with the symptom that led us there |
| [06-how-the-code-fits.md](06-how-the-code-fits.md) | The shape of the codebase and why it is split that way |
| [07-gestures-and-keyboard.md](07-gestures-and-keyboard.md) | Every gesture, the on-screen keyboard, and how the modifier keys behave |
| [08-the-next-app.md](08-the-next-app.md) | **What to do differently on the next app.** The only file here that is not about Padlink |

## The 60 second version

Two apps talk over your Wi-Fi. The Mac app listens, the iPad app connects.

```
cd /Users/hengkysandy/claude-chats/first-mobile-app/Padlink

./padlink up      # build + launch the Mac app
./padlink pad     # build + install + launch on the plugged-in iPad
./padlink test    # run all three test suites
```

Then on the Mac, click the keyboard icon in the menu bar, choose "Pair a device",
and point the iPad camera at the code. Drag on the iPad, the Mac's cursor moves.

Two fingers scroll, two fingers tap to right click, pinch to zoom, three fingers
up for Mission Control, three fingers sideways to go back and forward. The full
list, including the two gestures macOS refuses to allow, is in
[07-gestures-and-keyboard.md](07-gestures-and-keyboard.md).

The worktree the app was built in is merged into `main`, so these run from the
repository itself now. See [04-build-and-run.md](04-build-and-run.md).

## What this project is

An iPad app plus a macOS app. The iPad becomes a trackpad and keyboard for the
MacBook, over Wi-Fi. Pairing is by QR code, and the link is encrypted with a
pre-shared key.

Reached working end to end on real hardware on 2026-08-14. Gestures, the
on-screen keyboard, hardware keyboard passthrough and pinch to zoom were finished
and confirmed by hand on 2026-08-15, which is where the MVP was called done.
