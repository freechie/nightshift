import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(nightShift: NightShiftClient())
app.delegate = delegate
app.run()
