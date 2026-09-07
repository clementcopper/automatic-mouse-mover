---
paths:
  - "Sources/AMMCore/**"
  - "Sources/amm-tests/**"
---

# Engine and tests (`Sources/AMMCore`, `Sources/amm-tests`)

Distilled from `LEARNINGS.md` § macOS, § The 1.6.0 field report and § Swift port. The `Platform` seam, the settle poll, the one-thread rule and the test harness are described in `CLAUDE.md`.

- **Posting a mouse event is asynchronous; never read the cursor back immediately.** That reported 20 of 20 moves as failed and drove the cursor one way. Poll the position until it changes, with a deadline (0 ms → 20/20 failed, 20 ms → 0/20).
- **A probe that needs a sleep tests the mechanism, not the code.** The throwaway test had 50 ms, the shipped check none; give the production path the same wait or the probe is meaningless.
- **Ask `AXIsProcessTrusted()` on the first failure.** Waiting out ten failures over five minutes and blaming the mouse told the user nothing.
- **Everything runs on the main thread; keep it that way.** Every state bug the Go version had (double start, blocked quit, an unlocked pointer read) came from a second thread that the domain never needed. A `Timer` cannot die, so nothing has to restart it either.
- **Verify a test by reintroducing the bug.** The 24-hour alert throttle was dead code for years; the Swift suite was proven against three mutants (no retry, no throttle, double start) and caught each.
- **Tests must not write into unified logging.** Logging is part of `Platform`, so the fake captures it; a real `Logger` in the engine would plant invented "cannot be moved" errors in the system log on every run.
- **`FakePlatform` has two permission axes on purpose:** `canMove` (does the event land) and `trusted` (`AXIsProcessTrusted`). A stale TCC grant is `trusted && !canMove`; do not collapse them.
- **The throttle must survive a Stop/Start.** `start()` resets the failure count only; replacing the whole state re-armed the alert on every restart in the Go version.
