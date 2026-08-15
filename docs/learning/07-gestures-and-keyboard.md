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
| **Three or four fingers, up** | **Mission Control** |
| **Three fingers, right / left** | **Page back / forward** (Safari, Finder) |

Bold rows are new as of 2026-08-14.

**Three fingers down, and four fingers sideways, do nothing. That is macOS, not
a bug here.** See the section below.

**Four-finger gestures only work if you turn off the system ones.** iPadOS keeps
four and five finger swipes for itself (App Switcher, Home, switching apps) and
there is no way for an app to take them back. Turn them off in **Settings >
General > Multitasking & Gestures**, or just use the three-finger versions.

## The one constraint behind all of it

**macOS has no public API for synthesizing a real trackpad gesture.** There is no
supported way to post a pinch, a rotate, or a swipe event. `CGEvent` can post
mouse moves, clicks, scrolls and key presses, and that is the whole list.

So every gesture above is sent as something the Mac already answers to:

- **A zoom** is Command held across a scroll. That is genuinely how the Mac
  zooms, so it works everywhere Command-scroll works.
- **A swipe** is a keyboard shortcut. Mission Control is Control-Up, spaces are
  Control-Left and Control-Right, page navigation is Command-[ and Command-].

A swipe is therefore instant rather than animated with your fingers: the Mac
receives a keystroke, not a partial gesture.

## The second constraint, found the hard way

**macOS ignores a synthesized event for a shortcut the system itself owns.**

This was measured on real hardware on 2026-08-15, after three finger swipes were
reported as doing nothing:

| Posted with `CGEvent` | Result |
|---|---|
| Command and A, then Command and C, into TextEdit | **works**, the clipboard got the text |
| Command and Shift and 3 (screenshot) | **no file created** |
| Control and Up (Mission Control) | **does not open** |
| A plain mouse move | works |
| A scroll carrying the Command flag | delivered with the flag intact |

So ordinary application shortcuts arrive perfectly, and anything the
WindowServer or the Dock owns is thrown away. This is a security boundary in
macOS, not a fault in Padlink, and no amount of work on the keystroke path can
get around it.

What that costs, and what was done about it:

- **Mission Control** was Control and Up. It is now a `systemAction` message,
  and the Mac opens `/System/Applications/Mission Control.app` instead. A
  different route to the same place, and a supported one. This works.
- **App Exposé** was Control and Down. Blocked, and there is no app to open. The
  gesture now sends **nothing**. Sending a keystroke already known not to work
  would cost a round trip to do nothing and still look like a feature.
- **Switching spaces** was four fingers sideways, Control and an arrow. Blocked,
  with no public API of any kind. Also sends nothing.

That is why the finger counts no longer do different things vertically. Up is
Mission Control for both three fingers and four, and down is not used.

Five fingers is still treated as four. A hand resting while three fingers swipe
is common, and ignoring it entirely reads as the gesture being broken.

## What zoom actually needs

The Command flag does reach the Mac on a scroll event, which was confirmed with
an event tap reading back what macOS delivered. So a pinch is being sent
correctly.

It will zoom in **Safari, Chrome and Finder**, which all read Command and scroll.
It will **not** zoom in Preview, which wants a real `NSEvent.magnify`, and macOS
has no public API to synthesize one. If a pinch seems to do nothing, try it in
Safari before assuming it is broken.

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

Two layouts, chosen from the sliders button in the bar at the bottom.

| Layout | What it is |
|---|---|
| **MacBook** (default) | Every key, function row included, laid out like the machine in front of you |
| **Compact** | Letters, modifiers and arrows only. Bigger keys, much more trackpad |

The choice is remembered across launches. Hiding the keyboard is a separate
button in the bottom bar, because which keyboard you use is something you set
once and whether it is on screen is something you flip while working.

### How big the keys can get

Measured on an 11 inch iPad, where a real MacBook key is 17mm across:

| | Landscape | Portrait |
|---|---|---|
| MacBook | 12.2mm | 8.5mm |
| Compact | 16.8mm | 11.7mm |

**A life-size MacBook keyboard cannot fit.** A MacBook keyboard is about 285mm
wide and an 11 inch iPad is about 179mm. The most that fits is the screen width
divided by the layout's width in key units, and no setting changes that.

So if the keys feel small: **turn the iPad to landscape**, and **use Compact**,
which is 10 key units wide instead of 14.5 and lands on almost exactly a real
MacBook key. What Compact gives up (function row, digit row, symbols) is
reachable through the text button in the bottom bar.

### Modifiers: tap once to arm, tap twice to lock

Tapping `⌘` then `C` has to produce Command-C, so a modifier must survive its own
tap. The question is how long.

- **Tap once**: armed. It applies to the next key, then clears itself. Shown as a
  pale highlight.
- **Tap again**: locked. It stays until you tap it a third time. Shown as a solid
  highlight.

This is exactly how the iOS shift key already behaves, so there is nothing to
learn. It also needs no timer, because "tap twice" just means "tap something that
is already armed, so there is no timing window to miss.

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

It should not, but there are three escape hatches: tap the modifier until it is
no longer highlighted, hide the keyboard and show it again, or quit and reopen
the iPad app. Any of the three releases everything on the Mac.

## A keyboard attached to the iPad

Plug in or pair a Magic Keyboard (or any Bluetooth keyboard) and it drives the
Mac directly. No on-screen keyboard, no text field, and the lowest latency the
app can manage.

**It sends the physical key, not the letter printed on it.** That is deliberate,
and it is the difference between typing into an iPad and driving a Mac. A key
code is interpreted through the *Mac's* keyboard layout, so a Mac set to French
produces French whatever the iPad's keys say. Sending the character instead would
force the iPad's layout onto the wrong machine.

It also means **key repeat works**. iPadOS delivers one key-down event and no
repeats, so the app cannot repeat a character. But the press and the release are
sent as they happen, the key is genuinely held on the Mac, and the Mac's own
repeat takes over.

Modifiers are really held down, so `⌘` across three presses of `Tab` keeps the
app switcher open. They are released automatically when you leave the app.

## The latency figure

While connected, the status bar shows the round trip to the Mac and back.

| Colour | Meaning |
|---|---|
| Green, up to 40ms | The design estimate. Feels like a trackpad |
| Orange, up to 90ms | Noticeable if you look for it |
| Red, past 90ms | Feels wrong, and it is the network rather than the app |

It exists because "this feels bad because the app is broken" and "this feels bad
because the Wi-Fi is busy" look identical from the outside. One of them shows
180ms. A 5GHz network, or moving closer to the router, is the usual fix.

## Revoking a device

On the Mac: menu bar icon, then **Forget a device**.

That device can no longer connect, immediately, and any session it currently has
is dropped. Worth doing for an iPad you sold, lent, or lost, because a pairing is
a long-lived key and nothing else expires it.
