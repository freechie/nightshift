import Foundation

var failures = 0

@MainActor
func check(_ ok: Bool, _ what: String) {
  if !ok {
    print("FAIL: \(what)")
    failures += 1
  }
}

check(Warmth(0) != nil && Warmth(100) != nil, "0 and 100 are warmth values")
check(Warmth(-1) == nil && Warmth(101) == nil, "values outside 0...100 are rejected")

check(reading(strength: 50, enabled: true) == .on(Warmth(50)!), "enabled at 50 reads as on at 50")
check(reading(strength: 50, enabled: false) == .off, "disabled reads as off whatever the strength")
check(reading(strength: 50, enabled: nil) == .off, "an unreadable status reads as off, as the old app does")
check(reading(strength: nil, enabled: true) == .unreadable, "an unreadable strength reads as unreadable")
check(reading(strength: 101, enabled: true) == .unreadable, "a strength outside 0...100 reads as unreadable")
check(reading(strength: nil, enabled: false) == .unreadable, "a failed strength reads as unreadable even when disabled")
check(reading(strength: 0, enabled: true) == .on(Warmth(0)!), "enabled at 0 reads as on at 0")

check(menuTitle(for: .on(Warmth(1)!)) == "1%", "on at 1 reads as 1%")
check(menuTitle(for: .on(Warmth(100)!)) == "100%", "on at 100 reads as 100%")
check(menuTitle(for: .off) == "Off", "off reads as Off")
check(menuTitle(for: .unreadable) == "Unavailable", "a failed read says so")
check(menuTitle(for: .unavailable) == "Night Shift is unavailable", "a missing client says so in the menu")
check(menuTitle(for: reading(strength: 0, enabled: true)) == "0%", "on at 0 reads as 0%, not Off")

check(sliderState(for: .on(Warmth(40)!)) == SliderState(isEnabled: true, value: 40), "on moves the slider to its warmth")
check(sliderState(for: .off) == SliderState(isEnabled: true, value: 0), "off moves the slider to 0")
check(sliderState(for: .unreadable) == SliderState(isEnabled: false, value: nil), "a failed read disables the slider and leaves it")
check(sliderState(for: .unavailable) == SliderState(isEnabled: false, value: nil), "a missing client disables the slider and leaves it")

// Stands in for NightShiftClient: reads what it holds, and an apply that
// fails leaves it unchanged, as a failed applyStrength does.
@MainActor
final class FakeSource: WarmthSource {
  var held: WarmthReading
  var applyWorks = true
  var applied: [Int] = []
  var staged: [Int] = []

  init(_ held: WarmthReading) {
    self.held = held
  }

  func read() -> WarmthReading {
    held
  }

  func apply(_ warmth: Warmth) -> WarmthReading {
    applied.append(warmth.percent)
    if applyWorks {
      held = .on(warmth)
    }
    return read()
  }

  func stage(_ warmth: Warmth) {
    staged.append(warmth.percent)
    held = .on(warmth)
  }
}

check(currentReading(nil) == .unavailable, "no client reads as unavailable")
check(currentReading(FakeSource(.off)) == .off, "a client's reading is shown as it is")
check(applyReleased(50, to: nil) == nil, "a release with no client does nothing")
let outOfRange = FakeSource(.off)
check(applyReleased(101, to: outOfRange) == nil && outOfRange.applied.isEmpty, "a value outside 0...100 is never applied")
let works = FakeSource(.off)
check(applyReleased(60, to: works) == .on(Warmth(60)!) && works.applied == [60], "a release applies once and shows the new warmth")
let fails = FakeSource(.on(Warmth(30)!))
fails.applyWorks = false
let afterFail = applyReleased(60, to: fails)
check(afterFail == .on(Warmth(30)!) && fails.applied == [60], "a failed apply shows the warmth actually held")
check(afterFail.map { sliderState(for: $0) } == SliderState(isEnabled: true, value: 30), "a failed apply moves the slider back")

check(statusItemTitle(for: .on(Warmth(12)!), showWarmthInBar: true) == "12%", "the bar shows 12%")
check(statusItemTitle(for: .off, showWarmthInBar: true) == "Off", "the bar shows Off")
check(statusItemTitle(for: .on(Warmth(0)!), showWarmthInBar: true) == "0%", "the bar shows 0% when warmth is on at 0")
check(statusItemTitle(for: .unreadable, showWarmthInBar: true) == "", "a failed read leaves the bar untitled")
check(statusItemTitle(for: .unavailable, showWarmthInBar: true) == "", "a missing client leaves the bar untitled")
check(statusItemTitle(for: .on(Warmth(12)!), showWarmthInBar: false) == "", "the bar title stays empty when warmth in the bar is off")

