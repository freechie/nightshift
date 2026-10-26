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

if failures > 0 {
  exit(1)
}
print("swift-tests: ok")
