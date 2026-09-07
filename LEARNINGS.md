# LEARNINGS.md

Tool quirks, platform traps and dead ends for this repo. Linked from [CLAUDE.md](CLAUDE.md).
The Go era (v1.0 to v1.6.1) and its own learnings live on branch `go`.

## Swift port (v2.0, 2026-09-07)

The Go version worked — 0 errors in 3 days of log, 17 s CPU in 5.7 days — but ~620 of its
1595 production lines existed only to marry Go's runtime to AppKit: cgo wrappers, headers,
exported callbacks, a main-thread trampoline, and in the engine a mutex, three channels and
a state struct behind a read-write lock. Both 1.6.1 hangs and the last data race (an
unlocked state pointer read from the wake callback) lived in those lines. The app uses
nothing a Go runtime offers — even its logger was bridged back into `os_log` — so it was
ported to ~450 lines of Swift that run on one thread.

- **Spike before port, with abort criteria written down first.** Build on the Intel with
  the Command Line Tools only, universal, `minos 13.0`, signed, launches, logs, and the
  move path reaches `AXIsProcessTrusted`. All passed within the hour (197 KB binary,
  `move failed settleMs=419 accessibilityTrusted=false` in the log, exactly the expected
  refusal without a TCC grant). The cursor moved after the grant: `moved mouse` 90 s
  after the first start from `/Applications`.
- **`swift build --arch arm64 --arch x86_64` fails on the Command Line Tools** with
  "xcbuild executable … does not exist". `--triple arm64-apple-macosx13.0` and the x86_64
  twin work, one build each, then `lipo`; the products sit in
  `.build/arm64-apple-macosx/release/` (the triple without its version). ~75 s per
  architecture cold, seconds warm.
