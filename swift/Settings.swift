// Copyright 2026 John
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import Carbon
import CNightshift
import ServiceManagement

private enum SettingsPage: String, CaseIterable {
  case settings
  case license
  case about

  var title: String {
    switch self {
    case .settings: "Settings"
    case .license: "License"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .settings: "slider.horizontal.3"
    case .license: "checkmark.seal"
    case .about: "info.circle"
    }
  }

  var itemIdentifier: NSToolbarItem.Identifier {
    NSToolbarItem.Identifier(rawValue)
  }
}

private final class SettingsFlippedView: NSView {
  override var isFlipped: Bool { true }
}

private final class SettingsFormCaption: NSTextField {
  override func layout() {
    super.layout()
    let width = bounds.width
    if width > 1, abs(preferredMaxLayoutWidth - width) > 0.5 {
      preferredMaxLayoutWidth = width
      invalidateIntrinsicContentSize()
    }
  }
}

private final class SettingsDot: NSView {
  var color: NSColor = .secondaryLabelColor {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
  }
}

private final class SettingsGroupView: NSView {
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let scale = window?.backingScaleFactor ?? 2
    layer?.cornerRadius = 10
    layer?.borderWidth = 1 / max(scale, 1)
    let fill = dark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
    let border = dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
    layer?.backgroundColor = fill.cgColor
    layer?.borderColor = border.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private final class TintSwatch: NSControl {
  var tint: BarTint = .accent
  var chosen = false {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: chosen ? 4 : 2, dy: chosen ? 4 : 2))
    barFillColor(tint).setFill()
    circle.fill()
    if chosen {
      let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
      ring.lineWidth = 2
      NSColor.labelColor.setStroke()
      ring.stroke()
    }
  }

  override func mouseDown(with event: NSEvent) {
    sendAction(action, to: target)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private final class TintChooser: NSStackView {
  var onPick: ((BarTint) -> Void)?
  private let accentLabel = NSTextField(labelWithString: "Accent")
  private let well = NSColorWell()
  private var swatches: [TintSwatch] = []
  private var syncing = false
  private var custom = BarTint.custom(red: 0, green: 122, blue: 255)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    orientation = .horizontal
    alignment = .centerY
    distribution = .fill
    spacing = 6
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    accentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    accentLabel.textColor = .secondaryLabelColor
    accentLabel.setAccessibilityLabel("Accent color")
    accentLabel.setContentHuggingPriority(.required, for: .horizontal)
    let accent = NSStackView(views: [accentLabel, swatch(for: .accent)])
    accent.orientation = .horizontal
    accent.alignment = .centerY
    accent.spacing = 4
    accent.setContentHuggingPriority(.required, for: .horizontal)
    addArrangedSubview(accent)
    setCustomSpacing(12, after: accent)
    for primary in BarPrimary.allCases {
      addArrangedSubview(swatch(for: .primary(primary)))
    }
    well.colorWellStyle = .minimal
    well.color = barFillColor(custom)
    well.target = self
    well.action = #selector(wellPicked(_:))
    well.setAccessibilityLabel("Custom color")
    well.translatesAutoresizingMaskIntoConstraints = false
    well.widthAnchor.constraint(equalToConstant: 28).isActive = true
    well.heightAnchor.constraint(equalToConstant: 28).isActive = true
    well.setContentHuggingPriority(.required, for: .horizontal)
    well.setContentCompressionResistancePriority(.required, for: .horizontal)
    addArrangedSubview(well)
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addArrangedSubview(spacer)
    show(.accent)
  }

  private func swatch(for tint: BarTint) -> TintSwatch {
    let swatch = TintSwatch(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    swatch.tint = tint
    swatch.target = self
    swatch.action = #selector(swatchPicked(_:))
    swatch.setAccessibilityLabel(barTintTitle(tint))
    swatch.translatesAutoresizingMaskIntoConstraints = false
      swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
    swatches.append(swatch)
    return swatch
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func show(_ tint: BarTint) {
    syncing = true
    if case .custom = tint {
      custom = tint
      well.color = barFillColor(tint)
    }
    for swatch in swatches {
      swatch.chosen = swatch.tint == tint
    }
    let customChosen: Bool
    if case .custom = tint {
      customChosen = true
    } else {
      customChosen = false
    }
    well.wantsLayer = true
    well.layer?.cornerRadius = 14
    well.layer?.borderWidth = customChosen ? 2 : 0
    well.layer?.borderColor = NSColor.labelColor.cgColor
    syncing = false
  }

  @objc private func swatchPicked(_ sender: TintSwatch) {
    show(sender.tint)
    onPick?(sender.tint)
  }

  @objc private func wellPicked(_ sender: NSColorWell) {
    if syncing { return }
    guard let color = sender.color.usingColorSpace(.sRGB) else { return }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let tint = BarTint.custom(
      red: Int((red * 255).rounded()),
      green: Int((green * 255).rounded()),
      blue: Int((blue * 255).rounded())
    )
    show(tint)
    onPick?(tint)
  }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSToolbarDelegate {
  private var window: NSWindow?
  private var facade: MenuFacade?
  private var onIntent: ((MenuIntent) -> Void)?
  var onRefresh: (() -> Void)?
  private var page: SettingsPage = .settings
  private let pages = NSView()
  private var pageViews: [SettingsPage: NSView] = [:]

  private let loginSwitch = NSSwitch()
  private let warmthSwitch = NSSwitch()
  private let cycleSwitch = NSSwitch()
  private let tintChooser = TintChooser()
  private let schedulePopup = NSPopUpButton()
  private let hoursLabel = NSTextField(labelWithString: "—")
  private let maxSlider = ReleaseSlider(value: 50, minValue: 1, maxValue: 100, target: nil, action: nil)
  private let maxValue = NSTextField(labelWithString: "—")
  private let maxCaption = SettingsFormCaption(wrappingLabelWithString: "")
  private let fullPicker = NSDatePicker()
  private let fullCaption = SettingsFormCaption(wrappingLabelWithString: "")
  private let unlockButton = NSButton(title: "Unlock…", target: nil, action: nil)
  private var shortcutButtons: [NSButton] = []
  private var shortcutNotes: [NSTextField] = []
  private var shortcutDots: [SettingsDot] = []
  private let licenseStatus = NSTextField(labelWithString: "Not active")
  private var licenseDot: SettingsDot?
  private var licensePitch: NSTextField?
  private let buyButton = NSButton(title: "Unlock the ramp", target: nil, action: nil)
  private var buySection: NSView?
  private let installID = NSTextField(labelWithString: "—")
  private let addMacButton = NSButton(title: "Add a Mac", target: nil, action: nil)
  private let redeemButton = NSButton(title: "Add this Mac", target: nil, action: nil)
  private let seatCode = NSTextField(labelWithString: "")
  private let seatField = NSTextField(string: "")
  private var addSection: NSView?
  private var redeemSection: NSView?
  private let updateAuto = NSButton(checkboxWithTitle: "Automatically Check For Updates", target: nil, action: nil)
  private let updateLast = NSTextField(labelWithString: "Last check: Never")
  private let updateStatus = NSTextField(labelWithString: "Not checked yet.")
  private var updateCheckButton: NSButton?
  private var updateChecking = false
  private var variantPopover: NSPopover?
  private var recordingIndex: Int?
  private var recordNote: String?
  private var keyMonitor: Any?

  func show(facade: MenuFacade?, onIntent: @escaping (MenuIntent) -> Void) {
    self.facade = facade
    self.onIntent = onIntent
    if window == nil {
      window = makeWindow()
    }
    refresh(facade?.snapshot() ?? .unavailable)
    NSApp.setActivationPolicy(.regular)
    installSettingsMenu()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func refresh(_ snapshot: MenuSnapshot) {
    guard window != nil else { return }
    loginSwitch.state = loginOn() ? .on : .off
    warmthSwitch.state = (facade?.showWarmthInBar ?? menuBarWarmthShown()) ? .on : .off
    cycleSwitch.state = hourCycleIs24() ? .on : .off
    let tint = barTint()
    tintChooser.show(tint)
    maxSlider.barFill = barFillColor(tint)

    let known = facade != nil && snapshot.warmth != .unavailable
    schedulePopup.isEnabled = known
    if let item = schedulePopup.menu?.item(withTag: snapshot.schedule.rawValue) {
      schedulePopup.select(item)
    }
    hoursLabel.stringValue = facade?.scheduleHours() ?? "—"

    let paid = snapshot.rampLicensed
    maxSlider.isEnabled = paid
    maxCaption.stringValue = paid ? "Warmest the ramp gets." : "Nightshift Pro."
    if snapshot.maxPercent >= 1 {
      if maxSlider.integerValue != snapshot.maxPercent {
        maxSlider.integerValue = snapshot.maxPercent
      }
      maxValue.stringValue = "\(snapshot.maxPercent)%"
    } else {
      maxValue.stringValue = "—"
    }
    unlockButton.isHidden = paid
    let custom = snapshot.schedule == .custom
    fullPicker.isEnabled = paid && custom
    if !paid {
      fullCaption.stringValue = "Nightshift Pro."
    } else if !custom {
      fullCaption.stringValue = "Needs a Custom schedule."
    } else {
      fullCaption.stringValue = "When warmth reaches Max."
    }
    let shownMinute = snapshot.fullAtMinute ?? minute(of: Date())
    fullPicker.locale = Locale(identifier: hourCycleIs24() ? "en_GB" : "en_US_POSIX")
    if minute(of: fullPicker.dateValue) != shownMinute, let date = date(minute: shownMinute) {
      fullPicker.dateValue = date
    }
    showLicense(snapshot)
    showShortcuts()
  }

  func windowWillClose(_ notification: Notification) {
    stopRecording(resume: true)
    NSApp.setActivationPolicy(.accessory)
  }

  private func makeWindow() -> NSWindow {
    buildPages()
    let contentController = NSViewController()
    contentController.view = pages

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = contentController
    window.setContentSize(NSSize(width: 680, height: 600))
    window.contentMinSize = NSSize(width: 640, height: 520)
    window.identifier = NSUserInterfaceItemIdentifier("NightshiftSettings")
    window.title = "Nightshift Settings"
    window.titlebarAppearsTransparent = false
    window.toolbarStyle = .preference
    let toolbar = NSToolbar(identifier: "NightshiftSettingsToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.canHide = false
    window.delegate = self
    window.center()
    show(page: .settings)
    window.toolbar?.selectedItemIdentifier = SettingsPage.settings.itemIdentifier
    return window
  }

  private func buildPages() {
    wireControls()
    let less = NSTextField(labelWithString: "Less Warm")
    less.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    less.textColor = .secondaryLabelColor
    let more = NSTextField(labelWithString: "More Warm")
    more.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    more.textColor = .secondaryLabelColor
    maxValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    maxValue.textColor = .secondaryLabelColor
    maxValue.alignment = .right
    maxValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
    maxSlider.commitsOnRelease = true
    maxSlider.isContinuous = true
    let sliderWidth = floor(480 - 20 - less.fittingSize.width - more.fittingSize.width - 40 - 24)
    maxSlider.widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true
    let maxLine = NSStackView(views: [less, maxSlider, more, maxValue])
    maxLine.orientation = .horizontal
    maxLine.alignment = .centerY
    maxLine.spacing = 8
    pageViews[.settings] = scroll(sections: [
      section("Startup", rows: [
        row("Open at login", caption: "Starts when you log in.", control: loginSwitch),
      ]),
      section("Menu bar", rows: [
        row("Show percent", caption: "Warmth percent next to the icon.", control: warmthSwitch),
      ]),
      section("Color", rows: [
        row("Bars and icon", caption: "One color for the bars and the icon.", control: tintChooser, below: true),
      ]),
      section("Clock", rows: [
        row("24-hour time", caption: "Full at uses 24-hour time.", control: cycleSwitch),
      ]),
      section("Notifications", rows: [
        row("Notification style", caption: "Choose Alerts to keep banners up.", control: push("Open…", #selector(openNotifications(_:)), "Open Notification settings")),
      ]),
      section("Schedule", rows: [
        row("Schedule", caption: "Custom uses your hours.", control: schedulePopup),
        row("Hours", caption: "Set in System Settings › Displays › Night Shift.", control: hoursControl()),
      ]),
      section("Evening Ramp", accessory: ProBadge(frame: .zero), rows: [
        row("Max", captionView: maxCaption, control: maxLine, below: true),
        row("Full at", captionView: fullCaption, control: fullControl()),
      ], footer: "Climbs to Max over two hours, then holds."),
      keyboardSection(),
    ])
    pageViews[.license] = scroll(sections: licenseSections())
    pageViews[.about] = aboutPage()
  }

  private func wireControls() {
    loginSwitch.target = self
    loginSwitch.action = #selector(loginChanged(_:))
    warmthSwitch.target = self
    warmthSwitch.action = #selector(warmthChanged(_:))
    cycleSwitch.target = self
    cycleSwitch.action = #selector(cycleChanged(_:))
    tintChooser.onPick = { [weak self] tint in
      self?.saveTint(tint)
    }
    for mode in [ScheduleMode.off, .custom, .sunsetToSunrise] {
      schedulePopup.addItem(withTitle: modeTitle(mode))
      schedulePopup.lastItem?.tag = mode.rawValue
    }
    schedulePopup.target = self
    schedulePopup.action = #selector(scheduleChanged(_:))
    maxSlider.target = self
    maxSlider.action = #selector(maxChanged(_:))
    fullPicker.datePickerStyle = .textFieldAndStepper
    fullPicker.datePickerElements = .hourMinute
    fullPicker.datePickerMode = .single
    fullPicker.isBezeled = true
    fullPicker.calendar = menuCalendar()
    fullPicker.timeZone = .current
    fullPicker.target = self
    fullPicker.action = #selector(fullAtChanged(_:))
    unlockButton.target = self
    unlockButton.action = #selector(showLicensePage(_:))
    unlockButton.bezelStyle = .rounded
    buyButton.target = self
    buyButton.action = #selector(buy(_:))
    buyButton.bezelStyle = .rounded
    addMacButton.target = self
    addMacButton.action = #selector(addMac(_:))
    addMacButton.bezelStyle = .rounded
    redeemButton.target = self
    redeemButton.action = #selector(redeemMac(_:))
    redeemButton.bezelStyle = .rounded
    seatCode.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    seatCode.isSelectable = true
    seatField.placeholderString = "Code from your other Mac"
    seatField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    seatField.alignment = .center
    seatField.widthAnchor.constraint(equalToConstant: 180).isActive = true
    installID.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    installID.textColor = .secondaryLabelColor
    installID.lineBreakMode = .byTruncatingMiddle
    installID.isSelectable = true
  }

  private func show(page: SettingsPage) {
    self.page = page
    for (candidate, view) in pageViews {
      view.isHidden = candidate != page
      if view.superview == nil {
        view.translatesAutoresizingMaskIntoConstraints = false
        pages.addSubview(view)
        NSLayoutConstraint.activate([
          view.leadingAnchor.constraint(equalTo: pages.leadingAnchor),
          view.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
          view.topAnchor.constraint(equalTo: pages.safeAreaLayoutGuide.topAnchor),
          view.bottomAnchor.constraint(equalTo: pages.bottomAnchor),
        ])
      }
    }
    window?.toolbar?.selectedItemIdentifier = page.itemIdentifier
    if page == .about {
      checkForUpdates(manual: false)
    }
  }

  @objc private func showPageFromToolbar(_ sender: NSToolbarItem) {
    guard let page = SettingsPage(rawValue: sender.itemIdentifier.rawValue) else { return }
    show(page: page)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    SettingsPage.allCases.map(\.itemIdentifier)
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    SettingsPage.allCases.map(\.itemIdentifier)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    SettingsPage.allCases.map(\.itemIdentifier)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let page = SettingsPage(rawValue: identifier.rawValue) else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = page.title
    item.paletteLabel = page.title
    item.toolTip = page.title
    item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
    item.target = self
    item.action = #selector(showPageFromToolbar(_:))
    return item
  }

  private func saveTint(_ tint: BarTint) {
    guard menuBarSetTint(tint) else {
      tintChooser.show(barTint())
      return
    }
    maxSlider.barFill = barFillColor(tint)
    onRefresh?()
  }

  @objc private func loginChanged(_ sender: NSSwitch) {
    let want = sender.state == .on
    let service = SMAppService.mainApp
    do {
      if want {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      sender.state = loginOn() ? .on : .off
    }
    sender.state = loginOn() ? .on : .off
  }

  @objc private func warmthChanged(_ sender: NSSwitch) {
    let shown = sender.state == .on
    guard menuBarSetWarmthShown(shown) else {
      sender.state = menuBarWarmthShown() ? .on : .off
      return
    }
    facade?.showWarmthInBar = shown
    onRefresh?()
  }

  @objc private func cycleChanged(_ sender: NSSwitch) {
    let cycle = sender.state == .on ? 24 : 12
    if !writeHourCycle(Int32(cycle)) {
      sender.state = hourCycleIs24() ? .on : .off
    }
    if let snapshot = facade?.snapshot() {
      refresh(snapshot)
    }
  }

  @objc private func scheduleChanged(_ sender: NSPopUpButton) {
    guard let mode = ScheduleMode(rawValue: sender.selectedTag()) else { return }
    onIntent?(.setSchedule(mode))
  }

  @objc private func maxChanged(_ sender: ReleaseSlider) {
    let value = sender.integerValue
    maxValue.stringValue = "\(value)%"
    guard sender.shouldCommit else { return }
    onIntent?(.setMax(value))
  }

  @objc private func fullAtChanged(_ sender: NSDatePicker) {
    onIntent?(.setFullAt(minute(of: sender.dateValue)))
  }

  @objc private func showLicensePage(_ sender: NSButton) {
    show(page: .license)
  }

  @objc private func openNotifications(_ sender: NSButton) {
    openAllowed("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
  }

  @objc private func openNightShift(_ sender: NSButton) {
    openAllowed("x-apple.systempreferences:com.apple.Displays-Settings.extension?nightShift")
  }

  @objc private func openLink(_ sender: NSButton) {
    guard let link = sender.identifier?.rawValue else { return }
    openAllowed(link)
  }

  @objc private func buy(_ sender: NSButton) {
    sender.isEnabled = false
    licenseStatus.stringValue = "Waiting for checkout…"
    licenseStatus.textColor = .systemOrange
    licenseDot?.color = .systemOrange
    DispatchQueue.global(qos: .userInitiated).async {
      var openURL: NSString?
      var portal = ObjCBool(false)
      var stdoutLine: NSString?
      var stderrLine: NSString?
      let code = rampBeginPurchase(&openURL, &portal, &stdoutLine, &stderrLine)
      let url = openURL as String?
      let message = stderrLine as String?
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.finishPurchase(code: Int(code), url: url, message: message)
        }
      }
    }
  }

  @objc private func copyInstallID(_ sender: NSButton) {
    let text = rampInstallID() as String? ?? ""
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Install ID")
    }
  }

  @objc private func recordShortcut(_ sender: NSButton) {
    let index = sender.tag
    if recordingIndex == index {
      stopRecording(resume: true)
      return
    }
    stopRecording(resume: true)
    recordingIndex = index
    recordNote = nil
    WarmthHotKeys.shared.pauseForRecording()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let isRepeat = event.isARepeat
      let keyCode = event.keyCode
      let flags = event.modifierFlags
      let key = event.characters(byApplyingModifiers: [])
      let consumed = MainActor.assumeIsolated {
        self.record(isRepeat: isRepeat, keyCode: keyCode, flags: flags, key: key)
      }
      return consumed ? nil : event
    }
    showShortcuts()
  }

  @objc private func restoreShortcuts(_ sender: NSButton) {
    stopRecording(resume: false)
    _ = WarmthHotKeys.shared.restoreDefaultShortcuts()
    showShortcuts()
  }

  private func record(isRepeat: Bool, keyCode rawCode: UInt16, flags rawFlags: NSEvent.ModifierFlags, key typed: String?) -> Bool {
    if isRepeat { return true }
    let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(kNSHotKeyCommand) }
    if flags.contains(.shift) { modifiers |= UInt32(kNSHotKeyShift) }
    if flags.contains(.option) { modifiers |= UInt32(kNSHotKeyOption) }
    if flags.contains(.control) { modifiers |= UInt32(kNSHotKeyControl) }
    if rawCode == UInt16(kVK_Escape), modifiers == 0 {
      stopRecording(resume: true)
      return true
    }
    if modifiers == UInt32(kNSHotKeyCommand),
      rawCode == UInt16(kVK_ANSI_W) || rawCode == UInt16(kVK_ANSI_Q)
    {
      stopRecording(resume: true)
      return false
    }
    let key = typed?.uppercased() ?? ""
    let keyCode = UInt32(rawCode)
    guard let index = recordingIndex else { return true }
    let statuses = WarmthHotKeys.shared.shortcutPair()
    let other = index == 0 ? statuses.1 : statuses.0
    if !nsShortcutAllowed(keyCode, modifiers) {
      var pressed = [CChar](repeating: 0, count: 40)
      let named = key.withCString { nsShortcutName(keyCode, modifiers, $0, &pressed, pressed.count) }
      let loneCommand = modifiers == UInt32(kNSHotKeyCommand)
      noteRefusal(loneCommand && named ? kNSRefusalOtherApps : kNSRefusalModifiers, pressed: named ? pressed : nil)
      return true
    }
    var shortcut = NSShortcut()
    let made = key.withCString { nsShortcutMake(keyCode, modifiers, $0, &shortcut) }
    guard made else {
      noteRefusal(kNSRefusalKey, pressed: nil)
      return true
    }
    var otherShortcut = other
    if nsShortcutSame(&shortcut, &otherShortcut) {
      noteRefusal(kNSRefusalOtherKey, name: shortcutLabel(shortcut))
      return true
    }
    let saved: Bool
    if index == 0 {
      saved = WarmthHotKeys.shared.saveShortcuts(lower: shortcut, raise: statuses.1)
    } else {
      saved = WarmthHotKeys.shared.saveShortcuts(lower: statuses.0, raise: shortcut)
    }
    if saved {
      stopRecording(resume: false)
    } else {
      noteRefusal(kNSRefusalSave, name: shortcutLabel(shortcut))
    }
    return true
  }

  private func noteRefusal(_ why: NSShortcutRefusal, pressed: UnsafePointer<CChar>?) {
    var note = [CChar](repeating: 0, count: 160)
    _ = nsShortcutRefusal(why, pressed, nil, &note, note.count)
    recordNote = note.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return "" }
      return String(cString: base)
    }
    showShortcuts()
  }

  private func noteRefusal(_ why: NSShortcutRefusal, name: String) {
    name.withCString { noteRefusal(why, pressed: $0) }
  }

  private func stopRecording(resume: Bool) {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    let was = recordingIndex != nil
    recordingIndex = nil
    recordNote = nil
    if was, resume {
      WarmthHotKeys.shared.resumeAfterRecording()
    }
    showShortcuts()
  }

  private func finishPurchase(code: Int, url: String?, message: String?) {
    if code == 1, let url {
      openAllowed(url)
    }
    if code == 2, let message, !message.isEmpty {
      licenseStatus.stringValue = message
    }
    buyButton.isEnabled = true
    if let snapshot = facade?.snapshot() {
      refresh(snapshot)
    }
  }

  private func showLicense(_ snapshot: MenuSnapshot) {
    let until = rampLicenseUntil() as String?
    let soon = rampLicenseRenewingSoon()
    if snapshot.rampLicensed, let until, soon {
      licenseStatus.stringValue = "Ends \(licenseDay(until))"
      licenseStatus.textColor = .systemOrange
    } else if snapshot.rampLicensed, let until {
      licenseStatus.stringValue = "Active through \(licenseDay(until))"
      licenseStatus.textColor = .systemGreen
    } else if snapshot.rampLicensed {
      licenseStatus.stringValue = "Active"
      licenseStatus.textColor = .systemGreen
    } else if licenseStatus.stringValue != "Waiting for checkout…" {
      licenseStatus.stringValue = "Not active"
      licenseStatus.textColor = .secondaryLabelColor
    }
    licenseDot?.color = licenseStatus.textColor ?? .secondaryLabelColor
    licensePitch?.isHidden = snapshot.rampLicensed
    buySection?.isHidden = snapshot.rampLicensed && !soon
    buyButton.title = soon ? "Renew…" : "Buy…"
    addSection?.isHidden = !snapshot.rampLicensed
    redeemSection?.isHidden = snapshot.rampLicensed
    if !snapshot.rampLicensed {
      seatCode.isHidden = true
      seatCode.stringValue = ""
    }
    let id = (rampInstallID() as String?) ?? ""
    if !id.isEmpty {
      installID.stringValue = id
    }
  }

  private func showShortcuts() {
    let pair = WarmthHotKeys.shared.shortcutPair()
    let shortcuts = [pair.0, pair.1]
    let ready = WarmthHotKeys.shared.keyStatuses()
    for index in 0..<shortcutButtons.count {
      let recording = recordingIndex == index
      shortcutButtons[index].title = recording ? "Type Shortcut…" : shortcutLabel(shortcuts[index])
      if recording, let recordNote {
        shortcutNotes[index].stringValue = recordNote
        shortcutDots[index].color = .controlAccentColor
      } else if recording {
        shortcutNotes[index].stringValue = "Recording"
        shortcutDots[index].color = .controlAccentColor
      } else if index < ready.count {
        shortcutNotes[index].stringValue = ready[index].ready ? "On" : "Not registered"
        shortcutDots[index].color = ready[index].ready ? .systemGreen : .systemOrange
      }
    }
  }

  private func hoursControl() -> NSView {
    hoursLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let change = push("Change…", #selector(openNightShift(_:)), "Change hours in System Settings")
    let line = NSStackView(views: [hoursLabel, change])
    line.orientation = .horizontal
    line.spacing = 10
    return line
  }

  private func fullControl() -> NSView {
    let line = NSStackView(views: [unlockButton, fullPicker])
    line.orientation = .horizontal
    line.spacing = 8
    return line
  }

  private func keyboardSection() -> NSView {
    let titles = ["Lower Warmth", "Raise Warmth"]
    let captions = [
      "Hold to step down.",
      "Hold to step up.",
    ]
    var rows: [NSView] = []
    for index in 0..<2 {
      let button = push("", #selector(recordShortcut(_:)), titles[index])
      button.tag = index
      shortcutButtons.append(button)
      let note = NSTextField(labelWithString: "")
      note.textColor = .secondaryLabelColor
      note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      shortcutNotes.append(note)
      let dot = SettingsDot(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
      dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
      shortcutDots.append(dot)
      let state = NSStackView(views: [dot, note])
      state.orientation = .horizontal
      state.alignment = .centerY
      state.spacing = 6
      let control = NSStackView(views: [state, button])
      control.orientation = .horizontal
      control.spacing = 10
      rows.append(row(titles[index], caption: captions[index], control: control))
    }
    let reset = push("Restore Defaults", #selector(restoreShortcuts(_:)), "Restore Defaults")
    rows.append(row("Defaults", caption: "⌃⌥⌘− and ⌃⌥⌘=.", control: reset))
    return section("Keyboard", rows: rows, footer: "Click, then press the keys. Esc cancels.")
  }

  private func licenseSections() -> [NSView] {
    let name = NSTextField(labelWithString: "Nightshift Pro")
    name.font = .systemFont(ofSize: 17, weight: .semibold)
    let licenseDot = SettingsDot(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    licenseDot.translatesAutoresizingMaskIntoConstraints = false
    licenseDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
    licenseDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
    licenseDot.color = licenseStatus.textColor ?? .secondaryLabelColor
    self.licenseDot = licenseDot
    let state = NSStackView(views: [licenseDot, licenseStatus])
    state.orientation = .horizontal
    state.alignment = .centerY
    state.spacing = 6
    let titles = NSStackView(views: [name, state])
    titles.orientation = .vertical
    titles.alignment = .centerX
    titles.spacing = 4
    let icon = NSImageView(image: settingsTile(size: 64))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.imageScaling = .scaleNone
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 64),
      icon.heightAnchor.constraint(equalToConstant: 64),
    ])
    let hero = NSStackView(views: [icon, titles])
    hero.orientation = .horizontal
    hero.alignment = .centerY
    hero.spacing = 12
    hero.setContentHuggingPriority(.required, for: .horizontal)
    hero.setContentCompressionResistancePriority(.required, for: .horizontal)
    let about = SettingsFormCaption(wrappingLabelWithString: "Unlock your evening ramp today")
    about.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    about.textColor = .secondaryLabelColor
    about.alignment = .center
    about.preferredMaxLayoutWidth = 420
    licensePitch = about
    let column = NSStackView(views: [hero, about])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    column.translatesAutoresizingMaskIntoConstraints = false
    let heroBox = NSView()
    heroBox.translatesAutoresizingMaskIntoConstraints = false
    heroBox.addSubview(column)
    NSLayoutConstraint.activate([
      heroBox.widthAnchor.constraint(equalToConstant: 480),
      column.topAnchor.constraint(equalTo: heroBox.topAnchor),
      column.leadingAnchor.constraint(equalTo: heroBox.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: heroBox.trailingAnchor),
      column.bottomAnchor.constraint(equalTo: heroBox.bottomAnchor),
      about.widthAnchor.constraint(equalToConstant: 420),
    ])
    installID.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
    installID.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let copy = NSButton(
      image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Install ID") ?? NSImage(),
      target: self,
      action: #selector(copyInstallID(_:))
    )
    copy.bezelStyle = .rounded
    copy.toolTip = "Copy"
    copy.setAccessibilityLabel("Copy Install ID")
    let idLine = NSStackView(views: [installID, copy])
    idLine.orientation = .horizontal
    idLine.spacing = 6
    heroBox.setContentHuggingPriority(.required, for: .horizontal)
    heroBox.setContentCompressionResistancePriority(.required, for: .horizontal)
    let top = section(nil, rows: [heroBox])
    top.setContentHuggingPriority(.required, for: .horizontal)
    top.setContentCompressionResistancePriority(.required, for: .horizontal)
    top.widthAnchor.constraint(equalToConstant: 480).isActive = true
    let purchase = section("Purchase", rows: [proPurchaseRow()])
    buySection = purchase
    seatCode.isHidden = true
    let addControls = NSStackView(views: [addMacButton, seatCode])
    addControls.orientation = .vertical
    addControls.alignment = .trailing
    addControls.spacing = 6
    let add = row("Another Mac", caption: "A code for the other Mac. It lasts 15 minutes.", control: addControls)
    let redeemLine = NSStackView(views: [seatField, redeemButton])
    redeemLine.orientation = .horizontal
    redeemLine.alignment = .centerY
    redeemLine.spacing = 8
    let redeem = row("This Mac", caption: nil, control: redeemLine)
    let adding = section("Other Macs", rows: [add], footer: "One purchase covers 3 Macs.")
    let joining = section("Other Macs", rows: [redeem], footer: "One purchase covers 3 Macs.")
    addSection = adding
    redeemSection = joining
    return [
      top,
      purchase,
      adding,
      joining,
      section("This Mac", rows: [
        row("Install ID", caption: nil, control: idLine),
      ]),
    ]
  }

  @objc private func addMac(_ sender: NSButton) {
    sender.isEnabled = false
    DispatchQueue.global(qos: .userInitiated).async {
      var code: NSString?
      var stderrLine: NSString?
      let result = rampMintSeatCode(&code, &stderrLine)
      let text = code as String?
      let message = stderrLine as String?
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.finishAddMac(ok: result == 0, code: text, message: message)
        }
      }
    }
  }

  @objc private func redeemMac(_ sender: NSButton) {
    let typed = seatField.stringValue
    sender.isEnabled = false
    DispatchQueue.global(qos: .userInitiated).async {
      var stdoutLine: NSString?
      var stderrLine: NSString?
      let result = rampRedeemSeatCode(typed, &stdoutLine, &stderrLine)
      let message = (stderrLine as String?) ?? (stdoutLine as String?)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.finishRedeem(ok: result == 0, message: message)
        }
      }
    }
  }

  private func finishAddMac(ok: Bool, code: String?, message: String?) {
    addMacButton.isEnabled = true
    if ok, let code, !code.isEmpty {
      seatCode.stringValue = code
      seatCode.isHidden = false
      licenseStatus.stringValue = "Use this code on the other Mac."
      licenseStatus.textColor = .secondaryLabelColor
      licenseDot?.color = .secondaryLabelColor
      return
    }
    if let message, !message.isEmpty {
      licenseStatus.stringValue = message
      licenseStatus.textColor = .systemOrange
      licenseDot?.color = .systemOrange
    }
  }

  private func finishRedeem(ok: Bool, message: String?) {
    redeemButton.isEnabled = true
    if ok {
      seatField.stringValue = ""
      onRefresh?()
    }
    if let snapshot = facade?.snapshot() {
      refresh(snapshot)
    }
    if !ok, let message, !message.isEmpty {
      licenseStatus.stringValue = message
      licenseStatus.textColor = .systemOrange
      licenseDot?.color = .systemOrange
    }
  }

  private func proPurchaseRow() -> NSView {
    let name = NSTextField(labelWithString: "Nightshift Pro")
    name.font = .systemFont(ofSize: NSFont.systemFontSize)
    name.translatesAutoresizingMaskIntoConstraints = false
    let note = NSTextField(wrappingLabelWithString: "Opens checkout in your browser.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.alignment = .right
    note.preferredMaxLayoutWidth = 260
    note.translatesAutoresizingMaskIntoConstraints = false
    buyButton.translatesAutoresizingMaskIntoConstraints = false
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(name)
    row.addSubview(buyButton)
    row.addSubview(note)
    NSLayoutConstraint.activate([
      row.widthAnchor.constraint(equalToConstant: 480),
      name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
      name.centerYAnchor.constraint(equalTo: buyButton.centerYAnchor),
      buyButton.topAnchor.constraint(equalTo: row.topAnchor, constant: 18),
      buyButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
      buyButton.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
      note.topAnchor.constraint(equalTo: buyButton.bottomAnchor, constant: 6),
      note.trailingAnchor.constraint(equalTo: buyButton.trailingAnchor),
      note.widthAnchor.constraint(equalToConstant: 260),
      note.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -18),
    ])
    return row
  }

  private func aboutSections() -> [NSView] {
    let icon = NSImageView(image: settingsTile(size: 144))
    icon.imageScaling = .scaleNone
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 144),
      icon.heightAnchor.constraint(equalToConstant: 144),
    ])
    let name = NSTextField(labelWithString: "Nightshift")
    name.font = .systemFont(ofSize: 15, weight: .semibold)
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    let versionText: String
    if let version, let build {
      versionText = "Version \(version) (\(build))"
    } else if let version {
      versionText = "Version \(version)"
    } else {
      versionText = "Development build"
    }
    let versionLabel = NSTextField(labelWithString: versionText)
    versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    versionLabel.textColor = .secondaryLabelColor
    versionLabel.isSelectable = true
    let variant = variantRow()
    let words = NSStackView(views: [
      name,
      versionLabel,
      variant,
      aboutLink("Acknowledgements", "https://freechie.github.io/nightshift/acknowledgements.html"),
      aboutLink("Privacy Policy", "https://freechie.github.io/nightshift/privacy.html"),
      aboutLink("Terms of Service", "https://freechie.github.io/nightshift/terms.html"),
    ])
    words.orientation = .vertical
    words.alignment = .leading
    words.spacing = 2
    words.setCustomSpacing(8, after: variant)
    let hero = NSStackView(views: [icon, words])
    hero.orientation = .horizontal
    hero.alignment = .centerY
    hero.spacing = 18
    hero.setContentHuggingPriority(.required, for: .horizontal)
    let report = push("Report an Issue…", #selector(openLink(_:)), "Report an Issue")
    report.identifier = NSUserInterfaceItemIdentifier("https://github.com/freechie/nightshift/issues")
    let legal = NSStackView(views: [
      aboutFinePrint("Copyright 2026 John."),
      aboutFinePrint("Licensed under the Apache License 2.0."),
      aboutFinePrint("Nightshift is a trademark of John."),
    ])
    legal.orientation = .vertical
    legal.alignment = .centerX
    legal.spacing = 2
    let column = NSStackView(views: [hero, report, legal])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = 16
    column.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    column.setContentHuggingPriority(.required, for: .horizontal)
    return [column]
  }

  private func aboutPage() -> NSView {
    let body = scroll(sections: aboutSections())
    let footer = updateFooter()
    let page = NSView()
    body.translatesAutoresizingMaskIntoConstraints = false
    footer.translatesAutoresizingMaskIntoConstraints = false
    page.addSubview(body)
    page.addSubview(footer)
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: page.topAnchor),
      body.leadingAnchor.constraint(equalTo: page.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: page.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: page.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: page.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: page.bottomAnchor),
    ])
    return page
  }

  private func updateFooter() -> NSView {
    let content = updateControls()
    let rule = MenuHairline(frame: .zero)
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    rule.heightAnchor.constraint(equalToConstant: 1 / max(scale, 1)).isActive = true
    let footer = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    footer.addSubview(rule)
    footer.addSubview(content)
    let inset: CGFloat = 20
    NSLayoutConstraint.activate([
      rule.topAnchor.constraint(equalTo: footer.topAnchor),
      rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: inset),
      rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -inset),
      content.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
      content.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -18),
    ])
    return footer
  }

  private func updateControls() -> NSView {
    updateAuto.target = self
    updateAuto.action = #selector(updateAutoChanged(_:))
    let install = NSButton(checkboxWithTitle: "Install Updates Automatically", target: nil, action: nil)
    install.state = .off
    install.isEnabled = false
    install.toolTip = "Not available."
    let channelLabel = NSTextField(labelWithString: "Update to:")
    let channel = NSPopUpButton()
    channel.addItem(withTitle: "Stable versions")
    channel.setAccessibilityLabel("Update channel")
    let info = NSButton()
    info.bezelStyle = .helpButton
    info.title = ""
    info.toolTip = "GitHub releases."
    info.setAccessibilityLabel("About stable versions")
    let channelRow = NSStackView(views: [channelLabel, channel, info])
    channelRow.orientation = .horizontal
    channelRow.alignment = .centerY
    channelRow.spacing = 6
    updateLast.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    updateLast.textColor = .secondaryLabelColor
    updateLast.alignment = .right
    updateStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    updateStatus.textColor = .secondaryLabelColor
    updateStatus.alignment = .right
    let check = push("Check Now", #selector(checkForUpdatesNow(_:)), "Check Now")
    updateCheckButton = check
    let column = NSStackView(views: [
      updatePair(updateAuto, check),
      updatePair(install, updateLast, baseline: install),
      updatePair(channelRow, updateStatus, baseline: channelLabel),
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    for row in column.arrangedSubviews {
      row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    showSavedUpdate()
    return column
  }

  private func updatePair(_ left: NSView, _ right: NSView, baseline: NSView? = nil) -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    right.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [left, spacer, right])
    row.orientation = .horizontal
    row.alignment = baseline == nil ? .centerY : .firstBaseline
    row.spacing = 12
    if let baseline {
      right.firstBaselineAnchor.constraint(equalTo: baseline.firstBaselineAnchor).isActive = true
    }
    return row
  }

  @objc private func updateAutoChanged(_ sender: NSButton) {
    UserDefaults.standard.set(sender.state == .on, forKey: Self.updateAutoKey)
    if sender.state == .on {
      checkForUpdates(manual: false)
    }
  }

  @objc private func checkForUpdatesNow(_ sender: NSButton) {
    checkForUpdates(manual: true)
  }

  private func checkForUpdates(manual: Bool) {
    if updateChecking { return }
    if !manual && !updateIsStale() { return }
    updateChecking = true
    updateCheckButton?.isEnabled = false
    if manual || updateStatus.stringValue == "Not checked yet." {
      updateStatus.stringValue = "Checking…"
    }
    let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    Task {
      let notice = await Self.fetchUpdateNotice(local: local)
      self.updateChecking = false
      self.updateCheckButton?.isEnabled = true
      guard let notice else {
        if manual { self.updateStatus.stringValue = "Couldn't check for updates." }
        return
      }
      let now = Date()
      UserDefaults.standard.set(now, forKey: Self.updateCheckedKey)
      UserDefaults.standard.set(notice, forKey: Self.updateMessageKey)
      self.updateLast.stringValue = "Last check: \(self.updateDate(now))"
      self.updateStatus.stringValue = notice
    }
  }

  private func showSavedUpdate() {
    updateAuto.state = updateAutoOn() ? .on : .off
    if let stamp = UserDefaults.standard.object(forKey: Self.updateCheckedKey) as? Date {
      updateLast.stringValue = "Last check: \(updateDate(stamp))"
    } else {
      updateLast.stringValue = "Last check: Never"
    }
    updateStatus.stringValue = UserDefaults.standard.string(forKey: Self.updateMessageKey) ?? "Not checked yet."
  }

  private func updateAutoOn() -> Bool {
    if UserDefaults.standard.object(forKey: Self.updateAutoKey) == nil { return true }
    return UserDefaults.standard.bool(forKey: Self.updateAutoKey)
  }

  private func updateIsStale() -> Bool {
    guard updateAutoOn() else { return false }
    guard let stamp = UserDefaults.standard.object(forKey: Self.updateCheckedKey) as? Date else { return true }
    return Date().timeIntervalSince(stamp) > 60 * 60 * 24
  }

  private func updateDate(_ date: Date) -> String {
    let format = DateFormatter()
    format.dateStyle = .short
    format.timeStyle = .short
    return format.string(from: date)
  }

  private static let updateAutoKey = "nightshift.update.auto"
  private static let updateCheckedKey = "nightshift.update.checkedAt"
  private static let updateMessageKey = "nightshift.update.message"

  private static func fetchUpdateNotice(local: String) async -> String? {
    guard let url = URL(string: "https://api.github.com/repos/freechie/nightshift/releases/latest") else { return nil }
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 20
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      if http.statusCode == 404 { return "No release published." }
      guard http.statusCode == 200 else { return nil }
      struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey {
          case tagName = "tag_name"
        }
      }
      let tag = try JSONDecoder().decode(Release.self, from: data).tagName
      return updateNotice(local: local, remoteTag: tag)
    } catch {
      return nil
    }
  }

  private func variantRow() -> NSView {
    let label = NSTextField(labelWithString: "Standalone variant")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    let info = NSButton()
    info.isBordered = false
    info.setButtonType(.momentaryChange)
    info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About this variant")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    info.imageScaling = .scaleProportionallyDown
    info.contentTintColor = .secondaryLabelColor
    info.target = self
    info.action = #selector(showVariantInfo(_:))
    info.toolTip = "About this variant"
    info.setAccessibilityLabel("About this variant")
    let row = NSStackView(views: [label, info])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 4
    return row
  }

  @objc private func showVariantInfo(_ sender: NSButton) {
    let popover = variantPopover ?? NSPopover()
    if variantPopover == nil {
      popover.behavior = .transient
      popover.animates = true
      popover.contentSize = NSSize(width: 280, height: 120)
      let controller = NSViewController()
      let view = variantInfoView()
      controller.view = view
      popover.contentSize = view.frame.size
      popover.contentViewController = controller
      variantPopover = popover
    }
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
  }

  private func variantInfoView() -> NSView {
    let message = "This is the standalone Nightshift build. Mac App Store and open source builds are not available yet."
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let text = NSTextField(wrappingLabelWithString: message)
    text.font = font
    text.preferredMaxLayoutWidth = 252
    let measured = NSAttributedString(string: message, attributes: [.font: font]).boundingRect(
      with: NSSize(width: 252, height: 400),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let textHeight = ceil(measured.height) + 2
    let more = push("More Info…", #selector(aboutNowhere(_:)), "More Info")
    more.sizeToFit()
    let buttonHeight = max(more.frame.height, 24)
    let height = 14 + textHeight + 12 + buttonHeight + 14
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
    text.frame = NSRect(x: 14, y: height - 14 - textHeight, width: 252, height: textHeight)
    more.frame = NSRect(x: 14, y: 14, width: more.frame.width, height: buttonHeight)
    box.addSubview(text)
    box.addSubview(more)
    return box
  }

  private func aboutLink(_ title: String, _ url: String) -> NSButton {
    let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(url)
    button.isBordered = false
    button.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: NSColor.linkColor,
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      ]
    )
    button.alignment = .left
    button.setAccessibilityLabel(title)
    return button
  }

  @objc private func aboutNowhere(_ sender: NSButton) {}

  private func aboutFinePrint(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.preferredMaxLayoutWidth = 420
    return label
  }

  private func scroll(sections: [NSView]) -> NSView {
    let stack = NSStackView(views: sections)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 20
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let document = SettingsFlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      stack.widthAnchor.constraint(equalTo: document.widthAnchor),
    ])
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = document
    let clip = scroll.contentView
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
    ])
    return scroll
  }

  private func section(_ title: String?, accessory: NSView? = nil, rows: [NSView], footer: String? = nil) -> NSView {
    var parts: [NSView] = []
    var header: NSView?
    if let title {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      label.lineBreakMode = .byTruncatingTail
      var headParts: [NSView] = [label]
      if let accessory {
        headParts.append(accessory)
      }
      let head = NSStackView(views: headParts)
      head.orientation = .horizontal
      head.alignment = .centerY
      head.spacing = 6
      head.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
      parts.append(head)
      header = head
    }
    parts.append(group(rows))
    if let footer {
      let foot = NSTextField(wrappingLabelWithString: footer)
      foot.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      foot.textColor = .secondaryLabelColor
      foot.preferredMaxLayoutWidth = 460
      let footBox = NSStackView(views: [foot])
      footBox.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
      parts.append(footBox)
    }
    let stack = NSStackView(views: parts)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    if let header {
      stack.setCustomSpacing(8, after: header)
    }
    return stack
  }

  private func group(_ rows: [NSView]) -> NSView {
    var parts: [NSView] = []
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    for row in rows {
      if !parts.isEmpty {
        let line = MenuHairline(frame: .zero)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 460).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1 / max(scale, 1)).isActive = true
        parts.append(line)
      }
      parts.append(row)
    }
    let stack = NSStackView(views: parts)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    let box = SettingsGroupView()
    box.wantsLayer = true
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
      stack.topAnchor.constraint(equalTo: box.topAnchor),
      stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
      box.widthAnchor.constraint(equalToConstant: 480),
    ])
    return box
  }

  private func row(_ title: String, caption: String?, control: NSView?, below: Bool = false) -> NSView {
    let captionField = SettingsFormCaption(wrappingLabelWithString: caption ?? "")
    captionField.isHidden = caption == nil
    return row(title, captionView: captionField, control: control, below: below)
  }

  private func row(_ title: String, captionView: NSTextField, control: NSView?, below: Bool = false) -> NSView {
    let name = NSTextField(labelWithString: title)
    name.font = .systemFont(ofSize: NSFont.systemFontSize)
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    captionView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    captionView.textColor = .secondaryLabelColor
    captionView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    var texts: [NSView] = [name]
    if !captionView.isHidden || captionView.stringValue.isEmpty == false || captionView === maxCaption || captionView === fullCaption {
      texts.append(captionView)
    }
    let words = NSStackView(views: texts)
    words.orientation = .vertical
    words.alignment = .leading
    words.spacing = 2
    words.setContentHuggingPriority(.defaultLow, for: .horizontal)
    if texts.contains(captionView) {
      captionView.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
    }
    let controlWidth = below || control == nil ? 0 : (control?.fittingSize.width ?? 0) + 12
    captionView.preferredMaxLayoutWidth = 480 - 20 - controlWidth
    if below {
      words.widthAnchor.constraint(equalToConstant: 460).isActive = true
    }
    var parts: [NSView] = [words]
    if let control {
      hug(control)
      if control.accessibilityLabel() == nil || control.accessibilityLabel()?.isEmpty == true {
        control.setAccessibilityLabel(title)
      }
      parts.append(control)
    }
    let line = NSStackView(views: parts)
    line.orientation = below ? .vertical : .horizontal
    line.alignment = below ? .leading : .centerY
    line.spacing = below ? 8 : 12
    if !below {
      line.distribution = .fill
      line.setHuggingPriority(.defaultLow, for: .horizontal)
    }
    if below, let control {
      control.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
    }
    line.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    line.translatesAutoresizingMaskIntoConstraints = false
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(line)
    NSLayoutConstraint.activate([
      line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      line.topAnchor.constraint(equalTo: row.topAnchor),
      line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      row.widthAnchor.constraint(equalToConstant: 480),
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    return row
  }

  private func hug(_ view: NSView) {
    if view is TintChooser { return }
    if let stack = view as? NSStackView {
      let across = stack.orientation == .vertical
      let priority: NSLayoutConstraint.Priority = across ? .init(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1) : .required
      stack.setHuggingPriority(priority, for: .horizontal)
      for part in stack.arrangedSubviews {
        hug(part)
      }
    } else {
      view.setContentHuggingPriority(.required, for: .horizontal)
      view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
  }

  private func settingsTile(size: CGFloat) -> NSImage {
    let colors = [
      NSColor(srgbRed: 0.16, green: 0.17, blue: 0.42, alpha: 1),
      NSColor(srgbRed: 0.49, green: 0.25, blue: 0.53, alpha: 1),
      NSColor(srgbRed: 1.00, green: 0.62, blue: 0.34, alpha: 1),
    ]
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      let tileRect = rect.insetBy(dx: rect.width * 0.1, dy: rect.width * 0.1)
      let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRect.width * 0.225, yRadius: tileRect.width * 0.225)
      NSGradient(colors: colors)?.draw(in: tile, angle: -90)
      let config = NSImage.SymbolConfiguration(pointSize: tileRect.width * 0.36, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
      if let symbol = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: "Nightshift")?.withSymbolConfiguration(config) {
        let target = NSRect(
          x: tileRect.midX - symbol.size.width / 2,
          y: tileRect.midY - symbol.size.height / 2,
          width: symbol.size.width,
          height: symbol.size.height
        )
        symbol.draw(in: target)
      }
      return true
    }
  }

  private func installSettingsMenu() {
    if NSApp.mainMenu != nil { return }
    let bar = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "Nightshift")
    appMenu.addItem(withTitle: "Close Nightshift Settings", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
    appItem.submenu = appMenu
    bar.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    bar.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowItem.submenu = windowMenu
    bar.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    NSApp.mainMenu = bar
  }

  private func push(_ title: String, _ action: Selector, _ label: String) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(label)
    return button
  }

  private func modeTitle(_ mode: ScheduleMode) -> String {
    switch mode {
    case .off: "Off"
    case .custom: "Custom"
    case .sunsetToSunrise: "Sunset to Sunrise"
    }
  }

  private func loginOn() -> Bool {
    SMAppService.mainApp.status == .enabled
  }

  private func openAllowed(_ text: String) {
    guard let url = rampWorkspaceURL(text) as URL? else { return }
    NSWorkspace.shared.open(url)
  }

  private func licenseDay(_ until: String) -> String {
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.timeZone = TimeZone(secondsFromGMT: 0)
    parse.dateFormat = "yyyy-MM-dd"
    guard let date = parse.date(from: until) else { return until }
    let show = DateFormatter()
    show.timeZone = parse.timeZone
    show.dateStyle = .medium
    show.timeStyle = .none
    return show.string(from: date)
  }
}
