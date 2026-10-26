import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let nightShift: (any WarmthSource)?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)

  init(nightShift: (any WarmthSource)?) {
    self.nightShift = nightShift
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem.autosaveName = "nightshift-swift"
    statusItem.button?.toolTip = "Nightshift Swift"
    statusItem.button?.imagePosition = .imageLeading
    let image = menuImage()
    statusItem.button?.image = image
    // No symbol: a text title instead, as the old app does (d:4765-4766).
    if image == nil {
      statusItem.button?.title = "NS"
    }

    slider.target = self
    slider.action = #selector(sliderReleased)
    slider.isContinuous = false
    slider.frame = NSRect(x: 16, y: 2, width: 200, height: 24)
    let sliderRow = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 28))
    sliderRow.addSubview(slider)
    let sliderItem = NSMenuItem()
    sliderItem.view = sliderRow

    let menu = NSMenu()
    // Items with no action stay enabled, so the slider gets drags (d:4561).
    menu.autoenablesItems = false
    titleItem.isEnabled = false
    menu.delegate = self
    menu.addItem(titleItem)
    menu.addItem(sliderItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Nightshift Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
    show(currentReading(nightShift))
  }

  func menuWillOpen(_ menu: NSMenu) {
    show(currentReading(nightShift))
  }

  @objc private func sliderReleased() {
    guard let reading = applyReleased(slider.integerValue, to: nightShift) else { return }
    show(reading)
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
    let state = sliderState(for: reading)
    slider.isEnabled = state.isEnabled
    if let value = state.value {
      slider.integerValue = value
    }
  }
}