check(ScheduleMode.off.segment == 0 && ScheduleMode.off.rawValue == 0, "Off is the first segment and mode 0")
check(ScheduleMode.custom.segment == 1 && ScheduleMode.custom.rawValue == 2, "Custom is the second segment and mode 2")
check(ScheduleMode.sunsetToSunrise.segment == 2 && ScheduleMode.sunsetToSunrise.rawValue == 1, "Sunset to Sunrise is the third segment and mode 1")
check(ScheduleMode(segment: 0) == .off && ScheduleMode(segment: 1) == .custom && ScheduleMode(segment: 2) == .sunsetToSunrise, "segments map back onto modes")
check(ScheduleMode(segment: -1) == nil && ScheduleMode(segment: 3) == nil, "any other segment is not a schedule")

check(rampControls(licensed: false, schedule: .custom) == RampControls(maxEnabled: false, fullAtEnabled: false, showsPro: true), "an unlicensed ramp is locked and badged")
check(rampControls(licensed: true, schedule: .off) == RampControls(maxEnabled: true, fullAtEnabled: false, showsPro: false), "a licensed Off schedule enables Max only")
check(rampControls(licensed: true, schedule: .sunsetToSunrise) == RampControls(maxEnabled: true, fullAtEnabled: false, showsPro: false), "Sunset to Sunrise keeps Full at off")
check(rampControls(licensed: true, schedule: .custom) == RampControls(maxEnabled: true, fullAtEnabled: true, showsPro: false), "Custom enables Full at")

check(maxSliderDisplay(saved: 40, warmth: .off) == MaxSliderDisplay(value: 40, text: "40%"), "a saved max is shown")
check(maxSliderDisplay(saved: 0, warmth: .on(Warmth(30)!)) == MaxSliderDisplay(value: 30, text: "—"), "no max shows the current warmth and a dash")
check(maxSliderDisplay(saved: 0, warmth: .off) == MaxSliderDisplay(value: 50, text: "—"), "no max while off shows 50 and a dash")
check(maxSliderDisplay(saved: 101, warmth: .on(Warmth(30)!)) == MaxSliderDisplay(value: 30, text: "—"), "a max outside 1...100 counts as unset")

var clock = Calendar(identifier: .gregorian)
clock.timeZone = TimeZone(secondsFromGMT: 0)!
let day = clock.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0))!
check(date(minute: -1, on: day, calendar: clock) == nil, "minute -1 is not a clock time")
check(date(minute: 1440, on: day, calendar: clock) == nil, "minute 1440 is not a clock time")
let eightThirty = date(minute: 8 * 60 + 30, on: day, calendar: clock)
check(eightThirty != nil && minute(of: eightThirty!, calendar: clock) == 510, "8:30 is minute 510")

check(collapsedSections(in: "brightness\nramp\n") == [.ramp], "a retired section name is dropped")
check(collapsedSections(in: "  appearance  \n\nramp") == [.appearance, .ramp], "ramp and appearance are the sections that stick")
check(collapsedSectionsText([.ramp, .appearance]) == "appearance\nramp\n", "sections are saved one name per line, sorted")
check(collapsedSectionsText([]) == "", "an expanded menu saves an empty section list")

let live = MenuFiles.live()
check(live.maxURL.lastPathComponent == "max", "max file is named max")
check(live.fullURL.lastPathComponent == "full", "full file is named full")
check(live.sectionsURL.lastPathComponent == "sections", "collapse is stored in sections")
check(live.maxURL.deletingLastPathComponent().lastPathComponent == MenuFiles.swiftBundleID, "max uses the Swift app support folder")
check(live.fullURL.deletingLastPathComponent() == live.maxURL.deletingLastPathComponent(), "full sits next to max")
check(live.sectionsURL.deletingLastPathComponent() == live.maxURL.deletingLastPathComponent(), "sections sit next to max and full")

@MainActor
final class FakeControls {
  var schedule = ScheduleMode.custom
  var dark = false
  var tone: Bool? = true
  var licensed = true
  var scheduleWorks = true
  var schedules: [ScheduleMode] = []
  var darks: [Bool] = []
  var tones: [Bool] = []

  func facade(files: MenuFiles, warmth: FakeSource, showWarmthInBar: Bool = true) -> MenuFacade {
    MenuFacade(
      warmth: warmth,
      files: files,
      schedule: { self.schedule },
      changeSchedule: { mode in
        self.schedules.append(mode)
        guard self.scheduleWorks else { return false }
        self.schedule = mode
        return true
      },
      darkMode: { self.dark },
      changeDarkMode: { on in
        self.darks.append(on)
        self.dark = on
      },
      trueTone: { self.tone },
      changeTrueTone: { on in
        self.tones.append(on)
        self.tone = on
        return true
      },
      licensed: { self.licensed },
      showWarmthInBar: showWarmthInBar
    )
  }
}

