// The engine's tests, as a plain executable: `swift run amm-tests` exits non-zero on
// any failure. No framework, because the Command Line Tools ship none, and none is
// needed: the engine is synchronous, so a test calls tick() and looks at the state.
import Foundation
@testable import AMMCore

/// Stands in for macOS. Models the real asynchrony (`moveDelay`) and the two
/// permission axes separately: `canMove` (does the event land) and `trusted`
/// (`AXIsProcessTrusted`). A stale TCC grant is exactly `trusted && !canMove`.
final class FakePlatform: Platform {
    var idle: Double = Mover.idleThreshold + 1
    /// false simulates a missing Accessibility permission: the position never
    /// changes, which is exactly how macOS behaves when it drops the event.
    var canMove = true
    var trusted = true
    /// Refuses to go past zero, the way macOS clamps a move at the edge of the
    /// screen: the event is accepted, the position simply does not change.
    var clampNegative = false
    /// The position only updates after the event has been delivered, not while
    /// moveMouse is still running.
    var moveDelay: TimeInterval = 0

    private let lock = NSLock()
    private var x = 0, y = 0
    private(set) var moveCount = 0
    private(set) var alertCount = 0
    private(set) var logs: [(LogLevel, String)] = []

    func accessibilityTrusted() -> Bool { trusted }
    func idleSeconds() -> Double { idle }

    func mousePos() -> (x: Int, y: Int) {
        lock.lock(); defer { lock.unlock() }
        return (x, y)
    }

    func moveMouse(x: Int, y: Int) {
        moveCount += 1
        guard canMove else { return }
        if clampNegative && (x < 0 || y < 0) { return }
        let land = {
            self.lock.lock(); defer { self.lock.unlock() }
            self.x = x; self.y = y
        }
        if moveDelay == 0 {
            land()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + moveDelay, execute: land)
        }
    }

    func alert(title: String, message: String) { alertCount += 1 }
    func log(_ level: LogLevel, _ message: String) { logs.append((level, message)) }
}

var failures = 0
var current = ""

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if !condition {
        failures += 1
        print("FAIL \(current) (line \(line)): \(message)")
    }
}

