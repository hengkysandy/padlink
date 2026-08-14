# Gestures and the on-screen keyboard

What the iPad surface does, and why each gesture is built the way it is.

## The gestures

| On the iPad | On the Mac |
|---|---|
| One finger, drag | Move the cursor |
| One finger, tap | Left click |
| Tap, then put the finger back down and drag | Hold the button down: select text, drag a file |
| **Two fingers, tap** | **Right click** (context menu) |
| Two fingers, drag | Scroll, both axes |
| Two fingers, flick and lift | Scroll, then keep coasting and slow down |
| **Two fingers, pinch** | **Zoom in and out** |
| **Three fingers, up** | **Mission Control** |
| **Three fingers, down** | **App Exposé** |
| **Three fingers, right / left** | **Page back / forward** (Safari, Finder, Preview) |
| **Four fingers, left / right** | **Next / previous desktop** |
| **Four fingers, up** | **Mission Control** |

Bold rows are new as of 2026-08-14.

## The one constraint behind all of it

**macOS has no public API for synthesizing a real trackpad gesture.** There is no
supported way to post a pinch, a rotate, or a swipe event. `CGEvent` can post
mouse moves, clicks, scrolls and key presses, and that is the whole list.

So every gesture above is sent as something the Mac already answers to:

- **A zoom** is Command held across a scroll. That is genuinely how the Mac
  zooms, so it works everywhere Command-scroll works.
- **A swipe** is a keyboard shortcut. Mission Control is Control-Up, spaces are
  Control-Left and Control-Right, page navigation is Command-[ and Command-].

That is why the protocol did not need a new message for any of this. It is also
why a swipe is instant rather than animated with your fingers: the Mac receives
a keystroke, not a partial gesture.

## Why three fingers and four fingers do different things

macOS itself ships both mappings, in **System Settings > Trackpad > More
Gestures**:

- "Swipe between pages" can be set to three fingers.
- "Swipe between full-screen applications" can be set to four fingers.

Padlink uses both at once, one per finger count. The alternative was to put both
on one count and guess which the user meant, in whatever app they happened to be
looking at. "Go back" and "next desktop" are not recoverable from each other.

Five fingers is treated as four. A hand resting while three fingers swipe is
common, and ignoring it entirely reads as the gesture being broken.

## Why scroll and zoom have a small dead zone

Both start identically: two fingers on the glass, not moving. The app cannot know
which one you meant until you move. So it waits for **12 points** of movement,
then decides once and locks the answer for the rest of the gesture.

Locking is the important half. Deciding again on every frame makes a slow
diagonal pinch flicker between zooming and scrolling, which is unusable.

The movement you make during those 12 points is **not thrown away**. It is banked
and flushed with the first scroll. Dropping it would take 12 points off the front
of every scroll, which feels like the content lagging your fingers and never
catching up.

## Why momentum stops when you touch the glass

Same as a real trackpad. Otherwise a tap lands on content that is still sliding
under it.

Momentum also refuses to start if you stopped moving before lifting. Holding
still and then lifting is a deliberate stop, and coasting anyway ignores it.

## The keyboard

Three layouts, chosen from the keyboard icon in the bar at the bottom.

| Layout | What it is |
|---|---|
| **MacBook** (default) | Every key, function row included, laid out like the machine in front of you |
| **Compact** | Letters, modifiers and arrows only. Bigger keys, much more trackpad |
| **Trackpad only** | No keyboard. The app as it was before |

The choice is remembered across launches.

### Modifiers: tap once to arm, tap twice to lock

Tapping `⌘` then `C` has to produce Command-C, so a modifier must survive its own
tap. The question is how long.

- **Tap once**: armed. It applies to the next key, then clears itself. Shown as a
  pale highlight.
- **Tap again**: locked. It stays until you tap it a third time. Shown as a solid
  highlight.

This is exactly how the iOS shift key already behaves, so there is nothing to
learn. It also needs no timer, because "tap twice" just means "tap something that
is already armed" — there is no timing window to miss.

Plain latching (tap on, tap off) was rejected: a `⌘` tapped by accident would
stay down forever, and a held Command makes the whole Mac behave strangely.
One-shot alone was rejected too: it cannot hold Command across several Tab
presses, which is what the app switcher needs.

### Why an armed modifier is safer than a locked one

An **armed** modifier never reaches the Mac as a held key. It rides as a flag on
the key press itself, so a connection dying mid-shortcut cannot leave anything
held.

Only a **locked** modifier is really held down on the Mac. That keeps the one
mechanism that can strand a modifier attached to the one state you chose on
purpose and can see on screen.

On top of that, a locked modifier is released automatically when:

- the connection drops (the Mac releases everything it was holding),
- you leave the app,
- you switch keyboard layout.

### `⇪` locks shift

There is no caps lock in the protocol and no caps lock bit in the modifier set.
Locking shift is what the key is for anyway, and it stays visible and clearable
like every other lock.

## If a modifier ever does get stuck

It should not, but the escape hatch is: tap the modifier until it is unhighlighted,
or switch to "Trackpad only" and back, or just quit and reopen the iPad app. Any
of the three releases everything on the Mac.
