# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project policy

This is a fork by Daniel Martin, rewritten to carry no runtime dependencies. The upstream `github.com/prashantgupta24/automatic-mouse-mover` is in maintenance mode; this one is not bound by that. Keep the KISS bias though: no framework, no abstraction layer "for later".

macOS-only. `robotgo` and `systray` need cgo and Cocoa; nothing here builds meaningfully on Linux.

## Commands

```bash
make build     # universal (arm64 + amd64) ./bin/amm.app, ad-hoc signed, prints `lipo -archs`
make           # build, then `open ./bin`
make start     # go run cmd/main.go — runs the tray app directly
make clean     # rm -rf ./bin
make vet       # go vet ./...
make icons     # appInfo/icon.svg -> icon.icns, and checks the tray artwork
make coverage  # go test -race -coverprofile, then HTML report at cover.html
go test -race -v ./...                                              # what CI runs
go test -v -run 'TestSuite/TestMouseMoveFailure' ./internal/mousemover/   # single test
```

Tests use a testify **suite**, so a single test is addressed as `TestSuite/<Name>`, not by its bare name.

Needs Go 1.21+. CI runs on `macos-15`: `go.yml` does vet, `go test -race` and `make build` on every push; `release.yml` fires on a `v*` tag, builds, packages with `ditto` and attaches the zip to the release.

The build pins `-mmacosx-version-min=13.0` and `-ldflags="-s -w"` (see the `MIN_MACOS` and `LDFLAGS` variables). The deployment target keeps a bundle built on a newer Mac running on Ventura; the strip flags cut 36% and leave panic traces intact. See LEARNINGS.md.

## Architecture

**Zero runtime dependencies.** `go.mod` requires only testify, and only for tests. Everything native lives in `internal/mac`.

- `cmd/main.go` — builds the menu and drives `mousemover` through `Start()` / `Quit()`. Menu clicks are handled in a single `select` loop over each item's `ClickedCh`. No config, no persistence.
- `internal/mac` — all cgo. `mac.go`/`mac.m` wrap CoreGraphics (idle time, cursor, alert); `menubar.go`/`menubar.m` wrap AppKit (`NSStatusItem`); `system.*` cover the login item, preferences and the wake notification; `log.*` route slog into unified logging. Replaced robotgo, activity-tracker, mac-sleep-notifier and systray.
- `internal/mousemover` — the engine, no cgo. `GetInstance()` returns a package-level singleton.

### The core loop (`mouseMover.go`)

`Start()` creates a 30 s ticker and hands it to `run()`, which spawns the loop goroutine. Per tick:

- `IdleSeconds()` below `idleThreshold` (60 s) → do nothing, the user is at the machine.
- Otherwise `moveAndCheck`, and on success **flip the sign of `movePixel`** so the cursor oscillates instead of drifting off screen. On failure bump `didNotMoveCount`; at ≥10 failures and >24 h since the last alert, show the "grant Accessibility permission" alert from the README.

The whole activity detection is one call: `CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType)`. No polling, no event tap, no accessibility API.

`MoveMouse` posts a real HID event (`CGEventPost(kCGHIDEventTap, …)`) rather than warping the cursor — that is what resets the system idle timer and keeps the Mac awake. `moveAndCheck` detects failure by reading the position, moving, and reading again: unchanged = macOS dropped the event because Accessibility permission is missing.

There is **no sleep detection**. A sleeping Mac runs no goroutines, and in clamshell mode AMM is supposed to keep working — a display-asleep guard would break exactly that case.

### State and test seams

All of `state` sits behind an `sync.RWMutex` with getter/setter pairs in `mouseMoverUtil.go` — never touch the struct fields directly from the loop. The `platform` interface (`types.go`) is the test seam: `internal/mac.API` implements it for real, tests substitute `fakePlatform` and drive `run()` with their own tick channel, resetting the singleton with `instance = nil` in `SetupTest`. Tests therefore need no cgo, no cursor and pop no dialog.

Logging is per-run via `getLogger(m, doWriteToFile, filename)` on `log/slog`; file output is off by default. The default handler is `mac.NewLogHandler`, which writes into **unified logging** — a Finder-launched app has no stderr, so anything else is invisible. Read it back with:

```bash
log show --last 10m --predicate 'subsystem == "com.pg.amm"' --style compact
```

slog `Info` maps to `OS_LOG_TYPE_DEFAULT`, **not** `OS_LOG_TYPE_INFO`: macOS does not retain the latter unless logging is turned up for the subsystem, so info records would silently never appear.

### Menu bar (`internal/mac/menubar.m`)

Every AppKit call funnels through `runOnMain` — menu items are built from a goroutine, and touching AppKit off the main thread crashes. `init()` in `menubar.go` calls `runtime.LockOSThread()` so `[NSApp run]` gets the process' first thread.

`[gMenu setAutoenablesItems:NO]` is load-bearing: without it AppKit re-decides enabled state at menu-display time and silently overrides `setEnabled:`, so Start/Stop stop greying out. A programmatic read-back of `isEnabled` cannot see this — it only shows up when a human opens the menu.

### Icons

`assets/icon/tray.png` is embedded with `//go:embed tray.*`, so swapping the menu bar
icon means replacing that one file — PNG or SVG, both verified to load through
`NSImage initWithData:` and to rasterise. Keep exactly one `tray.*` file. The artwork
must stay **pure black plus alpha**: it is drawn as a template image
(`[image setTemplate:YES]` in `menubar.m`), so AppKit tints it from the alpha and
discards colour.

The app bundle's Finder icon is separate and may be in colour: `appInfo/icon.icns`,
copied by the Makefile. `make icons` builds it from `appInfo/icon.svg` — `tools/mkicons`
rasterises through `NSImage`, because nothing on a stock Mac does it otherwise (`sips`
cannot open an SVG, `iconutil` only reads PNG). The same command warns when the tray
artwork has colour in it. It is deliberately not a dependency of `build`.

The `icon.icns` currently checked in holds only a 512px representation, so macOS
downscales it for every smaller slot; running `make icons` over a real SVG fixes that.

`Info.plist` sets `LSUIElement=true` — menu-bar-only, no dock icon. The version lives in
two places that must be bumped together with the release tag: the `version` const in
`cmd/main.go` and `CFBundleShortVersionString`/`CFBundleVersion` in `appInfo/Info.plist`.

## Learnings

Dependency traps and past debugging dead ends are in [LEARNINGS.md](LEARNINGS.md). Read it before touching `go.mod` or the build flags.
