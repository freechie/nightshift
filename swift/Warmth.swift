struct Warmth: Equatable {
  let percent: Int

  init?(_ percent: Int) {
    guard (0...100).contains(percent) else { return nil }
    self.percent = percent
  }
}

enum WarmthReading: Equatable {
  case on(Warmth)
  case off
  case unreadable
  case unavailable
}

func menuTitle(for reading: WarmthReading) -> String {
  switch reading {
  case .on(let warmth): "\(warmth.percent)%"
  case .off: "Off"
  case .unreadable: "Unavailable"
  case .unavailable: "Night Shift is unavailable"
  }
}

func reading(strength: Int?, enabled: Bool?) -> WarmthReading {
  guard let strength, let warmth = Warmth(strength) else { return .unreadable }
  guard enabled == true else { return .off }
  return .on(warmth)
}

// Where readings come from: NightShiftClient in the app, a fake in the tests.
@MainActor
protocol WarmthSource {
  func read() -> WarmthReading
  func apply(_ warmth: Warmth) -> WarmthReading
  // Live drag: set strength only, no readback. Release still goes through apply.
  func stage(_ warmth: Warmth)
}

// What the menu shows for a source, or for none at all.
@MainActor
func currentReading(_ source: (any WarmthSource)?) -> WarmthReading {
  source?.read() ?? .unavailable
}

// A released slider applies its value; nil when there is nothing to apply.
@MainActor
func applyReleased(_ percent: Int, to source: (any WarmthSource)?) -> WarmthReading? {
  guard let source, let warmth = Warmth(percent) else { return nil }
  return source.apply(warmth)
}

// The slider for a reading. A nil value leaves the slider where it is.
struct SliderState: Equatable {
  let isEnabled: Bool
  let value: Int?
}

func sliderState(for reading: WarmthReading) -> SliderState {
  switch reading {
  case .on(let warmth): SliderState(isEnabled: true, value: warmth.percent)
  case .off: SliderState(isEnabled: true, value: 0)
  case .unreadable, .unavailable: SliderState(isEnabled: false, value: nil)
  }
}