func test(_ name: String, _ body: (FakePlatform, Mover) -> Void) {
    current = name
    let before = failures
    let fake = FakePlatform()
    let mover = Mover(platform: fake)
    mover.moveSettleTimeout = 0.020 // keep the failure tests brisk
    body(fake, mover)
    mover.stop()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

test("start") { fake, mover in
    mover.start()
    check(mover.isRunning, "should be running")
    check(mover.timer != nil, "should have a timer")
}

test("activityLeavesCursorAlone") { fake, mover in
    fake.idle = Mover.idleThreshold - 1
    for _ in 0..<3 { mover.tick() }
    check(fake.moveCount == 0, "should not move while the user is active")
    check(mover.lastMouseMovedTime == nil, "no move time")
}

test("mouseMoveSuccess") { fake, mover in
    mover.tick()
    check(fake.moveCount == 1, "should have moved once, got \(fake.moveCount)")
    check(mover.lastMouseMovedTime != nil, "move time should be set")
    check(mover.didNotMoveCount == 0, "no failures")
}

// Guards the sign flip that keeps the cursor oscillating instead of drifting.
test("moveDirectionAlternates") { fake, mover in
    mover.tick()
    let first = fake.mousePos()
    mover.tick()
    let second = fake.mousePos()
    check(first.x != 0, "first move should go somewhere")
    check(second.x == 0 && second.y == 0, "second move should come back to the start, got \(second)")
}

test("mouseMoveFailure") { fake, mover in
    fake.canMove = false
    mover.tick()
    check(mover.lastMouseMovedTime == nil, "no move time")
    check(mover.didNotMoveCount == 1, "should have counted a failure")
    check(fake.moveCount == 2, "both directions should have been tried, got \(fake.moveCount)")
}

// Guards the CGEventPost race: the position only updates once the posted event has
// been delivered, so reading it back immediately reported every move as failed.
test("moveIsNotJudgedTooEarly") { fake, mover in
    fake.moveDelay = 0.005
    mover.tick()
    check(mover.didNotMoveCount == 0, "a delayed move is still a successful move")
    check(mover.lastMouseMovedTime != nil, "move time should be set")
    check(fake.alertCount == 0, "no alert for a move that worked")
}

// The case that bit in the field: the Accessibility box still looked ticked, but the
// grant was pinned to an older build. Waiting out ten failures before saying anything
// sent the user looking in the wrong place for five minutes.
test("untrustedAlertsImmediately") { fake, mover in
    fake.canMove = false
    fake.trusted = false
    mover.tick()
    check(mover.didNotMoveCount == 1, "one failure so far")
    check(fake.alertCount == 1, "should alert on the first failure when not trusted")
}

test("trustedStillWaitsForThreshold") { fake, mover in
    fake.canMove = false
    for _ in 0..<(Mover.failuresBeforeAlert - 1) { mover.tick() }
    check(mover.didNotMoveCount == Mover.failuresBeforeAlert - 1, "just below the threshold")
    check(fake.alertCount == 0, "no alert before the threshold when trusted")
}

// The wake path: look at the idle time straight away rather than sitting out a tick.
test("checkNowMovesWithoutWaitingForTick") { fake, mover in
    mover.start()
    mover.checkNow()
    check(fake.moveCount == 1, "a kick should move without a tick")
}

// A wake must not revive a mover the user stopped.
test("checkNowIsIgnoredWhenStopped") { fake, mover in
    mover.start()
    mover.stop()
    mover.checkNow()
    check(fake.moveCount == 0, "a stopped mover must stay put")
    check(!mover.isRunning, "should report stopped")
}

// Waking the Mac by touching the keyboard must not move the cursor.
test("checkNowRespectsActivity") { fake, mover in
    fake.idle = Mover.idleThreshold - 1
    mover.start()
    mover.checkNow()
    check(fake.moveCount == 0, "should not move while the user is active")
}

// The 24-hour window. It used to compare against a timestamp set three lines above
// the check, so the alert never showed; and it must survive a Stop/Start.
test("alertThrottle") { fake, mover in
    var clock = Date()
    mover.now = { clock }
    fake.canMove = false
    for _ in 0..<Mover.failuresBeforeAlert { mover.tick() }
    check(fake.alertCount == 1, "alert should have fired at the threshold, got \(fake.alertCount)")
    let firstAlert = mover.lastAlertTime
    check(firstAlert != nil, "alert time should be set")

    for _ in 0..<Mover.failuresBeforeAlert { mover.tick() }
    check(fake.alertCount == 1, "alert should only fire once per 24 hours")
    check(mover.lastAlertTime == firstAlert, "alert time should not move")

    mover.stop()
    mover.start()
    check(mover.didNotMoveCount == 0, "start resets the failure count")
    for _ in 0..<Mover.failuresBeforeAlert { mover.tick() }
    check(fake.alertCount == 1, "a restart must not re-arm the alert")

    clock = clock.addingTimeInterval(Mover.alertInterval + 1)
    mover.tick()
    check(fake.alertCount == 2, "after 24 hours the alert may fire again")
}

// The menu and the wake path both call start; a second call must not start a second
// timer.
test("doubleStartRunsOneTimer") { fake, mover in
    mover.start()
    let timer = mover.timer
    mover.start()
    check(mover.timer === timer, "a second start must keep the first timer")
    mover.stop()
    check(!mover.isRunning && mover.timer == nil, "stop must leave nothing behind")
    check(timer?.isValid == false, "the timer must be invalidated")
}

test("restartAfterStop") { fake, mover in
    mover.start()
    mover.stop()
    mover.start()
    check(mover.isRunning, "should be running again")
    check(mover.timer?.isValid == true, "should have a live timer")
}

// The cursor parked in a screen corner: macOS clamps the move, the position does not
// change and the move looks dropped. Try the other way before believing that.
test("clampedCursorTriesTheOtherDirection") { fake, mover in
    fake.clampNegative = true
    check(mover.moveAndCheck(-10), "a clamped move must be retried the other way")
    check(fake.mousePos().x == 10, "the retry should have moved away from the edge")
}

// Keeps the retry from papering over a genuinely missing permission.
test("droppedEventStillFails") { fake, mover in
    fake.canMove = false
    fake.trusted = false
    check(!mover.moveAndCheck(10), "a dropped event is still a failure")
    check(fake.moveCount == 2, "both directions should have been tried")
}

test("engineNeverLogsOnItsOwn") { fake, mover in
    fake.canMove = false
    mover.tick()
    check(fake.logs.contains { $0.0 == .error }, "a failed move is logged through the platform")
}

print(failures == 0 ? "PASS" : "FAIL: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
