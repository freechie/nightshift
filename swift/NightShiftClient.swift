import CNightshift

@MainActor
final class NightShiftClient {
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
    guard applyStrength(client, warmth.percent, &stored) else { return read() }
    return read()
  }
}
