import Foundation

/// Everything the engine needs from macOS. `MacPlatform` in the app implements it for
/// real; the tests substitute a fake, so they touch no cursor and pop no dialog.
public protocol Platform {
    /// Whether macOS lets this process post input events (`AXIsProcessTrusted`).
    func accessibilityTrusted() -> Bool
    /// Seconds since the last keyboard, mouse or tablet event.
    func idleSeconds() -> Double
    func mousePos() -> (x: Int, y: Int)
    /// Posts a mouse-moved event. Asynchronous on the real system: the position
    /// updates only once the event has been delivered.
    func moveMouse(x: Int, y: Int)
    /// Must return at once; the real dialog is put up on the next run loop pass.
    func alert(title: String, message: String)
    func log(_ level: LogLevel, _ message: String)
}

public enum LogLevel {
    case debug, info, error
}

/// Keeps the Mac awake by nudging the cursor once the machine has been idle for a
/// while. Everything runs on the main thread: a `Timer` calls `tick`, and so do the
/// menu and the wake notification. There is no shared state and no lock, and nothing
/// here may be called from another thread.
public final class Mover {
    /// How often the idle time is looked at.
    public static let checkInterval: TimeInterval = 30
    /// How long the machine has to be idle before the cursor is nudged.
    public static let idleThreshold: TimeInterval = 60
    /// Failed moves before the diagnostic alert, when Accessibility looks fine.
    public static let failuresBeforeAlert = 10
    /// How often the cursor position is re-read while waiting for a move to land.
    public static let moveSettleInterval: TimeInterval = 0.010
    /// One alert per this much time, however often the move keeps failing.
    public static let alertInterval: TimeInterval = 24 * 60 * 60

    /// How long to wait for a posted move to take effect before calling it a failure.
    /// A variable so the tests do not have to sit out the real budget.
    public var moveSettleTimeout: TimeInterval = 0.200
    /// The clock, injectable so a test can move it past the alert interval.
    public var now: () -> Date = Date.init

    public private(set) var isRunning = false
    public private(set) var lastMouseMovedTime: Date?
    public private(set) var lastAlertTime: Date?
    public private(set) var didNotMoveCount = 0

    let platform: Platform
    var timer: Timer?
    var movePixel = 10

    public init(platform: Platform) {
        self.platform = platform
    }

    /// Starts the timer. A second call while running does nothing.
    public func start() {
        if isRunning { return }
        isRunning = true
        didNotMoveCount = 0
        platform.log(.info, "starting mouse mover")
        let t = Timer(timeInterval: Mover.checkInterval, repeats: true) { [weak self] _ in self?.tick() }
        // Let macOS batch the wake-up with other timers; the tick may land up to this
        // much late, which the 30 s grid does not notice.
        t.tolerance = 5
        // .common, not the default mode: a default-mode timer does not fire while a
        // dialog is up (runModal) or the status menu is open (event tracking), so a
        // user who leaves About open and walks away would get no moves.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the timer. Safe to call twice.
    public func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        platform.log(.info, "stopping mouse mover")
    }

    /// One iteration: nudge the cursor unless the user is active. The timer calls it,
    /// the wake handler calls it to skip the wait for the next tick, and the tests
    /// drive it directly.
    public func tick() {
        let idle = platform.idleSeconds()
        if idle < Mover.idleThreshold {
            platform.log(.debug, "activity detected, leaving the cursor alone idleSeconds=\(idle)")
            return
        }

        guard moveAndCheck(movePixel) else {
            reportFailedMove()
            return
        }

        lastMouseMovedTime = now()
        didNotMoveCount = 0
        // Flip the direction so the cursor oscillates instead of drifting off screen.
        movePixel = -movePixel
        platform.log(.info, "moved mouse")
    }

    /// Nudges the cursor and reports whether it actually moved. A cursor parked in a
    /// screen corner cannot go any further that way: macOS clamps the event to the
    /// edge and the position never changes, which looks exactly like a dropped event.
    /// The sign only flips after a success, so without the retry the mover stayed stuck
    /// in the corner for ever and blamed the Accessibility permission.
    func moveAndCheck(_ pixels: Int) -> Bool {
        tryMove(pixels) || tryMove(-pixels)
    }

    /// Posts one move and waits to see whether it landed. `CGEventPost` is
    /// asynchronous, so reading the position straight back reports every move as
    /// failed; poll instead, which returns as soon as the move lands and only spends
    /// the full budget when the event really was swallowed.
    func tryMove(_ pixels: Int) -> Bool {
        let start = platform.mousePos()
        platform.moveMouse(x: start.x + pixels, y: start.y + pixels)

        let deadline = Date().addingTimeInterval(moveSettleTimeout)
        while true {
            let moved = platform.mousePos()
            if moved.x != start.x || moved.y != start.y {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: Mover.moveSettleInterval)
        }
    }

    /// Counts a failed move and, at most once per `alertInterval`, tells the user.
    /// Asks macOS outright whether the process is trusted rather than inferring it: a
    /// grant that has gone stale after a rebuild still shows a ticked box in System
    /// Settings, so guessing from failed moves points the user at the wrong thing.
    func reportFailedMove() {
        didNotMoveCount += 1
        let trusted = platform.accessibilityTrusted()

        let message: String
        if trusted {
            let last = lastMouseMovedTime.map { "\($0)" } ?? "never"
            message = "Mouse pointer cannot be moved at \(now()). Last moved at \(last). Happened \(didNotMoveCount) times. (Only notifies once every 24 hours.) See README for details."
        } else {
            message = "AMM is not allowed to control the mouse.\n\nOpen System Settings > Privacy & Security > Accessibility. If amm is already listed, remove it with the minus button and add it again - a ticked box can still be stale after the app was rebuilt or replaced, because the permission is tied to the exact binary."
        }
        platform.log(.error, "\(message) accessibilityTrusted=\(trusted)")

        // Without permission the diagnosis is certain, so say so at once instead of
        // making the user wait out ten failures.
        let threshold = trusted ? Mover.failuresBeforeAlert : 1
        guard didNotMoveCount >= threshold else { return }
        if let last = lastAlertTime, now().timeIntervalSince(last) < Mover.alertInterval {
            return
        }
        lastAlertTime = now()
        let title = trusted ? "Error with Automatic Mouse Mover" : "Automatic Mouse Mover needs permission"
        platform.alert(title: title, message: message)
    }
}
