import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(menu: NightShiftClient()?.menuFacade())
app.delegate = delegate
app.run()
