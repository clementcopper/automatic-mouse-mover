import AppKit
import ServiceManagement
import AMMCore

/// The status item, its menu and the two macOS hooks (login item, wake). Everything
/// here runs on the main thread, including every call into the engine.
final class App: NSObject, NSApplicationDelegate {
    /// The one persisted setting. The login item is not stored: macOS owns it and
    /// `SMAppService` reports it back.
    static let prefResumeAfterWake = "ResumeAfterWake"
    /// Height of the menu bar artwork in points; the bar is 22 pt.
    static let iconHeight: CGFloat = 16

    let platform = MacPlatform()
    lazy var mover = Mover(platform: platform)

    var statusItem: NSStatusItem!
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var wakeItem: NSMenuItem!

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Name the build in the log. A report from someone else's Mac is only worth
        // anything if it says which version and architecture was actually running.
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let macos = ProcessInfo.processInfo.operatingSystemVersionString
        platform.log(.info, "starting version=\(version) arch=\(arch) macos=\(macos)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = trayIcon() {
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "AMM"
            statusItem.button?.imagePosition = .noImage
        }

        let menu = NSMenu()
        // Load-bearing: otherwise AppKit re-decides each item's enabled state when the
        // menu opens and silently overrides isEnabled, so Start/Stop stop greying out.
        menu.autoenablesItems = false
        add(menu, "About AMM", "Information about the app", #selector(about))
        menu.addItem(.separator())
        startItem = add(menu, "Start", "start moving the mouse when the machine goes idle", #selector(start))
        stopItem = add(menu, "Stop", "stop moving the mouse", #selector(stop))
        menu.addItem(.separator())
        loginItem = add(menu, "Launch at Login", "start AMM automatically when you log in", #selector(toggleLogin))
        wakeItem = add(menu, "Resume After Wake", "keep going after the Mac wakes from sleep", #selector(toggleWake))
        menu.addItem(.separator())
        add(menu, "Quit", "Quit the whole app", #selector(quit))
        statusItem.menu = menu

        mover.start()
        syncStartStop()

        // On by default: resuming after sleep is what one expects, and the whole point
        // is that starting the mover cannot be forgotten. A registered default is not
        // persisted, so the user's own choice always wins once made.
        UserDefaults.standard.register(defaults: [App.prefResumeAfterWake: true])

        let status = SMAppService.mainApp.status
        platform.log(.info, "login item status=\(status.rawValue)")
        loginItem.state = status == .enabled ? .on : .off
        wakeItem.state = resumeAfterWake ? .on : .off

        // A sleeping Mac runs no code, so the timer survives on its own. The wake is
        // watched to check straight away instead of waiting out the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.didWake() }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ tooltip: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = tooltip
        return item
    }

    /// `tray.svg` or `tray.png` from the bundle's Resources, drawn as a template image:
    /// AppKit tints it from the alpha channel, black on a light menu bar, white on a
    /// dark one, inverted while the menu is open. The artwork must therefore stay pure
    /// black plus alpha; anything coloured collapses into a silhouette. It need not be
    /// square: the height is fixed and the width follows the aspect ratio, and the
    /// status item widens to match.
    private func trayIcon() -> NSImage? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        for ext in ["svg", "png"] {
            let url = dir.appendingPathComponent("tray.\(ext)")
            guard let image = NSImage(contentsOf: url), image.size.height > 0 else { continue }
            let height = App.iconHeight
            image.size = NSSize(width: image.size.width * height / image.size.height, height: height)
            image.isTemplate = true
            return image
        }
        platform.log(.error, "no tray.svg or tray.png in \(dir.path)")
        return nil
    }

    private func syncStartStop() {
        startItem.isEnabled = !mover.isRunning
        stopItem.isEnabled = mover.isRunning
    }

    var resumeAfterWake: Bool {
        UserDefaults.standard.bool(forKey: App.prefResumeAfterWake)
    }

    /// Only checks; it never restarts. A stopped mover was stopped on purpose, and a
    /// sleep cycle is no reason to override that.
    private func didWake() {
        guard resumeAfterWake, mover.isRunning else { return }
        platform.log(.info, "woke up, checking now")
        mover.tick()
    }

    @objc func start() {
        platform.log(.info, "starting the app")
        mover.start()
        syncStartStop()
    }

    @objc func stop() {
        platform.log(.info, "stopping the app")
        mover.stop()
        syncStartStop()
    }

    /// SMAppService ties the registration to the executable: after a rebuild the app
    /// has to be registered again. Ad-hoc signing is enough.
    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        let enable = service.status != .enabled
        do {
            if enable { try service.register() } else { try service.unregister() }
        } catch {
            // Say why rather than leaving a tick that does nothing.
            platform.log(.error, "could not change the login item enable=\(enable) err=\(error.localizedDescription)")
            platform.alert(title: "Launch at Login could not be changed", message: error.localizedDescription)
        }
        let status = service.status
        loginItem.state = status == .enabled ? .on : .off
        if status == .requiresApproval {
            platform.alert(title: "Launch at Login needs approval",
                           message: "macOS is holding the request. Open System Settings > General > Login Items and allow amm there.")
        }
    }

    @objc func toggleWake() {
        let enabled = !resumeAfterWake
        UserDefaults.standard.set(enabled, forKey: App.prefResumeAfterWake)
        wakeItem.state = enabled ? .on : .off
        platform.log(.info, "resume after wake enabled=\(enabled)")
    }

    @objc func about() {
        platform.alert(title: "Automatic Mouse Mover \(version)",
                       message: "by Daniel Martin\ngithub.com/clementcopper/automatic-mouse-mover\n\nBased on the original by Prashant Gupta, MIT licensed.")
    }

    @objc func quit() {
        platform.log(.info, "quitting")
        mover.stop()
        NSApp.terminate(nil)
    }
}
