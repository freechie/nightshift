import AppKit

enum MenuLayout {
  static let width: CGFloat = 300
  static let margin: CGFloat = 14
  static let content: CGFloat = 272
}

// Text on an accent fill: white, or near-black when the accent is light.
func textOnAccent() -> NSColor {
  guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
    return .white
  }
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  accent.getRed(&r, green: &g, blue: &b, alpha: &a)
  let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
  return luma > 0.7 ? NSColor(white: 0, alpha: 0.85) : .white
}

func barFillColor(_ tint: BarTint) -> NSColor {
  switch tint {
  case .accent:
    .controlAccentColor
  case .primary(let primary):
    primary.systemColor
  case .custom(let red, let green, let blue):
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
  }
}

extension BarPrimary {
  var systemColor: NSColor {
    switch self {
    case .blue: .systemBlue
    case .purple: .systemPurple
    case .pink: .systemPink
    case .red: .systemRed
    case .orange: .systemOrange
    case .yellow: .systemYellow
    case .green: .systemGreen
    case .graphite: .systemGray
    }
  }

  var title: String {
    switch self {
    case .blue: "Blue"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .graphite: "Graphite"
    }
  }
}

func barTintTitle(_ tint: BarTint) -> String {
  switch tint {
  case .accent: "Accent"
  case .primary(let primary): primary.title
  case .custom: "Custom"
  }
}

func menuBarImage(for tint: BarTint) -> NSImage? {
  let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [barFillColor(tint)]))
  guard let glyph = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else { return nil }
  let image = NSImage(size: glyph.size, flipped: false) { rect in
    glyph.draw(in: rect)
    return true
  }
  image.accessibilityDescription = "Nightshift"
  image.isTemplate = false
  return image
}

// Hand-drawn track for macOS before 26. Tick marks would drop the accent fill,
// so the bar and knob ride up inside a taller slider and the ticks sit below.
// macOS 26 and later use the system slider instead, which has the liquid-glass knob.
final class AccentSliderCell: NSSliderCell {
  static let tickRoom: CGFloat = 8
  var fillColor: NSColor = .controlAccentColor

  override func barRect(flipped: Bool) -> NSRect {
    raised(super.barRect(flipped: flipped), flipped: flipped)
  }

  override func knobRect(flipped: Bool) -> NSRect {
    raised(super.knobRect(flipped: flipped), flipped: flipped)
  }

  private func raised(_ rect: NSRect, flipped: Bool) -> NSRect {
    guard !isVertical, sliderType == .linear else { return rect }
    let lift = AccentSliderCell.tickRoom / 2
    return rect.offsetBy(dx: 0, dy: flipped ? -lift : lift)
  }

