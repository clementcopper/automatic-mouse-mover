# Automatic Mouse Mover

A menu bar app that keeps your Mac awake by nudging the cursor whenever you step away —
so Slack, Teams and anything else that watches for idle time keep showing you as active.

It only moves the cursor while you are **not** using the machine. Touch the mouse or the
keyboard and it stays out of your way.

macOS 13 or newer, Apple Silicon and Intel. Written in Swift, no dependencies, about
300 KB.

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
[Releases](https://github.com/clementcopper/automatic-mouse-mover/releases).

The app is ad-hoc signed but **not notarised**, so macOS blocks it on first launch with
*"Apple could not verify amm.app is free of malware…"*. That is expected. Two ways past
it — pick one.

**Finder.** Drag `amm.app` into Applications, double-click it, dismiss the dialog, then
open **System Settings → Privacy & Security**, scroll to the bottom and click **Open
Anyway**. On macOS 15 and newer this is the only route through the GUI: right-click →
Open no longer bypasses the check.

**Terminal.** Clearing the quarantine attribute *before* the first launch avoids the
dialog entirely:

```bash
ditto -x -k ~/Downloads/amm-*-universal.zip ~/Downloads/
mv ~/Downloads/amm.app /Applications/
xattr -cr /Applications/amm.app
open /Applications/amm.app
```

The order matters — once macOS has assessed the app, the dialog is what you get.

### From source

Needs the Xcode Command Line Tools (`xcode-select --install`), which bring the Swift
toolchain. The full Xcode is not required.

```bash
git clone https://github.com/clementcopper/automatic-mouse-mover.git
cd automatic-mouse-mover
make build
```

`make build` produces a universal `./bin/amm.app`, signs it ad-hoc and prints the
architectures it contains. Drag it to `/Applications`. A self-built app is never
quarantined, so none of the Gatekeeper steps above apply.

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
| **Resume After Wake** | Checks the idle time as soon as the Mac wakes instead of waiting for the next interval. On by default. Something you stopped on purpose stays stopped. |

The menu bar icon is a template image, so it turns black or white to match a light or
dark menu bar on its own.

Like the Accessibility grant, the login item is tied to the exact binary: after updating
the app, untick **Launch at Login** and tick it again.

### Changing the icon

Replace `assets/icon/tray.svg` with your own `tray.svg` or `tray.png` and rebuild. The
Makefile copies it into the bundle and the app loads it at launch; there is no generator
step.

It has to be **pure black plus an alpha channel**. AppKit tints the icon from the alpha
and throws the colour away, so anything coloured collapses into a silhouette. SVG stays
sharp at any scale; for PNG, draw it at twice the size it will be shown.

**It does not have to be square.** The artwork is scaled to 16 pt tall and the width
follows the aspect ratio, so a wide mark stays a wide mark — a 512x179 drawing ends up as
a 62 pt wide item in a 22 pt menu bar. Only the height is fixed, by the menu bar itself.

The app's Finder icon is a separate file and that one may be in colour. Draw it as
`appInfo/icon.svg` and run:

```bash
make icons
```

That rasterises the SVG into all ten sizes `iconutil` expects and writes
`appInfo/icon.icns`. It also checks the menu bar artwork and warns if it carries colour.
Nothing else has to be installed, because the rasterising is done by AppKit itself
(`sips` cannot read SVG).

## How it works

Every 30 seconds the app asks macOS how long it has been since the last keyboard, mouse
or tablet event:

```swift
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: kCGAnyInputEventType)
```

Past 60 seconds of that, it moves the cursor ten pixels and flips the direction each
time, so the pointer oscillates instead of drifting into a corner. The check runs on a
30-second grid, so in practice a move lands every 60 to 90 seconds. The move is a posted
event rather than a warp:

```swift
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, ...).post(tap: .cghidEventTap)
```

which is exactly why the idle timer resets. Posting is asynchronous, so the app polls the
cursor position for up to 200 ms to see whether the move landed. If it did not, it tries
the opposite direction — a cursor parked in a screen corner cannot go further one way —
and only then checks whether it actually holds Accessibility permission and says so.

There is no sleep detection. A sleeping Mac runs no code, and in clamshell mode the app
is supposed to keep working, which a display-asleep check would have broken.

## Development

```bash
make test      # the engine's tests
make start     # run from the build tree, no bundle (no icon, no login item)
make build     # universal ./bin/amm.app
```

Four targets in `Package.swift`: `AMMCore` is the engine behind a `Platform` protocol,
with no AppKit in it; `amm` is the app; `amm-tests` are the tests; `mkicons` is the icon
tool. Everything runs on the main thread — a `Timer` drives the engine, and there is no
queue, lock or atomic anywhere.

The tests are a plain executable rather than an XCTest bundle, because the Command Line
Tools ship no XCTest and the engine needs none: it is synchronous, so a test calls
`tick()` and looks at the result. The suite runs in a tenth of a second.

## Origins and license

Written by **Daniel Martin**.

Based on the original [automatic-mouse-mover](https://github.com/prashantgupta24/automatic-mouse-mover)
by Prashant Gupta, which is where the idea and the first five years of this app come from.
This fork first rewrote it in Go without any dependencies (1.6, on branch `go` and tag
`v1.6.1`), then ported it to Swift (2.0).

MIT licensed — see [LICENSE](LICENSE).
