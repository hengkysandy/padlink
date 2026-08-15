# Starting a new Mac and iPad app from zero

Copy this. It is the scaffolding Padlink ended up with, with the project-specific
parts replaced by `<App>`, and with the reason attached to every line that cost
time to get right.

The other files cover the platform: [01](01-apple-signing.md) for certificates and
what expires, [02](02-ipad-setup.md) for putting an app on a physical iPad,
[03](03-macos-permissions.md) for Accessibility and the keychain. This file is
only about getting a new project to the point where `./app up` works.

## The shape, and why

```
<App>/
  Package.swift            SwiftPM: the shared logic, and a CLI test client
  project.yml              XcodeGen: the two app targets
  Sources/<App>Core/       shared logic, no UIKit and no AppKit anywhere
  Tests/<App>CoreTests/    swift-testing
  <App>Mac/                the macOS app
  <App>MacTests/           XCTest
  <App>Pad/                the iPad app
  <App>PadTests/           XCTest
  app                      one bash script for every command
```

**One SwiftPM package plus XcodeGen, not one or the other.** SwiftPM cannot build
an app bundle, and a hand-maintained `.xcodeproj` is a large generated file that
nobody can read or merge. XcodeGen gives a readable `project.yml` you can comment,
and consumes the package as a local dependency.

**The core has no platform types in it.** This is the highest value decision in
the whole layout. Padlink's entire trackpad is one pure Swift type, so 379 tests
run in 0.2 seconds with no simulator. Anything that decides *what should happen*
goes in Core; the app targets only translate and post.

`.xcodeproj` and the generated `Info.plist` are **gitignored**. Regenerate after
adding or removing any source file:

```bash
xcodegen generate
```

## `Package.swift`

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "<App>Core",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "<App>Core", targets: ["<App>Core"]),
        // A CLI that speaks the same protocol as the real client. Worth its
        // weight: it drives the Mac app with no device in the room.
        .executable(name: "<app>-testclient", targets: ["<App>TestClient"])
    ],
    targets: [
        .target(name: "<App>Core"),
        .executableTarget(name: "<App>TestClient", dependencies: ["<App>Core"]),
        .testTarget(name: "<App>CoreTests", dependencies: ["<App>Core"])
    ]
)
```

## `project.yml`

Only the keys that are not obvious are commented. Each of these cost real time.

```yaml
name: <App>Mac
options:
  deploymentTarget: { macOS: "15.0", iOS: "18.0" }
  createIntermediateGroups: true

packages:
  <App>Core:
    path: .                       # the SwiftPM package in the same folder

targets:
  <App>Mac:
    type: application
    platform: macOS
    sources: [<App>Mac]
    dependencies:
      - package: <App>Core
        product: <App>Core
    info:
      path: <App>Mac/Info.plist
      properties:
        CFBundleName: <App>
        LSUIElement: true         # menu bar only: no Dock icon, no main window
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.<you>.<app>.mac
        SWIFT_VERSION: "6.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        # Ad-hoc by default, so the project builds for anyone who clones it with
        # no Apple account. The script overrides these when a team id exists.
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: "YES"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""

  <App>MacTests:
    type: bundle.unit-test
    platform: macOS
    sources: [<App>MacTests]
    dependencies: [target: <App>Mac]
    settings:
      base:
        SWIFT_VERSION: "6.0"
        # No `info:` block here, so XcodeGen has no plist path to generate.
        # Without this, code signing the test bundle fails.
        GENERATE_INFOPLIST_FILE: "YES"

  <App>Pad:
    type: application
    platform: iOS
    sources: [<App>Pad]
    dependencies:
      - package: <App>Core
        product: <App>Core
    info:
      path: <App>Pad/Info.plist
      properties:
        CFBundleName: <App>
        # Only if you use Bonjour. Without it NWBrowser reports nothing at all,
        # forever, with no error. Must match the service type in code exactly.
        NSBonjourServices: [_<app>._tcp]
        # iOS asks this once. If the answer is no, the app can never see the
        # other machine again until the user digs into Settings, so the wording
        # has to make the consequence obvious.
        # `>-` and not `>`: a plain folded scalar keeps a trailing newline,
        # which ends up inside the string iOS shows in the alert.
        NSLocalNetworkUsageDescription: >-
          <App> uses your local network to find and connect to your Mac.
          Without this it cannot see your Mac at all.
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        # An iOS app with no launch screen key runs in compatibility mode: a
        # letterboxed phone-sized canvas on an iPad. An empty dictionary is a
        # plain background and is enough.
        UILaunchScreen: {}
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.<you>.<app>.pad
        SWIFT_VERSION: "6.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        TARGETED_DEVICE_FAMILY: "2"   # 2 is iPad. 1 is iPhone, "1,2" is both.
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: "YES"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""

  <App>PadTests:
    type: bundle.unit-test
    platform: iOS
    sources: [<App>PadTests]
    dependencies: [target: <App>Pad]
    settings:
      base:
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "YES"

