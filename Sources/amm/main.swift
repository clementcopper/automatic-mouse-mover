import AppKit

// Menu bar only, no dock icon; matches LSUIElement in Info.plist.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
