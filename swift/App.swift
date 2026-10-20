import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let nightShift: NightShiftClient?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)

  init(nightShift: NightShiftClient?) {
    self.nightShift = nightShift
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem.button?.image = menuImage()

    slider.target = self
    slider.action = #selector(sliderReleased)
    slider.isContinuous = false
    slider.frame = NSRect(x: 16, y: 2, width: 200, height: 24)
    let sliderRow = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 28))
    sliderRow.addSubview(slider)
    let sliderItem = NSMenuItem()
    sliderItem.view = sliderRow

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(titleItem)
    menu.addItem(sliderItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Nightshift Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
    show(nightShift?.read() ?? .unavailable)
  }

  func menuWillOpen(_ menu: NSMenu) {
    show(nightShift?.read() ?? .unavailable)
  }

  @objc private func sliderReleased() {
    guard let nightShift, let warmth = Warmth(slider.integerValue) else { return }
    show(nightShift.apply(warmth))
  }

  // The status bar fits a symbol to its alignment rect without scaling,
  // which cuts off the top ray. A plain image is drawn whole (d:2709-2732).
  private func menuImage() -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    guard let glyph = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: nil)?
      .withSymbolConfiguration(config) else { return nil }
    let image = NSImage(size: glyph.size, flipped: false) { rect in
      glyph.draw(in: rect)
      return true
    }
    image.accessibilityDescription = "Nightshift"
    image.isTemplate = true
    return image
  }

  private func show(_ reading: WarmthReading) {
    titleItem.title = menuTitle(for: reading)
    switch reading {
    case .on(let warmth):
      slider.isEnabled = true
      slider.integerValue = warmth.percent
    case .off:
      slider.isEnabled = true
      slider.integerValue = 0
    case .unreadable, .unavailable:
      slider.isEnabled = false
    }
  }
}
