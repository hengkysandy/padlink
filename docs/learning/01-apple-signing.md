# Apple signing, certificates, and what expires

This is the part of Apple development with the most confusing vocabulary. Four
different things all sound like "the certificate", and they expire on four
different schedules.

## The four things, in plain words

**Apple ID.** Your normal Apple account, the personal Gmail one.

**Team.** Every Apple ID gets a team, even a personal one. Yours is a 10 character
code. It never changes and it never expires. It is not secret in a serious way,
but it identifies your account, so this project keeps it in a gitignored file
called `.padlink-team` rather than in this public repository. Read your own with
`cat .padlink-team`.

**Certificate.** Proof that a build came from you. Yours is an "Apple Development"
certificate, created 2026-08-13, valid until **2027-08-13**. One year. Xcode made
it for you when you signed in.

**Provisioning profile.** Permission for *this app* to run on *these devices*.
This is the one that expires fast. Yours was created 2026-08-13 and dies
**2026-08-20**. Seven days.

## Free account vs paid account

This is the single most important fact in this document.

| | Free Apple ID (what you have) | Paid, 99 USD a year |
|---|---|---|
| App life on device | **7 days**, then it stops opening | 1 year |
| Devices | Small limit, tied to your machines | 100 per type |
| Share with other people | No | Yes, via TestFlight |
| App Store | No | Yes |
| Cost | 0 | 99 USD a year |

**With a free account the app is not broken when it stops working after 7 days.
That is the design.** Apple wants a paid membership for anything long-lived.

Reinstalling resets the clock. It takes 2 minutes:

```
cd .../worktrees/padlink-mac/Padlink
./padlink pad
```

Your pairing survives, because the pairing key lives in the iPad Keychain, not in
the app.

**When to pay:** when you get tired of the 7 day cycle, or when you want the app
on someone else's iPad. Not before. Everything built so far works on the free tier.

## How to check your own expiry dates

Certificate:

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -dates -subject
```

Provisioning profile (the 7 day one):

```bash
ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
  | while read f; do
      security cms -D -i "$f" | plutil -p - | grep -E "Name|ExpirationDate|TimeToLive"
    done
```

`TimeToLive => 7` means a free account. A paid one shows 365.

Note the folder: older guides say `~/Library/MobileDevice/Provisioning Profiles`.
Modern Xcode uses the `~/Library/Developer/Xcode/UserData/` path above. Looking in
the old place shows nothing and makes it seem like you have no profile at all.

## What we did in Xcode, once

You only need Xcode's window for this one step. Everything else is command line.

1. Open Xcode.
2. **Settings** (Cmd-comma), then **Accounts**.
3. Press **+**, choose **Apple ID**, sign in.
4. Your team appears in the list. The 10 character code in the **Team** column is
   your team id.

Then, once, in the project folder:

```bash
./padlink team <YOUR_TEAM_ID>
```

This writes `.padlink-team`, which is gitignored. Every later build reads it
automatically. You never open Xcode again unless you want to.

## Why bother with a real certificate at all

You can build without one. It is called ad-hoc signing, and it is what this
project did at first.

The problem: **ad-hoc signing produces a different signature on every single
build.** macOS decides each build is a brand new app it has never seen, so the
Accessibility permission is dropped every time. That permission is the thing that
lets Padlink move your cursor, so we were re-granting it after every rebuild.

A real certificate keeps the signature stable across rebuilds, so the permission
sticks. That is the whole reason we set it up.

A physical iPad is stricter still: it will not run an ad-hoc build at all. So a
real certificate is required, not optional, the moment you leave the simulator.

## Verifying a build is signed properly

```bash
codesign -dvvv /Applications/PadlinkMac.app 2>&1 | grep -E "Authority|TeamIdentifier"
```

Good output names a real authority chain and your team:

```
Authority=Apple Development: <your email> (<cert id>)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=<your team id>
```

The chain up to Apple Root CA is the part that matters.

Bad output says `Signature=adhoc` and `TeamIdentifier=not set`.

## The error messages, decoded

**"Your team has no devices from which to generate a provisioning profile."**
You asked to build for a generic iOS device instead of a specific one. Target the
real iPad by its id. `./padlink pad` does this for you.

**"Untrusted Developer" on the iPad.** Expected on the first install of any app
from a new certificate. Fix on the iPad: Settings, General, VPN & Device
Management, tap your developer account, tap Trust.

**The app stops opening after a week.** The provisioning profile expired. Rerun
`./padlink pad`.
</content>
</invoke>
