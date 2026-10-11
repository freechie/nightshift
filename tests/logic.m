// Unit tests for NightshiftLogic. Plain C so it also builds off macOS:
//   cc -x c -std=c11 -I. tests/logic.m -x c NightshiftLogic.m -lm
#include "NightshiftLogic.h"

#include <stdio.h>
#include <string.h>

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(cond)                                                    \
  do {                                                                 \
    gChecks++;                                                         \
    if (!(cond)) {                                                     \
      gFailures++;                                                     \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                  \
  } while (0)

#define CHECK_EQ(got, want)                                                    \
  do {                                                                         \
    long g_ = (long)(got);                                                     \
    long w_ = (long)(want);                                                    \
    gChecks++;                                                                 \
    if (g_ != w_) {                                                            \
      gFailures++;                                                             \
      fprintf(stderr, "%s:%d: %s is %ld, want %ld\n", __FILE__, __LINE__, #got, \
              g_, w_);                                                         \
    }                                                                          \
  } while (0)

static void checkRamp(void) {
  // 21:00 -> 22:00 glide
  CHECK_EQ(nsGlideStage(1260, 1320, 1260), 1);
  CHECK_EQ(nsGlideStage(1260, 1320, 1289), 1);
  CHECK_EQ(nsGlideStage(1260, 1320, 1290), 2);
  CHECK_EQ(nsGlideStage(1260, 1320, 1320), 3);
  CHECK_EQ(nsGlideStage(1260, 1260, 1260), 3);
  // across midnight: 23:30 -> 00:30
  CHECK_EQ(nsGlideStage(1410, 30, 0), 2);
  CHECK_EQ(nsGlideStage(1410, 30, 1420), 1);

  // Full at before the schedule ends wins.
  CHECK_EQ(nsGlideEnd(1260, 420, 1320, 30), 1320);
  // No Full at: glide minutes from now.
  CHECK_EQ(nsGlideEnd(1260, 420, -1, 30), 1290);
  // Full at already passed: glide minutes.
  CHECK_EQ(nsGlideEnd(1260, 420, 1200, 30), 1290);
  // Schedule ends sooner than the glide.
  CHECK_EQ(nsGlideEnd(400, 420, -1, 30), 420);
  CHECK_EQ(nsGlideEnd(420, 420, -1, 30), 420);
  // Wraps past midnight.
  CHECK_EQ(nsGlideEnd(1430, 420, -1, 30), 20);

  CHECK(nsClockInSchedule(1260, 420, 0));
  CHECK(nsClockInSchedule(1260, 420, 420));
  CHECK(!nsClockInSchedule(1260, 420, 421));
  CHECK(!nsClockInSchedule(1260, 1260, 1260));
  CHECK(!nsClockInSchedule(1260, 420, -1));
  CHECK(!nsClockInSchedule(1260, 420, 1440));

  CHECK(nsAheadOfTurnOn(600, 1260, 1200));
  CHECK(nsAheadOfTurnOn(600, 1260, 1260));
  CHECK(!nsAheadOfTurnOn(600, 1260, 1261));
  CHECK(!nsAheadOfTurnOn(600, 1260, 600));
  CHECK(!nsAheadOfTurnOn(1260, 1260, 1300));

  CHECK_EQ(nsDefaultFullAt(1260, 420, 1380, 120), 1380);
  CHECK_EQ(nsDefaultFullAt(1260, 420, 600, 120), 1380);
  CHECK_EQ(nsDefaultFullAt(1260, 420, -1, 180), 0);
  CHECK_EQ(nsDefaultFullAt(1260, 1290, -1, 120), 1290);
  CHECK_EQ(nsDefaultFullAt(1260, 1260, -1, 120), -1);
}

static DDCCandidate candidate(uint32_t vendor, uint32_t product, uint32_t serial, bool external,
                              const char *port) {
  DDCCandidate c;
  memset(&c, 0, sizeof(c));
  c.vendor = vendor;
  c.product = product;
  c.serial = serial;
  c.external = external;
  strncpy(c.port, port, sizeof(c.port) - 1);
  return c;
}

static DDCTarget target(uint32_t vendor, uint32_t model, uint32_t serial, const char *port,
                        int twins, bool serialShared) {
  DDCTarget t;
  memset(&t, 0, sizeof(t));
  t.vendor = vendor;
  t.model = model;
  t.serial = serial;
  strncpy(t.port, port, sizeof(t.port) - 1);
  t.twins = twins;
  t.serialShared = serialShared;
  return t;
}

static void checkMatching(void) {
  enum { BNQ = 0x09D1, DEL = 0x10AC };
  char out[32];
  CHECK(nsDDCPortName("dispext0@88000000", '@', out, sizeof(out)));
  CHECK(strcmp(out, "dispext0") == 0);
  CHECK(nsDDCPortName("dispext1:dcpav-service-epic:0", ':', out, sizeof(out)));
  CHECK(strcmp(out, "dispext1") == 0);
  CHECK(!nsDDCPortName("dcp@0", '@', out, sizeof(out)));
  CHECK(out[0] == '\0');
  CHECK(!nsDDCPortName("", '@', out, sizeof(out)));
  char tiny[4];
  CHECK(!nsDDCPortName("dispext0@1", '@', tiny, sizeof(tiny)));

  // One BenQ, one built-in: the only external candidate of that model.
  DDCCandidate one[] = {candidate(BNQ, 0x8032, 0, true, "dispext0"),
                        candidate(0x0610, 0xA050, 0, false, "disp0")};
  DDCTarget benq = target(BNQ, 0x8032, 0, "", 1, false);
  CHECK_EQ(nsDDCPickCandidate(one, 2, &benq), 0);
  // Never matches the internal panel or another brand.
  DDCTarget other = target(DEL, 0x8032, 0, "", 1, false);
  CHECK_EQ(nsDDCPickCandidate(one, 2, &other), -1);
  // Unknown vendor still matches by model when that is unique.
  DDCTarget unknownVendor = target(0xFFFFFFFFu, 0x8032, 0, "", 1, false);
  CHECK_EQ(nsDDCPickCandidate(one, 2, &unknownVendor), 0);

  // Two identical BenQs: the port decides, and a serial that disagrees with
  // the port's candidate makes it ambiguous.
  DDCCandidate twins[] = {candidate(BNQ, 0x8032, 111, true, "dispext0"),
                          candidate(BNQ, 0x8032, 222, true, "dispext1")};
  DDCTarget second = target(BNQ, 0x8032, 222, "dispext1", 2, false);
  CHECK_EQ(nsDDCPickCandidate(twins, 2, &second), 1);
  DDCTarget crossed = target(BNQ, 0x8032, 111, "dispext1", 2, false);
  CHECK_EQ(nsDDCPickCandidate(twins, 2, &crossed), -1);
  // No port: serial decides unless another twin shares it.
  DDCTarget bySerial = target(BNQ, 0x8032, 111, "", 2, false);
  CHECK_EQ(nsDDCPickCandidate(twins, 2, &bySerial), 0);
  DDCTarget sharedSerial = target(BNQ, 0x8032, 111, "", 2, true);
  CHECK_EQ(nsDDCPickCandidate(twins, 2, &sharedSerial), -1);
  // No port, no serial, two twins: ambiguous, use the shade.
  DDCTarget blind = target(BNQ, 0x8032, 0, "", 2, false);
  CHECK_EQ(nsDDCPickCandidate(twins, 2, &blind), -1);
  // A model seen once but with a twin online (its service missing) is not
  // a safe guess either.
  DDCTarget oneVisible = target(BNQ, 0x8032, 0, "", 2, false);
  CHECK_EQ(nsDDCPickCandidate(one, 2, &oneVisible), -1);
  CHECK_EQ(nsDDCPickCandidate(NULL, 0, &benq), -1);
}

static void checkSlots(void) {
  uint32_t slots[4] = {0, 0, 0, 0};
  CHECK_EQ(nsDDCSlotFor(slots, 4, 7), 0);
  slots[0] = 5;
  slots[1] = 7;
  CHECK_EQ(nsDDCSlotFor(slots, 4, 7), 1);
  // Finding 9: slot 0 freed while display 7 still owns slot 1. The probe
  // must reuse slot 1, not make a second slot for 7 in slot 0.
  slots[0] = 0;
  CHECK_EQ(nsDDCSlotFor(slots, 4, 7), 1);
  CHECK_EQ(nsDDCSlotFor(slots, 4, 9), 0);
  uint32_t full[2] = {1, 2};
  CHECK_EQ(nsDDCSlotFor(full, 2, 3), -1);
  CHECK_EQ(nsDDCSlotFor(full, 2, 2), 1);
  CHECK_EQ(nsDDCSlotFor(slots, 4, 0), -1);
}

static void checkReadback(void) {
  CHECK_EQ(nsDDCValue(50, 100), 50);
  CHECK_EQ(nsDDCValue(50, 255), 128);
  CHECK_EQ(nsDDCValue(-5, 100), 0);
  CHECK_EQ(nsDDCValue(150, 100), 100);
  CHECK_EQ(nsDDCRawPercent(128, 255), 50);
  CHECK_EQ(nsDDCRawPercent(10, 0), 0);
  CHECK_EQ(nsDDCRawPercent(300, 255), 100);
  CHECK(nsDDCNear(52, 50, 100));
  CHECK(!nsDDCNear(56, 50, 100));
  CHECK(nsDDCNear(3, 1, 10));  // tolerance is at least 2

  // Lamp at 70, asked for 0, a settled reading says it stopped at 20: floor.
  CHECK_EQ(nsDDCLearnFloor(-1, 70, 0, 20, 100, 0, true), 20);
  // Finding 3: same write, but the reply still shows the old 70 (stale).
  // That is not a floor.
  CHECK_EQ(nsDDCLearnFloor(-1, 70, 0, 70, 100, 0, true), -1);
  // A stale reading that is far above a low target is not learned either.
  CHECK_EQ(nsDDCLearnFloor(-1, 70, 10, 70, 100, 10, true), -1);
  // A first reading that the second read didn't confirm is not learned.
  CHECK_EQ(nsDDCLearnFloor(-1, 70, 0, 20, 100, 0, false), -1);
  // Asked for 10, the lamp moved down but stopped at 25: floor 25.
  CHECK_EQ(nsDDCLearnFloor(-1, 80, 10, 25, 100, 10, true), 25);
  // A higher stop never raises a known floor.
  CHECK_EQ(nsDDCLearnFloor(20, 80, 0, 30, 100, 0, true), 20);
  // A lower stop lowers it.
  CHECK_EQ(nsDDCLearnFloor(20, 80, 0, 15, 100, 0, true), 15);
  // The lamp reached the target below the old floor: forget the floor, or
  // record 0 when it went all the way down.
  CHECK_EQ(nsDDCLearnFloor(20, 50, 10, 10, 100, 10, false), -1);
  CHECK_EQ(nsDDCLearnFloor(20, 50, 0, 0, 100, 0, false), 0);
  // Going up never touches the floor.
  CHECK_EQ(nsDDCLearnFloor(20, 20, 60, 60, 100, 60, true), 20);
  CHECK_EQ(nsDDCLearnFloor(-1, 20, 60, 80, 100, 60, true), -1);
}

static void checkSplit(void) {
  long hw = -1;
  long sw = -1;
  nsCombinedLevels(100, 20, &hw, &sw);
  CHECK_EQ(hw, 100);
  CHECK_EQ(sw, 100);
  nsCombinedLevels(50, 20, &hw, &sw);
  CHECK_EQ(hw, 20);
  CHECK_EQ(sw, 100);
  nsCombinedLevels(75, 20, &hw, &sw);
  CHECK_EQ(hw, 60);
  CHECK_EQ(sw, 100);
  nsCombinedLevels(75, -1, &hw, &sw);
  CHECK_EQ(hw, 50);
  // Finding 1: below the switch the lamp stays at its floor and the overlay
  // never goes below kNSShadeFloor until 0.
  nsCombinedLevels(49, 20, &hw, &sw);
  CHECK_EQ(hw, 20);
  CHECK(sw > 90 && sw <= 100);
  nsCombinedLevels(1, 20, &hw, &sw);
  CHECK_EQ(hw, 20);
  CHECK_EQ(sw, kNSShadeFloor + 1);
  nsCombinedLevels(0, 20, &hw, &sw);
  CHECK_EQ(hw, 20);
  CHECK_EQ(sw, 0);
  long last = -1;
  for (long p = 1; p <= 100; p++) {
    nsCombinedLevels(p, 30, &hw, &sw);
    CHECK(sw >= kNSShadeFloor);
    CHECK(sw <= 100 && hw >= 30 && hw <= 100);
    long light = hw * sw;  // rough total light: never goes down as p rises
    CHECK(light >= last);
    last = light;
  }
  nsCombinedLevels(130, 0, &hw, &sw);
  CHECK_EQ(hw, 100);

  CHECK_EQ(nsLampToCombined(20, 20), 50);
  CHECK_EQ(nsLampToCombined(100, 20), 100);
  CHECK_EQ(nsLampToCombined(5, 20), 50);
  CHECK_EQ(nsLampToCombined(60, 20), 75);
  CHECK_EQ(nsLampToCombined(50, 100), 50);
  // The lamp part of a percent round-trips.
  for (long p = 50; p <= 100; p++) {
    nsCombinedLevels(p, 0, &hw, &sw);
    CHECK_EQ(nsLampToCombined(hw, 0), p);
  }
}

static void checkSafety(void) {
  CHECK_EQ(nsSteppedPercent(50, 1, 16), 56);
  CHECK_EQ(nsSteppedPercent(50, -1, 16), 44);
  CHECK_EQ(nsSteppedPercent(6, -1, 16), 0);
  CHECK_EQ(nsSteppedPercent(0, -1, 16), 0);
  CHECK_EQ(nsSteppedPercent(100, 1, 16), 100);
  CHECK_EQ(nsSteppedPercent(1, -1, 16), 0);
  CHECK_EQ(nsSteppedPercent(99, 1, 16), 100);

  // Finding 1: an external display alone can't go black.
  CHECK_EQ(nsSafeBrightness(0, false, 0), 1);
  CHECK_EQ(nsSafeBrightness(-4, false, 0), 1);
  // With another lit display it can.
  CHECK_EQ(nsSafeBrightness(0, false, 1), 0);
  // The built-in panel keeps macOS behaviour.
  CHECK_EQ(nsSafeBrightness(0, true, 0), 0);
  CHECK_EQ(nsSafeBrightness(37, false, 0), 37);
  CHECK_EQ(nsSafeBrightness(140, false, 0), 100);

  // N9: revalidation keeps, reapplies or adopts.
  CHECK_EQ(nsRevalidateAction(70, 70, 100, -1, 1), kNSRevalidateKeep);
  CHECK_EQ(nsRevalidateAction(71, 70, 100, -1, 1), kNSRevalidateKeep);
  CHECK_EQ(nsRevalidateAction(70, 70, 0, -1, 1), kNSRevalidateKeep);
  // Just woke, far off: the monitor reset itself.
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 3600, 2), kNSRevalidateReapply);
  CHECK_EQ(nsRevalidateAction(15, 40, 100, -1, 2), kNSRevalidateReapply);
  CHECK_EQ(nsRevalidateAction(50, 25, 100, -1, 29), kNSRevalidateReapply);
  // Just woke, a little off: adopted.
  CHECK_EQ(nsRevalidateAction(55, 40, 100, 3600, 2), kNSRevalidateAdopt);
  // A screen change long after wake: the monitor's buttons moved it.
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 3600, 3600), kNSRevalidateAdopt);
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 3600, -1), kNSRevalidateAdopt);
  CHECK_EQ(nsRevalidateAction(100, 40, 100, -1, 30), kNSRevalidateAdopt);
  // Never right after the user changed it, even just after wake.
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 0, 2), kNSRevalidateKeep);
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 9.9, 3600), kNSRevalidateKeep);
  CHECK_EQ(nsRevalidateAction(100, 40, 100, 10, 3600), kNSRevalidateAdopt);
  // Raw values on another scale.
  CHECK_EQ(nsRevalidateAction(255, 64, 255, -1, 1), kNSRevalidateReapply);
  CHECK_EQ(nsRevalidateAction(80, 64, 255, -1, 1), kNSRevalidateAdopt);

  // N6: what counts as another lit display.
  {
    NSOtherDisplay builtinOn = {.builtin = true, .percent = 40};
    NSOtherDisplay builtinUnread = {.builtin = true, .percent = -1};
    NSOtherDisplay builtinZero = {.builtin = true, .percent = 0};
    NSOtherDisplay ddcOn = {.hardware = true, .percent = 30};
    NSOtherDisplay ddcBlack = {.hardware = true, .percent = 0};
    NSOtherDisplay hardwareUnread = {.hardware = true, .percent = -1};
    // A dummy plug, virtual or DisplayLink display: only the shade's value.
    NSOtherDisplay shadeOnly = {.percent = 100};
    NSOtherDisplay unreadable = {.percent = -1};
    NSOtherDisplay asleep = {.hardware = true, .asleep = true, .percent = 80};
    NSOtherDisplay mirror = {.hardware = true, .mirrored = true, .percent = 80};
    NSOtherDisplay builtinAsleep = {.builtin = true, .asleep = true, .percent = 80};
    CHECK(nsCountsAsLit(builtinOn));
    CHECK(nsCountsAsLit(builtinUnread));
    CHECK(!nsCountsAsLit(builtinZero));
    CHECK(nsCountsAsLit(ddcOn));
    CHECK(!nsCountsAsLit(ddcBlack));
    CHECK(!nsCountsAsLit(hardwareUnread));
    CHECK(!nsCountsAsLit(shadeOnly));
    CHECK(!nsCountsAsLit(unreadable));
    CHECK(!nsCountsAsLit(asleep));
    CHECK(!nsCountsAsLit(mirror));
    CHECK(!nsCountsAsLit(builtinAsleep));
    NSOtherDisplay dummyPlugSetup[] = {shadeOnly, unreadable};
    CHECK_EQ(nsLitDisplays(dummyPlugSetup, 2), 0);
    // So with only a dummy plug beside it, the monitor can't go black.
    CHECK_EQ(nsSafeBrightness(0, false, nsLitDisplays(dummyPlugSetup, 2)), 1);
    NSOtherDisplay mixed[] = {shadeOnly, ddcOn, builtinOn, ddcBlack, asleep};
    CHECK_EQ(nsLitDisplays(mixed, 5), 2);
    CHECK_EQ(nsSafeBrightness(0, false, nsLitDisplays(mixed, 5)), 0);
    CHECK_EQ(nsLitDisplays(NULL, 3), 0);
  }

  CHECK_EQ(nsPersistedBrightness(0), 1);
  CHECK_EQ(nsPersistedBrightness(1), 1);
  CHECK_EQ(nsPersistedBrightness(64), 64);
  CHECK_EQ(nsRestoredBrightness(0), kNSRestoreMinimum);
  CHECK_EQ(nsRestoredBrightness(1), kNSRestoreMinimum);
  CHECK_EQ(nsRestoredBrightness(kNSRestoreMinimum), kNSRestoreMinimum);
  CHECK_EQ(nsRestoredBrightness(64), 64);

  // A key press down from the dimmest visible level on the only display
  // asks for 0 and gets 1 again: the screen stays visible however often the
  // key is pressed.
  long percent = 1;
  for (int i = 0; i < 5; i++) {
    percent = nsSafeBrightness(nsSteppedPercent(percent, -1, 16), false, 0);
    CHECK_EQ(percent, 1);
  }
  long hw = 0;
  long sw = 0;
  nsCombinedLevels(percent, 25, &hw, &sw);
  CHECK(sw >= kNSShadeFloor);
}

int main(void) {
  checkRamp();
  checkMatching();
  checkSlots();
  checkReadback();
  checkSplit();
  checkSafety();
  if (gFailures != 0) {
    fprintf(stderr, "logic: %d of %d checks failed\n", gFailures, gChecks);
    return 1;
  }
  printf("logic: %d checks passed\n", gChecks);
  return 0;
}