schemes:
  <App>Mac:
    build: { targets: { <App>Mac: all } }
    test:  { targets: [<App>MacTests] }
    run:   { config: Debug }
  <App>Pad:
    build: { targets: { <App>Pad: all } }
    test:  { targets: [<App>PadTests] }
    run:   { config: Debug }
```

**Every plist key goes in `project.yml`.** Editing a generated `Info.plist` by
hand does nothing, because the next generate overwrites it.

## The script

Write it on day one, not when it starts hurting. Nobody remembers an `xcodebuild`
invocation with signing flags, and typing it by hand is where the drift starts.

The shape that worked:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"          # resolve own location, so it runs from anywhere

# The team id is account-specific and this repository is public, so it lives in
# a gitignored file. With no team, everything still builds ad-hoc.
SIGNING=()
if [ -f .app-team ]; then
  TEAM="$(tr -d '[:space:]' < .app-team)"
  [ -n "$TEAM" ] && SIGNING=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM" \
                             CODE_SIGN_IDENTITY="Apple Development" \
                             -allowProvisioningUpdates)
fi

case "${1:-}" in
  up)   ... xcodebuild -scheme <App>Mac ... "${SIGNING[@]}" build ;;
  pad)  ... xcodebuild -scheme <App>Pad -destination "id=$DEVICE" ... ;;
  test) swift test; xcodebuild test -scheme <App>Mac ...; xcodebuild test -scheme <App>Pad ... ;;
esac
```

Three details that were learned the hard way:

- **Install the Mac app to `/Applications` and launch it from there**, not from
  the build folder. The build folder sits inside dot-folders that Finder will not
  show in the Accessibility file picker, and a clean build deletes it, which
  silently invalidates the permission and makes the app look broken.
- **Boot the simulator before running iOS tests.** Otherwise the runner
  intermittently fails with "Application failed preflight checks".
- **Build both apps back to back from the same snapshot** if they share a
  versioned wire protocol. They drift apart silently otherwise.

## First run, in order

```bash
brew install xcodegen
sudo xcode-select -s /Applications/Xcode.app   # once per machine
xcodegen generate
swift test          # core only, no simulator, fast
./app up            # Mac app
./app pad           # physical iPad, needs a team id
```

`xcode-select` matters: the Command Line Tools do not ship swift-testing, so
`swift test` fails with `no such module 'Testing'` without it.

## What to decide before writing code

Not scaffolding, but it belongs in the same sitting:

1. **Which platform assumptions is the design resting on?** Write them down and
   prove the risky ones with a throwaway binary before designing around them.
   [08-the-next-app.md](08-the-next-app.md) explains why this is the single
   highest leverage hour in the project.
2. **Free Apple account or paid?** Free means the iPad build dies after 7 days,
   forever, and re-installing is a physical cable every week. See
   [01-apple-signing.md](01-apple-signing.md).
3. **Which permissions does it need, and do they fail silently?** Accessibility
   and local network both do. Plan the loud on-screen warning at the same time as
   the feature, not after the first confusing evening.
