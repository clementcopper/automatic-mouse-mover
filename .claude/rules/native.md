---
paths:
  - "Sources/amm/**"
---

# Native layer (`Sources/amm`, AppKit, CoreGraphics, os.Logger)

Distilled from `LEARNINGS.md` § macOS, § The 1.6.0 field report and § Swift port. Stories there; template icon, `CGEventPost` vs warp, no sleep detection, `autoenablesItems`, `Logger.notice`, the non-blocking alert and the one-thread rule are already in `CLAUDE.md`.

- **A ticked Accessibility box can still be a denied one.** TCC pins the grant to the ad-hoc binary's cdhash, so every rebuild invalidates it while System Settings shows "allowed". Diagnose with the `sqlite3`/`csreq` recipe in `LEARNINGS.md`; the user fix is remove and re-add the entry, not toggling.
- **A login item must be re-registered after every rebuild;** `SMAppService` status `.notFound` only means "never registered", not an error. Ad-hoc signing is enough.
- **Write `/usr/bin/log show`, never `log show`, in anything scripted.** In a non-interactive zsh `log` is a builtin; with `2>/dev/null` the failure reads as "no records" (three empty queries on 2026-09-07 before the cause showed).
- **`Logger.info` is not persisted; use `.notice` for anything that must be readable later,** and `privacy: .public` on every interpolation or it shows as `<private>`.
- **`kCGAnyInputEventType` is `CGEventType(rawValue: ~0)!`.** Swift imports the enum without validating raw values; the unwrap is safe.
- **Accessibility queries against a status-bar menu are unreliable.** The AX tree materialises the menu only when opened; fine for existence checks, useless for state. Greying out is a hand check.
- **Measure the asset before designing around it.** Reading `PLTE`/`tRNS` showed the tray PNG was pure black plus alpha; the planned second asset and switching mechanism collapsed into one line.
- **A modal alert from a background thread parks that thread for ever.** As an accessory app AMM never comes forward, so the dialog sat unseen behind everything. Alerts go through `NSAlert` on the main queue via `DispatchQueue.main.async` plus `activate(ignoringOtherApps:)`, one at a time.
- **The vector menu bar icon was not the CPU hog.** Measured: 19 s CPU in 4 days on an M2, 17 s in 5.7 days on the Intel, both with the SVG `NSImage`. Do not add flattening without a new measurement.
- **An "unresponsive, high CPU" report needs artefacts before a cause.** Ask for `sample amm 10`, a spindump and `/usr/bin/log show --predicate 'subsystem == "com.pg.amm"'`; the app logs version, architecture and macOS build on startup so a report can be pinned to a build.
