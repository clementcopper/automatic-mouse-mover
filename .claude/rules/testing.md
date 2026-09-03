---
paths:
  - "internal/mousemover/**"
---

# Engine and tests (`internal/mousemover`)

Distilled from `LEARNINGS.md` § Testing and § The 1.6.0 field report. The `platform` seam, the settle poll, the `Start`/`Quit`/`CheckNow` mutex and the closed `quit` channel are described in `CLAUDE.md`.

- **`CGEventPost` is asynchronous; never read the cursor back immediately.** That reported 20 of 20 moves as failed and drove the cursor one way. Poll the position until it changes, with a deadline (0 ms → 20/20 failed, 20 ms → 0/20).
- **A probe that needs a sleep tests the mechanism, not the code.** The throwaway test had 50 ms, the shipped check none; give the production path the same wait or the probe is meaningless.
- **Ask `AXIsProcessTrusted()` on the first failure.** Waiting out ten failures over five minutes and blaming the mouse told the user nothing.
- **A package-level var that tests reassign is a data race.** `SetupTest` wrote the logger while a previous test's loop goroutine read it; set a per-instance field before `run()` starts.
- **Tests must not write into unified logging.** With the os_log handler as default, every run planted fake "cannot be moved" errors; verify with `log stream` on the subsystem: 0 records.
- **A fixed `time.Sleep` waiting for a goroutine is a latent flake.** Under `-race` the loop started after the window; poll for the state with a deadline.
- **Verify a test by reintroducing the bug.** The 24-hour alert throttle was dead code for years (`lastErrorTime` set three lines above the check); `TestSuite/TestAlertThrottle` was proven by watching it fail on the old condition.
- **Assert that a scripted replace matched before writing back.** `gofmt` had normalised `//TestAlertThrottle` to `// TestAlertThrottle`, the replace matched nothing and the run said "no tests to run" instead of failing.
- **Two hangs were found by reading, not by reproduction.** The wake callback drives `Start`/`Quit` from its own goroutine next to the menu loop; a flag set inside the loop goroutine let a second `Start` open a second loop, and a send on an unbuffered `quit` blocked for ever. Every state change that gates a goroutine must happen before the goroutine is spawned, and shutdown must close, never send.
- **`fakePlatform` has two permission axes on purpose:** `canMove` (does the event land) and `trusted` (`AXIsProcessTrusted`). A stale TCC grant is `trusted && !canMove`; do not collapse them.
