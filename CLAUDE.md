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

Needs Go 1.21+ (`go.mod`); CI builds with Go 1.25. CI runs on `macos-15`: `go.yml` does vet, `go test -race` and `make build` on every push; `release.yml` fires on a `v*` tag, builds, packages with `ditto` and attaches the zip to the release.

The build pins `-mmacosx-version-min=13.0` and `-ldflags="-s -w"` (see the `MIN_MACOS` and `LDFLAGS` variables). The deployment target keeps a bundle built on a newer Mac running on Ventura; the strip flags cut 36% and leave panic traces intact. See LEARNINGS.md.

## Architecture

**Zero runtime dependencies.** `go.mod` requires only testify, and only for tests. Everything native lives in `internal/mac`.

- `cmd/main.go` — builds the menu and drives `mousemover` through `Start()` / `Quit()` / `CheckNow()`. Menu clicks are handled in a single `select` loop over each item's `ClickedCh`; the loop is the only writer of menu state, so nothing else may touch it. Menu: About, Start, Stop, Launch at Login, Resume After Wake, Quit. The only persisted setting is the `ResumeAfterWake` bool in `NSUserDefaults`; the login item is not stored — macOS owns it and `SMAppService` reports it back. `wantRunning` is an `atomic.Bool` because the wake callback runs on another goroutine: a wake resumes only what the user had running, a deliberate Stop stays stopped.
- `platform.Alert` returns at once — the dialog is put up on the main thread with `dispatch_async` and outlives the call, and only one is on screen at a time. Do **not** wrap it in `go`: it used to block until dismissed, and the goroutine around it is what made an unseen dialog park a thread for ever.
- `internal/mac` — all cgo. `mac.go`/`mac.m` wrap CoreGraphics (idle time, cursor, alert); `menubar.go`/`menubar.m` wrap AppKit (`NSStatusItem`); `system.*` cover the login item, preferences and the wake notification; `log.*` route slog into unified logging. Replaced robotgo, activity-tracker, mac-sleep-notifier and systray.
- `internal/mousemover` — the engine, no cgo. `GetInstance()` returns a package-level singleton.

### The core loop (`mouseMover.go`)

`Start()` creates a 30 s ticker and hands its channel plus a stop func to `run()`, which spawns the loop goroutine. The loop selects over three channels: `tick`, `kick` (`CheckNow()`, used after a wake so the check does not wait out the next tick — buffered size 1, sent non-blocking) and `quit`. Each tick or kick runs `checkAndMove`:

- `IdleSeconds()` below `idleThreshold` (60 s) → do nothing, the user is at the machine.
- Otherwise `moveAndCheck`, and on success **flip the sign of `movePixel`** so the cursor oscillates instead of drifting off screen. On failure `reportFailedMove`.

The whole activity detection is one call: `CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType)`. No polling, no event tap, no accessibility API.

`MoveMouse` posts a real HID event (`CGEventPost(kCGHIDEventTap, …)`) rather than warping the cursor — that is what resets the system idle timer and keeps the Mac awake. `tryMove` detects failure by reading the position, moving, and reading it again: unchanged = macOS dropped the event. `CGEventPost` is **asynchronous**, so a single read-back reports every move as failed; it polls every `moveSettleInterval` (10 ms) up to `moveSettleTimeout` (200 ms, a `var` so tests can shrink it) and returns as soon as the move lands.

`moveAndCheck` calls `tryMove` **twice**, the second time with the sign flipped. A cursor parked in a screen corner cannot move further that way — macOS clamps the event to the edge and the position never changes, which is indistinguishable from a dropped event. Since the sign only flips after a success, one direction alone left the mover stuck in the corner for good, blaming the Accessibility permission.

`reportFailedMove` does not guess at the cause — it asks macOS via `AccessibilityTrusted()` (`AXIsProcessTrusted`):

- untrusted → alert after **1** failure, with the "remove and re-add amm in Accessibility" wording;
- trusted → alert after **10** failures (`failuresBeforeAlert`), with the diagnostic wording.

Both are throttled to one alert per 24 h through `lastAlertTime`. That field exists separately from `lastErrorTime` on purpose: `lastErrorTime` has just been set to now on the same path, so throttling against it made the condition permanently false and no alert ever appeared.

There is **no display-sleep guard**. In clamshell mode AMM is supposed to keep working, so a `CGDisplayIsAsleep` check would break exactly the case that matters. A *wake* is watched (`mac.WatchWake`, `NSWorkspaceDidWakeNotification`) — not because the loop dies during sleep (a sleeping Mac runs no goroutines, it resumes on its own) but to check immediately on wake (`CheckNow`), and to restart the loop if it is no longer running while `wantRunning` is still set. Gated by the `ResumeAfterWake` preference.

### State and test seams

