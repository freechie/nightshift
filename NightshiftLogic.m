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

#include <stdio.h>
#include <string.h>
#include <math.h>

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

bool nsDDCLocationSame(const char *a, const char *b) {
  if (a == NULL || b == NULL || a[0] == '\0' || b[0] == '\0') {
    return false;
  }
  // A bare port name is not a framebuffer path, even when the strings match.
  if (strchr(a, '/') == NULL || strchr(b, '/') == NULL) {
    return false;
  }
  if (strcmp(a, b) == 0) {
    return true;
  }
  size_t la = strlen(a);
  size_t lb = strlen(b);
  const char *longer = a;
  const char *shorter = b;
  size_t ll = la;
  size_t ls = lb;
  if (la < lb) {
    longer = b;
    shorter = a;
    ll = lb;
    ls = la;
  }
  if (ls < 8) {
    return false;
  }
  if (strcmp(longer + (ll - ls), shorter) != 0) {
    return false;
  }
  return longer[ll - ls - 1] == '/';
}

int nsDDCPickCandidate(const DDCCandidate *candidates, int count, const DDCTarget *target) {
  if (candidates == NULL || target == NULL || count <= 0) {
    return -1;
  }
  // The registry path is the pipe. An adapter can rewrite vendor and product,
  // so a unique path wins over those ids. Two paths for one display, or a
  // path that is not among the services, is not a guess at another monitor.
  if (target->location[0] != '\0') {
    int hits = 0;
    int last = -1;
    int located = 0;
    for (int i = 0; i < count; i++) {
      const DDCCandidate *c = &candidates[i];
      if (!c->external || c->location[0] == '\0') {
        continue;
      }
      located++;
      if (nsDDCLocationSame(c->location, target->location)) {
        hits++;
        last = i;
      }
    }
    if (hits == 1) {
      return last;
    }
    if (hits > 1 || located > 0) {
      return -1;
    }
  }
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

// MARK: Proving a monitor follows DDC

int nsDDCProbeTarget(int current, int max) {
  if (max < 1 || current < 0 || current > max) {
    return -1;
  }
  int steps[2] = {2, 1};
  for (int i = 0; i < 2; i++) {
    int step = steps[i];
    if (current + step <= max) {
      return current + step;
    }
    if (current - step >= 0) {
      return current - step;
    }
  }
  return -1;
}

bool nsDDCProbeLanded(int before, int written, int after) {
  if (written == before || after == before) {
    return false;
  }
  return after == written;
}

static uint8_t ddcXor(uint8_t seed, const uint8_t *bytes, int from, int toInclusive) {
  uint8_t sum = seed;
  for (int i = from; i <= toInclusive; i++) {
    sum ^= bytes[i];
  }
  return sum;
}

static bool ddcOpcodeOk(uint8_t opcode) {
  return opcode == 0x02 || opcode == 0xE3;
}

// first..csIndex-1 are the checksummed bytes. Seed is 0x50. lenIndex is the
// length byte; the opcode is the next byte. Brightness fields sit at the
// usual offsets from that length byte and must end before the checksum.
static bool ddcTake(const uint8_t *bytes, int count, int first, int lenIndex, int csIndex,
                    NSDDCReply *out) {
  if (first < 0 || lenIndex < first || csIndex <= lenIndex + 1 || csIndex >= count) {
    return false;
  }
  if (!ddcOpcodeOk(bytes[lenIndex + 1])) {
    return false;
  }
  if (ddcXor(0x50, bytes, first, csIndex - 1) != bytes[csIndex]) {
    return false;
  }
  out->valid = true;
  out->brightness = false;
  out->current = 0;
  out->max = 0;
  if (bytes[lenIndex + 1] == 0x02) {
    int curLow = lenIndex + 8;
    if (curLow < csIndex && bytes[lenIndex + 2] == 0x00 && bytes[lenIndex + 3] == 0x10) {
      int maxValue = (bytes[lenIndex + 5] << 8) | bytes[lenIndex + 6];
      int currentValue = (bytes[lenIndex + 7] << 8) | bytes[curLow];
      if (maxValue > 0 && currentValue >= 0 && currentValue <= maxValue) {
        out->brightness = true;
        out->current = currentValue;
        out->max = maxValue;
      }
    }
  }
  return true;
}

static bool ddcFrameAt(const uint8_t *bytes, int count, int first, int lenIndex, NSDDCReply *out) {
  if (lenIndex < 0 || lenIndex >= count || (bytes[lenIndex] & 0x80) == 0) {
    return false;
  }
  int length = bytes[lenIndex] & 0x7F;
  if (length < 3 || length > 32) {
    return false;
  }
  // Some replies count the checksum in the length (capabilities, 0x86).
  // Apple's 11-byte VCP read does not (0x88, checksum at index 10).
  if (ddcTake(bytes, count, first, lenIndex, lenIndex + length, out)) {
    return true;
  }
  return ddcTake(bytes, count, first, lenIndex, lenIndex + 1 + length, out);
}

static bool ddcConsider(const uint8_t *bytes, int count, int start, NSDDCReply *out) {
  if (start < 0 || start >= count) {
    return false;
  }
  // Host address 0x50 or data address 0x51, echoed in front of the frame.
  // It is not part of the checksum.
  if (bytes[start] == 0x50 || bytes[start] == 0x51) {
    start++;
    if (start >= count) {
      return false;
    }
  }
  if (bytes[start] == 0x6E || bytes[start] == 0x6F || bytes[start] == 0x6e) {
    if (ddcFrameAt(bytes, count, start, start + 1, out)) {
      return true;
    }
    // 11-byte layout even when the length byte has no 0x80 flag.
    return ddcTake(bytes, count, start, start + 1, start + 10, out);
  }
  if ((bytes[start] & 0x80) != 0) {
    return ddcFrameAt(bytes, count, start, start, out);
  }
  return false;
}

bool nsDDCDecodeReply(const uint8_t *bytes, int count, NSDDCReply *out) {
  if (out == NULL) {
    return false;
  }
  out->valid = false;
  out->brightness = false;
  out->current = 0;
  out->max = 0;
  if (bytes == NULL || count < 4) {
    return false;
  }
  // Only the front of the buffer. A checksum that appears later is not a
  // reply, and must not turn a write-only link into a brightness reading.
  return ddcConsider(bytes, count, 0, out);
}

bool nsDDCFrameValid(const uint8_t *bytes, int count) {
  NSDDCReply reply;
  return nsDDCDecodeReply(bytes, count, &reply);
}

int nsDDCProbeKeep(int fallbackCurrent, int fallbackMax, int *scaleOut) {
  int scale = 100;
  if (fallbackMax > 0 && fallbackMax <= 10000) {
    scale = fallbackMax;
  }
  if (scaleOut != NULL) {
    *scaleOut = scale;
  }
  if (fallbackMax > 0 && fallbackCurrent >= 1 && fallbackCurrent <= scale) {
    return fallbackCurrent;
  }
  return scale;
}

NSDDCProbeVerdict nsDDCProbeDecide(const NSDDCProbeFacts *facts, int *current, int *max) {
  if (current != NULL) {
    *current = 0;
  }
  if (max != NULL) {
    *max = 0;
  }
  if (facts == NULL) {
    return kNSDDCProbeSoftware;
  }
  if (facts->evidence == kNSDDCEvidenceRead && facts->max > 0 && facts->current >= 0 &&
      facts->current <= facts->max) {
    if (current != NULL) {
      *current = facts->current;
    }
    if (max != NULL) {
      *max = facts->max;
    }
    return kNSDDCProbeControllable;
  }
  // A capabilities or VCP frame proves the panel answered. The write has to
  // succeed as well. The value kept is the last-known raw level, or full
  // brightness when that is unknown, so the probe does not black the panel.
  if (facts->evidence == kNSDDCEvidenceFramed && facts->writeOk) {
    int scale = 0;
    int keep = nsDDCProbeKeep(facts->fallbackCurrent, facts->fallbackMax, &scale);
    if (current != NULL) {
      *current = keep;
    }
    if (max != NULL) {
      *max = scale;
    }
    return kNSDDCProbeControllable;
  }
  return kNSDDCProbeSoftware;
}

int nsDDCNextReadOffset(int tried, int offset0, bool budgetLeft) {
  if (!budgetLeft) {
    return -1;
  }
  if (tried <= 0) {
    return 0;
  }
  if (offset0 != kNSDDCOffsetEmpty) {
    return -1;
  }
  if (tried == 1) {
    return 0x51;
  }
  if (tried == 2) {
    return 0x50;
  }
  return -1;
}

static bool ddcBudgetOpen(const NSDDCProbeIO *io) {
  return io->budget == NULL || io->budget(io->ctx);
}

static NSDDCProbeVerdict ddcBudgetStop(NSDDCProbeIO *io, int *currentOut, int *maxOut) {
  NSDDCProbeFacts facts;
  memset(&facts, 0, sizeof(facts));
  facts.evidence = kNSDDCEvidenceTimedOut;
  facts.fallbackCurrent = io->fallbackCurrent;
  facts.fallbackMax = io->fallbackMax;
  io->evidence = kNSDDCEvidenceTimedOut;
  return nsDDCProbeDecide(&facts, currentOut, maxOut);
}

NSDDCProbeVerdict nsDDCProbeControl(NSDDCProbeIO *io, int *currentOut, int *maxOut) {
  if (currentOut != NULL) {
    *currentOut = 0;
  }
  if (maxOut != NULL) {
    *maxOut = 0;
  }
  if (io == NULL || io->read == NULL || io->write == NULL) {
    if (io != NULL) {
      io->evidence = kNSDDCEvidenceNone;
    }
    return kNSDDCProbeSoftware;
  }
  io->evidence = kNSDDCEvidenceNone;
  int before = 0;
  int scale = 0;
  bool readOk = false;
  // HDMI often drops the first VCP read. A later try is still a read.
  // A call that does not return inside the budget ends the probe. It must
  // not fall through into a brightness write.
  for (int attempt = 0; attempt < 4; attempt++) {
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    before = 0;
    scale = 0;
    if (io->read(io->ctx, &before, &scale) && scale > 0 && before >= 0 && before <= scale) {
      readOk = true;
      break;
    }
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
  }
  NSDDCProbeFacts facts;
  memset(&facts, 0, sizeof(facts));
  facts.fallbackCurrent = io->fallbackCurrent;
  facts.fallbackMax = io->fallbackMax;
  if (!readOk) {
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    bool framed = io->framed != NULL && io->framed(io->ctx);
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    if (!framed) {
      // The write function is there. Its return code, with no frame, is not
      // evidence the packet reached the panel.
      facts.evidence = kNSDDCEvidenceWriteOnly;
      facts.writeOk = true;
      io->evidence = facts.evidence;
      return nsDDCProbeDecide(&facts, currentOut, maxOut);
    }
    int keepScale = 0;
    int keep = nsDDCProbeKeep(io->fallbackCurrent, io->fallbackMax, &keepScale);
    facts.evidence = kNSDDCEvidenceFramed;
    facts.writeOk = io->write(io->ctx, keep);
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    facts.fallbackCurrent = keep;
    facts.fallbackMax = keepScale;
    io->evidence = facts.writeOk ? kNSDDCEvidenceFramed : kNSDDCEvidenceNone;
    facts.evidence = io->evidence;
    return nsDDCProbeDecide(&facts, currentOut, maxOut);
  }
  int target = nsDDCProbeTarget(before, scale);
  if (!ddcBudgetOpen(io)) {
    return ddcBudgetStop(io, currentOut, maxOut);
  }
  if (target < 0 || !io->write(io->ctx, target)) {
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    io->evidence = kNSDDCEvidenceNone;
    return nsDDCProbeDecide(&facts, currentOut, maxOut);
  }
  // A slow panel can report the pre-write value once. Keep reading until one
  // sample is the value just written, or four tries are used up. A cached
  // read stays on the first value for every try and does not pass.
  bool landed = false;
  bool sawReply = false;
  for (int attempt = 0; attempt < 4; attempt++) {
    if (!ddcBudgetOpen(io)) {
      return ddcBudgetStop(io, currentOut, maxOut);
    }
    int after = 0;
    int scaleAfter = 0;
    if (!io->read(io->ctx, &after, &scaleAfter)) {
      if (!ddcBudgetOpen(io)) {
        return ddcBudgetStop(io, currentOut, maxOut);
      }
      continue;
    }
    sawReply = true;
    if (scaleAfter == scale && nsDDCProbeLanded(before, target, after)) {
      landed = true;
      break;
    }
  }
  // The nudge already went out. Put the original back whether or not a
  // confirmation read proved the panel moved. A timed-out bus does not get
  // another write.
  if (!ddcBudgetOpen(io)) {
    return ddcBudgetStop(io, currentOut, maxOut);
  }
  (void)io->write(io->ctx, before);
  if (!ddcBudgetOpen(io)) {
    return ddcBudgetStop(io, currentOut, maxOut);
  }
  if (landed) {
    facts.evidence = kNSDDCEvidenceRead;
    facts.writeOk = true;
    facts.current = before;
    facts.max = scale;
  } else if (sawReply) {
    facts.evidence = kNSDDCEvidenceUnchanged;
  } else {
    facts.evidence = kNSDDCEvidenceNone;
  }
  io->evidence = facts.evidence;
  return nsDDCProbeDecide(&facts, currentOut, maxOut);
}

bool nsDDCDebugLine(uint32_t display, int service, int verdict, int evidence, char *out,
                    size_t cap) {
  if (out == NULL || cap == 0) {
    return false;
  }
  out[0] = '\0';
  if (verdict != kNSDDCProbeControllable && verdict != kNSDDCProbeSoftware) {
    return false;
  }
  if (evidence < kNSDDCEvidenceNone || evidence > kNSDDCEvidenceTimedOut) {
    return false;
  }
  int wrote = snprintf(out, cap, "ddc %u %d %d %d", display, service, verdict, evidence);
  if (wrote < 0 || (size_t)wrote >= cap) {
    out[0] = '\0';
    return false;
  }
  return true;
}

int nsDDCDebugReport(const uint32_t *displays, const int *builtin, int displayCount,
                     const NSDDCDebugRow *rows, int rowCount, char *out, size_t cap) {
  if (out == NULL || cap == 0) {
    return -1;
  }
  out[0] = '\0';
  if (displays == NULL || displayCount < 0) {
    displayCount = 0;
  }
  if (rows == NULL || rowCount < 0) {
    rowCount = 0;
  }
  size_t used = 0;
  int lines = 0;
  for (int i = 0; i < displayCount; i++) {
    if (builtin != NULL && builtin[i] != 0) {
      continue;
    }
    int service = -1;
    int verdict = kNSDDCProbeSoftware;
    int evidence = kNSDDCEvidenceNotProbed;
    for (int r = 0; r < rowCount; r++) {
      if (rows[r].display == displays[i]) {
        service = rows[r].service;
        verdict = rows[r].verdict;
        evidence = rows[r].evidence;
        break;
      }
    }
    char line[64];
    if (!nsDDCDebugLine(displays[i], service, verdict, evidence, line, sizeof(line))) {
      continue;
    }
    int wrote = snprintf(out + used, cap - used, "%s\n", line);
    if (wrote < 0 || (size_t)wrote >= cap - used) {
      out[used] = '\0';
      return -1;
    }
    used += (size_t)wrote;
    lines++;
  }
  return lines;
}

const char *nsDDCControlLabel(NSDDCProbeVerdict verdict) {
  if (verdict == kNSDDCProbeControllable) {
    return "DDC/CI connected";
  }
  return "Software dimming";
}

// Software dimming multiplies the display's gamma table. A linear percent
// leaves the lower half too dark, and the picture keeps brightening past 50.
// shade = p^(1/k), k = 2.2 (sRGB): higher shade is brighter, 0 stays black,
// 100 stays undimmed, and the middle lifts (50 -> 73). p^2.2 would darken
// the middle (50 -> 22), which is the wrong direction. Set the exponent to
// 1 to restore linear: the function returns the slider percent unchanged.
const double kNSSoftwareDimExponent = 2.2;

long nsSoftwareDimShade(long percent) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  if (percent == 0 || percent == 100 || kNSSoftwareDimExponent == 1.0) {
    return percent;
  }
  double unit = (double)percent / 100.0;
  double shade = pow(unit, 1.0 / kNSSoftwareDimExponent);
  long result = (long)llround(shade * 100.0);
  if (result < 1) {
    return 1;
  }
  if (result > 100) {
    return 100;
  }
  return result;
}

