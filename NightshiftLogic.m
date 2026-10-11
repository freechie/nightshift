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
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Plain C on purpose (no Objective-C), so tests/logic.m can build it with any
// C compiler. Named .m only so the existing clang -fobjc-arc rules apply.

#include "NightshiftLogic.h"

#include <math.h>
#include <string.h>

static int between(int from, int to) { return (to - from + 1440) % 1440; }

// MARK: Evening ramp

int nsGlideStage(int fromMinute, int toMinute, int now) {
  int span = between(fromMinute, toMinute);
  int elapsed = between(fromMinute, now);
  if (span == 0 || elapsed >= span) {
    return 3;
  }
  if (elapsed * 2 >= span) {
    return 2;
  }
  return 1;
}

int nsGlideEnd(int now, int scheduleEnd, int fullAt, int glideMinutes) {
  int untilEnd = between(now, scheduleEnd);
  if (untilEnd == 0) {
    return now;
  }
  if (fullAt >= 0) {
    int untilFull = between(now, fullAt);
    if (untilFull > 0 && untilFull <= untilEnd) {
      return fullAt;
    }
  }
  if (untilEnd <= glideMinutes) {
    return scheduleEnd;
  }
  return (now + glideMinutes) % 1440;
}

bool nsClockInSchedule(int start, int end, int clock) {
  int length = between(start, end);
  if (length == 0 || clock < 0 || clock >= 1440) {
    return false;
  }
  return between(start, clock) <= length;
}

bool nsAheadOfTurnOn(int now, int start, int clock) {
  int untilStart = between(now, start);
  int untilClock = between(now, clock);
  return untilStart > 0 && untilClock > 0 && untilClock <= untilStart;
}

int nsDefaultFullAt(int start, int end, int rampClock, int rampMinutes) {
  int length = between(start, end);
  if (length == 0) {
    return -1;
  }
  if (rampClock >= 0 && nsClockInSchedule(start, end, rampClock)) {
    return rampClock;
  }
  int ramp = length < rampMinutes ? length : rampMinutes;
  return (start + ramp) % 1440;
}

// MARK: DDC monitor matching

bool nsDDCPortName(const char *name, char stop, char *out, size_t cap) {
  size_t length = 0;
  while (name[length] != '\0' && name[length] != stop) {
    length++;
  }
  if (length == 0 || length >= cap || strncmp(name, "disp", 4) != 0) {
    out[0] = '\0';
    return false;
  }
  memcpy(out, name, length);
  out[length] = '\0';
  return true;
}

int nsDDCPickCandidate(const DDCCandidate *candidates, int count, const DDCTarget *target) {
  bool vendorKnown = target->vendor != 0 && target->vendor != 0xFFFFFFFFu;
  int sameModel = 0;
  int lastModel = -1;
  int samePort = 0;
  int lastPort = -1;
  int sameSerial = 0;
  int lastSerial = -1;
  for (int i = 0; i < count; i++) {
    const DDCCandidate *c = &candidates[i];
    if (!c->external || c->product != target->model ||
        (vendorKnown && c->vendor != target->vendor)) {
      continue;
    }
    sameModel++;
    lastModel = i;
    if (target->port[0] != '\0' && strcmp(c->port, target->port) == 0) {
      samePort++;
      lastPort = i;
    }
    if (target->serial != 0 && c->serial == target->serial) {
      sameSerial++;
      lastSerial = i;
    }
  }
  if (samePort == 1) {
    const DDCCandidate *c = &candidates[lastPort];
    if (target->serial != 0 && c->serial != 0 && c->serial != target->serial) {
      return -1;
    }
    return lastPort;
  }
  if (sameSerial == 1 && !target->serialShared) {
    return lastSerial;
  }
  if (sameModel == 1 && target->twins <= 1) {
    return lastModel;
  }
  return -1;
}

// MARK: DDC slots and readback

int nsDDCSlotFor(const uint32_t *displays, int count, uint32_t display) {
  if (display == 0) {
    return -1;
  }
  for (int i = 0; i < count; i++) {
    if (displays[i] == display) {
      return i;
    }
  }
  for (int i = 0; i < count; i++) {
    if (displays[i] == 0) {
      return i;
    }
  }
  return -1;
}

int nsDDCValue(long percent, int scale) {
  int value = (int)llround((percent / 100.0) * scale);
  if (value < 0) {
    value = 0;
  }
  if (value > scale) {
    value = scale;
  }
  return value;
}

long nsDDCRawPercent(int raw, int scale) {
  if (scale <= 0) {
    return 0;
  }
  long percent = (long)llround((raw * 100.0) / (double)scale);
  if (percent < 0) {
    return 0;
  }
  if (percent > 100) {
    return 100;
  }
  return percent;
}

static int nearTolerance(int scale) {
  int tol = scale / 20;
  return tol < 2 ? 2 : tol;
}

bool nsDDCNear(int got, int want, int scale) {
  int diff = got - want;
  if (diff < 0) {
    diff = -diff;
  }
  return diff <= nearTolerance(scale);
}