  override func drawBar(inside rect: NSRect, flipped: Bool) {
    if isVertical || sliderType != .linear {
      super.drawBar(inside: rect, flipped: flipped)
      return
    }
    let thickness = min(6, controlView?.bounds.height ?? 6)
    let track = NSRect(
      x: rect.minX,
      y: rect.midY - thickness / 2,
      width: rect.width,
      height: thickness
    )
    let radius = thickness / 2
    let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
    NSColor.quaternaryLabelColor.setFill()
    trackPath.fill()

    let knob = knobRect(flipped: flipped)
    let end = max(track.minX, min(knob.midX, track.maxX))
    var filled = track
    filled.size.width = end - track.minX
    if filled.width > 0 {
      let fill: NSColor = isEnabled ? fillColor : .tertiaryLabelColor
      NSGraphicsContext.saveGraphicsState()
      trackPath.addClip()
      fill.setFill()
      filled.fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    let rim = NSBezierPath(
      roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
      xRadius: max(0, radius - 0.5),
      yRadius: max(0, radius - 0.5)
    )
    rim.lineWidth = 1
    NSColor.white.withAlphaComponent(0.14).setStroke()
    rim.stroke()

    // Ticks under the bar at the knob travel ends and mid. Knob center travels
    // knob.width / 2 in from each end, so fractions 0 / 0.5 / 1 line up with
    // min / mid / max even on a 1...100 range. Drawn a little below the track.
    let span = maxValue - minValue
    guard span > 0 else { return }
    let travelMinX = rect.minX + knob.width / 2
    let travelWidth = rect.width - knob.width
    // Slight gap under the track so ticks sit below the bar, not flush on it.
    let gap: CGFloat = 2
    let attached = flipped ? track.maxY + gap : track.minY - gap
    let tickLen: CGFloat = 2.5
    let fractions: [CGFloat] = [0, 0.5, 1]
    NSColor.tertiaryLabelColor.setStroke()
    for fraction in fractions {
      let x = (travelMinX + fraction * travelWidth).rounded() + 0.5
      let tick = NSBezierPath()
      tick.move(to: NSPoint(x: x, y: attached))
      tick.line(to: NSPoint(x: x, y: flipped ? attached + tickLen : attached - tickLen))
      tick.lineWidth = 1.5
      tick.lineCapStyle = .round
      tick.stroke()
    }
  }
}

final class ReleaseSlider: NSSlider {
  var commitsOnRelease = false
  private var releasing = false
  private var snapped = false
  private static let mid = 50

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    useSystemTrack()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    useSystemTrack()
  }

  override var minValue: Double {
    didSet { syncNeutral() }
  }

  // Tick marks would leave the track untinted. Primary prominence keeps the accent fill.
  private func useSystemTrack() {
    if #available(macOS 26.0, *) {
      numberOfTickMarks = 3
      tickMarkPosition = .below
      allowsTickMarkValuesOnly = false
      tintProminence = .primary
      syncNeutral()
    } else {
      cell = AccentSliderCell()
    }
    applyBarFill()
  }

  var barFill: NSColor = .controlAccentColor {
    didSet { applyBarFill() }
  }

  override var isEnabled: Bool {
    didSet { applyBarFill() }
  }

  // A disabled bar stays gray. An enabled bar uses the Settings color.
  private func applyBarFill() {
    if #available(macOS 26.0, *) {
      trackFillColor = isEnabled ? barFill : .tertiaryLabelColor
    } else if let accent = cell as? AccentSliderCell {
      accent.fillColor = barFill
    }
    needsDisplay = true
  }

  private func syncNeutral() {
    if #available(macOS 26.0, *) {
      neutralValue = minValue
    }
  }

  override var intrinsicContentSize: NSSize {
    var size = super.intrinsicContentSize
    if #available(macOS 26.0, *) {
      return size
    }
    if !isVertical {
      size.height += AccentSliderCell.tickRoom
    }
    return size
  }

  // Live warmth while the bead is held needs commitsOnRelease = false so every
  // continuous action applies. Release-only sliders (Ramp Max) keep the gate.
  var shouldCommit: Bool {
    if commitsOnRelease {
      return releasing || NSApp.currentEvent?.type == .keyDown
    }
    return true
  }

  // Release (mouse up or the post-tracking send) or an arrow key: apply in full.
  // Anything else is a live drag tick.
  var isSettling: Bool {
    if releasing { return true }
    let type = NSApp.currentEvent?.type
    return type == .leftMouseUp || type == .keyDown
  }

  // Magnet with hysteresis while dragging: catch the thumb near mid, hold it
  // at mid until the pointer pulls clearly away (shouldStaySnapped). AppKit
  // sets the raw pointer value before each action, so integerValue is raw here.
  // Continuous commit (Color temperature) applies each action; release-only
  // sliders fire once on mouse up. Arrow keys step freely so they can leave mid.
  func snapToMid() -> Int {
    let mid = ReleaseSlider.mid
    if NSApp.currentEvent?.type == .keyDown {
      snapped = false
      return integerValue
    }
    if !releasing {
      snapped = shouldStaySnapped(raw: integerValue, snapped: snapped, mid: mid)
    }
    if snapped, integerValue != mid {
      integerValue = mid
    }
    return integerValue
  }

  override func mouseDown(with event: NSEvent) {
    snapped = false
    super.mouseDown(with: event)
    defer { snapped = false }
    releasing = true
    sendAction(action, to: target)
    releasing = false
  }
}