void nsExternalBrightness(NSDDCProbeVerdict verdict, long percent, long floor, long *hardware,
                          long *software) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  if (verdict != kNSDDCProbeControllable) {
    if (hardware != NULL) {
      *hardware = -1;
    }
    if (software != NULL) {
      *software = nsSoftwareDimShade(percent);
    }
    return;
  }
  long lamp = 0;
  long shade = 100;
  nsCombinedLevels(percent, floor, &lamp, &shade);
  if (hardware != NULL) {
    *hardware = lamp;
  }
  if (software != NULL) {
    *software = shade;
  }
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

int nsCommandWarmthDirection(unsigned hotKeyID) {
  if (hotKeyID == 1) {
    return -1;
  }
  if (hotKeyID == 2) {
    return 1;
  }
  return 0;
}

long nsCommandWarmthStep(void) {
  return 5;
}

long nsCommandWarmthNext(long percent, int direction) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  if (direction == 1 || direction == -1) {
    percent += direction * nsCommandWarmthStep();
  }
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  return percent;
}

double nsCommandWarmthRepeatGap(double seconds) {
  // NaN fails this comparison, so it takes the floor too.
  if (!(seconds >= 0.02)) {
    return 0.02;
  }
  return seconds;
}

NSWarmthMediaAction nsCommandWarmthMediaAction(int direction, bool down, bool repeat,
                                               int heldDirection) {
  if (direction != 1 && direction != -1) {
    return kNSWarmthMediaIgnore;
  }
  if (!down) {
    return heldDirection == direction ? kNSWarmthMediaEnd : kNSWarmthMediaIgnore;
  }
  // A second down for the direction already held, or a repeat, must not
  // step. The hold timer is the only repeat. A repeat does not begin a hold,
  // so it cannot race the hotkey's own press and step twice.
  if (repeat || heldDirection == direction) {
    return heldDirection == direction ? kNSWarmthMediaRepeat : kNSWarmthMediaIgnore;
  }
  return kNSWarmthMediaBegin;
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

// MARK: License server and purchase pages

// A URL's parts, without decoding anything: scheme, host and port as
// written, and whatever follows the authority.
typedef struct {
  const char *scheme;
  size_t schemeLength;
  const char *host;
  size_t hostLength;
  long port;  // -1: none written
  const char *rest;
  size_t restLength;
} URLParts;

static bool asciiEqualFold(const char *a, size_t length, const char *b) {
  if (strlen(b) != length) {
    return false;
  }
  for (size_t i = 0; i < length; i++) {
    char x = a[i];
    char y = b[i];
    if (x >= 'A' && x <= 'Z') {
      x = (char)(x - 'A' + 'a');
    }
    if (y >= 'A' && y <= 'Z') {
      y = (char)(y - 'A' + 'a');
    }
    if (x != y) {
      return false;
    }
  }
  return true;
}

static bool hasUppercase(const char *text, size_t length) {
  for (size_t i = 0; i < length; i++) {
    if (text[i] >= 'A' && text[i] <= 'Z') {
      return true;
    }
  }
  return false;
}

static bool isAuthorityEnd(char c) {
  return c == '/' || c == '?' || c == '#';
}

// Splits "scheme://host[:port]rest", reading exactly length bytes: a NUL
// inside them is refused like any other control character, never taken as
// the end. Each rule has its own verdict, checked in this order, so a test
// can tell which rule refused a string.
static NSLinkVerdict splitURL(const char *url, size_t length, URLParts *parts) {
  if (url == NULL || length == 0) {
    return kNSLinkEmpty;
  }
  for (size_t i = 0; i < length; i++) {
    unsigned char c = (unsigned char)url[i];
    if (c < 0x20 || c == 0x7f) {
      return kNSLinkControl;
    }
  }
  for (size_t i = 0; i < length; i++) {
    unsigned char c = (unsigned char)url[i];
    if (c == 0x20 || c > 0x7f) {
      return kNSLinkNotASCII;
    }
  }
  if (memchr(url, '\\', length) != NULL) {
    return kNSLinkBackslash;
  }
  size_t colon = 0;
  while (colon + 3 <= length && memcmp(url + colon, "://", 3) != 0) {
    colon++;
  }
  if (colon == 0 || colon + 3 > length) {
    return kNSLinkNoScheme;
  }
  parts->scheme = url;
  parts->schemeLength = colon;
  const char *authority = url + colon + 3;
  size_t left = length - colon - 3;
  size_t authorityLength = 0;
  while (authorityLength < left && !isAuthorityEnd(authority[authorityLength])) {
    authorityLength++;
  }
  parts->rest = authority + authorityLength;
  parts->restLength = left - authorityLength;
  if (memchr(authority, '@', authorityLength) != NULL) {
    return kNSLinkUserinfo;
  }
  const char *portColon = memchr(authority, ':', authorityLength);
  parts->host = authority;
  parts->hostLength = portColon != NULL ? (size_t)(portColon - authority) : authorityLength;
  parts->port = -1;
  if (portColon != NULL) {
    const char *digits = portColon + 1;
    size_t count = (size_t)(authority + authorityLength - digits);
    if (count == 0 || count > 5) {
      return kNSLinkBadPort;
    }
    if (count > 1 && digits[0] == '0') {
      return kNSLinkPortLeadingZero;
    }
    long port = 0;
    for (size_t i = 0; i < count; i++) {
      if (digits[i] < '0' || digits[i] > '9') {
        return kNSLinkBadPort;
      }
      port = port * 10 + (digits[i] - '0');
    }
    if (port < 1 || port > 65535) {
      return kNSLinkBadPort;
    }
    parts->port = port;
  }
  if (parts->hostLength == 0) {
    return kNSLinkBadHost;
  }
  if (parts->host[parts->hostLength - 1] == '.') {
    return kNSLinkTrailingDot;
  }
  if (parts->host[0] == '.') {
    return kNSLinkBadHost;
  }
  for (size_t i = 0; i < parts->hostLength; i++) {
    char c = parts->host[i];
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '.';
    if (!ok || (c == '.' && i + 1 < parts->hostLength && parts->host[i + 1] == '.')) {
      return kNSLinkBadHost;
    }
  }
  return kNSLinkOK;
}

NSLinkVerdict nsLicenseOriginVerdict(const char *origin, size_t length, bool allowLoopbackHTTP) {
  URLParts parts;
  NSLinkVerdict verdict = splitURL(origin, length, &parts);
  if (verdict != kNSLinkOK) {
    return verdict;
  }
  if (!(parts.restLength == 0 || (parts.restLength == 1 && parts.rest[0] == '/'))) {
    return kNSLinkPath;
  }
  // One spelling per origin: the scheme and host are written in lowercase,
  // as make package, the server file and the app all require.
  if (hasUppercase(parts.scheme, parts.schemeLength) ||
      hasUppercase(parts.host, parts.hostLength)) {
    return kNSLinkUppercase;
  }
  if (asciiEqualFold(parts.scheme, parts.schemeLength, "https")) {
    return kNSLinkOK;
  }
  if (allowLoopbackHTTP && asciiEqualFold(parts.scheme, parts.schemeLength, "http") &&
      (asciiEqualFold(parts.host, parts.hostLength, "127.0.0.1") ||
       asciiEqualFold(parts.host, parts.hostLength, "localhost"))) {
    return kNSLinkOK;
  }
  return kNSLinkScheme;
}

const char *nsLinkVerdictText(NSLinkVerdict verdict) {
  switch (verdict) {
    case kNSLinkOK: return "it is acceptable";
    case kNSLinkEmpty: return "it is empty";
    case kNSLinkControl: return "it has a control character";
    case kNSLinkNotASCII: return "it has a space or a non-ASCII character";
    case kNSLinkBackslash: return "it has a backslash";
    case kNSLinkNoScheme: return "it has no https://";
    case kNSLinkUserinfo: return "it has a user name (\"@\")";
    case kNSLinkBadPort: return "its port isn't 1-65535 in digits";
    case kNSLinkPortLeadingZero: return "its port starts with 0";
    case kNSLinkBadHost: return "its host isn't a plain host name";
    case kNSLinkTrailingDot: return "its host ends in \".\"";
    case kNSLinkPath: return "it has a path, query or fragment";
    case kNSLinkUppercase: return "its scheme or host has capital letters (write it in lowercase)";
    case kNSLinkPort: return "it has a port";
    case kNSLinkScheme: return "it isn't https";
    case kNSLinkHost: return "it isn't a Stripe Checkout or billing portal page";
  }
  return "it isn't acceptable";
}

bool nsLicenseOriginAllowed(const char *origin, size_t length, bool allowLoopbackHTTP) {
  return nsLicenseOriginVerdict(origin, length, allowLoopbackHTTP) == kNSLinkOK;
}

NSLinkVerdict nsPurchaseURLVerdict(const char *url, size_t length) {
  URLParts parts;
  NSLinkVerdict verdict = splitURL(url, length, &parts);
  if (verdict != kNSLinkOK) {
    return verdict;
  }
  if (parts.port != -1) {
    return kNSLinkPort;
  }
  if (!asciiEqualFold(parts.scheme, parts.schemeLength, "https")) {
    return kNSLinkScheme;
  }
  // Stripe's own hosts only. Turning on a Stripe custom domain for Checkout or
  // the billing portal (say pay.example.com) changes the URLs the server hands
  // back, so add that host here first, or every purchase link is refused.
  if (!asciiEqualFold(parts.host, parts.hostLength, "checkout.stripe.com") &&
      !asciiEqualFold(parts.host, parts.hostLength, "billing.stripe.com")) {
    return kNSLinkHost;
  }
  return kNSLinkOK;
}

int nsMediaBrightnessKey(long data1, bool *down) {
  long code = (data1 >> 16) & 0xFFFF;
  *down = ((data1 >> 8) & 0xFF) == 0xA;
  return code == 2 ? 1 : code == 3 ? -1 : 0;
}

bool nsMediaKeyRepeat(long data1) {
  return (data1 & 0xFF) != 0;
}

static const uint64_t kNSChordModifiers = (uint64_t)kNSModifierShift | (uint64_t)kNSModifierControl |
                                         (uint64_t)kNSModifierOption | (uint64_t)kNSModifierCommand |
                                         (uint64_t)kNSModifierHelp | (uint64_t)kNSModifierFunction;

NSMediaRoute nsMediaBrightnessRoute(long data1, uint64_t modifierFlags, bool *down) {
  bool pressed = false;
  int direction = nsMediaBrightnessKey(data1, &pressed);
  if (down != NULL) {
    *down = pressed;
  }
  if (direction == 0) {
    return kNSMediaRouteNone;
  }
  uint64_t mods = modifierFlags & kNSChordModifiers;
  if ((mods & (uint64_t)kNSModifierCommand) == 0) {
    return kNSMediaRouteBrightness;
  }
  if (mods == (uint64_t)kNSModifierCommand) {
    return kNSMediaRouteIntensity;
  }
  return kNSMediaRouteUntouched;
}

uint64_t nsMediaTapMaskBits(void) {
  return (uint64_t)1 << 14;
}

bool nsMediaTapMaskAllowed(uint64_t bits) {
  return bits == nsMediaTapMaskBits();
}

double nsTapRecoveryDelay(bool trusted, int recent) {
  if (!trusted || recent > 5) {
    return -1;
  }
  double delay = 0.25;
  for (int i = 1; i < recent; i++) {
    delay *= 2;
  }
  return delay;
}

double nsTapRetryDelay(int tries) {
  return tries < 30 ? 2 : 30;
}

NSAccessAction nsAccessAction(bool trusted, bool haveTaps) {
  if (!trusted && haveTaps) {
    return kNSAccessDrop;
  }
  if (trusted && !haveTaps) {
    return kNSAccessRebuild;
  }
  return kNSAccessKeep;
}

bool nsPurchaseURLAllowed(const char *url, size_t length) {
  return nsPurchaseURLVerdict(url, length) == kNSLinkOK;
}

bool nsWorkspaceOpenAllowed(const char *url, size_t length, bool allowLoopbackHTTP) {
  NSLinkVerdict purchase = nsPurchaseURLVerdict(url, length);
  NSLinkVerdict origin = nsLicenseOriginVerdict(url, length, allowLoopbackHTTP);
  if (purchase == kNSLinkOK) {
    return true;
  }
  if (origin == kNSLinkOK) {
    return false;
  }
  if (url == NULL) {
    return false;
  }
  static const char *const pages[] = {
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.Displays-Settings.extension?nightShift",
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      "https://github.com/freechie/nightshift",
      "https://github.com/freechie/nightshift/issues",
  };
  for (size_t i = 0; i < sizeof pages / sizeof pages[0]; i++) {
    size_t n = strlen(pages[i]);
    if (length == n && memcmp(url, pages[i], n) == 0) {
      return true;
    }
  }
  return false;
}
