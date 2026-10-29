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

// Stands in for NightShiftClient on the menu side: one object that the menu
// reads and stages through and the ramp writes through, as in the app. A write
// that fails leaves it unchanged, as a failed applyStrength does. Schedule and
// license come from FakeControls so the menu and the ramp agree. The Custom
// window is 9:00-12:00 and it is 13:00, outside it.
@MainActor
final class FakeSource: WarmthSource, RampHardware {
  var held: WarmthReading
  var applyWorks = true
  var applied: [Int] = []
  var staged: [Int] = []
  weak var controls: FakeControls?

  init(_ held: WarmthReading) {
    self.held = held
  }

  func read() -> WarmthReading {
    held
  }

  func stage(_ warmth: Warmth) {
    staged.append(warmth.percent)
    held = .on(warmth)
  }

  func nightShift() -> NightShiftStatus? {
    let mode = controls?.schedule ?? .off
    let window = mode == .custom ? ScheduleWindow(start: Minute(9 * 60)!, end: Minute(12 * 60)!) : nil
    if case .on = held { return NightShiftStatus(mode: mode, window: window, enabled: true) }
    return NightShiftStatus(mode: mode, window: window, enabled: false)
  }

  func strength() -> Int? {
    switch held {
    case .on(let warmth): warmth.percent
    case .off: 0
    case .unreadable, .unavailable: nil
    }
  }

  func write(_ warmth: Warmth) -> Int? {
    applied.append(warmth.percent)
    guard applyWorks else { return nil }
    held = warmth.percent >= 1 ? .on(warmth) : .off
    return warmth.percent
  }

  func arm() -> Bool { true }
  func licensed() -> Bool { controls?.licensed ?? false }
  func minuteNow() -> Minute? { Minute(13 * 60) }
}

check(currentReading(nil) == .unavailable, "no client reads as unavailable")
check(currentReading(FakeSource(.off)) == .off, "a client's reading is shown as it is")