final class MenuHairline: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let color = dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)
    layer?.backgroundColor = color.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

final class ProBadge: NSView {
  private let label = NSTextField(labelWithString: "PRO")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 9.5, weight: .bold)
    label.textColor = textOnAccent()
    label.translatesAutoresizingMaskIntoConstraints = false
    toolTip = "Unlock the ramp with Pro"
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 15),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    layer?.cornerRadius = bounds.height / 2
    label.textColor = textOnAccent()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }
}

@MainActor
final class SectionHeader: NSView {
  let titleField: NSTextField
  private let chevron = NSImageView()
  var onToggle: @MainActor () -> Void = {}
  private(set) var isCollapsed = false

  init(title: String, badge: NSView?, value: NSTextField? = nil) {
    titleField = NSTextField(labelWithString: title)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    titleField.textColor = .labelColor
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    symbol = symbol?.withSymbolConfiguration(config)
    symbol?.isTemplate = true
    chevron.image = symbol
    chevron.contentTintColor = .secondaryLabelColor
    chevron.imageScaling = .scaleProportionallyDown
    chevron.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
    let box = NSView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(chevron)
    box.widthAnchor.constraint(equalToConstant: 12).isActive = true
    box.heightAnchor.constraint(equalToConstant: 12).isActive = true

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

    var views: [NSView] = [titleField]
    if let badge {
      views.append(badge)
    }
    views.append(spacer)
    if let value {
      value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      value.alignment = .right
      value.setContentHuggingPriority(.required, for: .horizontal)
      views.append(value)
    }
    views.append(box)
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.detachesHiddenViews = true
    row.translatesAutoresizingMaskIntoConstraints = false
    if badge != nil {
      row.setCustomSpacing(8, after: titleField)
    }
    addSubview(row)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: MenuLayout.content),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setCollapsed(false)
  }

  required init?(coder: NSCoder) {
    titleField = NSTextField(labelWithString: "")
    super.init(coder: coder)
  }

  func setCollapsed(_ collapsed: Bool) {
    isCollapsed = collapsed
    chevron.frameCenterRotation = collapsed ? 0 : -90
    setAccessibilityLabel("\(titleField.stringValue), \(collapsed ? "collapsed" : "expanded")")
  }

  @objc private func clicked() {
    onToggle()
  }

  override func accessibilityPerformPress() -> Bool {
    onToggle()
    return true
  }
}

// Renders a MenuSnapshot and emits intents. Layout follows the ObjC status panel:
// intensity, schedule, ramp, appearance. Renew stays hidden.
@MainActor
final class MenuPanel: NSView {
  var onIntent: @MainActor (MenuIntent) -> Void = { _ in }

