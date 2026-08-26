# LEARNINGS.md

Tool quirks, dependency traps and dead ends for this repo. Linked from [CLAUDE.md](CLAUDE.md).

## Why there are no dependencies any more

AMM used to pull robotgo, activity-tracker, mac-sleep-notifier and systray — 43 indirect
modules, 7.7 MB per architecture. All of it existed to answer one question and paint one
menu. Both turned out to be a handful of lines of CoreGraphics and AppKit, now in
`internal/mac`. Result: 3.3 MB, `go.mod` with testify and nothing else.

- **One call replaced four polling handlers.** `activity-tracker` ran a cursor poller, a
  gohook event tap, a window-title read through the accessibility API and an IOKit sleep
  notifier, all to decide "was there user activity?". macOS answers that directly with
  `CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType)`
  — since 10.4, no permission needed. Before adding a library, check whether the platform
  already exposes the thing.
- **`getlantern/systray` cost 4.2 MB because of one line.** `log = golog.LoggerFor("systray")`
  drags in OpenTelemetry, zap and go-logr. Its darwin implementation is 546 lines total.
  Measure what a dependency actually links before assuming it is small.
- **Measure dependency weight with an A/B build, not with `go tool nm`.** Symbol sizes
  summed to 38 MB for a 7.7 MB binary — useless. Building a minimal program per import
  and diffing binary sizes gave usable numbers.
- **go.mod's indirect list overstates things.** 43 entries, but only ~20 module trees
  compiled on darwin: the X11, Windows and OCR entries are graph-only and link nothing.
  Check with `go list -deps ./cmd/...`, not by counting go.mod lines.

## macOS

- **`CGEventPost` vs. warping the cursor.** `CGEventCreateMouseEvent` +
  `CGEventPost(kCGHIDEventTap, …)` posts a real HID event and **resets the system idle
  timer** — that is the whole wake-keeping mechanism. `CGWarpMouseCursorPosition` would
  move the pointer without resetting it and would silently break the app. Verified
  empirically: idle went from 644 s to 0.03 s across one self-posted move.
- **`CGEventPost` is asynchronous, and reading the cursor back immediately is a bug.**
  `moveAndCheck` read the position straight after posting the move and reported **20 out
  of 20 moves as failed** on real hardware, driving `didNotMoveCount` to the alert
  threshold while the mouse was in fact moving fine. Because `movePixel` only flips sign
  on success, the cursor also drifted in one direction instead of oscillating. Poll the
  position until it changes, with a deadline. Measured failure rate by pause length:
  0 ms → 20/20, 1 ms → 1/20, 5 ms → 1/20, 20 ms → 0/20.
- **I verified the move with a 50 ms sleep in the throwaway test and shipped the check
  without one.** The scratch program proved the mechanism, not the code. If a probe needs
  a sleep to pass, the production path needs the same wait — or the probe is testing
  something the code does not do.
- **No sleep detection on purpose.** A sleeping Mac runs no goroutines, so the case
  handles itself; and in clamshell mode (external power + display) AMM is supposed to
  keep working, which a `CGDisplayIsAsleep` guard would have broken. Lid-close sleep
  without an external display cannot be prevented by any user-space program — not even
  an `IOPMAssertion`, which only blocks *idle* sleep.
- **The menu bar icon is a template image, and that is the whole dark-mode story.**
  `[image setTemplate:YES]` makes AppKit tint the artwork from its alpha channel. It
  beats a second white asset plus an appearance observer on two counts a manual switch
  gets wrong: the menu bar tinted dark by the wallpaper while `AppleInterfaceStyle` still
  reports "light", and the open-menu state where the icon must invert against the blue
  highlight. Any replacement icon has to stay pure black plus alpha. Confirmed by eye on
  2026-08-26: the cloud follows a light/dark switch live, without restarting the app.
- **I claimed the icon was coloured instead of measuring it, and planned a second asset
  plus a switching mechanism off that.** Reading `PLTE` and `tRNS` straight out of the
  PNG showed all 218 palette entries but index 0 are exactly `RGB(0,0,0)`, index 0 being
  fully transparent white, with the 217 alpha values just anti-aliasing. The measurement
  turned the job into one line. Measure the asset before designing around it.
- **A ticked Accessibility box can still be a denied one.** TCC pins the grant to a code
  signing requirement, and for an ad-hoc signed app that requirement is the binary's
  cdhash — so every rebuild invalidates it while System Settings keeps showing the app as
  allowed. Diagnose it, don't guess:

  ```sh
  sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
    "select hex(csreq) from access where service='kTCCServiceAccessibility' and client='com.pg.amm';" \
    | xxd -r -p > /tmp/amm.csreq
  csreq -r /tmp/amm.csreq -t                          # prints cdhash H"..."
  codesign --verify -R /tmp/amm.csreq /Applications/amm.app
  ```

  The fix for the user is to remove the entry with the minus button and add it again;
  toggling the checkbox does not refresh the stored requirement. A Developer ID signature
  would pin the team identifier instead and survive rebuilds.
