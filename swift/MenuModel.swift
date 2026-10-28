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
    collapsed: [],
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
    guard let text = try? String(contentsOf: sectionsURL, encoding: .utf8) else { return [] }
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
  let showWarmthInBar: Bool
  private let schedule: @MainActor () -> ScheduleMode
  private let changeSchedule: @MainActor (ScheduleMode) -> Bool
  private let darkMode: @MainActor () -> Bool
  private let changeDarkMode: @MainActor (Bool) -> Void
  private let trueTone: @MainActor () -> Bool?
  private let changeTrueTone: @MainActor (Bool) -> Bool

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
    self.showWarmthInBar = showWarmthInBar
  }

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
