// Copyright 2026 John
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CNightshift
import Foundation

// Wire tokens for nightshiftd.sock. English stays in the CLI (warmthSentence).

func statusWireLine(now: Int, max: Int, state: String, full: Int) -> String {
  "\(now) \(max) \(state) \(full)"
}

func statusWireState(enabled: Bool, phase: RampPhase, now: Minute?) -> String {
  guard enabled else { return "off" }
  guard let glide = phase.glide, let now else { return "idle" }
  return glide.stage(at: now) >= 3 ? "holding" : "ramping"
}

func scheduleWireName(_ mode: ScheduleMode) -> String {
  switch mode {
  case .off: "off"
  case .custom: "custom"
  case .sunsetToSunrise: "sunset"
  }
}

func scheduleMode(wire name: String) -> ScheduleMode? {
  switch name {
  case "off": .off
  case "custom": .custom
  case "sunset": .sunsetToSunrise
  default: nil
  }
}

func onOffWire(_ text: String) -> Bool? {
  switch text {
  case "on": true
  case "off": false
  default: nil
  }
}

func onOffReply(_ on: Bool) -> String { on ? "on" : "off" }

func parseCommandNumber(_ text: String, lo: Int, hi: Int) -> Int? {
  var value: CLong = 0
  let ok = text.withCString { parseNumber($0, CLong(lo), CLong(hi), &value) }
  guard ok else { return nil }
  return Int(value)
}
