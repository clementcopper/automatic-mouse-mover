import AppKit
import ApplicationServices
import os
import AMMCore

/// The real macOS behind the engine's `Platform` protocol.
struct MacPlatform: Platform {
    let logger = Logger(subsystem: "com.pg.amm", category: "amm")

    func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// This one call is the entire activity detection: seconds since the last
    /// keyboard, mouse or tablet event, no permission needed.
    func idleSeconds() -> Double {
        // kCGAnyInputEventType is (CGEventType)~0. Swift imports the enum without
        // validating raw values, so the force unwrap cannot fail.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func mousePos() -> (x: Int, y: Int) {
        let p = CGEvent(source: nil)?.location ?? .zero
        return (Int(p.x), Int(p.y))
    }

    /// Posts a real HID event instead of warping the cursor. Warping would move the
    /// pointer without resetting the system idle timer, and resetting that timer is
    /// the whole point of the app. Without Accessibility permission macOS silently
    /// drops the event, which is how the engine detects a failed move.
    func moveMouse(x: Int, y: Int) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Returns at once. The dialog goes up on the next pass of the main run loop and
    /// lives on without the caller, so a tick never stalls behind it; and only one is
    /// on screen at a time, so ten failed moves do not stack ten alerts.
    func alert(title: String, message: String) {
        DispatchQueue.main.async {
            if MacPlatform.alertOnScreen { return }
            MacPlatform.alertOnScreen = true
            defer { MacPlatform.alertOnScreen = false }

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            // No dock icon means no automatic activation: without this the window
            // opens behind whatever the user is looking at.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static var alertOnScreen = false

    /// Into unified logging: a Finder-launched app has no stderr, so this is the only
    /// place its output can be read back (`/usr/bin/log show --predicate 'subsystem == "com.pg.amm"'`).
    /// `info` goes out as `notice`, which is `OS_LOG_TYPE_DEFAULT`: macOS does not
    /// retain `OS_LOG_TYPE_INFO` unless logging is turned up for the subsystem, so
    /// info records would silently never appear. `public`, or the text is redacted
    /// to `<private>`.
    func log(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
