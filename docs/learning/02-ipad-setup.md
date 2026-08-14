# Setting up the iPad for development

Done once per iPad. After this, installing is a single command.

Your device: iPad Air 5th generation (`iPad13,16`), iPadOS 26.5.2.

## Step 1: connect by cable, once

USB-C from the iPad to the MacBook. Unlock the iPad. If it asks "Trust This
Computer?", tap **Trust** and enter your passcode.

You need the cable for the first install. Later installs can go over Wi-Fi if you
tick "Connect via network" in Xcode's Devices window, but the cable is more
reliable and this project does not depend on wireless installs.

Check the Mac can see it:

```bash
xcrun devicectl list devices
```

You want a line showing your iPad with state `available (paired)`. If it says
`unavailable`, the iPad is locked or the cable is data-only. Some USB-C cables
only carry power. If the device never appears, try a different cable before
anything else.

## Step 2: turn on Developer Mode

This lives on the iPad, and it only appears **after** the Mac has tried to talk to
the device at least once. On a fresh iPad the menu item does not exist yet, which
is confusing. Plug it in first.

On the iPad: **Settings**, then **Privacy & Security**, scroll to the bottom,
then **Developer Mode**. Turn it on.

The iPad restarts. After restarting it asks you to confirm again, with the
passcode. That double confirmation is normal, not a bug.

Why Apple does this: Developer Mode allows software from outside the App Store to
run. Requiring a physical restart and a passcode means a stranger with brief
access to your unlocked iPad cannot quietly enable it.

## Step 3: install the app

From the project folder:

```bash
cd /Users/hengkysandy/claude-chats/first-mobile-app/.claude/worktrees/padlink-mac/Padlink
./padlink pad
```

This builds, installs, and launches. It finds your iPad automatically.

Requirements it checks for you: a team id must be configured, and an iPad must be
available. It tells you what is missing rather than failing with a wall of build
output.

## Step 4: trust the certificate, once

The first launch shows **"Untrusted Developer"** and refuses to open the app.

On the iPad: **Settings**, **General**, **VPN & Device Management**. Under
"Developer App", tap your Apple ID, then **Trust**.

This is per certificate, not per app. Once trusted, every app you build with the
same certificate opens without asking again.

## Step 5: the permissions the app asks for

**Local network.** Asked the first time the app looks for your Mac. If you say no,
the app can never find the Mac again, and it looks broken rather than blocked.
iOS asks exactly once. To change your mind: Settings, Padlink, Local Network.

**Camera.** Asked when you first scan a pairing code. You can decline and paste
the pairing link instead, which works exactly the same way.

## Reinstalling every 7 days

With a free Apple account, the app expires. See
[01-apple-signing.md](01-apple-signing.md).

```bash
./padlink pad
```

Your pairing survives, because the key is in the iPad's Keychain rather than in
the app bundle. You do not have to scan a new code.

## Why we tested on the simulator first, and when to stop

The simulator was useful early because it shares the Mac's network stack, so the
iPad app can genuinely discover the Mac over Bonjour. No cable, no Developer
Mode, no trust dialog.

It cannot test:

- **Two-finger gestures.** The simulator's only two-finger input is a symmetric
  pinch around the window centre, which is precisely the gesture whose centre
  barely moves. Scrolling is effectively untestable there.
- **The camera.** There is none, so QR scanning cannot run at all.
- **The local network permission.** The simulator never asks and never enforces.
- **Real latency.** The Mac is talking to itself, so the numbers mean nothing.

That last point matters most. The only question that finally counts is whether it
feels responsive under your finger, and only hardware can answer it.
</content>
</invoke>
