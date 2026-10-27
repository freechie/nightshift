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

// Hold state for warmth hotkeys. Carbon delivers press/release once; repeats
// are our timer. Matches nightshiftd commandWarmthTick / hold fields.

struct WarmthHold: Equatable {
  var generation = 0
  var direction = 0  // -1 lower, 1 raise, 0 idle
  var percent: Int?
  var dirty = false
  var keyCode: UInt32 = 0
  var keyReadable = false

  var isHolding: Bool { direction != 0 }

  // Returns the percent to preview, or nil when nothing changed.
  mutating func press(
    direction newDirection: Int,
    startingPercent: Int?,
    keyCode: UInt32,
    keyReadable: Bool
  ) -> Int? {
    guard newDirection == -1 || newDirection == 1 else { return nil }
    if direction == newDirection {
      return nil
    }
    if direction != 0 {
      _ = release()
    }
    direction = newDirection
    self.keyCode = keyCode
    self.keyReadable = keyReadable
    percent = startingPercent
    dirty = false
    generation += 1
    return tick()
  }

  // One step while held. Nil when idle, unknown start, or already at the stop.
  mutating func tick() -> Int? {
    guard direction != 0 else { return nil }
    guard let current = percent else { return nil }
    let next = Self.stepped(from: current, direction: direction)
    if next == current {
      return nil
    }
    dirty = true
    percent = next
    return next
  }

  // Commit percent when dirty. Clears the hold either way.
  mutating func release() -> Int? {
    let commit = dirty ? percent : nil
    direction = 0
    percent = nil
    dirty = false
    keyCode = 0
    keyReadable = false
    generation += 1
    return commit
  }

  // Same clamp/step as nsCommandWarmthNext (step 5).
  static func stepped(from percent: Int, direction: Int) -> Int {
    var value = percent
    if value < 0 { value = 0 }
    if value > 100 { value = 100 }
    if direction == 1 || direction == -1 {
      value += direction * 5
    }
    if value < 0 { value = 0 }
    if value > 100 { value = 100 }
    return value
  }
}
