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
