# macOS permissions: Accessibility and the Keychain

Two permissions caused most of the confusion in this project. Both have the same
nasty property: **the app keeps working and silently does nothing.**

## Accessibility permission

### Why it is needed

The Mac app moves your cursor by creating synthetic input events (`CGEvent`).
macOS treats that as a serious capability, because a program that can move your
mouse and type can do anything you can do.

**Without the permission, macOS accepts every event and throws it away.** No
error, no crash, no log line. The iPad connects, the Mac replies normally, and
nothing moves. Every visible signal says the connection is healthy, because it is.

This exact confusion cost real time twice in this project. That is why the iPad
now shows a loud orange banner saying "Connected, but your Mac is ignoring it".
If you see it, the app is working correctly and telling you the truth.

### Granting it

System Settings, **Privacy & Security**, **Accessibility**, then **+**, then pick
PadlinkMac from Applications.

### The trap: a toggle that is on while permission is denied

This happened, and the screenshot was genuinely convincing: PadlinkMac switched
on in the list, and the Mac still reporting no permission.

The cause: macOS records the permission against a **specific binary**. Our build
script deletes the old app and copies a new one (`rm -rf` then `cp -R`), so every
rebuild orphans the previous grant and leaves a dead entry behind. The list shows
one line per app name, so three stale records looked like one healthy toggle.

The fix, which clears all the ghosts:

```bash
osascript -e 'quit app "PadlinkMac"'
tccutil reset Accessibility com.hengkysandy.padlink.mac
open /Applications/PadlinkMac.app
```

`tccutil` prints one success line per record it removed. Ours printed **three**.
That number is the diagnosis: it tells you how many stale grants were hiding
behind that single toggle.

Then re-add the app with **+**. Do not just toggle the existing entry off and on,
because the entry itself is the stale thing.

### Does this happen to real users?

No. It is caused by rebuilding the app repeatedly, which only developers do. Once
an app is installed and stays put, the grant sticks.

## The Keychain password prompts

### The symptom

macOS asks for your login password every time the Mac app starts, saying it wants
to use the keychain.

### What it was not

Not the keychain locking. Checked and ruled out:

```bash
security show-keychain-info ~/Library/Keychains/login.keychain-db
# "no-timeout"  -> it does not auto-lock
```

### What it actually was

The pairing key was first written by an **ad-hoc signed** build, before the real
certificate existed. The old style macOS keychain attaches an access list to each
item, naming the exact app identity that created it. When we switched to proper
signing, the app became a different identity, so it had to ask permission to read
data it had written itself.

### The fix

Click **Always Allow**, not **Allow**, and enter your login password once.

`Allow` grants access for that one time only, which is why it kept coming back.

**No tool can do this for you, and that is deliberate.** macOS requires your
password to change a keychain item's access list. Anything that could do it
silently would defeat the purpose of the keychain.

### The permanent fix, still pending

The Mac app uses the legacy file keychain. The modern one ("data protection
keychain") uses the app's signed identity directly and never shows these prompts.

We could not use it originally: it fails with `errSecMissingEntitlement` (-34018)
from an ad-hoc signed macOS app. Now that the app is signed with a real team, that
blocker is gone. Tracked as a task.

Note that iOS never had this problem. The data protection keychain works there by
default, which is why the iPad side has never prompted you.

## Reading the signals

| What you see | What it means |
|---|---|
| Orange banner on iPad, "your Mac is ignoring it" | Connected fine. Accessibility is off on the Mac. |
| Cursor does not move, no banner at all | Not connected. Look at the banner text for the reason. |
| Password prompt on every Mac app launch | Stale keychain access list. Click Always Allow. |
| Accessibility toggle on, Mac still says denied | Stale TCC records from rebuilds. Run `tccutil reset`. |
