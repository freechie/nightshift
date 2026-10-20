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

check(menuTitle(for: .on(Warmth(1)!)) == "1%", "on at 1 reads as 1%")
check(menuTitle(for: .on(Warmth(100)!)) == "100%", "on at 100 reads as 100%")
check(menuTitle(for: .off) == "Off", "off reads as Off")
check(menuTitle(for: .unreadable) == "Unavailable", "a failed read says so")
check(menuTitle(for: .unavailable) == "Night Shift is unavailable", "a missing client says so in the menu")

if failures > 0 {
  exit(1)
}
print("swift-tests: ok")
