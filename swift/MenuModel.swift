import CNightshift
import Foundation

// Off, Sunset to Sunrise, Custom. The menu shows them as Off, Custom, Sunset.
enum ScheduleMode: Int, Equatable {
  case off = 0
  case sunsetToSunrise = 1
  case custom = 2

  // Segment order is Off, Custom, Sunset to Sunrise.
  var segment: Int {
    switch self {
    case .off: 0
    case .custom: 1
    case .sunsetToSunrise: 2
    }
  }

  init?(segment: Int) {
    switch segment {
    case 0: self = .off
    case 1: self = .custom
    case 2: self = .sunsetToSunrise
    default: return nil
    }
  }
}

enum MenuSection: String, Hashable {
  case ramp
  case appearance
}

struct MenuSnapshot: Equatable {
  var warmth: WarmthReading
  var schedule: ScheduleMode
  var darkModeOn: Bool
  var trueTone: Bool?
  var rampLicensed: Bool
  var maxPercent: Int
  var fullAtMinute: Int?
  var collapsed: Set<MenuSection>
  var showWarmthInBar: Bool

  static let unavailable = MenuSnapshot(
    warmth: .unavailable,
    schedule: .off,
    darkModeOn: false,
    trueTone: nil,
    rampLicensed: false,
    maxPercent: 0,
    fullAtMinute: nil,
    collapsed: [.appearance],
    showWarmthInBar: true
  )
}

enum MenuIntent: Equatable {
  case setWarmth(Warmth)
  case stageWarmth(Warmth)
  case setSchedule(ScheduleMode)
  case setMax(Int)
  case setFullAt(Int)
  case toggle(MenuSection)
  case setDarkMode(Bool)
  case setTrueTone(Bool)
}

// Slider magnet with hysteresis (System Settings feel): catch the thumb within
// `enter` of mid, then hold it at mid until the pointer is `exit` or more away,
// so a held thumb covers 48...52 catch / 47...53 hold (softer than ±3/±6).
// One threshold flips at the same point both ways and the thumb chatters there;
// two thresholds do not.
func shouldStaySnapped(raw: Int, snapped: Bool, mid: Int = 50, enter: Int = 2, exit: Int = 4) -> Bool {
  let distance = abs(raw - mid)
  return snapped ? distance < exit : distance <= enter
}

// The status item next to the icon. N% or Off, and nothing when the reading
// cannot be one of those. showWarmthInBar defaults on; off leaves the title empty.
// The shared menubar file. A missing warmth line stays shown, which is this
// app's default. An explicit "warmth off" hides the percent.
func menuBarWarmthShown() -> Bool {
  let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/nightshift/menubar")
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  return menuBarWarmthShown(in: text)
}

func menuBarSetWarmthShown(_ shown: Bool) -> Bool {
  menuBarSet("warmth", shown ? "on" : "off")
}

func barTint() -> BarTint {
  let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/nightshift/menubar")
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  return barTint(in: text)
}

func menuBarSetTint(_ tint: BarTint) -> Bool {
  menuBarSet("tint", barTintText(tint))
}

private func menuBarSet(_ key: String, _ value: String) -> Bool {
  let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/nightshift/menubar")
  let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  let text = menuBarText(setting: key, value: value, in: existing)
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return true
  } catch {
    return false
  }
}

func menuBarWarmthShown(in text: String) -> Bool {
  guard let value = menuBarPrefs(in: text)["warmth"] else { return true }
  return value == "on"
}

func menuBarText(settingWarmth shown: Bool, in existing: String) -> String {
  menuBarText(setting: "warmth", value: shown ? "on" : "off", in: existing)
}

// Accent follows System Settings. A primary is one of the system colors.
// Custom is the color from the macOS color picker, stored as rrggbb.
enum BarPrimary: String, Equatable, CaseIterable {
  case blue, purple, pink, red, orange, yellow, green, graphite
}

enum BarTint: Equatable {
  case accent
  case primary(BarPrimary)
  case custom(red: Int, green: Int, blue: Int)
}

func barTint(in text: String) -> BarTint {
  guard let value = menuBarPrefs(in: text)["tint"] else { return .accent }
  return barTint(parsing: value)
}

func rgb(hex: String) -> (Int, Int, Int)? {
  guard hex.count == 6, let value = Int(hex, radix: 16), value >= 0, value <= 0xFFFFFF else { return nil }
  return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
}