- **No XCTest, no swift-testing in the Command Line Tools** (`xcrun --find xctest`: "not a
  developer tool"). The tests are a plain executable target with `check(cond, msg)` and
  an exit code, `@testable import` of the engine in the debug build. 17 tests in 0.1 s
  against 11.5 s for the Go suite, because the engine is synchronous and nothing sleeps.
- **`Logger.info` is `OS_LOG_TYPE_INFO`, the level macOS does not persist.** `Logger.notice`
  is `DEFAULT` and stays. Every interpolation needs `privacy: .public` or it shows as
  `<private>`.
- **The tests were proven against mutants, not just seen green.** Removing the second
  `tryMove` direction, the 24-hour throttle, and the double-start guard each failed the
  suite (4, 3 and 2 checks).
- **The wake restart branch was dead in Swift and is gone.** It existed because a Go loop
  goroutine could be gone while the flag still said running; a `Timer` cannot die, so a
  stopped mover is always one the user stopped.
- **Cadence is 60 to 90 s, not 60.** Counted from 748 moves over 3 days of log: 138
  intervals of 60–70 s, 507 of 70–100 s. The move resets the idle timer a few ms after
  the tick, so the 60 s tick reads 59.99 and skips. Documented instead of "fixed".
- **A log line does not need its own timestamp.** `moved mouse at=…` printed UTC next to
  the record's local timestamp; dropped.
- **A `Timer.scheduledTimer` is silent while a dialog is up or the status menu is open.**
  It lives in the run loop's default mode; `runModal` and menu tracking run other modes.
  A user leaving About open and walking away would have had no moves until OK — the Go
  loop on its own thread never had that problem. Measured with a probe: over one second
  of `runModal`, 0 of 3 due fires in the default mode, 3 of 3 with the timer added via
  `RunLoop.main.add(_, forMode: .common)`. Found on the second read-through, one day
  after the port; no test can see it because the tests never spin a run loop.
- **`imagePosition = .imageOnly` hides the fallback title.** With no `tray.*` in the
  bundle (`make start`) the status item drew nothing at all. Set the position after
  deciding whether there is an image.

## macOS

- **Ad-hoc signing gets you onto Apple Silicon, but not past Gatekeeper.** A downloaded
  build is quarantined, and without notarisation macOS 15+ refuses it with *"Apple could
  not verify … is free of malware"*. `spctl -a -vv` says `rejected` even on a bundle whose
  signature verifies cleanly per architecture. `xattr -cr` does clear it — measured: 9
  quarantined files inside the bundle, 0 afterwards, signature still valid — but only if
  it runs **before** the first launch. Right-click → Open stopped working as a bypass in
  macOS 15; the GUI route is now System Settings → Privacy & Security → *Open Anyway*.
  Install instructions written for the terminal alone will fail for anyone using Finder.
- **A Finder-launched app has no stderr.** Verified: nothing written there ever showed up
  anywhere. Unified logging through `os_log` is the only place the app's own output can
  be read back.
- **`log show` returned nothing three times in a row, and the app was logging fine.** In a
  non-interactive zsh — the shell behind Claude's Bash tool — `log` is a builtin ("too
  many arguments"), and the `2>/dev/null` on the query turned that into an empty result
  indistinguishable from "no records". Seen 2026-09-07 while checking whether the running
  1.6.0 logged at all; `/usr/bin/log` found 763 records in 3 days. Spell the path out
  wherever the command is scripted, and never hide stderr on a diagnostic query.
- **Posting a mouse event vs. warping the cursor.** `CGEvent(mouseEventSource:…)` plus
  `post(tap: .cghidEventTap)` posts a real HID event and **resets the system idle
  timer** — that is the whole wake-keeping mechanism. `CGWarpMouseCursorPosition` would
  move the pointer without resetting it and would silently break the app. Verified
  empirically: idle went from 644 s to 0.03 s across one self-posted move.
- **Posting is asynchronous, and reading the cursor back immediately is a bug.** The first
  version read the position straight after posting and reported **20 out of 20 moves as
  failed** on real hardware, driving the failure count to the alert threshold while the
  mouse was in fact moving fine. Because the direction only flips on success, the cursor
  also drifted one way instead of oscillating. Poll the position until it changes, with a
  deadline. Measured failure rate by pause length: 0 ms → 20/20, 1 ms → 1/20, 5 ms → 1/20,
  20 ms → 0/20.
- **A probe that needs a sleep tests the mechanism, not the code.** The scratch program
  had a 50 ms sleep and passed; the shipped check had none. If a probe needs a wait, the
  production path needs the same wait — or the probe is testing something the code does
  not do.
- **A cursor in a screen corner failed for ever.** macOS clamps the move to the edge, the
  position does not change, and that is indistinguishable from a dropped event. Since the
  direction only flips after a success, the mover kept pushing into the same corner and
  eventually blamed the Accessibility permission. It tries the opposite direction before
  reporting failure.
- **No sleep detection on purpose.** A sleeping Mac runs no code, so the case handles
  itself; and in clamshell mode (external power + display) AMM is supposed to keep
  working, which a `CGDisplayIsAsleep` guard would have broken. Lid-close sleep without an
  external display cannot be prevented by any user-space program — not even an
  `IOPMAssertion`, which only blocks *idle* sleep.
- **The menu bar icon is a template image, and that is the whole dark-mode story.**
  `isTemplate = true` makes AppKit tint the artwork from its alpha channel. It beats a
  second white asset plus an appearance observer on two counts a manual switch gets
  wrong: the menu bar tinted dark by the wallpaper while `AppleInterfaceStyle` still
  reports "light", and the open-menu state where the icon must invert against the blue
  highlight. Any replacement icon has to stay pure black plus alpha.
- **Measure the asset before designing around it.** The tray icon was "coloured" by
  assumption; reading `PLTE` and `tRNS` out of the PNG showed pure black plus an alpha
  ramp, and a planned second asset plus switching mechanism collapsed into one line.
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
- **`SMAppService` status `.notFound` just means "never registered".** It is not an error
  and not a sign that the bundle is wrong. Measured round trip from `/Applications`:
  `.notFound` before the first call, `.enabled` after `register`, `.notRegistered` after
  `unregister`. Ad-hoc signing is enough — the header only demands a signature,
  notarisation is for LaunchDaemons.
- **A login item has to be registered again after every rebuild.** Same class as the TCC
  grant: *"If an app updates either the plist or the executable ... the SMAppService must
  be re-registered or it may not launch."*
- **A menu bar icon does not have to be square** — that was our constraint, not the
  system's. Scaling to a fixed height with the width derived from the aspect ratio works
  because the status item uses `variableLength`. Measured item sizes: 1:1 gives 32x22 pt,
  2:1 gives 48x22, 512x179 gives 62x22. The menu bar itself is 22 pt.
- **`menu.autoenablesItems = false` is load-bearing.** Otherwise AppKit re-decides each
  item's enabled state at menu-display time via `validateMenuItem:` and overrides
  `isEnabled`. A programmatic read-back cannot verify that: it returns the stored value,
  and the auto-enable pass only runs when a human opens the menu. Greying out is a hand
  check — confirmed by eye on 2026-08-26.
- **A modal alert shown from a background thread parks that thread for ever.** As an
  accessory app AMM never comes forward, so the dialog sat unseen behind everything.
  Alerts go through `NSAlert` on the main queue via `DispatchQueue.main.async` plus
  `activate(ignoringOtherApps:)`, one at a time.
- **Accessibility queries against a status-bar menu are unreliable.** `System Events`
  could read the menu structure once and then kept returning "invalid index" — the AX
  tree only materialises the menu when it is opened. Fine for checking that the status
  item and its item titles exist, useless for state.

## Build

- **Nothing on a stock Mac rasterises SVG for icon work — except AppKit.** `sips` cannot
  open an SVG at all (it prints the paths and writes nothing), and rsvg-convert, inkscape
  and cairosvg are not installed. `NSImage(contentsOf:)` reads SVG on macOS 13, so
  `mkicons` draws through `NSBitmapImageRep` instead of pulling in a converter. Verified
  end to end: `#1d6fe0` in, `(29,111,224,255)` out.
- `iconutil` wants exactly ten files named `icon_16x16.png` … `icon_512x512@2x.png`; any
  other name and it refuses the folder with "Failed to generate ICNS".
- **Ad-hoc sign the bundle, not just the binary.** Apple Silicon refuses to run unsigned
  arm64 code, and the bundle is what macOS validates at launch. `codesign --verify` names
  the gap exactly: *code has no resources but signature indicates they must be present*.
  `codesign --force --sign - ./bin/amm.app` in the Makefile fixes it; both slices survive.
- **The triple carries the deployment target.** Without it a binary's `minos` is the build
  host's macOS, and a bundle built on a newer Mac will not run on an older one. Check with
  `otool -l <binary> | grep -A3 LC_BUILD_VERSION`.

## The 1.6.0 field report: unresponsive with high CPU

A user on an M4 Pro installed the 1.6.0 release, with Accessibility granted, and found
`amm` unresponsive and burning CPU; only Activity Monitor got rid of it. No sample, no
spindump, no log.

- **The obvious suspect did not hold up.** The menu bar artwork is an SVG with one path of
  2397 commands, handed to the status item as a vector `NSImage`. Measured on two other
  machines instead: 19 s of CPU in 4 days 7 hours (M2, macOS 26.3.1) and 17 s in 5 days
  16 hours (Intel, macOS 13.7.8). Whatever AppKit does with that path, it is not
  re-rasterising it per frame.
- **Two real hangs were found by reading, both in the Go version's threading**: a second
  `Start` from the wake callback could open a second loop, and a `Quit` with no loop
  listening blocked the menu for good — an app that still draws its menu but ignores
  every click, which is exactly what "reagierte nicht mehr" looks like. The Swift port
  has no second thread to race.
- **What is still unexplained is the CPU.** If it happens again, the decisive artefacts
  are `sample amm 10`, a spindump, and
  `/usr/bin/log show --predicate 'subsystem == "com.pg.amm"'` — the app logs version,
  architecture and macOS build on startup so a foreign report can be pinned to a build.

## Rule files and the two-Mac workflow

- **A path-scoped rule loads where the code lives, not where the API it names is wrapped.**
  The first cut of `.claude/rules/native.md` carried the settle-poll and
  `AXIsProcessTrusted` rules under the native layer's path because they mention
  CoreGraphics symbols; the code they guard is the engine. A session simplifying the
  engine would never have seen them. Caught by `/code-review` on 2026-09-03; they live in
  `testing.md` now. When writing a rule, `grep` for the symbol it protects and scope to
  that directory.
- **Two Macs push the same branch.** On 2026-09-03 the Intel side was one commit ahead and
  five behind (the M2 session had shipped 1.6.1). A plain "sync" cannot resolve that; fetch
  and rebase before committing.
