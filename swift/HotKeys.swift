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

import AppKit
import Carbon
import CNightshift

// Global Carbon warmth hotkeys (signature NScm). No event tap, so no
// Accessibility prompt. Hold repeats on the main queue; release commits.

private let kWarmthHotKeySignature: OSType = 0x4E53636D  // 'NScm'

@MainActor
final class WarmthHotKeys {
  static let shared = WarmthHotKeys()

  var onPreview: ((Int) -> Void)?
  var onCommit: ((Int) -> Void)?
  var currentPercent: (() -> Int?)?
  var isSliderTracking: (() -> Bool)?

  private var hold = WarmthHold()
  private var lower = NSShortcut()
  private var raise = NSShortcut()
  private var hotKeyRefs: [EventHotKeyRef?] = [nil, nil]
  private var handlerRef: EventHandlerRef?
  private var menuTimer: Timer?
  private var menuOpenedAt: EventTime = -1
  private var menuClosedAt: EventTime = -1
  private var menuHeld = [false, false]
  private var menuPolled = [false, false]
  private var paused = false
  private var started = false

  private init() {}

  private func shortcut(at index: Int) -> NSShortcut {
    index == 0 ? lower : raise
  }

  func start() {
    guard !started else { return }
    started = true
    installHandler()
    loadShortcuts()
    registerKeys(notify: true)
  }

  func stop() {
    stopMenuPoll()
    unregisterKeys()
    if let handlerRef {
      RemoveEventHandler(handlerRef)
      self.handlerRef = nil
    }
    started = false
  }

  func menuWillOpen() {
    registerKeys(notify: false)
    startMenuPoll()
  }

  func menuDidClose() {
    stopMenuPoll()
  }

  func shortcutPair() -> (NSShortcut, NSShortcut) {
    (lower, raise)
  }

  func keyStatuses() -> [(name: String, ready: Bool)] {
    (0..<2).map { index in
      let shortcut = shortcut(at: index)
      let ready = hotKeyRefs[index] != nil
      return (shortcutLabel(shortcut), ready)
    }
  }

  func pauseForRecording() {
    paused = true
    unregisterKeys()
  }

  func resumeAfterRecording() {
    paused = false
    registerKeys(notify: false)
  }