  private let currentSlider = ReleaseSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
  private let currentValue = NSTextField(labelWithString: "0%")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let scheduleControl = NSSegmentedControl(
    labels: ["Off", "Custom", "Sunset to Sunrise"],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let maxSlider = ReleaseSlider(value: 50, minValue: 1, maxValue: 100, target: nil, action: nil)
  private let maxValue = NSTextField(labelWithString: "—")
  private let proBadge = ProBadge(frame: .zero)
  private let rampHeader: SectionHeader
  private let rampBody: NSStackView
  private let fullName = NSTextField(labelWithString: "Full at")
  private let fullPicker = NSDatePicker()
  private let appearanceHeader: SectionHeader
  private let appearanceBody: NSStackView
  private let darkButton = NSButton(title: "", target: nil, action: nil)
  private let toneButton = NSButton(title: "", target: nil, action: nil)
  private var snapshot = MenuSnapshot.unavailable
  private var rendering = false
  private var stack: NSStackView?

  override init(frame frameRect: NSRect) {
    rampHeader = SectionHeader(title: "Max", badge: proBadge, value: maxValue)
    appearanceHeader = SectionHeader(title: "Appearance", badge: nil)
    rampBody = NSStackView()
    appearanceBody = NSStackView()
    super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 280))
    wire()
    assemble()
  }

  required init?(coder: NSCoder) {
    rampHeader = SectionHeader(title: "Max", badge: proBadge, value: maxValue)
    appearanceHeader = SectionHeader(title: "Appearance", badge: nil)
    rampBody = NSStackView()
    appearanceBody = NSStackView()
    super.init(coder: coder)
  }

  func render(_ snapshot: MenuSnapshot) {
    rendering = true
    defer {
      fit()
      rendering = false
    }
    self.snapshot = snapshot
    let fill = barFillColor(barTint())
    currentSlider.barFill = fill
    maxSlider.barFill = fill
    showWarmth(snapshot.warmth)
    let segment = snapshot.schedule.segment
    if scheduleControl.selectedSegment != segment {
      scheduleControl.selectedSegment = segment
    }
    showRamp(snapshot)
    showAppearance(snapshot)
    rampHeader.setCollapsed(snapshot.collapsed.contains(.ramp))
    rampBody.isHidden = snapshot.collapsed.contains(.ramp)
    appearanceHeader.setCollapsed(snapshot.collapsed.contains(.appearance))
    appearanceBody.isHidden = snapshot.collapsed.contains(.appearance)
  }

  private func wire() {
    currentSlider.target = self
    currentSlider.action = #selector(currentChanged(_:))
    currentSlider.isContinuous = true
    currentSlider.commitsOnRelease = false
    currentSlider.setAccessibilityLabel("Color temperature")

    maxSlider.target = self
    maxSlider.action = #selector(maxChanged(_:))
    maxSlider.isContinuous = true
    maxSlider.commitsOnRelease = true
    maxSlider.setAccessibilityLabel("Max")

    scheduleControl.target = self
    scheduleControl.action = #selector(scheduleChanged(_:))
    scheduleControl.segmentDistribution = .fillProportionally
    scheduleControl.controlSize = .small
    scheduleControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    scheduleControl.selectedSegmentBezelColor = .controlAccentColor
    scheduleControl.setAccessibilityLabel("Night Shift schedule")

    fullPicker.datePickerStyle = .textFieldAndStepper
    fullPicker.datePickerElements = .hourMinute
    fullPicker.datePickerMode = .single
    fullPicker.isBezeled = true
    fullPicker.calendar = menuCalendar()
    fullPicker.timeZone = .current
    fullPicker.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    fullPicker.target = self
    fullPicker.action = #selector(fullAtChanged(_:))
    fullPicker.setAccessibilityLabel("Full at")

    darkButton.target = self
    darkButton.action = #selector(darkClicked(_:))
    toneButton.target = self
    toneButton.action = #selector(toneClicked(_:))
    styleAppearanceButton(darkButton)
    styleAppearanceButton(toneButton)

    rampHeader.onToggle = { [weak self] in
      self?.onIntent(.toggle(.ramp))
    }
    appearanceHeader.onToggle = { [weak self] in
      self?.onIntent(.toggle(.appearance))
    }
  }

  private func assemble() {
    let nightTitle = sectionLabel("Night Shift Intensity")
    message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    message.textColor = .secondaryLabelColor
    message.preferredMaxLayoutWidth = MenuLayout.content
    message.maximumNumberOfLines = 3
    message.isHidden = true
    let titleRow = titleValueRow(title: nightTitle, value: currentValue)
    let currentRow = colorTemperatureRow(slider: currentSlider)
    let night = verticalStack([titleRow, message, currentRow, scheduleControl], spacing: 10)
    night.setCustomSpacing(14, after: currentRow)
    scheduleControl.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true

    maxSlider.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
    fullName.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    fullName.setContentHuggingPriority(.required, for: .horizontal)
    let fullRow = NSStackView(views: [fullName, fullPicker])
    fullRow.orientation = .horizontal
    fullRow.alignment = .centerY
    fullRow.spacing = 8
    fullRow.translatesAutoresizingMaskIntoConstraints = false
    fullRow.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
    fillStack(rampBody, views: [maxSlider, fullRow], spacing: 10)
    rampBody.setCustomSpacing(14, after: maxSlider)
    let ramp = verticalStack([rampHeader, rampBody], spacing: 10)

    fillStack(appearanceBody, views: [darkButton, toneButton], spacing: 8)
    let appearance = verticalStack([appearanceHeader, appearanceBody], spacing: 10)

    let hairlineA = MenuHairline(frame: .zero)
    let hairlineB = MenuHairline(frame: .zero)
    for line in [hairlineA, hairlineB] {
      line.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
      line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    let stack = verticalStack([night, hairlineA, ramp, hairlineB, appearance], spacing: 12)
    stack.edgeInsets = NSEdgeInsets(top: 12, left: MenuLayout.margin, bottom: 8, right: MenuLayout.margin)
    self.stack = stack
    addSubview(stack)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: MenuLayout.width),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func showWarmth(_ reading: WarmthReading) {
    switch reading {
    case .on(let warmth):
      currentValue.stringValue = "\(warmth.percent)%"
      message.isHidden = true
    case .off:
      currentValue.stringValue = "Off"
      message.isHidden = true
    case .unreadable, .unavailable:
      currentValue.stringValue = "—"
      message.stringValue = menuTitle(for: reading)
      message.isHidden = false
    }
    let state = sliderState(for: reading)
    currentSlider.isEnabled = state.isEnabled
    if let value = state.value, currentSlider.integerValue != value {
      currentSlider.integerValue = value
    }
  }

  private func showRamp(_ snapshot: MenuSnapshot) {
    let controls = rampControls(licensed: snapshot.rampLicensed, schedule: snapshot.schedule)
    proBadge.isHidden = !controls.showsPro
    let display = maxSliderDisplay(saved: snapshot.maxPercent, warmth: snapshot.warmth)
    maxSlider.isEnabled = controls.maxEnabled
    maxSlider.alphaValue = controls.maxEnabled ? 1 : 0.4
    if maxSlider.integerValue != display.value {
      maxSlider.integerValue = display.value
    }
    maxValue.stringValue = display.text
    maxValue.textColor = controls.maxEnabled ? .labelColor : .tertiaryLabelColor

    fullPicker.isEnabled = controls.fullAtEnabled
    fullPicker.alphaValue = controls.fullAtEnabled ? 1 : 0.4
    fullName.textColor = controls.fullAtEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    let shown = snapshot.fullAtMinute ?? minute(of: Date())
    if minute(of: fullPicker.dateValue) != shown, let date = date(minute: shown) {
      fullPicker.dateValue = date
    }
  }

  private func showAppearance(_ snapshot: MenuSnapshot) {
    styleCheck(darkButton, title: "Dark mode", symbol: "circle.lefthalf.filled", on: snapshot.darkModeOn)
    if let tone = snapshot.trueTone {
      toneButton.isHidden = false
      styleCheck(toneButton, title: "True Tone", symbol: "lightspectrum.horizontal", on: tone)
    } else {
      toneButton.isHidden = true
    }
  }

  private func fit() {
    // The stack's fitting size includes the section insets. The panel frame
    // is what the menu item uses as its height.
    let measured = stack ?? self
    measured.layoutSubtreeIfNeeded()
    var size = measured.fittingSize
    if size.width < MenuLayout.width {
      size.width = MenuLayout.width
    }
    if size.height < 40 {
      size.height = 240
    }
    frame = NSRect(origin: .zero, size: size)
  }

  private func sectionLabel(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    label.textColor = .labelColor
    return label
  }

  private func styleAppearanceButton(_ button: NSButton) {
    button.bezelStyle = .recessed
    button.isBordered = false
    button.setButtonType(.momentaryChange)
    button.imagePosition = .imageLeading
    button.alignment = .left
    button.font = .systemFont(ofSize: NSFont.systemFontSize)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
  }

  private func styleCheck(_ button: NSButton, title: String, symbol: String, on: Bool) {
    let color: NSColor = on ? .controlAccentColor : .labelColor
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    button.contentTintColor = color
    button.attributedTitle = NSAttributedString(
      string: "  \(title)",
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: color,
      ]
    )
  }

  // [Night Shift Intensity] ........ [64%]
  private func titleValueRow(title: NSTextField, value: NSTextField) -> NSStackView {
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    value.textColor = .secondaryLabelColor
    value.alignment = .right
    value.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [title, value])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
    return row
  }

  // Matches System Settings › Displays › Night Shift: Color temperature over a
  // full-width bar, Less Warm / More Warm under the bar ends.
  private func colorTemperatureRow(slider: NSSlider) -> NSStackView {
    let title = NSTextField(labelWithString: "Color temperature")
    title.font = .systemFont(ofSize: NSFont.systemFontSize)
    title.lineBreakMode = .byTruncatingTail
    title.maximumNumberOfLines = 1

    let less = NSTextField(labelWithString: "Less Warm")
    less.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    less.textColor = .secondaryLabelColor
    less.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let more = NSTextField(labelWithString: "More Warm")
    more.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    more.textColor = .secondaryLabelColor
    more.alignment = .right
    more.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let under = NSStackView(views: [less, more])
    under.orientation = .horizontal
    under.distribution = .fillEqually
    under.alignment = .firstBaseline
    under.spacing = 8
    under.translatesAutoresizingMaskIntoConstraints = false

    let column = NSStackView(views: [title, slider, under])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    column.setCustomSpacing(2, after: slider)
    column.translatesAutoresizingMaskIntoConstraints = false
    column.widthAnchor.constraint(equalToConstant: MenuLayout.content).isActive = true
    slider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    under.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
  }

  private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    styleStack(stack, spacing: spacing)
    return stack
  }

  private func fillStack(_ stack: NSStackView, views: [NSView], spacing: CGFloat) {
    styleStack(stack, spacing: spacing)
    for view in views {
      stack.addArrangedSubview(view)
    }
  }

  private func styleStack(_ stack: NSStackView, spacing: CGFloat) {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
  }

  @objc private func currentChanged(_ sender: NSSlider) {
    guard let slider = sender as? ReleaseSlider else { return }
    let value = slider.snapToMid()
    currentValue.stringValue = "\(value)%"
    guard !rendering, slider.shouldCommit, let warmth = Warmth(value) else { return }
    onIntent(slider.isSettling ? .setWarmth(warmth) : .stageWarmth(warmth))
  }

  @objc private func scheduleChanged(_ sender: NSSegmentedControl) {
    guard !rendering, let mode = ScheduleMode(segment: sender.selectedSegment) else { return }
    onIntent(.setSchedule(mode))
  }

  @objc private func maxChanged(_ sender: NSSlider) {
    guard let slider = sender as? ReleaseSlider else { return }
    let value = slider.snapToMid()
    maxValue.stringValue = "\(value)%"
    guard !rendering, slider.shouldCommit else { return }
    let controls = rampControls(licensed: snapshot.rampLicensed, schedule: snapshot.schedule)
    guard controls.maxEnabled else { return }
    onIntent(.setMax(value))
  }

  @objc private func fullAtChanged(_ sender: NSDatePicker) {
    guard !rendering else { return }
    onIntent(.setFullAt(minute(of: sender.dateValue)))
  }

  @objc private func darkClicked(_ sender: NSButton) {
    guard !rendering else { return }
    onIntent(.setDarkMode(!snapshot.darkModeOn))
  }

  @objc private func toneClicked(_ sender: NSButton) {
    guard !rendering, let tone = snapshot.trueTone else { return }
    onIntent(.setTrueTone(!tone))
  }
}
