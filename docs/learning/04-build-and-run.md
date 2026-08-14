# Building, running, and testing

## The toolchain we are on

| Tool | Version | Notes |
|---|---|---|
| macOS | 26.5.2 | |
| Xcode | 26.6 | Needed for the simulator and for `swift-testing` |
| Swift | 6.3.3 | Strict concurrency is on |
| XcodeGen | 2.46.0 | Generates the `.xcodeproj` |
| iPadOS | 26.5.2 | iPad Air 5 |

One setup command, already done, needed once per machine:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

Without it, `swift test` fails with `no such module 'Testing'`, because the
Command Line Tools do not ship swift-testing. If that error ever appears, this is
why.

## Where the code lives, and why it is confusing

The app is on a branch in a **git worktree**, not on `main`:

```
/Users/hengkysandy/claude-chats/first-mobile-app/                    <- main branch
/Users/hengkysandy/claude-chats/first-mobile-app/.claude/worktrees/padlink-mac/   <- the app
```

A worktree is a second checkout of the same repository, on a different branch, in
a different folder. The work was isolated there so `main` stayed clean.

**This has bitten us repeatedly.** Running commands in
`first-mobile-app/Padlink` fails with "does not contain a scheme named
PadlinkMac", because on `main` the app genuinely does not exist yet.

Always work here:

```bash
cd /Users/hengkysandy/claude-chats/first-mobile-app/.claude/worktrees/padlink-mac/Padlink
```

A useful shell alias:

```bash
alias padlink='cd /Users/hengkysandy/claude-chats/first-mobile-app/.claude/worktrees/padlink-mac/Padlink && ./padlink'
```

## The `padlink` script

One command for everything. It resolves its own location, so it works from
anywhere once aliased.

```
./padlink team <ID>     set your Apple team id, once
./padlink up            build and launch the Mac app
./padlink pad           build, install, and launch on the physical iPad
./padlink test          run all three test suites
./padlink paste         pair using the code on the clipboard
./padlink pair "<url>"  pair with a code you have as text
./padlink move 200 0    and every other test client command
./padlink down          quit the Mac app
```

### Two details in `up` that matter

**It installs to `/Applications` and runs from there**, rather than running out of
the build folder. Two reasons, both learned the hard way. The build folder sits
inside two dot-folders, so Finder will not show it in the Accessibility file
picker. And a clean build deletes it, which silently invalidates the permission
and makes the app look broken.

**Quoting a pairing URL is mandatory.** A `padlink://` URL contains `&`, which zsh
reads as "run in background". Without quotes you get `zsh: parse error near '&'`.
`./padlink paste` avoids the problem entirely by reading the clipboard.

## The Xcode project is generated, not committed

`Padlink.xcodeproj` is produced by XcodeGen from `project.yml`, and it is
gitignored. So is the generated `Info.plist`.

**Every plist key goes in `project.yml`** under `info.properties`. Editing a
generated `Info.plist` by hand does nothing, because the next generate overwrites
it.

After adding or removing a source file, regenerate:

```bash
xcodegen generate
```

The `padlink` script does not do this automatically. If you pull this branch and
the build complains about missing files, run it.

## Running the tests

```bash
./padlink test
```

Three suites, three different runners:

| Suite | Framework | Count |
|---|---|---|
| `PadlinkCore` | swift-testing | 114 |
| `PadlinkMac` | XCTest | 66 |
| `PadlinkPadTests` | XCTest | 231 |

Core uses swift-testing because it is a plain SwiftPM package. The app targets use
XCTest because they need a host application.

`./padlink test` boots the iPad simulator first. Without that, the test runner can
fail with "Application failed preflight checks" when the simulator is still
starting up.

## Two apps must be built together

The wire protocol has a version number. If the two apps disagree, the iPad refuses
to connect and says so, naming both versions.

This bit us once: an agent bumped the protocol to version 2, the iPad build had
it, the running Mac app did not. **When the source is changing, build both apps
back to back from the same snapshot**, or they silently drift apart:

```bash
./padlink up && ./padlink pad
```