func barTint(parsing value: String) -> BarTint {
  let text = value.trimmingCharacters(in: .whitespaces).lowercased()
  if text == "accent" { return .accent }
  if let primary = BarPrimary(rawValue: text) { return .primary(primary) }
  let parts = text.split(separator: " ").map(String.init)
  if parts.count == 2, parts[0] == "custom", let color = rgb(hex: parts[1]) {
    return .custom(red: color.0, green: color.1, blue: color.2)
  }
  return .accent
}

func barTintText(_ tint: BarTint) -> String {
  switch tint {
  case .accent:
    "accent"
  case .primary(let primary):
    primary.rawValue
  case .custom(let red, let green, let blue):
    String(format: "custom %02x%02x%02x", red, green, blue)
  }
}

func menuBarText(settingTint tint: BarTint, in existing: String) -> String {
  menuBarText(setting: "tint", value: barTintText(tint), in: existing)
}

func menuBarPrefs(in text: String) -> [String: String] {
  var prefs: [String: String] = [:]
  for line in text.split(separator: "\n") {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let value = parts[1].trimmingCharacters(in: .whitespaces)
    guard !parts[0].isEmpty, !value.isEmpty else { continue }
    prefs[parts[0]] = value
  }
  return prefs
}

func menuBarText(setting key: String, value: String, in existing: String) -> String {
  var prefs = menuBarPrefs(in: existing)
  prefs[key] = value
  return prefs.keys.sorted().map { "\($0) \(prefs[$0]!)\n" }.joined()
}

func statusItemTitle(for reading: WarmthReading, showWarmthInBar: Bool) -> String {
  guard showWarmthInBar else { return "" }
  switch reading {
  case .on(let warmth): return "\(warmth.percent)%"
  case .off: return "Off"
  case .unreadable, .unavailable: return ""
  }
}

struct RampControls: Equatable {
  var maxEnabled: Bool
  var fullAtEnabled: Bool
  var showsPro: Bool
}

func rampControls(licensed: Bool, schedule: ScheduleMode) -> RampControls {
  RampControls(
    maxEnabled: licensed,
    fullAtEnabled: licensed && schedule == .custom,
    showsPro: !licensed
  )
}

// The License status line. Waiting for checkout is the only line a refresh
// keeps, and only while this Mac is unlicensed. A notice is painted after
// that refresh and does not come back from `held`.
enum LicenseTone: Equatable {
  case secondary
  case orange
  case green
}

enum LicenseLine: Equatable {
  case notActive
  case waitingForCheckout
  case active
  case activeThrough(String)
  case ends(String)
  case notice(String, LicenseTone)
}

func licenseLineToShow(licensed: Bool, until: String?, renewingSoon: Bool, held: LicenseLine?) -> LicenseLine {
  if !licensed, held == .waitingForCheckout {
    return .waitingForCheckout
  }
  if licensed, let until {
    return renewingSoon ? .ends(until) : .activeThrough(until)
  }
  if licensed {
    return .active
  }
  return .notActive
}

func licenseLineText(_ line: LicenseLine) -> String {
  switch line {
  case .notActive:
    "Not active"
  case .waitingForCheckout:
    "Waiting for checkout…"
  case .active:
    "Active"
  case .activeThrough(let day):
    "Active through \(day)"
  case .ends(let day):
    "Ends \(day)"
  case .notice(let text, _):
    text
  }
}

func licenseLineTone(_ line: LicenseLine) -> LicenseTone {
  switch line {
  case .notActive:
    .secondary
  case .waitingForCheckout:
    .orange
  case .active, .activeThrough:
    .green
  case .ends:
    .orange
  case .notice(_, let tone):
    tone
  }
}

// A saved max is 1...100. Anything else is unset: the slider shows a
// stand-in and the label is an em dash.
struct MaxSliderDisplay: Equatable {
  var value: Int
  var text: String
}

func maxSliderDisplay(saved: Int, warmth: WarmthReading) -> MaxSliderDisplay {
  if (1...100).contains(saved) {
    return MaxSliderDisplay(value: saved, text: "\(saved)%")
  }
  let fallback: Int
  if case .on(let warmth) = warmth, (1...100).contains(warmth.percent) {
    fallback = warmth.percent
  } else {
    fallback = 50
  }
  return MaxSliderDisplay(value: fallback, text: "—")
}

func menuCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  return calendar
}

func date(minute: Int, on day: Date = Date(), calendar: Calendar = menuCalendar()) -> Date? {
  guard (0..<1440).contains(minute) else { return nil }
  var parts = calendar.dateComponents([.year, .month, .day], from: day)
  parts.hour = minute / 60
  parts.minute = minute % 60
  parts.second = 0
  return calendar.date(from: parts)
}

func minute(of date: Date, calendar: Calendar = menuCalendar()) -> Int {
  let parts = calendar.dateComponents([.hour, .minute], from: date)
  let value = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  return (0..<1440).contains(value) ? value : 0
}

func collapsedSections(in text: String) -> Set<MenuSection> {
  var sections = Set<MenuSection>()
  for line in text.components(separatedBy: "\n") {
    let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if let section = MenuSection(rawValue: name) {
      sections.insert(section)
    }
  }
  return sections
}

func collapsedSectionsText(_ sections: Set<MenuSection>) -> String {
  let names = sections.map(\.rawValue).sorted()
  guard !names.isEmpty else { return "" }
  return names.joined(separator: "\n") + "\n"
}

func savedNumber(in data: Data, lo: Int, hi: Int) -> Int? {
  guard data.count <= 63, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
    return nil
  }
  let scalars = Array(text)
  var index = 0
  while index < scalars.count, scalars[index] == " " || scalars[index] == "\n" || scalars[index] == "\r" || scalars[index] == "\t" {
    index += 1
  }
  let start = index
  while index < scalars.count, scalars[index].isASCII, scalars[index].isNumber {
    index += 1
  }
  guard index > start else { return nil }
  guard scalars[index...].allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
    return nil
  }
  guard let value = Int(String(scalars[start..<index])), (lo...hi).contains(value) else { return nil }
  return value
}

// Max, full, and section collapse all live under the Swift app's own
// support folder so this menu never writes the ObjC nightshift files.
struct MenuFiles {
  var maxURL: URL
  var fullURL: URL
  var sectionsURL: URL

  static let swiftBundleID = "io.github.freechie.nightshift.swift"

  static func live() -> MenuFiles {
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let swift = base.appendingPathComponent(swiftBundleID, isDirectory: true)
    return MenuFiles(
      maxURL: swift.appendingPathComponent("max"),
      fullURL: swift.appendingPathComponent("full"),
      sectionsURL: swift.appendingPathComponent("sections")
    )
  }

  func readMax() -> Int? {
    readNumber(at: maxURL, lo: 1, hi: 100)
  }

  func writeMax(_ value: Int) -> Bool {
    guard (1...100).contains(value) else { return false }
    return write(text: "\(value)\n", to: maxURL)
  }

  func readFullAt() -> Int? {
    readNumber(at: fullURL, lo: 0, hi: 1439)
  }

  func writeFullAt(_ minute: Int) -> Bool {
    guard (0..<1440).contains(minute) else { return false }
    return write(text: "\(minute)\n", to: fullURL)
  }

  func readCollapsed() -> Set<MenuSection> {
    guard let text = try? String(contentsOf: sectionsURL, encoding: .utf8) else {
      return FileManager.default.fileExists(atPath: sectionsURL.path) ? [] : [.appearance]
    }
    return collapsedSections(in: text)
  }

  func writeCollapsed(_ sections: Set<MenuSection>) -> Bool {
    write(text: collapsedSectionsText(sections), to: sectionsURL)
  }

  private func readNumber(at url: URL, lo: Int, hi: Int) -> Int? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return savedNumber(in: data, lo: lo, hi: hi)
  }

  private func write(text: String, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(text.utf8).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch {
      return false
    }
  }
}

// Applies one intent and returns the snapshot the menu should show.
// Warmth, Max, and Full at go through RampEngine, the only writer of the
// max and full files. A live drag stages through WarmthSource. Schedule,
// Dark mode, and True Tone go through the closures. Sections use MenuFiles.
@MainActor
final class MenuFacade {
  private let warmth: any WarmthSource
  private let ramp: RampEngine
  private let files: MenuFiles
  var showWarmthInBar: Bool
  private let schedule: @MainActor () -> ScheduleMode
  private let changeSchedule: @MainActor (ScheduleMode) -> Bool
  private let darkMode: @MainActor () -> Bool
  private let changeDarkMode: @MainActor (Bool) -> Void
  private let trueTone: @MainActor () -> Bool?
  private let changeTrueTone: @MainActor (Bool) -> Bool
  private let hours: @MainActor () -> String

