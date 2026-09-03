---
paths:
  - "internal/mac/**"
---

# Native layer (`internal/mac`, cgo, AppKit, CoreGraphics)

Distilled from `LEARNINGS.md` § macOS, § Historic SIGILL and § The 1.6.0 field report. Stories there; template icon, `CGEventPost` vs warp, no sleep detection, `runOnMain`, `setAutoenablesItems`, `OS_LOG_TYPE_DEFAULT`, the non-blocking `Alert` and the two-direction move are already in `CLAUDE.md`.

- **A ticked Accessibility box can still be a denied one.** TCC pins the grant to the ad-hoc binary's cdhash, so every rebuild invalidates it while System Settings shows "allowed". Diagnose with the `sqlite3`/`csreq` recipe in `LEARNINGS.md`; the user fix is remove and re-add the entry, not toggling.
- **A login item must be re-registered after every rebuild;** `SMAppService` status 3 (`NotFound`) only means "never registered", not an error. Ad-hoc signing is enough.
- **`os_log` redacts `%s` as `<private>`;** the format must be `%{public}s` or the log shows nothing useful.
- **`[NSApp stop:]` needs a following event** (`NSEventTypeApplicationDefined`) or the run loop keeps blocking.
- **Accessibility queries against a status-bar menu are unreliable.** The AX tree materialises the menu only when opened; fine for existence checks, useless for state. Greying out is a hand check.
- **Measure the asset before designing around it.** Reading `PLTE`/`tRNS` showed the tray PNG was pure black plus alpha; the planned second asset and switching mechanism collapsed into one line.
- **SIGILL out of cgo is a hard trap, `recover()` does nothing.** And version numbers do not sort chronologically: robotgo `v0.110.8` is newer than `v1.0.0-rc2.1`; grep for the fix before believing a bump.
- **`CFUserNotificationDisplayAlert(0.0, …)` never expires.** As an accessory app AMM never comes forward, so the dialog sat unseen behind everything and parked its goroutine for ever. Alerts go through `NSAlert` on the main thread via `dispatch_async` plus `activateIgnoringOtherApps:`.
- **The vector menu bar icon was not the CPU hog.** Measured: 19 s CPU in 4 days on an M2 with the SVG `NSImage`. It is flattened to 1x/2x bitmaps at load as a precaution, not as a fix with evidence.
- **An "unresponsive, high CPU" report needs artefacts before a cause.** Ask for `sample amm 10`, a spindump and `log show --predicate 'subsystem == "com.pg.amm"'`; the app logs version, architecture and macOS build on startup so a report can be pinned to a build.
