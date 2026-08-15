# Building the next app faster

The other files in this folder say what to do with Apple's tools. This one says
what to do differently, and it is the only file here that is not about Padlink.

One pattern cost more time than every other problem in this project put
together, and it is not a platform quirk. It will happen again on any app that
touches hardware, an operating system, or another machine, so it is first.

## 1. A feature can be 100% tested and 0% working

This happened **three times**, and each time the tests were green and the
feature was completely dead on the device.

| Feature | Tests said | Reality |
|---|---|---|
| Three finger swipes | all passing | iPadOS cancelled the touches before the code ran |
| Drag to select | all passing | the 300ms window was faster than a human hand moves |
| Pinch to zoom | all passing | every test pinched symmetrically, the one shape that worked |

Look at what those tests actually exercised. They fed events **directly** into
the layer under test. On the real device those events never arrived, arrived too
late, or arrived in a shape no test used. The tests were not wrong. They were
testing a layer that was never broken.

**The rule.** For anything that crosses a boundary you do not own (OS input, OS
gestures, permissions, another machine, real hardware), a unit test proves your
half and nothing else. Decide up front which half each test covers, and plan a
real device check for the other half. Do not let "the suite is green" stand in
for "the boundary works".

**The cheap version of this.** Before writing the feature, write a one command
probe that answers "does this even reach the other side". It is usually 30 lines
and it saves a full build, install and hand test cycle every time you are wrong.

## 2. Measure the platform before you design against it

Padlink shipped three finger and four finger swipes as keystrokes: Control and
Up for Mission Control, Control and an arrow to switch spaces. The design
document, the protocol, the tests and the user documentation were all built on
that. **None of it could ever have worked.**

macOS ignores a synthesized event for a shortcut the system itself owns. Half an
hour with a 40 line probe would have found it before any of that was written:

| Posted with `CGEvent` | Result |
|---|---|
| Command and A, then Command and C, into TextEdit | works, the clipboard got the text |
| A plain mouse move | works |
| A scroll carrying the Command flag | delivered with the flag intact |
| **Command and Shift and 3** (screenshot) | **nothing** |
| **Control and Up** (Mission Control) | **nothing** |

**The rule.** Every design rests on assumptions about what the platform will
let you do. List them, then spend an hour proving the risky ones with a throwaway
binary. An assumption that survives contact with a probe is worth building on. An
assumption that has only ever been reasoned about is a guess wearing a design
document.

This is the same idea as the keychain spike that opened the project (Task 0),
which did work well. The mistake was doing it once, for one risk, instead of for
every risky assumption.

## 3. Stop guessing the moment you have guessed twice

Late in the project, three finger swipes still did nothing. The reasoning was
sound: the modifier probably was not really held, because the code puts flags on
the key event and never presses a real Control key.

**That was wrong.** Measured: the modifier is held, and `flagsState` confirms it.
Shipping that "fix" would have changed nothing, and the next failure would have
been blamed on something else again.

**The rule.** The first hypothesis is free. The second one means you do not
understand the system yet, and the next thing you write should be a measurement,
not a fix. This is what the systematic debugging skill is for, and it is worth
following literally rather than in spirit.

## 4. When a failure has three possible causes, ship the readout first

"The swipe does nothing" had three completely different causes, which look
identical from the chair:

1. The fingers never reached the app.
2. The system took them away mid gesture.
3. Everything worked and the far side ignored it.

Two speculative fixes were spent before adding a small on screen readout showing
the finger count and what the trackpad made of it. **It answered the question in
one hand test**, and the answer was cause 3, which neither speculative fix
addressed.

**The rule.** Count the places a failure could come from. At three or more, the
next thing you build is the instrument, not the fix. It is almost always smaller
than the fix, and it usually earns its place in the shipped product too, because
if you cannot tell those cases apart, neither can the user.

## 5. Test the shape a hand makes, not the shape that is easy to type

Every zoom test moved both fingers by the same amount:

```swift
_ = handle(began, [(1, 0, 0), (2, 100, 0)])
_ = handle(moved, [(1, -40, 0), (2, 140, 0)])   // both fingers, equal, opposite
```

That holds the centre point perfectly still and hands the decision to the spread
unopposed. It is the one pinch shape that worked, and nobody pinches that way.
Anchor a thumb and move one finger, which is what a real hand does, and the
maths came out as an exact tie that always resolved to scrolling.

**The rule.** For anything geometric or physical, the convenient input is the
symmetric one and the real input never is. Always include an asymmetric case, a
degenerate case (fingers touching, zero distance, zero time), and a case built
from numbers you did not choose.

## 6. Guards about transitions are directional, so write both

A two finger tap becomes a right click. There was already a guard stopping that
from firing when a **third finger lands**. There was no guard for the mirror
case, a hand **lifting** from three fingers to two, which passes through a two
finger moment with no travel and no elapsed time.

Result: every three and four finger gesture ended by opening a context menu, and
that stray click was also dismissing Mission Control immediately after opening
it, which is why the swipe looked dead.

**The rule.** When a guard is about a change in state, ask what the same change
looks like in reverse, and write that test in the same sitting.

## 7. Check the number, not the green tick

A bulk edit that replaced everything between two text markers silently deleted
**14 unrelated tests** that happened to sit between them. Every remaining test
passed. The only signal was the count falling from 377 to 365.

**The rule.** Read the test count on every run, and be suspicious when it falls.
Prefer edits anchored to a unique string over edits anchored to a range.

## 8. What actually worked, and is worth copying

Not everything was a mistake. These paid for themselves:

- **A pure core with no platform types in it.** `TouchInterpreter` is the entire
  trackpad with no UIKit anywhere, so 379 tests run in 0.2 seconds with no
  simulator. Every "what should happen when" question is answered in a plain
  function. Copy this shape: decisions in a pure type, a thin shell that only
  translates and posts.
- **One script for everything.** `./padlink up`, `pad`, `test`. Nobody remembers
  an `xcodebuild` invocation with signing flags. Write the script on day one, not
  when it starts hurting.
- **A running journal.** `NOTES.md`, dated, terse, with the actual commands.
  Sessions ran out of context repeatedly and the journal is what made the next
  one start in the right place.
- **Comments that record the rejected option.** "Plain latching was rejected
  because a Command tapped by accident would stay down forever." Six months from
  now that is the only thing stopping someone re-introducing the bug.
- **Making silent failures loud.** macOS throws away every event without
  Accessibility permission and reports nothing. A large orange banner that
  contradicts every other success signal on the screen is not over-design, it is
  the only defence against a state where everything looks perfect and nothing
  works.

## 9. The order to do it in next time

1. **List the risky platform assumptions.** Anything of the form "the OS will let
   me X". Write them down before any design.
2. **Probe each one** with a throwaway binary. An hour here is the highest
   leverage hour in the project.
3. **Design against what survived**, and record which assumptions were proved and
   which were merely reasoned about.
4. **Build the pure core first**, with tests, because it is fast and it is where
   the thinking is.
5. **Get one end to end path working on real hardware early**, even if ugly. In
   this project that was cursor movement, and it flushed out the permission and
   signing problems while they were still cheap.
6. **Add the instrument before the third feature.** Whatever tells you which
   layer a failure came from.
7. **Hand test every feature that crosses a boundary**, and treat "the suite is
   green" as necessary rather than sufficient.

## 10. And the boring one

Read the standing instructions and follow them from the first commit. Em-dashes
were written into the README, the journal, both plan documents, the design spec
and the gesture documentation, against an explicit instruction not to use them
anywhere. Removing them later was a whole pass over the repository that should
never have been needed.
