# Automatic Mouse Mover

A menu bar app that keeps your Mac awake by nudging the cursor whenever you step away —
so Slack, Teams and anything else that watches for idle time keep showing you as active.

It only moves the cursor while you are **not** using the machine. Touch the mouse or the
keyboard and it stays out of your way.

macOS 13 or newer, Apple Silicon and Intel.

## How it differs from "prevent sleep" tools

`caffeinate` and its kind stop the Mac from *sleeping*. They do not stop a messaging app
from deciding you are away, because that decision is made from how long it has been since
the last input event.

This app posts a real HID event. The system idle timer resets, so the Mac stays awake
**and** your status stays active. That is as close to sitting at the machine as software
gets.

## Install

### From the release

Download the latest `amm-*-universal.zip` from
[Releases](https://github.com/clementcopper/automatic-mouse-mover/releases), then:

```bash
ditto -x -k ~/Downloads/amm-*-universal.zip ~/Downloads/
mv ~/Downloads/amm.app /Applications/
xattr -cr /Applications/amm.app
open /Applications/amm.app
```

The app is ad-hoc signed but not notarised, so macOS quarantines anything that arrived
through a download. `xattr -cr` clears that.

### From source

Needs Go 1.21 or newer and the Xcode Command Line Tools (`xcode-select --install`); the
full Xcode is not required.

```bash
git clone https://github.com/clementcopper/automatic-mouse-mover.git
cd automatic-mouse-mover
make build
```

`make build` produces a universal `./bin/amm.app`, signs it ad-hoc and prints the
architectures it contains. Drag it to `/Applications`.

## Granting permission

Moving the cursor needs Accessibility permission:

**System Settings → Privacy & Security → Accessibility →** add `amm` and tick it.

> **If `amm` is already listed there, remove it with the minus button and add it again.**
>
> macOS ties the permission to the exact binary through its code signature. Replace or
> rebuild the app and the tick box still looks fine while the permission no longer
> applies. Toggling the checkbox does not refresh it — only removing and re-adding does.

Without permission the app tells you so the first time it fails, rather than leaving you
guessing at a cursor that will not move.

## The menu

| | |
|---|---|
| **Start / Stop** | Turn the mover on and off. It starts on its own when the app opens. |
| **Launch at Login** | Registers the app as a login item, so the mover runs from the moment you log in. Off by default. |
| **Resume After Wake** | Makes sure the mover is going again after the Mac wakes, and checks immediately instead of waiting for the next interval. On by default. Something you stopped on purpose stays stopped. |

The menu bar icon is a template image, so it turns black or white to match a light or
dark menu bar on its own.

Like the Accessibility grant, the login item is tied to the exact binary: after updating
the app, untick **Launch at Login** and tick it again.

### Changing the icon

Replace `assets/icon/tray.png` with your own `tray.png` or `tray.svg` and rebuild. Keep
exactly one `tray.*` file; there is no generator step.

It has to be **pure black plus an alpha channel**. AppKit tints the icon from the alpha
and throws the colour away, so anything coloured collapses into a silhouette. SVG stays
sharp at any scale; for PNG, 32x32 matches the 16pt icon on a Retina display exactly.

The app's Finder icon is a separate file and that one may be in colour. Draw it as
`appInfo/icon.svg` and run:

```bash
make icons
```

That rasterises the SVG into all ten sizes `iconutil` expects and writes
`appInfo/icon.icns`. It also checks the menu bar artwork and warns if it carries colour.
So one SVG per icon is all you need to draw — nothing else has to be installed, because
the rasterising is done by AppKit itself (`sips` cannot read SVG).

## How it works

Every 30 seconds the app asks macOS how long it has been since the last keyboard, mouse
or tablet event:

```c
CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,
                                       kCGAnyInputEventType)
```

Past 60 seconds of that, it moves the cursor ten pixels and flips the direction each
time, so the pointer oscillates instead of drifting into a corner. The move is a posted
event rather than a warp:

```c
CGEventPost(kCGHIDEventTap, CGEventCreateMouseEvent(...))
```

which is exactly why the idle timer resets. If the position does not change afterwards,
macOS swallowed the event — the app checks whether it actually holds Accessibility
permission and says so.

There is no sleep detection. A sleeping Mac runs no code, and in clamshell mode the app
is supposed to keep working, which a display-asleep check would have broken.

## What this fork changes

The app was rewritten to carry **no runtime dependencies at all**. `robotgo`,
`activity-tracker`, `mac-sleep-notifier` and `systray` are gone, replaced by roughly 250
lines of CoreGraphics and AppKit. The binary went from 7.7 MB to 3.3 MB per architecture,
and `go.mod` now asks for nothing but a test library.

Four long-standing failures disappeared with the code that caused them:

- **Crashes on lid close and screen lock** ([#63](https://github.com/prashantgupta24/automatic-mouse-mover/issues/63),
  [#64](https://github.com/prashantgupta24/automatic-mouse-mover/issues/64)) — an
  uninitialized struct in a dependency, reached through a window-title lookup that no
  longer happens.
- **Build failure on the macOS 15 SDK** ([#62](https://github.com/prashantgupta24/automatic-mouse-mover/issues/62)).
- **Memory leak of roughly 10 MB a day** ([#29](https://github.com/prashantgupta24/automatic-mouse-mover/issues/29)).
- **Stuck mouse and keyboard input** ([#54](https://github.com/prashantgupta24/automatic-mouse-mover/issues/54),
  [#22](https://github.com/prashantgupta24/automatic-mouse-mover/issues/22)) — event taps
  that were never unwound.

Added along the way:

- A universal build that runs natively on Apple Silicon ([#33](https://github.com/prashantgupta24/automatic-mouse-mover/issues/33))
- A menu bar icon that follows light and dark mode ([#56](https://github.com/prashantgupta24/automatic-mouse-mover/issues/56))
- Launch at Login and Resume After Wake
- A permission check that names the real problem instead of blaming the mouse

Fixed in the engine itself: the cursor was judged before the posted event had landed, so
every move counted as a failure and the pointer drifted into a screen corner; and the
"grant permission" alert could never fire, because its 24 hour throttle compared against
a timestamp set three lines above the check.

## Credits and license

Written by **Daniel Martin**.

Based on the original [automatic-mouse-mover](https://github.com/prashantgupta24/automatic-mouse-mover)
by Prashant Gupta, which is where the idea and the first five years of this app come from.

MIT licensed — see [LICENSE](LICENSE).
