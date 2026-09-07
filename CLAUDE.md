# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project policy

This is a fork by Daniel Martin, rewritten in Swift (v2.0) to be nothing but the macOS calls it needs. The upstream `github.com/prashantgupta24/automatic-mouse-mover` is Go and in maintenance mode; this one is not bound by that. Keep the KISS bias: no framework, no package dependency, no abstraction layer "for later". The Go version is preserved on branch `go` and under the `v1.6.1` tag.

macOS-only, 13 or newer. AppKit, CoreGraphics, ServiceManagement and `os` are the whole dependency list.

## Commands

```bash
make build     # universal (arm64 + amd64) ./bin/amm.app, ad-hoc signed, prints `lipo -archs`
make           # build, then `open ./bin`
make test      # swift run amm-tests — the engine's tests, exit code says pass/fail
make start     # swift run amm — runs the app from the build tree, no bundle (no icon, no login item)
make icons     # appInfo/icon.svg -> icon.icns, and checks the tray artwork
make clean     # rm -rf ./bin
swift build    # debug build of every target, what the tests use
```

Needs the Xcode Command Line Tools and nothing else: Swift 5.9 (Ventura) and 6.x (Tahoe) both build it, `Package.swift` is pinned to tools 5.9 so nothing newer creeps in. The CLT print an XCTest warning on every `swift build`; it is noise. CI runs on `macos-15`: `swift.yml` does `make test` and `make build` on every push; `release.yml` fires on a `v*` tag, checks the tag against `Info.plist`, builds, packages with `ditto` and attaches the zip to the release.

The Makefile builds each architecture with `--triple <arch>-apple-macosx13.0` and joins them with `lipo`. `swift build --arch a --arch b` would do it in one go but needs xcbuild from a full Xcode. The triple carries the deployment target, so a bundle built on a newer Mac still runs on Ventura. See LEARNINGS.md § Swift port.

## Architecture

Four targets in `Package.swift`:

- `Sources/AMMCore/Mover.swift` — the engine and the `Platform` protocol. No AppKit. Everything native sits behind the protocol; `MacPlatform` implements it, the tests substitute a fake.
- `Sources/amm/` — the app. `main.swift` sets the accessory policy and runs; `App.swift` builds the status item and menu and owns the two macOS hooks (login item, wake); `MacPlatform.swift` wraps CoreGraphics, `AXIsProcessTrusted`, `NSAlert` and unified logging.
- `Sources/amm-tests/main.swift` — the tests, a plain executable (see below).
- `Sources/mkicons/main.swift` — the icon tool.

**One thread.** The app has no concurrency: a `Timer` on the main run loop calls `Mover.tick()`, the menu actions and the wake notification (delivered on `.main`) call `start`/`stop`/`tick`, and the alert is dispatched onto the main queue. There is no lock, no queue and no atomic, and nothing may be added that calls into `Mover` from another thread. Both hangs of the Go version and its last data race lived in exactly the bridging that this removes.

### The engine (`Mover.swift`)

`start()` schedules a 30 s `Timer` in the run loop's `.common` modes and resets `didNotMoveCount`; a second call while running does nothing. `stop()` invalidates it. The mode matters: a default-mode timer does not fire while a dialog is up or the status menu is open, so About left open would have silenced the mover (measured: 0 of 3 due fires during `runModal`, 3 of 3 in `.common`). The wake handler calls `tick()` directly after checking `isRunning` itself. Each `tick()`:

- `idleSeconds()` below `idleThreshold` (60 s) → do nothing, the user is at the machine. In practice a move lands every 60 to 90 s: the move itself resets the idle timer a few ms after the tick, so the 60 s tick often reads 59.99.
- Otherwise `moveAndCheck`, and on success **flip the sign of `movePixel`** so the cursor oscillates instead of drifting off screen. On failure `reportFailedMove`.

The whole activity detection is one call: `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)` (that is `kCGAnyInputEventType`). No polling, no event tap, no accessibility API.

`moveMouse` posts a real HID event (`CGEvent(...).post(tap: .cghidEventTap)`) rather than warping the cursor — that is what resets the system idle timer and keeps the Mac awake. `tryMove` detects failure by reading the position, moving, and reading it again: unchanged = macOS dropped the event. Posting is **asynchronous**, so a single read-back reports every move as failed; it polls every `moveSettleInterval` (10 ms) up to `moveSettleTimeout` (200 ms, a variable so the tests can shrink it) and returns as soon as the move lands.

`moveAndCheck` calls `tryMove` **twice**, the second time with the sign flipped. A cursor parked in a screen corner cannot move further that way — macOS clamps the event to the edge and the position never changes, which is indistinguishable from a dropped event. Since the sign only flips after a success, one direction alone left the mover stuck in the corner for good, blaming the Accessibility permission.

`tick()` blocks the main thread for up to 2 × 200 ms, but only when both moves fail (measured: 419 ms). While the user is idle nobody is looking at the menu, so this is accepted rather than moved to a queue.

`reportFailedMove` does not guess at the cause — it asks macOS via `accessibilityTrusted()` (`AXIsProcessTrusted`):

- untrusted → alert after **1** failure, with the "remove and re-add amm in Accessibility" wording;
- trusted → alert after **10** failures (`failuresBeforeAlert`), with the diagnostic wording.