  func saveShortcuts(lower: NSShortcut, raise: NSShortcut) -> Bool {
    var pair = [lower, raise]
    var buf = [CChar](repeating: 0, count: 256)
    let written = buf.withUnsafeMutableBufferPointer { buffer in
      pair.withUnsafeMutableBufferPointer { shortcuts in
        nsShortcutsFormat(shortcuts.baseAddress, buffer.baseAddress, buffer.count)
      }
    }
    guard written > 0, written < buf.count else { return false }
    let url = URL(fileURLWithPath: Self.shortcutsPath)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(bytes: buf, count: Int(written)).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      return false
    }
    paused = false
    self.lower = lower
    self.raise = raise
    unregisterKeys()
    registerKeys(notify: true)
    return true
  }

  func restoreDefaultShortcuts() -> Bool {
    var lower = NSShortcut()
    var raise = NSShortcut()
    guard nsShortcutDefault(1, &lower), nsShortcutDefault(2, &raise) else { return false }
    return saveShortcuts(lower: lower, raise: raise)
  }

  private static let shortcutsPath =
    NSHomeDirectory() + "/Library/Application Support/nightshift/shortcuts"

  fileprivate func handle(kind: UInt32, hotKey: EventHotKeyID, eventTime: EventTime) {
    let id = Int(hotKey.id)
    guard hotKey.signature == kWarmthHotKeySignature, id == 1 || id == 2 else { return }
    if nsHotKeyDuringMenu(eventTime, menuOpenedAt, menuClosedAt, menuPolled[id - 1]) {
      return
    }
    if kind == UInt32(kEventHotKeyReleased) {
      onReleased(id: UInt32(id))
    } else if kind == UInt32(kEventHotKeyPressed) {
      onPressed(id: UInt32(id))
    }
  }

  private func onPressed(id: UInt32) {
    let direction = Int(nsCommandWarmthDirection(id))
    guard direction != 0 else { return }
    if hold.direction == 0, isSliderTracking?() == true {
      return
    }
    let shortcut = shortcut(at: Int(id) - 1)
    let readable = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.keyCode))
    if let preview = hold.press(
      direction: direction,
      startingPercent: currentPercent?(),
      keyCode: shortcut.keyCode,
      keyReadable: readable
    ) {
      onPreview?(preview)
    }
    scheduleRepeat(generation: hold.generation, first: true)
  }

  private func onReleased(id: UInt32) {
    let direction = Int(nsCommandWarmthDirection(id))
    guard direction == hold.direction else { return }
    finishHold()
  }

  private func finishHold() {
    if let commit = hold.release() {
      onCommit?(commit)
    } else if let now = currentPercent?() {
      onCommit?(now)
    }
  }

  private func scheduleRepeat(generation: Int, first: Bool) {
    let seconds = first ? NSEvent.keyRepeatDelay : NSEvent.keyRepeatInterval
    let gap = nsCommandWarmthRepeatGap(seconds)
    DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
      guard let self else { return }
      guard generation == self.hold.generation, self.hold.direction != 0 else { return }
      if self.hold.keyReadable {
        let down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(self.hold.keyCode))
        if !down {
          self.finishHold()
          return
        }
      }
      if let preview = self.hold.tick() {
        self.onPreview?(preview)
      }
      self.scheduleRepeat(generation: generation, first: false)
    }
  }

  private func installHandler() {
    guard handlerRef == nil else { return }
    var types = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      warmthHotKeyEventHandler,
      2,
      &types,
      nil,
      &handlerRef
    )
    if status != noErr {
      NSLog("WarmthHotKeys handler install failed: %d", Int(status))
    }
  }

  private func loadShortcuts() {
    var pair = [NSShortcut(), NSShortcut()]
    let path = Self.shortcutsPath
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    text.withCString { cstr in
      _ = nsShortcutsParse(cstr, &pair)
    }
    lower = pair[0]
    raise = pair[1]
  }

  private func registerKeys(notify: Bool) {
    guard !paused else { return }
    for i in 0..<2 {
      if hotKeyRefs[i] != nil { continue }
      let shortcut = shortcut(at: i)
      if systemShortcutTaken(shortcut) {
        if notify {
          NSLog("warmth hotkey %d taken by macOS", i + 1)
        }
        continue
      }
      var ref: EventHotKeyRef?
      let hotKey = EventHotKeyID(signature: kWarmthHotKeySignature, id: UInt32(i + 1))
      let err = RegisterEventHotKey(
        shortcut.keyCode,
        shortcut.modifiers,
        hotKey,
        GetApplicationEventTarget(),
        0,
        &ref
      )
      if err == noErr {
        hotKeyRefs[i] = ref
      } else if notify {
        NSLog("warmth hotkey %d register failed: %d", i + 1, Int(err))
      }
    }
  }

  private func unregisterKeys() {
    if hold.direction != 0 {
      finishHold()
    }
    for i in 0..<2 {
      if let ref = hotKeyRefs[i] {
        UnregisterEventHotKey(ref)
        hotKeyRefs[i] = nil
      }
    }
  }

  private func systemShortcutTaken(_ shortcut: NSShortcut) -> Bool {
    var keys: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&keys) == noErr, let array = keys?.takeRetainedValue() as? [Any] else {
      return false
    }
    let mask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    for item in array {
      guard let dict = item as? [AnyHashable: Any] else { continue }
      guard let enabled = dict[kHISymbolicHotKeyEnabled] as? Bool, enabled else { continue }
      guard let keyCode = dict[kHISymbolicHotKeyCode] as? Int else { continue }
      guard let modifiers = dict[kHISymbolicHotKeyModifiers] as? Int else { continue }
      if keyCode == Int(shortcut.keyCode), (UInt32(modifiers) & mask) == shortcut.modifiers {
        return true
      }
    }
    return false
  }

  private func startMenuPoll() {
    stopMenuPoll()
    menuOpenedAt = GetCurrentEventTime()
    menuClosedAt = -1
    menuHeld = [false, false]
    menuPolled = [false, false]
    let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.pollMenuKeys()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    menuTimer = timer
  }

  private func stopMenuPoll() {
    menuTimer?.invalidate()
    menuTimer = nil
    menuClosedAt = GetCurrentEventTime()
  }

  private func pollMenuKeys() {
    for i in 0..<2 {
      let shortcut = shortcut(at: i)
      let keyDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.keyCode))
      let flags = CGEventSource.flagsState(.hidSystemState)
      var heldMods: UInt32 = 0
      if flags.contains(.maskCommand) { heldMods |= UInt32(kNSHotKeyCommand) }
      if flags.contains(.maskShift) { heldMods |= UInt32(kNSHotKeyShift) }
      if flags.contains(.maskAlternate) { heldMods |= UInt32(kNSHotKeyOption) }
      if flags.contains(.maskControl) { heldMods |= UInt32(kNSHotKeyControl) }
      let held = nsShortcutHeld(shortcut.modifiers, keyDown, heldMods)
      if held != menuHeld[i] {
        menuHeld[i] = held
        menuPolled[i] = true
        if held {
          onPressed(id: UInt32(i + 1))
        } else {
          onReleased(id: UInt32(i + 1))
        }
      }
    }
  }
}

func shortcutLabel(_ shortcut: NSShortcut) -> String {
  withUnsafePointer(to: shortcut.name) {
    $0.withMemoryRebound(to: CChar.self, capacity: 40) {
      String(cString: $0)
    }
  }
}

private func warmthHotKeyEventHandler(
  _: EventHandlerCallRef?,
  event: EventRef?,
  _: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }
  var hotKey = EventHotKeyID()
  let err = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKey
  )
  guard err == noErr else { return OSStatus(eventNotHandledErr) }
  let kind = GetEventKind(event)
  let time = GetEventTime(event)
  if Thread.isMainThread {
    MainActor.assumeIsolated {
      WarmthHotKeys.shared.handle(kind: kind, hotKey: hotKey, eventTime: time)
    }
  } else {
    DispatchQueue.main.async {
      WarmthHotKeys.shared.handle(kind: kind, hotKey: hotKey, eventTime: time)
    }
  }
  return noErr
}
