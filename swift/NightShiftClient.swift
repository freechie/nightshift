import CNightshift
import os

private let log = Logger(subsystem: "io.github.freechie.nightshift.swift", category: "warmth")

@MainActor
final class NightShiftClient: WarmthSource {
  private let client: CBBlueLightClient
  // Last known enabled state. Lets stage skip getStatus (~1ms with setStrength) while on.
  private var liveOn = false

  init?() {
    guard let client = makeClient() else { return nil }
    self.client = client
  }

  func read() -> WarmthReading {
    var stored = 0
    var status = BLStatus()
    let strength = readStrength(client, &stored) ? stored : nil
    let enabled = readStatus(client, &status) ? status.enabled.boolValue : nil
    if let enabled { liveOn = enabled }
    return reading(strength: strength, enabled: enabled)
  }

  // Live drag: an uncommitted strength paints while the mouse button is down;
  // a committed one, or setEnabled, waits for release. Release does the full
  // write. Off needs one full write to turn on.
  func stage(_ warmth: Warmth) {
    var status = BLStatus()
    if warmth.percent >= 1, !liveOn, readStatus(client, &status), !status.enabled.boolValue {
      _ = write(warmth)
      return
    }
    if !previewStrength(client, warmth.percent) {
      log.error("previewStrength failed for \(warmth.percent, privacy: .public)%")
    }
  }

  // Live menu: drag stages on this client. Warmth, max, and full commit through
  // RampEngine. Max, full, and collapse live in the Swift support folder (MenuFiles.live()).
  func menuFacade(files: MenuFiles = .live()) -> MenuFacade {
    MenuFacade(
      warmth: self,
      ramp: RampEngine(hardware: self, files: files),
      files: files,
      schedule: { self.readScheduleMode() },
      changeSchedule: { self.writeScheduleMode($0) },
      darkMode: { nsSwiftDarkMode() },
      changeDarkMode: { nsSwiftSetDarkMode($0) },
      trueTone: { self.readTrueTone() },
      changeTrueTone: { nsSwiftSetTrueTone($0) }
    )
  }

  private func readScheduleMode() -> ScheduleMode {
    var status = BLStatus()
    guard readStatus(client, &status), let mode = ScheduleMode(rawValue: Int(status.mode)) else {
      return .off
    }
    return mode
  }

  private func writeScheduleMode(_ mode: ScheduleMode) -> Bool {
    nsSwiftSetMode(client, Int32(mode.rawValue))
  }

  private func readTrueTone() -> Bool? {
    var enabled = ObjCBool(false)
    guard nsSwiftReadTrueTone(&enabled) else { return nil }
    return enabled.boolValue
  }
}

// Thin C wrappers. The ramp reads schedule and license fresh on every call.
extension NightShiftClient: RampHardware {
  func nightShift() -> NightShiftStatus? {
    var status = BLStatus()
    guard readStatus(client, &status), let mode = ScheduleMode(rawValue: Int(status.mode)) else {
      return nil
    }
    let enabled = status.enabled.boolValue
    liveOn = enabled
    var window: ScheduleWindow?
    if mode == .custom,
      let start = Minute(Int(status.schedule.from.hour) * 60 + Int(status.schedule.from.minute)),
      let end = Minute(Int(status.schedule.to.hour) * 60 + Int(status.schedule.to.minute))
    {
      window = ScheduleWindow(start: start, end: end)
    }
    return NightShiftStatus(mode: mode, window: window, enabled: enabled)
  }

  func strength() -> Int? {
    var stored = 0
    return readStrength(client, &stored) ? stored : nil
  }

  // applyStrength turns Night Shift on for >0.
  func write(_ warmth: Warmth) -> Int? {
    var stored = 0
    guard applyStrength(client, warmth.percent, &stored) else {
      log.error("applyStrength failed for \(warmth.percent, privacy: .public)%")
      return nil
    }
    liveOn = warmth.percent >= 1
    return stored
  }

  // Strength only. stage() would flush setEnabled(true) and turn Night Shift
  // on before the schedule does.
  func arm() -> Bool {
    stageStrength(client, 1)
  }

  func licensed() -> Bool { rampLicensed() }

  func minuteNow() -> Minute? { Minute(minute(of: Date())) }
}