check(statusItemTitle(for: .on(Warmth(12)!), showWarmthInBar: true) == "12%", "the bar shows 12%")
check(statusItemTitle(for: .off, showWarmthInBar: true) == "Off", "the bar shows Off")
check(statusItemTitle(for: .on(Warmth(0)!), showWarmthInBar: true) == "0%", "the bar shows 0% when warmth is on at 0")
check(statusItemTitle(for: .unreadable, showWarmthInBar: true) == "", "a failed read leaves the bar untitled")
check(statusItemTitle(for: .unavailable, showWarmthInBar: true) == "", "a missing client leaves the bar untitled")
check(statusItemTitle(for: .on(Warmth(12)!), showWarmthInBar: false) == "", "the bar title stays empty when warmth in the bar is off")
check(menuBarWarmthShown(in: "") && menuBarWarmthShown(in: "icon horizon\n"), "a menubar file without warmth stays shown")
check(menuBarWarmthShown(in: "warmth off\n") == false, "warmth off hides the bar percent")
check(menuBarText(settingWarmth: false, in: "icon horizon\n") == "icon horizon\nwarmth off\n", "warmth off keeps the other menubar lines")
check(barTint(in: "") == .accent && barTint(in: "icon horizon\n") == .accent, "a menubar file without tint follows the accent")
check(barTint(in: "tint accent\n") == .accent, "tint accent follows the accent")
check(barTint(in: "tint blue\n") == .primary(.blue), "tint blue is the blue primary")
check(barTint(in: "tint graphite\n") == .primary(.graphite), "tint graphite is the graphite primary")
check(barTint(in: "tint custom ff8000\n") == .custom(red: 255, green: 128, blue: 0), "a custom tint stores the picked color")
check(barTint(in: "tint custom FF00AA\n") == .custom(red: 255, green: 0, blue: 170), "a custom tint accepts uppercase hex")
check(barTint(in: "tint nope\n") == .accent && barTint(in: "tint custom zz\n") == .accent, "a bad tint line follows the accent")
check(
  menuBarText(settingTint: .primary(.red), in: "icon horizon\nwarmth on\n") == "icon horizon\ntint red\nwarmth on\n",
  "a primary tint keeps the other menubar lines"
)
check(
  menuBarText(settingTint: .custom(red: 1, green: 2, blue: 3), in: "warmth off\n") == "tint custom 010203\nwarmth off\n",
  "a custom tint is saved as hex"
)
check(
  menuBarText(settingWarmth: false, in: "tint blue\n") == "tint blue\nwarmth off\n",
  "warmth off keeps the tint line"
)

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
    warmth.controls = self
    return MenuFacade(
      warmth: warmth,
      ramp: RampEngine(hardware: warmth, files: files, notify: { _ in }),
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
  check(files.readMax() == nil && files.readFullAt() == nil, "missing menu files read as unset")
  check(files.readCollapsed() == [.appearance], "a missing section list starts with appearance collapsed")
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
  check(warmed.warmth == .on(Warmth(60)!) && source.applied == [60], "a release applies once through the ramp and shows the new warmth")
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

  let fails = FakeSource(.on(Warmth(30)!))
  fails.applyWorks = false
  let afterFail = controls.facade(files: files, warmth: fails).apply(.setWarmth(Warmth(60)!))
  check(afterFail.warmth == .on(Warmth(30)!) && fails.applied == [60], "a failed apply shows the warmth actually held")
  check(sliderState(for: afterFail.warmth) == SliderState(isEnabled: true, value: 30), "a failed apply moves the slider back")

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

// Stands in for NightShiftClient. A failed write leaves strength and enabled
// as they were, as a failed applyStrength does.
@MainActor
final class FakeHardware: RampHardware {
  var mode = ScheduleMode.custom
  var start = 21 * 60
  var end = 7 * 60
  var enabled = true
  var current: Int? = 1
  var now = 21 * 60
  var isLicensed = true
  var writeWorks = true
  var writes: [Int] = []
  var arms = 0

  func nightShift() -> NightShiftStatus? {
    let window = mode == .custom ? ScheduleWindow(start: Minute(start)!, end: Minute(end)!) : nil
    return NightShiftStatus(mode: mode, window: window, enabled: enabled)
  }

  func strength() -> Int? { current }

  func write(_ warmth: Warmth) -> Int? {
    guard writeWorks else { return nil }
    writes.append(warmth.percent)
    current = warmth.percent
    enabled = warmth.percent >= 1
    return warmth.percent
  }

  func arm() -> Bool {
    arms += 1
    current = 1
    return true
  }

  func licensed() -> Bool { isLicensed }
  func minuteNow() -> Minute? { Minute(now) }
}

@MainActor
func rampTests() {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("nightshift-swift-ramp-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = MenuFiles(
    maxURL: root.appendingPathComponent("max"),
    fullURL: root.appendingPathComponent("full"),
    sectionsURL: root.appendingPathComponent("sections")
  )

  let hw = FakeHardware()
  var notices: [RampNotice] = []
  let ramp = RampEngine(hardware: hw, files: files, notify: { notices.append($0) })

  hw.enabled = false
  hw.current = 0
  hw.now = 20 * 60 + 57
  ramp.tick()
  check(hw.arms == 0, "3 minutes before turn-on does not arm")
  hw.now = 20 * 60 + 58
  ramp.tick()
  check(hw.arms == 1 && hw.current == 1, "2 minutes before turn-on arms 1%")
  check(!hw.enabled && hw.writes.isEmpty, "arming stages strength only, Night Shift stays off")
  hw.now = 20 * 60 + 59
  ramp.tick()
  check(hw.arms == 1, "arming runs once per turn-on")

  check(ramp.setMax(60) == .saved && files.readMax() == 60, "max 60 outside the window is saved")
  check(hw.writes.isEmpty, "a max outside the window with Night Shift off writes no warmth")

  hw.enabled = true
  hw.now = 21 * 60 + 5
  ramp.tick()
  let evening = ramp.phase.glide
  check(evening?.fromMinute == Minute(21 * 60) && evening?.fromValue == 1, "the evening glide starts at turn-on from 1%")
  check(evening?.toMinute == Minute(23 * 60), "default Full at is start + 120")
  check(hw.writes == [3], "21:05 writes 1 + 59*5/120 = 3")
  hw.now = 22 * 60
  ramp.tick()
  check(hw.writes == [3, 30], "the 22:00 midpoint writes 1 + 59*60/120 = 30")

  hw.current = 45
  hw.now = 22 * 60 + 1
  ramp.tick()
  let drifted = ramp.phase.glide
  check(drifted?.fromMinute == Minute(22 * 60 + 1) && drifted?.fromValue == 45, "a manual 45% retargets from now at 45")
  check(drifted?.toMinute == Minute(23 * 60), "the retargeted glide still arrives at Full at")
  check(hw.writes == [3, 30], "a drift tick writes nothing")
  check(ramp.settings.max == Warmth(60), "a manual warmth below max leaves max")

  let beforeFailedApply = ramp.phase
  hw.writeWorks = false
  check(!ramp.applyWarmth(Warmth(70)!), "a failed user write reports failure")
  check(ramp.phase == beforeFailedApply && ramp.settings.max == Warmth(60), "a failed user write leaves phase and max")
  hw.writeWorks = true
  hw.now = 22 * 60 + 2
  ramp.tick()
  check(ramp.phase.glide?.fromMinute == Minute(22 * 60 + 1), "a failed user write leaves applied, so the next tick is no drift")
  check(hw.writes == [3, 30], "22:02 is still 45 + 15*1/59 = 45, so nothing is written")

  hw.writeWorks = false
  hw.now = 22 * 60 + 31
  let beforeFailedTick = hw.writes
  ramp.tick()
  check(hw.writes == beforeFailedTick, "a failed tick write records nothing")
  hw.writeWorks = true
  hw.now = 22 * 60 + 32
  ramp.tick()
  check(ramp.phase.glide?.fromMinute == Minute(22 * 60 + 1), "a failed tick write does not drift-retarget")
  check(hw.writes == [3, 30, 52], "the tick after a failed write glides on: 45 + 15*31/59 = 52")

  hw.current = 80
  hw.now = 22 * 60 + 33
  ramp.tick()
  check(ramp.settings.max == Warmth(80) && files.readMax() == 80, "a manual warmth above max raises max")
  check(ramp.phase.glide?.toMinute == Minute(22 * 60 + 33), "drift to max holds at max")

  hw.enabled = false
  hw.current = 0
  hw.now = 8 * 60
  ramp.tick()
  check(ramp.phase == .idle, "leaving the window clears the glide")
  try? FileManager.default.removeItem(at: files.fullURL)
  notices = []
  check(ramp.setFullAt(7 * 60 + 30) == .refusedOutsideSchedule, "7:30 at 8:00 is outside 21:00-7:00 and refused")
  check(files.readFullAt() == nil && ramp.settings.fullAtClock == nil, "a refused Full at writes no file")
  check(notices == [.outsideSchedule], "a refused Full at says why")
  check(ramp.setFullAt(23 * 60) == .saved && files.readFullAt() == 23 * 60, "23:00 at 8:00 is inside the schedule and saved")
  check(ramp.setFullAt(20 * 60) == .early && files.readFullAt() == 20 * 60, "20:00 at 8:00 comes before turn-on: early glide")
  if case .early = ramp.phase {} else { check(false, "Full at before turn-on is an early phase") }
  hw.mode = .sunsetToSunrise
  check(ramp.setFullAt(22 * 60) == .needsCustomSchedule && files.readFullAt() == 20 * 60, "Full at needs a Custom schedule")
  hw.mode = .custom
  hw.isLicensed = false
  check(ramp.setFullAt(22 * 60) == .locked && ramp.setMax(30) == .locked, "an unlicensed ramp changes nothing")
}

check(updateNotice(local: "0.3.0", remoteTag: "v0.3.0") == "You're up to date.", "the same release is current")
check(updateNotice(local: "0.3.0", remoteTag: "0.3") == "You're up to date.", "0.3 and 0.3.0 are the same release")
check(updateNotice(local: "0.3.0", remoteTag: "v0.4.0") == "Version 0.4.0 is available.", "a newer tag is available")
check(updateNotice(local: "0.3.0", remoteTag: "0.3.1") == "Version 0.3.1 is available.", "a newer patch is available")
check(updateNotice(local: "0.3.0", remoteTag: " ") == "Couldn't check for updates.", "a blank tag is not a release")

rampTests()

if failures > 0 {
  exit(1)
}
print("swift-tests: ok")
