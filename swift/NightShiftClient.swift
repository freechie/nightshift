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

  func apply(_ warmth: Warmth) -> WarmthReading {
    var stored = 0
    if !applyStrength(client, warmth.percent, &stored) {
      log.error("applyStrength failed for \(warmth.percent, privacy: .public)%")
    }
    return read()
  }

  // Live drag: setStrength alone does not repaint, so flush with setEnabled(true)
  // (~0.15ms per new value while on). Off needs one full apply to turn on.
  func stage(_ warmth: Warmth) {
    var status = BLStatus()
    if warmth.percent >= 1, !liveOn, readStatus(client, &status), !status.enabled.boolValue {
      _ = apply(warmth)
      return
    }
    if !stageStrength(client, warmth.percent) {
      log.error("stageStrength failed for \(warmth.percent, privacy: .public)%")
    } else if warmth.percent >= 1 {
      liveOn = true
      if !client.setEnabled(true) {
        log.error("setEnabled flush failed for \(warmth.percent, privacy: .public)%")
      }
    }
  }

  // Live menu: warmth stays on this client. Max and full use the shared ramp
  // files. Collapse uses the Swift support folder inside MenuFiles.live().
  func menuFacade(files: MenuFiles = .live()) -> MenuFacade {
    MenuFacade(
      warmth: self,
      files: files,
      schedule: { self.readScheduleMode() },
      changeSchedule: { self.writeScheduleMode($0) },
      darkMode: { nsSwiftDarkMode() },
      changeDarkMode: { nsSwiftSetDarkMode($0) },
      trueTone: { self.readTrueTone() },
      changeTrueTone: { nsSwiftSetTrueTone($0) },
      licensed: { rampLicensed() }
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