- **Ask `AXIsProcessTrusted()` instead of inferring permission from failed moves.** The
  app used to wait out ten failures over five minutes and then blame the mouse. It now
  says what is actually wrong on the first failure.
- **`[menu setAutoenablesItems:NO]` is load-bearing.** Otherwise AppKit re-decides each
  item's enabled state at menu-display time via `validateMenuItem:` and overrides
  `setEnabled:`.
- **A programmatic `isEnabled` read-back cannot verify that.** It returns the stored
  value, and the auto-enable pass only runs when a human opens the menu — the
  counter-test without the guard looked identical. Greying out is a hand check, full
  stop — confirmed by eye on 2026-08-26, Start and Stop grey each other out correctly.
- **AppKit calls must be marshalled to the main thread** (`runOnMain` in `menubar.m`),
  and `runtime.LockOSThread()` belongs in `init()` so `[NSApp run]` gets thread 0.
- **`[NSApp stop:]` needs a following event** or the run loop keeps blocking; post a
  dummy `NSEventTypeApplicationDefined`.
- **Accessibility queries against a status-bar menu are unreliable.** `System Events`
  could read the menu structure once and then kept returning "invalid index" — the AX
  tree only materialises the menu when it is opened. Fine for checking that the status
  item and its item titles exist, useless for state.

## Historic: the SIGILL crashes (fixed by deleting the code path)

Upstream #63/#64 were an uninitialized struct in robotgo: `get_active()` declared
`MData result;` and returned it unchanged when `GetFrontProcess()` failed, which happens
exactly when there is no front process — lid closed, screen locked, login window. The
garbage pointer then reached `AXUIElementCopyAttributeValue` and CoreFoundation
`HALT`ed (`UD2` = SIGILL). Fixed upstream in **robotgo v1.0.1** (`MData result = {0}`);
`v0.110.8`, which the Resousse fork moved to, does **not** have the fix despite being
newer in time than `v1.0.0-rc2.1`. Moot now — nothing calls `GetTitle()` any more.

Two lessons worth keeping:

- **SIGILL out of cgo is a hard trap, not a Go panic.** `recover()` does nothing.
- **Version numbers do not sort chronologically.** robotgo's `v0.110.8` (May 2025) is
  newer than `v1.0.0-rc2.1` (Sept 2023). Grep for the actual fix before believing a bump
  helped.

## Build

- Cross-compiling cgo works in **both** directions with plain Command Line Tools, no
  full Xcode: `CGO_ENABLED=1 GOARCH=arm64 CGO_CFLAGS="-arch arm64" CGO_LDFLAGS="-arch arm64"`
  and the x86_64 equivalent. Confirmed on an Intel host and on an M2. `make build` does
  both arches plus `lipo` and prints `lipo -archs`, so the result is verified rather than
  assumed.
- **A binary's `minos` is the build host's macOS version**, since no minimum deployment
  target is set. A bundle built on a newer Mac will not run on an older one — check with
  `otool -l <binary> | grep -A3 LC_BUILD_VERSION`. Build releases on the oldest system
  you intend to support, or set `-mmacosx-version-min`.
- **Ad-hoc sign the bundle, not just the binary.** Apple Silicon refuses to run unsigned
  arm64 code. The Go linker already signs the arm64 slice (`adhoc, linker-signed`) and
  `lipo` preserves it, but the surrounding `.app` stays unsigned — and the bundle is what
  macOS validates at launch. `codesign --verify` names it exactly: *code has no resources
  but signature indicates they must be present*. `codesign --force --sign - ./bin/amm.app`
  in the Makefile fixes it; both slices survive. This is not notarisation, so a copy that
  travelled through a download still needs `xattr -cr`.
- `-mmacosx-version-min` used to be forbidden here because robotgo switched screen
  capture backends on it. robotgo is gone; a minimum deployment target could now be set
  if releases need to run on older macOS than the build host.

## Testing

- The `platform` interface in `pkg/mousemover/types.go` is the only test seam. Tests
  substitute `fakePlatform` and drive `run()` with their own tick channel, so they touch
  no cgo, no cursor and pop no dialog.
- **The 24-hour alert throttle was dead code for years.** It compared against
  `lastErrorTime`, which was set to `time.Now()` three lines above the check, so the
  condition was never true and the accessibility alert in the README never appeared.
  `TestSuite/TestAlertThrottle` covers it, and was verified by reintroducing the old
  condition and watching the test fail.
- The repo has never been `gofmt`-clean under modern Go (old `//comment` style without a
  space). Match the surrounding style; a repo-wide `gofmt -w` would bury real changes.