`Start`, `Quit` and `CheckNow` are serialised by `MouseMover.mutex`: the menu loop is not the only caller, the wake callback drives the same three methods from its own goroutine. Two rules come out of that and must not be undone — `Start` sets the running flag **itself** rather than leaving it to the loop goroutine (a late goroutine let a second `Start` open a second loop), and `Quit` **closes** `quit` and then waits on `done` (a send on the unbuffered channel blocked for ever once no loop was listening, and froze the menu loop with it). The loop reads `quit`/`kick` into locals so `Start` can replace the fields without racing it.

All of `state` sits behind an `sync.RWMutex` with getter/setter pairs in `mouseMoverUtil.go` — never touch the struct fields directly from the loop. The `platform` interface (`types.go`) is the test seam: `internal/mac.API` implements it for real, tests substitute `fakePlatform` and drive `run()` with their own tick channel, resetting the singleton with `instance = nil` in `SetupTest`. Tests therefore need no cgo, no cursor and pop no dialog. `fakePlatform` models the real asynchrony (`moveDelay`) and the two permission axes separately: `canMove` (does the event land) and `trusted` (`AXIsProcessTrusted`) — a stale grant is exactly `trusted && !canMove`. Tests also set `m.logger` before `run()` starts, which keeps invented failures out of the system log without racing the goroutine.

Logging is per-run via `getLogger(m, doWriteToFile, filename)` on `log/slog`; file output is off by default. The default handler is `mac.NewLogHandler`, which writes into **unified logging** — a Finder-launched app has no stderr, so anything else is invisible. Read it back with:

```bash
log show --last 10m --predicate 'subsystem == "com.pg.amm"' --style compact
```

slog `Info` maps to `OS_LOG_TYPE_DEFAULT`, **not** `OS_LOG_TYPE_INFO`: macOS does not retain the latter unless logging is turned up for the subsystem, so info records would silently never appear.

### Menu bar (`internal/mac/menubar.m`)

Every AppKit call funnels through `runOnMain` — menu items are built from a goroutine, and touching AppKit off the main thread crashes. `init()` in `menubar.go` calls `runtime.LockOSThread()` so `[NSApp run]` gets the process' first thread.

`[gMenu setAutoenablesItems:NO]` is load-bearing: without it AppKit re-decides enabled state at menu-display time and silently overrides `setEnabled:`, so Start/Stop stop greying out. A programmatic read-back of `isEnabled` cannot see this — it only shows up when a human opens the menu.

### Icons

`assets/icon/tray.*` (currently `tray.svg`) is embedded with `//go:embed tray.*`, so swapping the menu bar
icon means replacing that one file — PNG or SVG, both verified to load through
`NSImage initWithData:` and to rasterise. `amm_menubar_set_icon` flattens whatever it gets
into 1x and 2x `NSBitmapImageRep`s once, so AppKit never re-renders a 2397-command vector
path while the menu bar redraws. Keep exactly one `tray.*` file. The artwork
must stay **pure black plus alpha**: it is drawn as a template image
(`[image setTemplate:YES]` in `menubar.m`), so AppKit tints it from the alpha and
discards colour.

It need not be square. `amm_menubar_set_icon` scales to `AMM_ICON_HEIGHT` (16 pt) and
derives the width from the aspect ratio; the status item was created with
`NSVariableStatusItemLength` and widens to match. Measured: a 1:1 mark gives a 32x22 pt
item, 512x179 gives 62x22.

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

### Permissions and signing

The build ad-hoc signs the bundle (`codesign --force --sign -`): Apple Silicon refuses unsigned arm64 code, and the Go linker only signs the binary, not the `.app` macOS validates at launch. This is **not** notarisation — a downloaded build still needs its quarantine attribute cleared.

Both grants are pinned to the exact binary: **rebuilding invalidates Accessibility permission and the login item registration**, while System Settings still shows a ticked box. So after `make build`, expect moves to fail until amm is removed and re-added in Privacy & Security > Accessibility. Do not diagnose that as a code bug. For the same reason the bundle id stays `com.pg.amm` — renaming it would invalidate both again.

### cgo callbacks

`menubar_export.go` and `system_export.go` hold every `//export`ed function AppKit calls back into. They run **on the main thread**, so none of them may block: clicks are handed to a buffered `ClickedCh` with a `select`/`default`, and `onReady`/`onWake` are dispatched with `go`.

## Learnings

The stories are in [LEARNINGS.md](LEARNINGS.md); the rules distilled from them live in
`.claude/rules/` and load by path (`internal/mac/**`, `internal/mousemover/**`, build files) when
you read a matching file. A new finding goes to both places, always: story there, one-liner in the
matching rule file. The learnings already in this file stay where they are; nothing new is added here. `Sessions/` holds dated session summaries — what was decided, and
what was measured rather than assumed.
