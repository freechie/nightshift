import CNightshift
import os

private let log = Logger(subsystem: "io.github.freechie.nightshift.swift", category: "ramp")

/// A minute of the local day, 0..<1440.
struct Minute: Equatable, Comparable {
  let value: Int

  init?(_ value: Int) {
    guard (0..<1440).contains(value) else { return nil }
    self.value = value
  }

  fileprivate init?(_ value: Int32) { self.init(Int(value)) }

  fileprivate var c: Int32 { Int32(value) }

  static func < (a: Minute, b: Minute) -> Bool { a.value < b.value }
}

/// The Custom schedule window. The end minute is outside it.
struct ScheduleWindow: Equatable {
  let start: Minute
  let end: Minute

  func contains(_ now: Minute) -> Bool { insideWindow(start.c, end.c, now.c) }
  // Unlike contains, the end counts.
  func admits(fullAt clock: Minute) -> Bool { nsClockInSchedule(start.c, end.c, clock.c) }
  func isAhead(of now: Minute, clock: Minute) -> Bool { nsAheadOfTurnOn(now.c, start.c, clock.c) }
  func minutesUntilStart(from now: Minute) -> Int { Int(minutesBetween(now.c, start.c)) }
}

/// One Night Shift status read. `window` is nil unless mode == .custom.
struct NightShiftStatus: Equatable {
  let mode: ScheduleMode
  let window: ScheduleWindow?
  let enabled: Bool
}

/// What the ramp reads and writes outside itself: NightShiftClient in the app,
/// a fake in the tests.
@MainActor
protocol RampHardware: AnyObject {
  func nightShift() -> NightShiftStatus?
  func strength() -> Int?
  /// applyStrength: turns Night Shift on for >0. The stored value, or nil on failure.
  func write(_ warmth: Warmth) -> Int?
  /// stageStrength(1) only. The drag stage() path flushes setEnabled(true),
  /// which would turn Night Shift on before the schedule does.
  func arm() -> Bool
  func licensed() -> Bool
  func minuteNow() -> Minute?
}

/// Warmth moves from `fromValue` at `fromMinute` to max at `toMinute`.
/// `toMinute == fromMinute` holds at max.
struct Glide: Equatable {
  let fromMinute: Minute
  let fromValue: Int
  let toMinute: Minute
  /// Progress stage already announced, 0...3.
  var announced: Int = 0

  init(from fromMinute: Minute, value fromValue: Int, to toMinute: Minute) {
    self.fromMinute = fromMinute
    self.fromValue = fromValue
    self.toMinute = toMinute
  }

  func value(at now: Minute, max: Int) -> Int {
    glideWarmth(fromMinute.c, toMinute.c, fromValue, max, now.c)
  }

  func stage(at now: Minute) -> Int { Int(nsGlideStage(fromMinute.c, toMinute.c, now.c)) }
}

enum RampPhase: Equatable {
  case idle
  case gliding(Glide)
  /// Full at was set ahead of turn-on, so the glide runs before the window opens.
  case early(Glide)
  /// In the window with warmth off. The next enabled tick adopts the current
  /// strength and retargets.
  case suspended

  var glide: Glide? {
    switch self {
    case .gliding(let g), .early(let g): g
    case .idle, .suspended: nil
    }
  }
}

/// The saved max and Full at. `max` nil means no max saved yet.
struct RampSettings: Equatable {
  var max: Warmth?
  var fullAtClock: Minute?
}

/// Reset together when the schedule start changes.
private struct Tonight: Equatable {
  var scheduleStart: Minute?
  /// Tonight's resolved Full at.
  var fullAt: Minute?
  /// arm() already ran for this start.
  var armedStart: Minute?
}

/// What the ramp tells the user. Logged until banners land.
enum RampNotice: Equatable {
  case outsideSchedule
  case couldNotSaveTime
  case progress(Int, max: Int, reaching: Minute?)
}

enum MaxOutcome: Equatable { case locked, invalid, saveFailed, saved, retargeted, capped }

enum FullAtOutcome: Equatable {
  case locked, invalid, needsCustomSchedule, saveFailed
  case refusedOutsideSchedule
  case early
  case saved
  case retargeted
  case heldAtMax
}

private func logNotice(_ notice: RampNotice) {
  log.info("ramp notice \(String(describing: notice), privacy: .public)")
}

/// Owns the ramp state and is the only writer of the max and full files.
@MainActor
final class RampEngine {
  static let rampMinutes = 120
  static let glideMinutes = 30
  static let armMinutes = 2
  // The daemon glides toward 50 before any max is saved.
  private static let unsetMax = 50

  private(set) var phase: RampPhase = .idle
  private(set) var settings: RampSettings
  /// The strength this engine last wrote. A different reading is a manual change.
  private var applied: Int?
  private var tonight = Tonight()
  private var loggedSchedule = false