  init(
    warmth: any WarmthSource,
    ramp: RampEngine,
    files: MenuFiles,
    schedule: @escaping @MainActor () -> ScheduleMode,
    changeSchedule: @escaping @MainActor (ScheduleMode) -> Bool,
    darkMode: @escaping @MainActor () -> Bool,
    changeDarkMode: @escaping @MainActor (Bool) -> Void,
    trueTone: @escaping @MainActor () -> Bool?,
    changeTrueTone: @escaping @MainActor (Bool) -> Bool,
    hours: @escaping @MainActor () -> String = { "—" },
    showWarmthInBar: Bool = true
  ) {
    self.warmth = warmth
    self.ramp = ramp
    self.files = files
    self.schedule = schedule
    self.changeSchedule = changeSchedule
    self.darkMode = darkMode
    self.changeDarkMode = changeDarkMode
    self.trueTone = trueTone
    self.changeTrueTone = changeTrueTone
    self.hours = hours
    self.showWarmthInBar = showWarmthInBar
  }

  func scheduleHours() -> String { hours() }

  func snapshot() -> MenuSnapshot {
    MenuSnapshot(
      warmth: warmth.read(),
      schedule: schedule(),
      darkModeOn: darkMode(),
      trueTone: trueTone(),
      rampLicensed: ramp.isLicensed,
      maxPercent: ramp.settings.max?.percent ?? 0,
      fullAtMinute: ramp.settings.fullAtClock?.value,
      collapsed: files.readCollapsed(),
      showWarmthInBar: showWarmthInBar
    )
  }

  // The 60s timer: one ramp step, then what the menu and bar should show.
  func rampTick() -> MenuSnapshot {
    ramp.tick()
    return snapshot()
  }

  // Live drag: no snapshot, so each tick costs only the strength write.
  func stageWarmth(_ warmth: Warmth) {
    self.warmth.stage(warmth)
  }

  // One nightshiftd.sock line → one token reply. English stays in the CLI.
  func reply(
    to line: String,
    loginOn: @MainActor () -> Bool,
    setLogin: @MainActor (Bool) -> String
  ) -> String {
    let command = line.withCString { nsDaemonCommand($0) }
    switch command {
    case kNSCommandUnknown:
      return "failed"
    case kNSCommandStatus:
      guard let wire = ramp.statusWire() else { return "failed" }
      return statusWireLine(now: wire.now, max: wire.max, state: wire.state, full: wire.full)
    case kNSCommandMax:
      guard line.hasPrefix("max "),
        let value = parseCommandNumber(String(line.dropFirst(4)), lo: 1, hi: 100)
      else { return "failed" }
      switch ramp.setMaxFromCommand(value) {
      case .locked: return "locked"
      case .invalid, .saveFailed: return "failed"
      case .saved, .retargeted, .capped:
        return "\(ramp.settings.max?.percent ?? value)"
      }
    case kNSCommandRamp:
      guard line.hasPrefix("ramp "),
        let minute = parseCommandNumber(String(line.dropFirst(5)), lo: 0, hi: 1439)
      else { return "failed" }
      switch ramp.setFullAtFromCommand(minute) {
      case .locked: return "locked"
      case .invalid, .needsCustomSchedule, .saveFailed, .refusedOutsideSchedule:
        return "failed"
      case .early, .saved, .retargeted, .heldAtMax:
        return "\(minute)"
      }
    case kNSCommandWarmth:
      guard let value = parseCommandNumber(line, lo: 0, hi: 100), let warmth = Warmth(value)
      else { return "failed" }
      guard ramp.applyWarmth(warmth) else { return "failed" }
      switch self.warmth.read() {
      case .on(let held): return "\(held.percent)"
      case .off: return "0"
      case .unreadable, .unavailable: return "failed"
      }
    case kNSCommandSchedule:
      if line == "schedule" {
        return scheduleWireName(schedule())
      }
      guard line.hasPrefix("schedule "),
        let mode = scheduleMode(wire: String(line.dropFirst(9))),
        changeSchedule(mode)
      else { return "failed" }
      return scheduleWireName(schedule())
    case kNSCommandClock:
      if line == "clock" {
        return hourCycleIs24() ? "24" : "12"
      }
      guard line.hasPrefix("clock ") else { return "failed" }
      let cycleText = String(line.dropFirst(6))
      let cycle: Int32
      if cycleText == "24" { cycle = 24 }
      else if cycleText == "12" { cycle = 12 }
      else { return "failed" }
      guard writeHourCycle(cycle) else { return "failed" }
      return "\(cycle)"
    case kNSCommandLogin:
      if line == "login" {
        return onOffReply(loginOn())
      }
      guard line.hasPrefix("login "), let on = onOffWire(String(line.dropFirst(6))) else {
        return "failed"
      }
      if loginOn() == on { return onOffReply(on) }
      return setLogin(on)
    case kNSCommandDark:
      if line == "dark" {
        return onOffReply(darkMode())
      }
      guard line.hasPrefix("dark "), let on = onOffWire(String(line.dropFirst(5))) else {
        return "failed"
      }
      changeDarkMode(on)
      guard darkMode() == on else { return "failed" }
      return onOffReply(on)
    case kNSCommandTone:
      if line == "tone" {
        guard let on = trueTone() else { return "unsupported" }
        return onOffReply(on)
      }
      guard line.hasPrefix("tone "), let on = onOffWire(String(line.dropFirst(5))) else {
        return "failed"
      }
      guard trueTone() != nil else { return "unsupported" }
      guard changeTrueTone(on), trueTone() == on else { return "failed" }
      return onOffReply(on)
    default:
      return "failed"
    }
  }