@MainActor
func menuTests() {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("nightshift-swift-menu-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = MenuFiles(
    maxURL: root.appendingPathComponent("max"),
    fullURL: root.appendingPathComponent("full"),
    sectionsURL: root.appendingPathComponent("sections")
  )
  check(files.readMax() == nil && files.readFullAt() == nil && files.readCollapsed().isEmpty, "missing menu files read as unset")
  check(files.writeMax(0) == false && files.readMax() == nil, "max rejects 0")
  check(files.writeMax(101) == false && files.readMax() == nil, "max rejects 101")
  check(files.writeMax(40) && files.readMax() == 40, "max 40 round-trips")
  check((try? String(contentsOf: files.maxURL, encoding: .utf8)) == "40\n", "max is saved as a decimal line")
  let mode = (try? FileManager.default.attributesOfItem(atPath: files.maxURL.path)[.posixPermissions] as? NSNumber)?.intValue
  check(mode == 0o600, "max is owner read/write only")
  try? Data("40x\n".utf8).write(to: files.maxURL)
  check(files.readMax() == nil, "a malformed max file is ignored")
  check(files.writeMax(40) && files.writeFullAt(510) && files.readFullAt() == 510, "full at 8:30 round-trips")
  check(files.writeFullAt(1440) == false && files.readFullAt() == 510, "full at rejects minute 1440")
  check(files.writeCollapsed([.appearance, .ramp]), "sections save")
  check(files.readCollapsed() == [.appearance, .ramp], "sections read back")
  check((try? String(contentsOf: files.sectionsURL, encoding: .utf8)) == "appearance\nramp\n", "sections keep the ramp and appearance names")
  try? "brightness\n".write(to: files.sectionsURL, atomically: true, encoding: .utf8)
  check(files.readCollapsed().isEmpty, "brightness is not a section anymore")

  let source = FakeSource(.off)
  let controls = FakeControls()
  let facade = controls.facade(files: files, warmth: source)
  check(facade.snapshot().showWarmthInBar, "warmth in the bar defaults on")
  check(controls.facade(files: files, warmth: source, showWarmthInBar: false).snapshot().showWarmthInBar == false, "warmth in the bar can be off")

  let warmed = facade.apply(.setWarmth(Warmth(60)!))
  check(warmed.warmth == .on(Warmth(60)!) && source.applied == [60], "the warmth slider applies through WarmthSource")
  facade.stageWarmth(Warmth(55)!)
  facade.stageWarmth(Warmth(58)!)
  check(source.staged == [55, 58] && source.applied == [60], "a live drag stages without a full apply")
  let released = facade.apply(.setWarmth(Warmth(60)!))
  check(released.warmth == .on(Warmth(60)!) && source.staged == [55, 58] && source.applied == [60, 60], "release applies once after staging")
  let viaIntent = facade.apply(.stageWarmth(Warmth(61)!))
  check(viaIntent.warmth == .on(Warmth(61)!) && source.staged == [55, 58, 61] && source.applied == [60, 60], "the stage intent stages, never applies")
  _ = facade.apply(.setWarmth(Warmth(60)!))
  source.applied = [60]
  let capped = facade.apply(.setMax(40))
  check(capped.maxPercent == 40 && capped.warmth == .on(Warmth(40)!) && source.applied == [60, 40], "a max below the current warmth applies that warmth")
  check(controls.schedules.isEmpty && controls.darks.isEmpty && controls.tones.isEmpty, "setting max does not change schedule, Dark mode, or True Tone")
  source.held = .on(Warmth(20)!)
  let kept = facade.apply(.setMax(40))
  check(kept.warmth == .on(Warmth(20)!) && source.applied == [60, 40], "a max above the current warmth leaves warmth alone")
  controls.licensed = false
  let blocked = facade.apply(.setMax(70))
  check(blocked.maxPercent == 40 && blocked.rampLicensed == false, "an unlicensed max change is ignored")
  controls.licensed = true
  controls.schedule = .sunsetToSunrise
  let sunset = facade.apply(.setFullAt(600))
  check(sunset.fullAtMinute == 510, "Sunset to Sunrise does not change Full at")
  controls.schedule = .off
  let off = facade.apply(.setFullAt(600))
  check(off.fullAtMinute == 510, "Off does not change Full at")
  controls.schedule = .custom
  let timed = facade.apply(.setFullAt(600))
  check(timed.fullAtMinute == 600, "Custom saves Full at")
  controls.licensed = false
  let lockedTime = facade.apply(.setFullAt(90))
  check(lockedTime.fullAtMinute == 600, "an unlicensed Full at change is ignored")
  controls.licensed = true

  controls.scheduleWorks = false
  let stuck = facade.apply(.setSchedule(.off))
  check(stuck.schedule == .custom && controls.schedules == [.off], "a failed setMode leaves the schedule as it was")
  controls.scheduleWorks = true
  let switched = facade.apply(.setSchedule(.off))
  check(switched.schedule == .off && controls.schedules == [.off, .off], "Off is sent as setMode")

  let dark = facade.apply(.setDarkMode(true))
  check(dark.darkModeOn && controls.darks == [true], "Dark mode is sent on")
  controls.tone = nil
  let hidden = facade.apply(.setTrueTone(true))
  check(hidden.trueTone == nil && controls.tones.isEmpty, "unsupported True Tone is left alone")
  controls.tone = false
  let tone = facade.apply(.setTrueTone(true))
  check(tone.trueTone == true && controls.tones == [true], "True Tone is sent on")

  let closed = facade.apply(.toggle(.ramp))
  check(closed.collapsed == [.ramp], "ramp collapses")
  let both = facade.apply(.toggle(.appearance))
  check(both.collapsed == [.ramp, .appearance], "appearance collapses too")
  let opened = facade.apply(.toggle(.ramp))
  check(opened.collapsed == [.appearance], "ramp opens again")
  let reread = controls.facade(files: files, warmth: source).snapshot()
  check(reread.collapsed == [.appearance], "collapse is read back from the Swift folder")
  check(!reread.collapsed.contains(.ramp), "an open ramp is not listed")
}