  private let hardware: any RampHardware
  private let files: MenuFiles
  private let notify: @MainActor (RampNotice) -> Void

  init(
    hardware: any RampHardware,
    files: MenuFiles,
    notify: @escaping @MainActor (RampNotice) -> Void = logNotice
  ) {
    self.hardware = hardware
    self.files = files
    self.notify = notify
    settings = RampSettings(
      max: files.readMax().flatMap(Warmth.init),
      fullAtClock: files.readFullAt().flatMap(Minute.init)
    )
  }

  var isLicensed: Bool { hardware.licensed() }

  private var maxValue: Int { settings.max?.percent ?? Self.unsetMax }

  /// Slider release and hotkeys. False, with nothing changed, when the write fails.
  @discardableResult
  func applyWarmth(_ warmth: Warmth) -> Bool {
    guard let stored = hardware.write(warmth) else { return false }
    guard isLicensed else {
      clear()
      applied = warmth.percent == 0 ? nil : stored
      return true
    }
    let scheduled = customNow()
    let inWindow = scheduled.map { $0.window.contains($0.now) } ?? false
    if warmth.percent == 0 {
      applied = nil
      if inWindow {
        phase = .suspended
      } else if phase == .suspended {
        phase = .idle
      }
      return true
    }
    raiseMax(warmth.percent)
    if let scheduled, inWindow {
      ensureFullAt(scheduled.window)
      retarget(scheduled.now, from: stored, end: scheduled.window.end)
    } else if phase == .suspended {
      phase = .idle
    }
    applied = stored
    return true
  }

  /// The 60s timer.
  func tick() {
    guard let status = hardware.nightShift() else { return }
    guard isLicensed else {
      if phase != .idle { clear() }
      return
    }
    guard status.mode == .custom, let window = status.window else {
      if !loggedSchedule {
        log.info("evening ramp needs a Custom Night Shift schedule")
        loggedSchedule = true
      }
      clear()
      tonight = Tonight()
      return
    }
    loggedSchedule = false
    guard let now = hardware.minuteNow() else { return }
    if tonight.scheduleStart != window.start {
      // Unlike clear(), keeps applied: a new start is not a manual change.
      tonight = Tonight(scheduleStart: window.start)
      phase = .idle
    }

    if !window.contains(now) {
      if case .early(let glide) = phase, settings.fullAtClock != nil {
        guard let current = hardware.strength() else { return }
        glideStep(now, glide, current: current, end: window.end, early: true)
        return
      }
      clear()
      let until = window.minutesUntilStart(from: now)
      if !status.enabled, (1...Self.armMinutes).contains(until),
        tonight.armedStart != window.start, hardware.arm()
      {
        tonight.armedStart = window.start
      }
      return
    }

    if case .early(let glide) = phase { phase = .gliding(glide) }
    guard status.enabled else {
      phase = .suspended
      applied = nil
      return
    }
    guard let current = hardware.strength() else { return }
    if phase == .suspended || (phase == .idle && settings.max == nil) {
      guard adoptCurrentMax(current) else { return }
      ensureFullAt(window)
      retarget(now, from: current, end: window.end)
      return
    }
    if phase == .idle { beginEvening(window) }
    guard let glide = phase.glide else { return }
    glideStep(now, glide, current: current, end: window.end, early: false)
  }

  /// The Max slider.
  @discardableResult
  func setMax(_ percent: Int) -> MaxOutcome {
    guard isLicensed else { return .locked }
    guard (1...100).contains(percent) else { return .invalid }
    guard rememberMax(percent) else { return .saveFailed }
    if let scheduled = customNow(), scheduled.window.contains(scheduled.now), scheduled.status.enabled {
      ensureFullAt(scheduled.window)
      // Glides to a lower max instead of jumping.
      retarget(scheduled.now, from: hardware.strength() ?? applied ?? percent, end: scheduled.window.end)
      return .retargeted
    }
    // #37: outside the window a max below the current warmth caps it now.
    if hardware.nightShift()?.enabled == true, let current = hardware.strength(), current > percent,
      let capped = Warmth(percent), let stored = hardware.write(capped)
    {
      applied = stored
      return .capped
    }
    return .saved
  }