  func apply(_ intent: MenuIntent) -> MenuSnapshot {
    switch intent {
    case .setWarmth(let warmth):
      ramp.applyWarmth(warmth)
    case .stageWarmth(let warmth):
      stageWarmth(warmth)
    case .setSchedule(let mode):
      _ = changeSchedule(mode)
    case .setMax(let percent):
      ramp.setMax(percent)
    case .setFullAt(let minute):
      ramp.setFullAt(minute)
    case .toggle(let section):
      toggle(section)
    case .setDarkMode(let on):
      changeDarkMode(on)
    case .setTrueTone(let on):
      if trueTone() != nil {
        _ = changeTrueTone(on)
      }
    }
    return snapshot()
  }

  private func toggle(_ section: MenuSection) {
    var collapsed = files.readCollapsed()
    if collapsed.contains(section) {
      collapsed.remove(section)
    } else {
      collapsed.insert(section)
    }
    _ = files.writeCollapsed(collapsed)
  }
}

// The update status line. Checking is only the fetch in flight. A failed
// automatic check restores the standing line. Check Now says the fetch failed.
enum UpdateLine: Equatable {
  case notCheckedYet
  case checking
  case notice(String)
}

func updateLineText(_ line: UpdateLine) -> String {
  switch line {
  case .notCheckedYet:
    "Not checked yet."
  case .checking:
    "Checking…"
  case .notice(let text):
    text
  }
}

func updateLineWhileFetching(manual: Bool, standing: UpdateLine) -> UpdateLine {
  if manual || standing == .notCheckedYet {
    return .checking
  }
  return standing
}

func updateLineAfterFetch(manual: Bool, standing: UpdateLine, notice: String?) -> UpdateLine {
  if let notice {
    return .notice(notice)
  }
  if manual {
    return .notice("Couldn't check for updates.")
  }
  switch standing {
  case .checking:
    return .notCheckedYet
  case .notCheckedYet, .notice:
    return standing
  }
}

func updateNotice(local: String, remoteTag: String) -> String {
  let remote = updateVersion(remoteTag)
  if remote.isEmpty { return "Couldn't check for updates." }
  if updateVersionIsNewer(remote, than: updateVersion(local)) {
    return "Version \(remote) is available."
  }
  return "You're up to date."
}

private func updateVersion(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.first == "v" || value.first == "V" {
    value.removeFirst()
  }
  return value
}

private func updateVersionIsNewer(_ remote: String, than local: String) -> Bool {
  let left = remote.split(separator: ".").map { Int($0) ?? 0 }
  let right = local.split(separator: ".").map { Int($0) ?? 0 }
  let count = max(left.count, right.count)
  for index in 0..<count {
    let newer = index < left.count ? left[index] : 0
    let here = index < right.count ? right[index] : 0
    if newer != here { return newer > here }
  }
  return false
}