Both are throttled to one alert per `alertInterval` (24 h) through `lastAlertTime`, which `start()` deliberately does not reset, so a Stop/Start does not re-arm the alert. `now` is an injectable clock so the test can move past the interval.

There is **no display-sleep guard**. In clamshell mode AMM is supposed to keep working, so a `CGDisplayIsAsleep` check would break exactly the case that matters. A *wake* is watched (`NSWorkspace.didWakeNotification`) only to `tick()` immediately instead of waiting out the next tick; gated by the `ResumeAfterWake` preference. It never restarts the mover: a stopped mover was stopped on purpose, and a `Timer` cannot die the way a goroutine loop could.

### Tests (`amm-tests`)

A plain executable, because the Command Line Tools ship no XCTest and the engine needs none: `tick()` is synchronous, so a test calls it and looks at the state. `test("name") { fake, mover in … }` gives each test a fresh `FakePlatform` and `Mover` with a 20 ms settle timeout and stops the mover afterwards; `check(cond, msg)` counts failures; the process exits 1 on any. It uses `@testable import AMMCore`, which is why `make test` builds debug.

`FakePlatform` models the real asynchrony (`moveDelay`, lands the position from another queue) and the two permission axes separately: `canMove` (does the event land) and `trusted` (`AXIsProcessTrusted`) — a stale grant is exactly `trusted && !canMove`. `clampNegative` is the screen edge. Logging goes through the fake, so tests never write into unified logging. The suite was verified by reintroducing three bugs (no retry, no throttle, double start); each was caught.

### App (`App.swift`, `MacPlatform.swift`)

Menu: About, Start, Stop, Launch at Login, Resume After Wake, Quit. `menu.autoenablesItems = false` is load-bearing: without it AppKit re-decides enabled state at menu-display time and silently overrides `isEnabled`, so Start/Stop stop greying out. A programmatic read-back cannot see this — it only shows up when a human opens the menu.

The only persisted setting is the `ResumeAfterWake` bool in `UserDefaults`, default on via `register(defaults:)`. The login item is not stored — macOS owns it and `SMAppService.mainApp.status` reports it back. The version lives in `Info.plist` alone; the app reads `CFBundleShortVersionString` and says `dev` under `swift run`.

`alert` returns at once — the `NSAlert` is dispatched onto the main queue and runs modal on the next pass, one at a time, after `NSApp.activate(ignoringOtherApps:)` because an accessory app never comes forward on its own.

Logging goes into **unified logging** — a Finder-launched app has no stderr, so anything else is invisible. Read it back with:

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "com.pg.amm"' --style compact
```

Spell it `/usr/bin/log`: in a non-interactive zsh, which is what the Bash tool runs, `log` is a shell builtin that fails with "too many arguments", and a `2>/dev/null` turns that into an empty result that looks like "no records".

`LogLevel.info` goes out as `Logger.notice`, which is `OS_LOG_TYPE_DEFAULT`, **not** `Logger.info`: macOS does not retain the latter unless logging is turned up for the subsystem, so info records would silently never appear. Every interpolation is `privacy: .public`, or the text is redacted to `<private>`.

### Icons

`assets/icon/tray.*` (currently `tray.svg`) is copied into `Contents/Resources` by the Makefile and loaded at launch (`svg` before `png`); swapping the menu bar icon means replacing that one file. The artwork must stay **pure black plus alpha**: it is drawn as a template image (`isTemplate = true`), so AppKit tints it from the alpha and discards colour. It need not be square: the height is fixed at 16 pt and the width follows the aspect ratio; the status item was created with `variableLength` and widens to match. The vector image is handed to AppKit as is — measured at 19 s CPU in 4 days, so no flattening.

The app bundle's Finder icon is separate and may be in colour: `appInfo/icon.icns`, copied by the Makefile. `make icons` builds it from `appInfo/icon.svg` through `NSImage`, because nothing on a stock Mac does it otherwise (`sips` cannot open an SVG, `iconutil` only reads PNG). The same command warns when the tray artwork has colour in it. The `icon.icns` currently checked in holds only a 512px representation; running `make icons` over a real SVG fixes that.

`Info.plist` sets `LSUIElement=true` — menu-bar-only, no dock icon.

### Permissions and signing

The build ad-hoc signs the bundle (`codesign --force --sign -`): Apple Silicon refuses unsigned arm64 code and the `.app` is what macOS validates at launch. This is **not** notarisation — a downloaded build still needs its quarantine attribute cleared.

Both grants are pinned to the exact binary: **rebuilding invalidates Accessibility permission and the login item registration**, while System Settings still shows a ticked box. So after `make build`, expect moves to fail until amm is removed and re-added in Privacy & Security > Accessibility. Do not diagnose that as a code bug. For the same reason the bundle id stays `com.pg.amm` — renaming it would invalidate both again.

## Learnings

The stories are in [LEARNINGS.md](LEARNINGS.md); the rules distilled from them live in
`.claude/rules/` and load by path (`Sources/amm/**`, `Sources/AMMCore/**` plus the tests, build files) when
you read a matching file. A new finding goes to both places, always: story there, one-liner in the
matching rule file. `Sessions/` holds dated session summaries — what was decided, and
what was measured rather than assumed.
