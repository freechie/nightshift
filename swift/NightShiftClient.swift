import CNightshift
import os

private let log = Logger(subsystem: "io.github.freechie.nightshift.swift", category: "warmth")

@MainActor
final class NightShiftClient: WarmthSource {
  private let client: CBBlueLightClient

  init?() {
    guard let client = makeClient() else { return nil }
    self.client = client
  }

  func read() -> WarmthReading {
    var stored = 0
    var status = BLStatus()
    let strength = readStrength(client, &stored) ? stored : nil
    let enabled = readStatus(client, &status) ? status.enabled.boolValue : nil
    return reading(strength: strength, enabled: enabled)
  }

  func apply(_ warmth: Warmth) -> WarmthReading {
    var stored = 0
    if !applyStrength(client, warmth.percent, &stored) {
      log.error("applyStrength failed for \(warmth.percent, privacy: .public)%")
    }
    return read()
  }
}