menuTests()

check(shouldStaySnapped(raw: 48, snapped: false) && shouldStaySnapped(raw: 52, snapped: false), "within 2 of mid catches")
check(!shouldStaySnapped(raw: 47, snapped: false) && !shouldStaySnapped(raw: 53, snapped: false), "3 away is not caught")
check(shouldStaySnapped(raw: 50, snapped: false), "mid catches")
check(shouldStaySnapped(raw: 47, snapped: true) && shouldStaySnapped(raw: 53, snapped: true), "once caught, holds through 47...53")
check(!shouldStaySnapped(raw: 46, snapped: true) && !shouldStaySnapped(raw: 54, snapped: true), "4 away lets go")
check(!shouldStaySnapped(raw: 0, snapped: true) && !shouldStaySnapped(raw: 100, snapped: false), "ends never snap")
// Feeds a drag's raw values through the magnet and returns the snapped state after each.
func snapTrace(_ raws: [Int]) -> [Bool] {
  var snapped = false
  return raws.map { raw in
    snapped = shouldStaySnapped(raw: raw, snapped: snapped)
    return snapped
  }
}
check(snapTrace([46, 45, 46, 45, 46]) == [false, false, false, false, false], "wobbling at 45/46 outside the catch zone never flips")
check(snapTrace([48, 47, 48, 47, 48]) == [true, true, true, true, true], "wobbling at 47/48 once caught stays at mid")
check(snapTrace([40, 48, 52, 53, 54, 53]) == [false, true, true, true, false, false], "crossing mid sticks once, then lets go cleanly")
check(shouldStaySnapped(raw: 11, snapped: false, mid: 10, enter: 1, exit: 2) && !shouldStaySnapped(raw: 12, snapped: true, mid: 10, enter: 1, exit: 2), "mid, enter and exit are parameters")

// WarmthHold: press steps once, release commits dirty percent.
do {
  var hold = WarmthHold()
  let first = hold.press(direction: 1, startingPercent: 40, keyCode: 0x18, keyReadable: false)
  check(first == 45, "raise from 40 -> 45")
  let second = hold.tick()
  check(second == 50, "hold tick 45 -> 50")
  let commit = hold.release()
  check(commit == 50, "release commits 50")
  check(!hold.isHolding, "hold cleared")
}

do {
  var hold = WarmthHold()
  _ = hold.press(direction: -1, startingPercent: 3, keyCode: 0x1B, keyReadable: false)
  check(hold.percent == 0, "lower from 3 clamps to 0")
  let commit = hold.release()
  check(commit == 0, "release commits clamped 0")
}

check(WarmthHold.stepped(from: 98, direction: 1) == 100, "98 + 5 clamps to 100")
check(WarmthHold.stepped(from: 100, direction: 1) == 100, "100 raise stays 100")
check(WarmthHold.stepped(from: 2, direction: -1) == 0, "2 - 5 clamps to 0")

if failures > 0 {
  exit(1)
}
print("swift-tests: ok")
