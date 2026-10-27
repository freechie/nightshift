import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let menuFacade: MenuFacade?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var panel: MenuPanel?
  // §3 rampTick hook. Filled by RampController; stub lands first so §2 can layer hotkeys.
  private var rampTimer: Timer?
  // True while Color temp is mid-drag (stageWarmth). Blocks hotkey holds.
  private var warmthDragging = false

  init(menu: MenuFacade?) {
    menuFacade = menu
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem.autosaveName = "nightshift-swift"
    statusItem.button?.toolTip = "Nightshift Swift"
    statusItem.button?.image = menuImage()

    let panel = MenuPanel()
    panel.onIntent = { [weak self] intent in
      self?.perform(intent)
    }
    self.panel = panel

    let menu = NSMenu()
    // Items with no action stay enabled, so the sliders get drags (d:4561).
    menu.autoenablesItems = false
    menu.delegate = self
    let content = NSMenuItem()
    content.view = panel
    menu.addItem(content)
    menu.addItem(.separator())
    let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(
      NSMenuItem(
        title: "Quit Nightshift Swift",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
    statusItem.menu = menu
    show(menuFacade?.snapshot() ?? .unavailable)
    wireHotKeys()
    WarmthHotKeys.shared.start()
    startRampTimer()
  }

  func applicationWillTerminate(_ notification: Notification) {
    WarmthHotKeys.shared.stop()
  }

  // 60s wall clock, fires once at launch (matches ObjC dispatch_walltime(NULL,0)).
  // .default mode: does not tick while the menu is tracking (avoids mid-drag retarget).
  private func startRampTimer() {
    let timer = Timer(
      timeInterval: 60,
      target: self,
      selector: #selector(rampTickTimerFired(_:)),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .default)
    rampTimer = timer
    timer.fire()
  }

  @objc private func rampTickTimerFired(_ timer: Timer) {
    rampTick()
  }

  private func rampTick() {
    // Stub: RampController.tick goes here in the rest of §3.
  }

  func menuWillOpen(_ menu: NSMenu) {
    show(menuFacade?.snapshot() ?? .unavailable)
    WarmthHotKeys.shared.menuWillOpen()
  }

  func menuDidClose(_ menu: NSMenu) {
    WarmthHotKeys.shared.menuDidClose()
  }

  // Settings is a stub in this pass. The item stays in the menu.
  @objc private func showSettings(_ sender: Any?) {}

  private func wireHotKeys() {
    let keys = WarmthHotKeys.shared
    keys.currentPercent = { [weak self] in
      guard let reading = self?.menuFacade?.snapshot().warmth else { return nil }
      switch reading {
      case .on(let warmth): return warmth.percent
      case .off: return 0
      case .unreadable, .unavailable: return nil
      }
    }
    keys.isSliderTracking = { [weak self] in
      self?.warmthDragging == true
    }
    keys.onPreview = { [weak self] percent in
      guard let self, let warmth = Warmth(percent) else { return }
      self.menuFacade?.stageWarmth(warmth)
      if let button = self.statusItem.button {
        self.applyBarTitle("\(percent)%", to: button)
      }
    }
    keys.onCommit = { [weak self] percent in
      guard let self, let warmth = Warmth(percent) else { return }
      self.warmthDragging = false
      self.show(self.menuFacade?.apply(.setWarmth(warmth)) ?? .unavailable)
    }
  }

  private func perform(_ intent: MenuIntent) {
    guard let menuFacade else { return }
    // Live drag skips snapshot, render, and bar title; the bar updates on release.
    if case .stageWarmth(let warmth) = intent {
      warmthDragging = true
      menuFacade.stageWarmth(warmth)
      return
    }
    warmthDragging = false
    show(menuFacade.apply(intent))
  }

  private func show(_ snapshot: MenuSnapshot) {
    panel?.render(snapshot)
    guard let button = statusItem.button else { return }
    let title = statusItemTitle(for: snapshot.warmth, showWarmthInBar: snapshot.showWarmthInBar)
    applyBarTitle(title, to: button)
  }

  private func applyBarTitle(_ title: String, to button: NSStatusBarButton) {
    if title.isEmpty {
      button.title = button.image == nil ? "NS" : ""
      button.imagePosition = button.image == nil ? .imageLeading : .imageOnly
      return
    }
    let size = NSFont.systemFontSize(for: NSControl.ControlSize.regular)
    button.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
      ]
    )
    button.imagePosition = .imageLeading
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
}
