import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let menuFacade: MenuFacade?
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var panel: MenuPanel?

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
  }

  func menuWillOpen(_ menu: NSMenu) {
    show(menuFacade?.snapshot() ?? .unavailable)
  }

  // Settings is a stub in this pass. The item stays in the menu.
  @objc private func showSettings(_ sender: Any?) {}

  private func perform(_ intent: MenuIntent) {
    guard let menuFacade else { return }
    // Live drag skips snapshot, render, and bar title; the bar updates on release.
    if case .stageWarmth(let warmth) = intent {
      menuFacade.stageWarmth(warmth)
      return
    }
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