  /// The Full at picker. Custom only (#37), unlike the daemon.
  @discardableResult
  func setFullAt(_ minute: Int) -> FullAtOutcome {
    guard isLicensed else { return .locked }
    guard let clock = Minute(minute) else { return .invalid }
    guard let scheduled = customNow() else { return .needsCustomSchedule }
    let (status, window, now) = (scheduled.status, scheduled.window, scheduled.now)

    if window.isAhead(of: now, clock: clock) {
      guard rememberFullAt(clock) else {
        notify(.couldNotSaveTime)
        return .saveFailed
      }
      let current = hardware.strength() ?? applied ?? 0
      guard adoptCurrentMax(current) else {
        if case .early = phase { phase = .idle }
        tonight.fullAt = nil
        return .saved
      }
      tonight.fullAt = clock
      retarget(now, from: Swift.max(current, 1), end: window.end, early: true)
      return .early
    }
    guard window.admits(fullAt: clock) else {
      notify(.outsideSchedule)
      return .refusedOutsideSchedule
    }
    guard rememberFullAt(clock) else {
      notify(.couldNotSaveTime)
      return .saveFailed
    }
    guard window.contains(now), status.enabled else {
      tonight.fullAt = nil
      return .saved
    }
    tonight.fullAt = clock
    var current = hardware.strength() ?? applied ?? 0
    let until = Int(minutesBetween(now.c, clock.c))
    let untilEnd = Int(minutesBetween(now.c, window.end.c))
    if until == 0 || until > untilEnd {
      guard adoptCurrentMax(current) else { return .saved }
      if let max = settings.max, let stored = hardware.write(max) {
        applied = stored
        current = stored
      }
      phase = .gliding(Glide(from: now, value: Swift.max(current, 1), to: now))
      announce(now)
      return .heldAtMax
    }
    retarget(now, from: Swift.max(current, 1), end: window.end)
    return .retargeted
  }

  /// Keeps tonight's schedule start and arm, so a cleared ramp does not re-arm.
  private func clear() {
    phase = .idle
    applied = nil
    tonight.fullAt = nil
  }

  private func customNow() -> (status: NightShiftStatus, window: ScheduleWindow, now: Minute)? {
    guard let now = hardware.minuteNow(), let status = hardware.nightShift(),
      status.mode == .custom, let window = status.window
    else { return nil }
    return (status, window, now)
  }

  private func retarget(_ now: Minute, from value: Int, end: Minute, early: Bool = false) {
    let from = Swift.min(Swift.max(value, 1), 100)
    let to =
      from == maxValue
      ? now
      : Minute(nsGlideEnd(now.c, end.c, Int32(tonight.fullAt?.value ?? -1), Int32(Self.glideMinutes))) ?? now
    let glide = Glide(from: now, value: from, to: to)
    applied = from
    phase = early ? .early(glide) : .gliding(glide)
    announce(now)
  }

  private func glideStep(_ now: Minute, _ glide: Glide, current: Int, end: Minute, early: Bool) {
    var glide = glide
    if let applied, current != applied {
      raiseMax(current)
      retarget(now, from: current, end: end, early: early)
      // The daemon's early path writes the retargeted glide in the same tick.
      guard early, let retargeted = phase.glide else { return }
      glide = retargeted
    }
    let value = glide.value(at: now, max: maxValue)
    if value != applied, let warmth = Warmth(value), let stored = hardware.write(warmth) {
      applied = stored
    }
    if applied != nil { announce(now) }
  }

  private func beginEvening(_ window: ScheduleWindow) {
    guard settings.max != nil else { return }
    ensureFullAt(window)
    guard let fullAt = tonight.fullAt else { return }
    phase = .gliding(Glide(from: window.start, value: 1, to: fullAt))
  }

  private func ensureFullAt(_ window: ScheduleWindow) {
    guard tonight.fullAt == nil else { return }
    let saved = Int32(settings.fullAtClock?.value ?? -1)
    tonight.fullAt = Minute(nsDefaultFullAt(window.start.c, window.end.c, saved, Int32(Self.rampMinutes)))
  }

  /// Max only rises on its own: a manual warmth above it becomes the new max.
  private func raiseMax(_ value: Int) {
    guard value >= 1 else { return }
    if settings.max == nil || value > maxValue { _ = rememberMax(value) }
  }

  private func adoptCurrentMax(_ current: Int) -> Bool {
    if settings.max != nil { return true }
    guard (1...100).contains(current) else { return false }
    return rememberMax(current)
  }

  private func rememberMax(_ value: Int) -> Bool {
    guard (1...100).contains(value), let max = Warmth(value), files.writeMax(value) else {
      log.error("failed to save max")
      return false
    }
    settings.max = max
    return true
  }

  private func rememberFullAt(_ clock: Minute) -> Bool {
    guard files.writeFullAt(clock.value) else {
      log.error("failed to save full at")
      return false
    }
    settings.fullAtClock = clock
    return true
  }

  private func announce(_ now: Minute) {
    guard var glide = phase.glide, glide.announced < 3 else { return }
    let stage = glide.stage(at: now)
    guard stage > glide.announced else { return }
    glide.announced = stage
    switch phase {
    case .early: phase = .early(glide)
    case .gliding: phase = .gliding(glide)
    case .idle, .suspended: return
    }
    let warmth = applied ?? glide.fromValue
    let reaching = warmth == maxValue || stage >= 3 ? nil : glide.toMinute
    notify(.progress(warmth, max: maxValue, reaching: reaching))
  }
}