int nsDDCLearnFloor(int floorRaw, int before, int wanted, int landed, int scale, long percent,
                    bool stable) {
  int tol = nearTolerance(scale);
  bool movedDown = wanted < before && before - landed > tol;
  bool stoppedAbove = (percent <= 0 && landed > 0) || landed > wanted + tol;
  if (stoppedAbove && wanted < before) {
    // The monitor stopped short of a lower value. Only a settled reading of
    // a lamp that really moved shows where it stops; a reply that still
    // shows the old level (no movement) says nothing about the floor.
    if (stable && movedDown && (floorRaw < 0 || landed < floorRaw)) {
      return landed;
    }
    return floorRaw;
  }
  if (floorRaw > landed && landed <= wanted + tol) {
    // The lamp went below what was thought to be its floor.
    return wanted <= tol ? 0 : -1;
  }
  return floorRaw;
}

// MARK: Backlight and overlay

const long kNSCombinedSwitch = 50;
const long kNSShadeFloor = 10;
const long kNSRestoreMinimum = 10;

const double kNSUserQuietSeconds = 10;
const double kNSWakeWindowSeconds = 30;
const long kNSResetGap = 25;

NSRevalidateAction nsRevalidateAction(int current, int target, int scale,
                                      double sinceChange, double sinceWake) {
  if (scale <= 0 || nsDDCNear(current, target, scale)) {
    return kNSRevalidateKeep;
  }
  if (sinceChange >= 0 && sinceChange < kNSUserQuietSeconds) {
    return kNSRevalidateKeep;
  }
  long gap = nsDDCRawPercent(current, scale) - nsDDCRawPercent(target, scale);
  if (gap < 0) {
    gap = -gap;
  }
  if (sinceWake >= 0 && sinceWake < kNSWakeWindowSeconds && gap >= kNSResetGap) {
    return kNSRevalidateReapply;
  }
  return kNSRevalidateAdopt;
}

long nsLampToCombined(long lamp, long floor) {
  if (floor < 0) {
    floor = 0;
  }
  if (lamp < floor) {
    lamp = floor;
  }
  if (lamp > 100) {
    lamp = 100;
  }
  long room = 100 - floor;
  if (room <= 0) {
    return kNSCombinedSwitch;
  }
  return kNSCombinedSwitch + ((lamp - floor) * (100 - kNSCombinedSwitch)) / room;
}

void nsCombinedLevels(long percent, long floor, long *hardware, long *software) {
  if (floor < 0) {
    floor = 0;
  }
  if (floor > 99) {
    floor = 99;
  }
  if (percent > 100) {
    percent = 100;
  }
  if (percent >= kNSCombinedSwitch) {
    long rise = percent - kNSCombinedSwitch;
    *hardware = floor + ((100 - floor) * rise) / (100 - kNSCombinedSwitch);
    *software = 100;
    return;
  }
  *hardware = floor;
  if (percent <= 0) {
    *software = 0;
    return;
  }
  // 1..49 maps onto kNSShadeFloor..100, so only 0 is black.
  *software = kNSShadeFloor + (percent * (100 - kNSShadeFloor)) / kNSCombinedSwitch;
}

long nsSteppedPercent(long percent, int direction, long stops) {
  long steps = (percent * stops + stops / 2) / 100 + direction;
  if (steps < 0) {
    steps = 0;
  }
  if (steps > stops) {
    steps = stops;
  }
  long next = (steps * 100 + stops / 2) / stops;
  if (next == percent) {
    next = percent + direction;
  }
  if (next < 0) {
    next = 0;
  }
  if (next > 100) {
    next = 100;
  }
  return next;
}

long nsSafeBrightness(long percent, bool builtin, int otherLitDisplays) {
  if (percent > 100) {
    return 100;
  }
  if (percent > 0) {
    return percent;
  }
  // The built-in panel's own 0 still leaves the backlight on, and macOS
  // handles it. Anything else at 0 is black.
  if (builtin) {
    return 0;
  }
  return otherLitDisplays > 0 ? 0 : 1;
}

bool nsCountsAsLit(NSOtherDisplay display) {
  if (display.asleep || display.mirrored) {
    return false;
  }
  if (display.builtin) {
    return display.percent != 0;
  }
  return display.hardware && display.percent > 0;
}

int nsLitDisplays(const NSOtherDisplay *others, int count) {
  int lit = 0;
  for (int i = 0; others != NULL && i < count; i++) {
    if (nsCountsAsLit(others[i])) {
      lit++;
    }
  }
  return lit;
}

long nsPersistedBrightness(long percent) {
  if (percent < 1) {
    return 1;
  }
  return percent > 100 ? 100 : percent;
}

long nsRestoredBrightness(long saved) {
  if (saved < kNSRestoreMinimum) {
    return kNSRestoreMinimum;
  }
  return saved > 100 ? 100 : saved;
}
