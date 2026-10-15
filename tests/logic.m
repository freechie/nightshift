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
  CHECK_EQ(nsDDCPickCandidate(one, 2, NULL), -1);

  // Framebuffer paths. A USB-C HDMI adapter can rewrite vendor and product.
  // The pipe path still names the display, and only a unique path binds.
  const char *benqPath = "IOService:/arm-io/AppleT600xIO/dispext0@88000000/AppleCLCD2";
  const char *acerPath = "IOService:/arm-io/AppleT600xIO/dispext1@90000000/AppleCLCD2";
  const char *benqTail = "dispext0@88000000/AppleCLCD2";
  CHECK(nsDDCLocationSame(benqPath, benqPath));
  CHECK(nsDDCLocationSame(benqPath, benqTail));
  CHECK(nsDDCLocationSame(benqTail, benqPath));
  CHECK(!nsDDCLocationSame("", benqPath));
  CHECK(!nsDDCLocationSame("dispext0", "dispext0"));
  CHECK(!nsDDCLocationSame(benqPath, acerPath));

  DDCCandidate adapted[2];
  adapted[0] = candidate(0x0AC8, 0x0001, 0, true, "");
  adapted[1] = candidate(0x0AC8, 0x0001, 0, true, "");
  strncpy(adapted[0].location, benqPath, sizeof(adapted[0].location) - 1);
  strncpy(adapted[1].location, acerPath, sizeof(adapted[1].location) - 1);
  DDCTarget benqPipe = target(BNQ, 0x8032, 0, "", 1, false);
  strncpy(benqPipe.location, benqTail, sizeof(benqPipe.location) - 1);
  DDCTarget acerPipe = target(0x04E7, 0x2720, 0, "", 1, false);
  strncpy(acerPipe.location, acerPath, sizeof(acerPipe.location) - 1);
  CHECK_EQ(nsDDCPickCandidate(adapted, 2, &benqPipe), 0);
  CHECK_EQ(nsDDCPickCandidate(adapted, 2, &acerPipe), 1);
  // The other monitor's path is not a fallback when the product was rewritten.
  DDCTarget missingPipe = target(BNQ, 0x8032, 0, "", 1, false);
  strncpy(missingPipe.location, "IOService:/arm-io/dispext2@1/AppleCLCD2",
          sizeof(missingPipe.location) - 1);
  CHECK_EQ(nsDDCPickCandidate(adapted, 2, &missingPipe), -1);
  // The same tail on two services is ambiguous. Do not pick one.
  DDCCandidate twinsPath[2];
  twinsPath[0] = candidate(BNQ, 0x8032, 0, true, "dispext0");
  twinsPath[1] = candidate(BNQ, 0x8032, 0, true, "dispext1");
  strncpy(twinsPath[0].location, "IOService:/a/dispext0@1/AppleCLCD2",
          sizeof(twinsPath[0].location) - 1);
  strncpy(twinsPath[1].location, "IOService:/b/dispext0@1/AppleCLCD2",
          sizeof(twinsPath[1].location) - 1);
  DDCTarget sharedTail = target(BNQ, 0x8032, 0, "", 2, false);
  strncpy(sharedTail.location, benqTail, sizeof(sharedTail.location) - 1);
  // benqTail is dispext0@..., not dispext0@1. Use the shared tail.
  strncpy(sharedTail.location, "dispext0@1/AppleCLCD2", sizeof(sharedTail.location) - 1);
  CHECK_EQ(nsDDCPickCandidate(twinsPath, 2, &sharedTail), -1);
  // No service recorded a path: product matching still applies.
  DDCTarget locatedBenq = target(BNQ, 0x8032, 0, "", 1, false);
  strncpy(locatedBenq.location, benqPath, sizeof(locatedBenq.location) - 1);
  CHECK_EQ(nsDDCPickCandidate(one, 2, &locatedBenq), 0);
  // An internal panel that happens to carry the path is not the external link.
  DDCCandidate internalPipe[1];
  internalPipe[0] = candidate(BNQ, 0x8032, 0, false, "disp0");
  strncpy(internalPipe[0].location, benqPath, sizeof(internalPipe[0].location) - 1);
  CHECK_EQ(nsDDCPickCandidate(internalPipe, 1, &benqPipe), -1);
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

// Cmd+F1 / Cmd+F2: the Current slider, five percent at a time, clamped
// to 0...100. F1 lowers, F2 raises.
static void checkCommandWarmth(void) {
  CHECK_EQ(nsCommandWarmthDirection(1), -1);
  CHECK_EQ(nsCommandWarmthDirection(2), 1);
  CHECK_EQ(nsCommandWarmthDirection(0), 0);
  CHECK_EQ(nsCommandWarmthDirection(3), 0);
  CHECK_EQ(nsCommandWarmthStep(), 5);
  CHECK(nsCommandWarmthRepeatGap(0.5) == 0.5);
  CHECK(nsCommandWarmthRepeatGap(0.02) == 0.02);
  CHECK(nsCommandWarmthRepeatGap(0.019) == 0.02);
  CHECK(nsCommandWarmthRepeatGap(0) == 0.02);
  CHECK(nsCommandWarmthRepeatGap(-1) == 0.02);

  CHECK_EQ(nsCommandWarmthNext(50, 1), 55);
  CHECK_EQ(nsCommandWarmthNext(50, -1), 45);
  CHECK_EQ(nsCommandWarmthNext(0, -1), 0);
  CHECK_EQ(nsCommandWarmthNext(100, 1), 100);
  CHECK_EQ(nsCommandWarmthNext(3, -1), 0);
  CHECK_EQ(nsCommandWarmthNext(98, 1), 100);
  CHECK_EQ(nsCommandWarmthNext(97, 1), 100);
  CHECK_EQ(nsCommandWarmthNext(2, -1), 0);
  CHECK_EQ(nsCommandWarmthNext(50, 0), 50);
  CHECK_EQ(nsCommandWarmthNext(-4, 0), 0);
  CHECK_EQ(nsCommandWarmthNext(140, 0), 100);
  CHECK_EQ(nsCommandWarmthNext(140, 1), 100);
  CHECK_EQ(nsCommandWarmthNext(-8, -1), 0);

  long percent = 0;
  for (int i = 0; i < 30; i++) {
    long next = nsCommandWarmthNext(percent, 1);
    CHECK(next >= 0 && next <= 100);
    CHECK(next >= percent);
    CHECK(next - percent == 5 || next == 100);
    percent = next;
  }
  CHECK_EQ(percent, 100);
  CHECK_EQ(nsCommandWarmthNext(percent, 1), 100);
  percent = 100;
  for (int i = 0; i < 30; i++) {
    long next = nsCommandWarmthNext(percent, -1);
    CHECK(next >= 0 && next <= 100);
    CHECK(next <= percent);
    CHECK(percent - next == 5 || next == 0);
    percent = next;
  }
  CHECK_EQ(percent, 0);
  CHECK_EQ(nsCommandWarmthNext(percent, -1), 0);
}

// The string's own length; NULL stays NULL.
static size_t lengthOf(const char *s) {
  return s != NULL ? strlen(s) : 0;
}

static bool originOK(const char *s, bool loopback) {
  return nsLicenseOriginAllowed(s, lengthOf(s), loopback);
}

static bool pageOK(const char *s) {
  return nsPurchaseURLAllowed(s, lengthOf(s));
}

static NSLinkVerdict originWhy(const char *s) {
  return nsLicenseOriginVerdict(s, lengthOf(s), false);
}

static NSLinkVerdict pageWhy(const char *s) {
  return nsPurchaseURLVerdict(s, lengthOf(s));
}

static void checkHosts(void) {
  // License server origins: https only, with loopback http in test builds.
  CHECK(originOK("https://license.example.com", false));
  CHECK(originOK("https://license.example.com/", false));
  CHECK(originOK("https://license.example.com:8443", false));
  CHECK(!originOK("HTTPS://License.Example.com", false));  // v3: lowercase only
  CHECK(!originOK("http://license.example.com", false));
  CHECK(!originOK("http://license.example.com", true));
  CHECK(!originOK("http://127.0.0.1:8787", false));
  CHECK(!originOK("http://localhost:8787", false));
  CHECK(originOK("http://127.0.0.1:8787", true));
  CHECK(originOK("http://localhost:8787/", true));
  CHECK(!originOK("http://LOCALHOST:8787", true));
  CHECK(!originOK("http://127.0.0.1.evil.com:8787", true));
  CHECK(!originOK("http://localhost.evil.com", true));
  CHECK(!originOK("http://127.0.0.1@evil.com", true));
  CHECK(!originOK("https://user:pass@license.example.com", false));
  CHECK(!originOK("https://license.example.com/api", false));
  CHECK(!originOK("https://license.example.com?x=1", false));
  CHECK(!originOK("https://license.example.com#x", false));
  CHECK(!originOK("https://license.example.com:0", false));
  CHECK(!originOK("https://license.example.com:65536", false));
  CHECK(!originOK("https://license.example.com:", false));
  CHECK(!originOK("https://license.example.com:84a3", false));
  CHECK(!originOK("https://", false));
  CHECK(!originOK("https://.example.com", false));
  CHECK(!originOK("https://example..com", false));
  CHECK(!originOK("https://[::1]:8787", true));
  CHECK(!originOK("ftp://license.example.com", false));
  CHECK(!originOK("file:///etc/passwd", true));
  CHECK(!originOK("license.example.com", false));
  CHECK(!originOK("https://license.example.com\\@evil.com", false));
  CHECK(!originOK("https://license.example.com /", false));
  CHECK(!originOK("", true));
  CHECK(!originOK(NULL, true));

  // Pages the app opens: Stripe Checkout and the billing portal, nothing else.
  CHECK(pageOK("https://checkout.stripe.com/c/pay/cs_test_a1#fid"));
  CHECK(pageOK("https://billing.stripe.com/p/session/test_YWNjdA"));
  CHECK(pageOK("https://billing.stripe.com/p/login/abc?prefilled_email=x"));
  CHECK(pageOK("https://CHECKOUT.Stripe.COM/c/pay/x"));
  CHECK(pageOK("HTTPS://checkout.stripe.com"));
  CHECK(!pageOK("http://checkout.stripe.com/c/pay/x"));
  CHECK(!pageOK("https://checkout.stripe.com.evil.com/c/pay/x"));
  CHECK(!pageOK("https://evilcheckout.stripe.com/c/pay/x"));
  CHECK(!pageOK("https://checkout-stripe.com/c/pay/x"));
  CHECK(!pageOK("https://stripe.com/c/pay/x"));
  CHECK(!pageOK("https://dashboard.stripe.com/"));
  CHECK(!pageOK("https://checkout.stripe.com./c/pay/x"));
  CHECK(!pageOK("https://checkout.stripe.com@evil.com/c/pay/x"));
  CHECK(!pageOK("https://user:pw@checkout.stripe.com/c/pay/x"));
  CHECK(!pageOK("https://evil.com#@checkout.stripe.com/"));
  CHECK(!pageOK("https://evil.com\\@checkout.stripe.com/"));
  CHECK(!pageOK("https://checkout.stripe.com:443/c/pay/x"));
  CHECK(!pageOK("https://checkout.stripe.com:8443/c/pay/x"));
  CHECK(!pageOK("https://checkout.stripe.com%2eevil.com/"));
  CHECK(!pageOK("https://checkout.stripe.com/c/pay/x y"));
  CHECK(!pageOK("https://checkout.stripe.com/\n"));
  CHECK(!pageOK("https://checkout.stripe.com/c/\xc3\xa9"));
  CHECK(!pageOK("file:///Applications/Calculator.app"));
  CHECK(!pageOK("x-apple.systempreferences:com.apple.Displays-Settings"));
  CHECK(!pageOK("-a Calculator"));
  CHECK(!pageOK("//checkout.stripe.com/c/pay/x"));
  CHECK(!pageOK("https:checkout.stripe.com/c/pay/x"));
  CHECK(!pageOK(""));
  CHECK(!pageOK(NULL));

  // Review v2: lengths are explicit, so an embedded NUL is a byte that is
  // checked (and refused), not the end of the string.
  static const char nulPage[] = "https://checkout.stripe.com\0@evil.com/";
  static const char nulOrigin[] = "https://license.example.com\0@evil.com";
  CHECK(!nsPurchaseURLAllowed(nulPage, sizeof nulPage - 1));
  CHECK_EQ(nsPurchaseURLVerdict(nulPage, sizeof nulPage - 1), kNSLinkControl);
  CHECK(nsPurchaseURLAllowed(nulPage, strlen(nulPage)));  // only up to the NUL: fine
  CHECK(!nsLicenseOriginAllowed(nulOrigin, sizeof nulOrigin - 1, false));
  CHECK_EQ(nsLicenseOriginVerdict(nulOrigin, sizeof nulOrigin - 1, true), kNSLinkControl);
  static const char nulEnd[] = "https://checkout.stripe.com/\0";
  CHECK_EQ(nsPurchaseURLVerdict(nulEnd, sizeof nulEnd - 1), kNSLinkControl);
  // A length past a short buffer's NUL still stops at the length, not later.
  CHECK(nsPurchaseURLAllowed("https://checkout.stripe.com/xyz", 28));
  CHECK_EQ(nsPurchaseURLVerdict("https://checkout.stripe.com", 0), kNSLinkEmpty);
  const char *controls[] = {
      "https://checkout.stripe.com/\x01",   "https://checkout.stripe.com/a\tb",
      "https://checkout.stripe.com/\r\nX: y", "https://checkout.stripe.com\x1f/",
      "https://checkout.stripe.com/\x7f",   "\x1bhttps://checkout.stripe.com/",
      "https://checkout.stripe.com/\n",
  };
  for (size_t i = 0; i < sizeof controls / sizeof controls[0]; i++) {
    CHECK_EQ(pageWhy(controls[i]), kNSLinkControl);
  }
  const char *originControls[] = {
      "https://license.example.com\x01", "https://license.example.com\t",
      "https://license.example.com\r\n", "https://license.example.com\x7f",
  };
  for (size_t i = 0; i < sizeof originControls / sizeof originControls[0]; i++) {
    CHECK_EQ(originWhy(originControls[i]), kNSLinkControl);
  }

  // Review v2: each rule refuses on its own. Every string below breaks one
  // rule and would get past it to a different verdict (or be accepted) if
  // that rule were removed.
  CHECK_EQ(originWhy("https://license.example.com"), kNSLinkOK);
  CHECK_EQ(originWhy(""), kNSLinkEmpty);
  CHECK_EQ(originWhy("https://license.example.com\xc3\xa9"), kNSLinkNotASCII);
  CHECK_EQ(originWhy("https://license.example.com /"), kNSLinkNotASCII);
  // "\" alone: without its rule, the "@" after it is the next refusal.
  CHECK_EQ(originWhy("https://license.example.com\\@evil.com"), kNSLinkBackslash);
  CHECK_EQ(originWhy("https://license.example.com\\"), kNSLinkBackslash);
  CHECK_EQ(originWhy("license.example.com"), kNSLinkNoScheme);
  CHECK_EQ(originWhy("://license.example.com"), kNSLinkNoScheme);
  // "@" alone: without its rule, "user@license..." fails only as a host.
  CHECK_EQ(originWhy("https://user@license.example.com"), kNSLinkUserinfo);
  CHECK_EQ(originWhy("https://license.example.com@evil.com"), kNSLinkUserinfo);
  CHECK_EQ(originWhy("https://user:pass@license.example.com"), kNSLinkUserinfo);
  CHECK_EQ(originWhy("https://license.example.com:0"), kNSLinkBadPort);
  CHECK_EQ(originWhy("https://license.example.com:65536"), kNSLinkBadPort);
  CHECK_EQ(originWhy("https://license.example.com:"), kNSLinkBadPort);
  CHECK_EQ(originWhy("https://license.example.com:443x"), kNSLinkBadPort);
  CHECK_EQ(originWhy("https://"), kNSLinkBadHost);
  CHECK_EQ(originWhy("https://.example.com"), kNSLinkBadHost);
  CHECK_EQ(originWhy("https://example..com"), kNSLinkBadHost);
  CHECK_EQ(originWhy("https://license_example.com"), kNSLinkBadHost);
  CHECK_EQ(originWhy("https://[::1]:8787"), kNSLinkBadPort);  // the first ":" starts the port
  CHECK_EQ(originWhy("https://[fe80]"), kNSLinkBadHost);
  // A trailing dot alone: without its rule these would be accepted.
  CHECK_EQ(originWhy("https://license.example.com."), kNSLinkTrailingDot);
  CHECK_EQ(originWhy("https://license.example.com.:8443"), kNSLinkTrailingDot);
  CHECK_EQ(originWhy("https://license.example.com./"), kNSLinkTrailingDot);
  CHECK(!originOK("https://license.example.com.", true));
  CHECK_EQ(originWhy("https://license.example.com/api"), kNSLinkPath);
  CHECK_EQ(originWhy("https://license.example.com//"), kNSLinkPath);
  CHECK_EQ(originWhy("https://license.example.com?x"), kNSLinkPath);
  CHECK_EQ(originWhy("https://license.example.com#x"), kNSLinkPath);
  CHECK_EQ(originWhy("http://license.example.com"), kNSLinkScheme);
  CHECK_EQ(originWhy("http://127.0.0.1:8787"), kNSLinkScheme);
  CHECK_EQ(nsLicenseOriginVerdict("http://127.0.0.1:8787", 21, true), kNSLinkOK);
  CHECK_EQ(nsLicenseOriginVerdict("http://10.0.0.1:8787", 20, true), kNSLinkScheme);
  CHECK_EQ(originWhy("ftp://license.example.com"), kNSLinkScheme);
  CHECK_EQ(pageWhy("https://checkout.stripe.com/c/pay/x"), kNSLinkOK);
  CHECK_EQ(pageWhy("https://checkout.stripe.com:443/"), kNSLinkPort);
  CHECK_EQ(pageWhy("http://checkout.stripe.com/"), kNSLinkScheme);
  CHECK_EQ(pageWhy("https://checkout.stripe.com.evil.com/"), kNSLinkHost);
  CHECK_EQ(pageWhy("https://checkout.stripe.com./"), kNSLinkTrailingDot);
  CHECK_EQ(pageWhy("https://checkout.stripe.com@evil.com/"), kNSLinkUserinfo);
  CHECK_EQ(pageWhy("https://evil.com\\@checkout.stripe.com/"), kNSLinkBackslash);

  // v3: an origin has one spelling (lowercase scheme and host) and its port
  // no leading zero, exactly as make package checks it.
  CHECK_EQ(originWhy("HTTPS://License.Example.com:08443/"), kNSLinkPortLeadingZero);
  CHECK_EQ(originWhy("HTTPS://License.Example.com:8443/"), kNSLinkUppercase);
  CHECK_EQ(originWhy("HTTPS://license.example.com"), kNSLinkUppercase);
  CHECK_EQ(originWhy("Https://license.example.com"), kNSLinkUppercase);
  CHECK_EQ(originWhy("https://License.example.com"), kNSLinkUppercase);
  CHECK_EQ(originWhy("https://license.example.COM"), kNSLinkUppercase);
  CHECK_EQ(nsLicenseOriginVerdict("http://LOCALHOST:8787", 21, true), kNSLinkUppercase);
  CHECK_EQ(nsLicenseOriginVerdict("HTTP://127.0.0.1:8787", 21, true), kNSLinkUppercase);
  CHECK_EQ(originWhy("https://license.example.com:08443"), kNSLinkPortLeadingZero);
  CHECK_EQ(originWhy("https://license.example.com:0443/"), kNSLinkPortLeadingZero);
  CHECK_EQ(originWhy("https://license.example.com:00001"), kNSLinkPortLeadingZero);
  // Two digits is enough to refuse: :08 is not port 8.
  CHECK_EQ(originWhy("https://license.example.com:08"), kNSLinkPortLeadingZero);
  CHECK_EQ(originWhy("https://license.example.com:08/"), kNSLinkPortLeadingZero);
  CHECK_EQ(pageWhy("https://checkout.stripe.com:08/"), kNSLinkPortLeadingZero);
  CHECK_EQ(originWhy("https://license.example.com:8"), kNSLinkOK);
  CHECK_EQ(originWhy("https://license.example.com:0"), kNSLinkBadPort);
  CHECK_EQ(originWhy("https://license.example.com:8443"), kNSLinkOK);
  CHECK_EQ(originWhy("https://license.example.com:1"), kNSLinkOK);
  CHECK_EQ(originWhy("https://license-1.example.com/"), kNSLinkOK);
  CHECK_EQ(pageWhy("https://checkout.stripe.com:0443/"), kNSLinkPortLeadingZero);
  // The shapes Stripe returns (scrubbed): a long fragment, a portal secret query.
  CHECK_EQ(pageWhy("https://checkout.stripe.com/c/pay/cs_test_a1Xscrub0Xscrub0#fidXXscrubbedXXabc%2FdeQ%3D"), kNSLinkOK);
  CHECK_EQ(pageWhy("https://billing.stripe.com/p/session?secret=scrub_X0scrub_X0"), kNSLinkOK);
  // Pages stay case-insensitive: only the host name is compared.
  CHECK_EQ(pageWhy("https://Checkout.Stripe.com/c/pay/x"), kNSLinkOK);
  // Every verdict has its own text for make package and make install.
  for (int a = kNSLinkOK; a <= kNSLinkHost; a++) {
    CHECK(nsLinkVerdictText((NSLinkVerdict)a) != NULL);
    for (int b = a + 1; b <= kNSLinkHost; b++) {
      CHECK(strcmp(nsLinkVerdictText((NSLinkVerdict)a), nsLinkVerdictText((NSLinkVerdict)b)) != 0);
    }
  }
}

// NSWorkspace opens: purchase pages, exact Settings and project links.
// A license-server origin is not a page, including loopback http.
static bool workspaceOK(const char *s, bool loopback) {
  return nsWorkspaceOpenAllowed(s, lengthOf(s), loopback);
}

static void checkWorkspaceOpens(void) {
  CHECK(workspaceOK("https://checkout.stripe.com", false));
  CHECK(workspaceOK("https://checkout.stripe.com/", false));
  CHECK(workspaceOK("https://checkout.stripe.com/c/pay/x", false));
  CHECK(workspaceOK("https://billing.stripe.com/p/session", true));
  CHECK(workspaceOK("https://Checkout.Stripe.com/c/pay/x", false));
  CHECK(nsLicenseOriginVerdict("https://license.example.com", 27, false) == kNSLinkOK);
  CHECK(!workspaceOK("https://license.example.com", false));
  CHECK(!workspaceOK("https://license.example.com/", true));
  CHECK(nsLicenseOriginVerdict("http://127.0.0.1:8787", 21, true) == kNSLinkOK);
  CHECK(!workspaceOK("http://127.0.0.1:8787", true));
  CHECK(!workspaceOK("http://localhost:8787", true));
  CHECK(!workspaceOK("http://127.0.0.1:8787", false));
  CHECK(!workspaceOK("https://checkout.stripe.com.evil.com/", false));
  CHECK(!workspaceOK("https://evil.com/checkout", false));
  CHECK(!workspaceOK("http://checkout.stripe.com/c/pay/x", false));
  CHECK(!workspaceOK("https://user@checkout.stripe.com/pay", false));
  CHECK(!nsWorkspaceOpenAllowed(NULL, 0, false));
  CHECK(!nsWorkspaceOpenAllowed(NULL, 0, true));
  CHECK(!workspaceOK("", false));
  CHECK(workspaceOK("https://github.com/freechie/nightshift", false));
  CHECK(workspaceOK("https://github.com/freechie/nightshift/issues", false));
  CHECK(!workspaceOK("https://github.com/freechie/nightshift/issues/1", false));
  CHECK(!workspaceOK("https://github.com/freechie/nightshift/", false));
  CHECK(!workspaceOK("https://GitHub.com/freechie/nightshift", false));
  CHECK(workspaceOK(
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
      false));
  CHECK(workspaceOK("x-apple.systempreferences:com.apple.Displays-Settings.extension?nightShift",
                    false));
  CHECK(workspaceOK("x-apple.systempreferences:com.apple.Notifications-Settings.extension", false));
  CHECK(!workspaceOK(
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension?extra", false));
  const char embedded[] = "https://checkout.stripe.com/\0@evil.com/";
  CHECK(!nsWorkspaceOpenAllowed(embedded, sizeof embedded - 1, false));
}

// Media keys: only brightness is Nightshift's; volume, mute and the rest
// must be told apart so the key tap hands them back to macOS.
static void checkMediaKeys(void) {
  struct {
    int code;
    int want;
  } keys[] = {{0, 0}, {1, 0}, {7, 0}, {16, 0}, {2, 1}, {3, -1}};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    long press = ((long)keys[i].code << 16) | (0xA << 8);
    long repeat = press | 1;
    long release = ((long)keys[i].code << 16) | (0xB << 8);
    bool down = false;
    CHECK_EQ(nsMediaBrightnessKey(press, &down), keys[i].want);
    CHECK(down);
    CHECK_EQ(nsMediaBrightnessKey(repeat, &down), keys[i].want);
    CHECK(down);
    CHECK_EQ(nsMediaBrightnessKey(release, &down), keys[i].want);
    CHECK(!down);
  }
  // The low byte (repeat count) doesn't change the answer.
  bool down = false;
  CHECK_EQ(nsMediaBrightnessKey((2L << 16) | (0xA << 8) | 0xFF, &down), 1);
  CHECK(down);

  // Session tap mask: system-defined only. The old OR with bit 10 is refused.
  uint64_t mask = nsMediaTapMaskBits();
  CHECK_EQ(mask, 16384);
  CHECK_EQ(mask & ((uint64_t)1 << 10), 0);
  CHECK(mask != 0 && (mask & (mask - 1)) == 0);
  CHECK(nsMediaTapMaskAllowed(mask));
  CHECK(!nsMediaTapMaskAllowed(mask | ((uint64_t)1 << 10)));
  CHECK(!nsMediaTapMaskAllowed((uint64_t)1 << 10));
  CHECK(!nsMediaTapMaskAllowed(0));
  CHECK(!nsMediaTapMaskAllowed(mask | 1));
}

// fnState off: Cmd+F1/F2 arrive as brightness media keys. Command alone
// follows the intensity hotkey. No Command stays brightness. Command plus
// any other chord modifier is not taken.
static long mediaData(int code, int state, int repeat) {
  return ((long)code << 16) | ((long)state << 8) | (long)(repeat & 0xFF);
}

static void checkBrightnessChord(void) {
  const int downKey = 3;
  const int upKey = 2;
  const int press = 0xA;
  const int release = 0xB;
  bool down = false;
  long brightDown = mediaData(downKey, press, 0);
  long brightUp = mediaData(upKey, press, 0);
  long brightDownUp = mediaData(downKey, release, 0);
  long brightUpUp = mediaData(upKey, release, 0);

  CHECK_EQ(nsMediaBrightnessRoute(brightDown, kNSModifierCommand, &down), kNSMediaRouteIntensity);
  CHECK(down);
  CHECK_EQ(nsMediaBrightnessKey(brightDown, &down), -1);
  CHECK_EQ(nsMediaBrightnessKey(brightDown, &down), nsCommandWarmthDirection(1));
  CHECK(!nsMediaKeyRepeat(brightDown));

  CHECK_EQ(nsMediaBrightnessRoute(brightUp, kNSModifierCommand, &down), kNSMediaRouteIntensity);
  CHECK(down);
  CHECK_EQ(nsMediaBrightnessKey(brightUp, &down), 1);
  CHECK_EQ(nsMediaBrightnessKey(brightUp, &down), nsCommandWarmthDirection(2));

  CHECK_EQ(nsMediaBrightnessRoute(brightDownUp, kNSModifierCommand, &down), kNSMediaRouteIntensity);
  CHECK(!down);
  CHECK_EQ(nsMediaBrightnessRoute(brightUpUp, kNSModifierCommand, &down), kNSMediaRouteIntensity);
  CHECK(!down);

  CHECK_EQ(nsMediaBrightnessRoute(brightDown, 0, &down), kNSMediaRouteBrightness);
  CHECK(down);
  CHECK_EQ(nsMediaBrightnessRoute(brightUp, 0, &down), kNSMediaRouteBrightness);
  CHECK_EQ(nsMediaBrightnessRoute(brightDownUp, 0, &down), kNSMediaRouteBrightness);
  CHECK(!down);

  // Shift, control, option, or function without Command stay on brightness.
  const uint64_t alone[] = {kNSModifierShift, kNSModifierControl, kNSModifierOption,
                            kNSModifierFunction, kNSModifierHelp};
  for (size_t i = 0; i < sizeof(alone) / sizeof(alone[0]); i++) {
    CHECK_EQ(nsMediaBrightnessRoute(brightDown, alone[i], &down), kNSMediaRouteBrightness);
    CHECK_EQ(nsMediaBrightnessRoute(brightUp, alone[i], &down), kNSMediaRouteBrightness);
  }

  const uint64_t extra[] = {kNSModifierShift, kNSModifierControl, kNSModifierOption,
                            kNSModifierFunction, kNSModifierHelp};
  for (size_t i = 0; i < sizeof(extra) / sizeof(extra[0]); i++) {
    uint64_t flags = (uint64_t)kNSModifierCommand | extra[i];
    CHECK_EQ(nsMediaBrightnessRoute(brightDown, flags, &down), kNSMediaRouteUntouched);
    CHECK(down);
    CHECK_EQ(nsMediaBrightnessRoute(brightUp, flags, &down), kNSMediaRouteUntouched);
    CHECK_EQ(nsMediaBrightnessRoute(mediaData(downKey, release, 0), flags, &down),
             kNSMediaRouteUntouched);
    CHECK(!down);
  }
  CHECK_EQ(nsMediaBrightnessRoute(brightDown,
                                 (uint64_t)kNSModifierCommand | kNSModifierShift | kNSModifierOption,
                                 &down),
           kNSMediaRouteUntouched);

  // Caps lock, numeric pad, the non-coalesced bit, and which Command key
  // do not count as another modifier.
  const uint64_t ignored = (uint64_t)kNSModifierCommand | (1ull << 16) | (1ull << 21) | 0x100ull | 0x8ull;
  CHECK_EQ(nsMediaBrightnessRoute(brightDown, ignored, &down), kNSMediaRouteIntensity);
  CHECK_EQ(nsMediaBrightnessRoute(brightUp, ignored, NULL), kNSMediaRouteIntensity);
  CHECK_EQ(nsMediaBrightnessRoute(brightDown, 0x100ull, &down), kNSMediaRouteBrightness);

  // A repeat is still the same chord. Volume and mute never route here.
  long repeat = mediaData(downKey, press, 1);
  CHECK(nsMediaKeyRepeat(repeat));
  CHECK(nsMediaKeyRepeat(mediaData(upKey, press, 5)));
  CHECK(!nsMediaKeyRepeat(brightDownUp));
  CHECK_EQ(nsMediaBrightnessRoute(repeat, kNSModifierCommand, &down), kNSMediaRouteIntensity);
  CHECK(down);
  CHECK_EQ(nsMediaBrightnessRoute(repeat, 0, &down), kNSMediaRouteBrightness);
  for (int code = 0; code <= 7; code++) {
    if (code == 2 || code == 3) {
      continue;
    }
    long other = mediaData(code, press, 0);
    CHECK_EQ(nsMediaBrightnessRoute(other, kNSModifierCommand, &down), kNSMediaRouteNone);
    CHECK_EQ(nsMediaBrightnessRoute(other, 0, &down), kNSMediaRouteNone);
    CHECK_EQ(nsMediaBrightnessRoute(other, (uint64_t)kNSModifierCommand | kNSModifierShift, &down),
             kNSMediaRouteNone);
  }

  // Media down, repeat, and up share the hotkey hold. One begin, one end.
  // A second down while that direction is held does not begin again, and a
  // second release does not end again.
  int held = 0;
  CHECK_EQ(nsCommandWarmthMediaAction(-1, true, false, held), kNSWarmthMediaBegin);
  held = -1;
  CHECK_EQ(nsCommandWarmthMediaAction(-1, true, true, held), kNSWarmthMediaRepeat);
  CHECK_EQ(nsCommandWarmthMediaAction(-1, true, false, held), kNSWarmthMediaRepeat);
  CHECK_EQ(nsCommandWarmthMediaAction(-1, false, false, held), kNSWarmthMediaEnd);
  held = 0;
  CHECK_EQ(nsCommandWarmthMediaAction(-1, false, false, held), kNSWarmthMediaIgnore);
  CHECK_EQ(nsCommandWarmthMediaAction(-1, true, true, held), kNSWarmthMediaIgnore);

  // The hotkey press already began. The media down/repeat must not step,
  // and one of the two releases saves.
  held = 1;
  CHECK_EQ(nsCommandWarmthMediaAction(1, true, false, held), kNSWarmthMediaRepeat);
  CHECK_EQ(nsCommandWarmthMediaAction(1, true, true, held), kNSWarmthMediaRepeat);
  CHECK_EQ(nsCommandWarmthMediaAction(1, false, false, held), kNSWarmthMediaEnd);
  CHECK_EQ(nsCommandWarmthMediaAction(1, false, false, 0), kNSWarmthMediaIgnore);
  CHECK_EQ(nsCommandWarmthMediaAction(-1, false, false, 1), kNSWarmthMediaIgnore);
  CHECK_EQ(nsCommandWarmthMediaAction(1, true, false, -1), kNSWarmthMediaBegin);
  CHECK_EQ(nsCommandWarmthMediaAction(1, true, true, -1), kNSWarmthMediaIgnore);
  CHECK_EQ(nsCommandWarmthMediaAction(0, true, false, 0), kNSWarmthMediaIgnore);
  CHECK_EQ(nsCommandWarmthMediaAction(2, true, false, 0), kNSWarmthMediaIgnore);
}

// Disabled key taps: never an immediate re-enable, never once
// Accessibility is gone, and a give-up after repeated disables.
static void checkTapRecovery(void) {
  CHECK(nsTapRecoveryDelay(false, 1) < 0);
  CHECK(nsTapRecoveryDelay(false, 0) < 0);
  CHECK(nsTapRecoveryDelay(true, 1) == 0.25);
  CHECK(nsTapRecoveryDelay(true, 2) == 0.5);
  CHECK(nsTapRecoveryDelay(true, 5) == 4);
  CHECK(nsTapRecoveryDelay(true, 6) < 0);
  CHECK(nsTapRecoveryDelay(true, 1000) < 0);
  for (int n = 0; n <= 5; n++) {
    CHECK(nsTapRecoveryDelay(true, n) > 0);
  }
  // Missing Accessibility: fast polling for a minute, then slow, never stop.
  CHECK(nsTapRetryDelay(0) == 2);
  CHECK(nsTapRetryDelay(29) == 2);
  CHECK(nsTapRetryDelay(30) == 30);
  CHECK(nsTapRetryDelay(1000000) == 30);
  for (int n = 0; n < 100; n++) {
    CHECK(nsTapRetryDelay(n) > 0);
  }
  // The Accessibility check: drop at once on revoke, rebuild on regrant.
  CHECK_EQ(nsAccessAction(false, true), kNSAccessDrop);
  CHECK_EQ(nsAccessAction(true, false), kNSAccessRebuild);
  CHECK_EQ(nsAccessAction(true, true), kNSAccessKeep);
  CHECK_EQ(nsAccessAction(false, false), kNSAccessKeep);
}

// A pretend panel. sticky reads ignore writes (a cached brightness). echo
// reads return savedPercent and ignore the panel (the UI's saved number).
typedef struct {
  int panel;
  int max;
  int savedPercent;
  bool sticky;
  bool echoSaved;
  bool failRead;
  bool failWrite;
  bool failSecondRead;
  int confirmLag;  // confirmation reads that still report held
  int held;
  int failFirst;  // the first N reads fail, later ones work
  bool framed;
  bool overran;
  bool hangAfterWrite;
  int framedCalls;
  int reads;
  int writes;
  int written[4];
} ProbePanel;

static bool probeRead(void *ctx, int *current, int *max) {
  ProbePanel *panel = ctx;
  panel->reads++;
  if (panel->failRead || panel->reads <= panel->failFirst) {
    return false;
  }
  if (panel->failSecondRead && panel->writes > 0) {
    return false;
  }
  if (panel->max <= 0) {
    return false;
  }
  *max = panel->max;
  // echoSaved is the UI's saved percent, not the panel. sticky leaves the
  // panel where the first read found it. confirmLag is a slow panel: the
  // first confirmation reads still show the pre-write value.
  if (panel->writes > 0 && panel->confirmLag > 0) {
    panel->confirmLag--;
    *current = panel->held;
  } else {
    *current = panel->echoSaved ? panel->savedPercent : panel->panel;
  }
  return *current >= 0 && *current <= *max;
}

static bool probeFramed(void *ctx) {
  ProbePanel *panel = ctx;
  panel->framedCalls++;
  return panel->framed;
}

static bool probeBudget(void *ctx) {
  ProbePanel *panel = ctx;
  return !panel->overran;
}

static bool probeFramedOverrun(void *ctx) {
  ProbePanel *panel = ctx;
  panel->framedCalls++;
  panel->overran = true;
  return false;
}

static bool probeReadConfirmOverrun(void *ctx, int *current, int *max) {
  ProbePanel *panel = ctx;
  panel->reads++;
  if (panel->writes > 0) {
    panel->overran = true;
    return false;
  }
  *current = panel->panel;
  *max = panel->max;
  return true;
}

static bool probeWrite(void *ctx, int value) {
  ProbePanel *panel = ctx;
  if (panel->writes < 4) {
    panel->written[panel->writes] = value;
  }
  panel->writes++;
  if (panel->failWrite) {
    return false;
  }
  if (!panel->sticky && !panel->echoSaved) {
    panel->panel = value;
  }
  // The value landed, then the call timed out. Later writes still apply.
  if (panel->hangAfterWrite && panel->writes == 1) {
    panel->overran = true;
  }
  return true;
}

static ProbePanel probePanel(int panel, int max) {
  ProbePanel p;
  memset(&p, 0, sizeof(p));
  p.panel = panel;
  p.max = max;
  return p;
}

static void checkProbe(void) {
  // Two raw steps when they fit; one when they don't; none on an empty scale.
  CHECK_EQ(nsDDCProbeTarget(42, 100), 44);
  CHECK_EQ(nsDDCProbeTarget(0, 100), 2);
  CHECK_EQ(nsDDCProbeTarget(100, 100), 98);
  CHECK_EQ(nsDDCProbeTarget(99, 100), 97);
  CHECK_EQ(nsDDCProbeTarget(0, 1), 1);
  CHECK_EQ(nsDDCProbeTarget(1, 1), 0);
  CHECK_EQ(nsDDCProbeTarget(42, 0), -1);
  CHECK_EQ(nsDDCProbeTarget(-1, 100), -1);

  // The second read must be the written value. A cached 42 is "near" 44 on
  // this scale (tolerance 5) and must still fail.
  CHECK(nsDDCNear(42, 44, 100));
  CHECK(!nsDDCProbeLanded(42, 44, 42));
  CHECK(nsDDCProbeLanded(42, 44, 44));
  CHECK(!nsDDCProbeLanded(42, 44, 43));
  CHECK(!nsDDCProbeLanded(42, 42, 42));
  // Minimum tolerance is 2, so a two-step nudge is still "near" the old value.
  CHECK(nsDDCNear(100, 102, 255));
  CHECK(!nsDDCProbeLanded(100, 102, 100));
  CHECK(nsDDCProbeLanded(100, 102, 102));

  ProbePanel live = probePanel(42, 100);
  int current = -1;
  int max = -1;
  NSDDCProbeIO io;
  memset(&io, 0, sizeof(io));
  io.read = probeRead;
  io.write = probeWrite;
  io.ctx = &live;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(current, 42);
  CHECK_EQ(max, 100);
  CHECK_EQ(live.panel, 42);  // original written back
  CHECK_EQ(live.writes, 2);
  CHECK_EQ(live.written[0], 44);
  CHECK_EQ(live.written[1], 42);
  CHECK_EQ(live.reads, 2);

  // The first confirmation read is still the old value. A later read shows
  // the write, so the panel is controllable and the original is restored.
  ProbePanel slow = probePanel(42, 100);
  slow.confirmLag = 1;
  slow.held = 42;
  io.ctx = &slow;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(slow.reads, 3);
  CHECK_EQ(slow.written[0], 44);
  CHECK_EQ(slow.written[1], 42);
  CHECK_EQ(slow.panel, 42);
  CHECK_EQ(slow.confirmLag, 0);

  // Every confirmation read stays at 42. Retrying must not turn that into a pass.
  ProbePanel stuck = probePanel(42, 100);
  stuck.sticky = true;
  stuck.confirmLag = 4;
  stuck.held = 42;
  io.ctx = &stuck;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(stuck.reads, 5);
  CHECK_EQ(stuck.panel, 42);
  CHECK(strcmp(nsDDCControlLabel(kNSDDCProbeControllable), "DDC/CI connected") == 0);
  long hw = -1;
  long sw = -1;
  long combinedHw = 0;
  long combinedSw = 0;
  nsExternalBrightness(kNSDDCProbeControllable, 76, 0, &hw, &sw);
  nsCombinedLevels(76, 0, &combinedHw, &combinedSw);
  CHECK_EQ(hw, combinedHw);
  CHECK_EQ(sw, combinedSw);
  CHECK(hw > 0 && sw == 100);
  nsExternalBrightness(kNSDDCProbeControllable, 56, 20, &hw, &sw);
  nsCombinedLevels(56, 20, &combinedHw, &combinedSw);
  CHECK_EQ(hw, combinedHw);
  CHECK_EQ(sw, combinedSw);
  nsExternalBrightness(kNSDDCProbeControllable, 40, 20, &hw, &sw);
  nsCombinedLevels(40, 20, &combinedHw, &combinedSw);
  CHECK_EQ(hw, combinedHw);
  CHECK_EQ(sw, combinedSw);
  CHECK(sw < 100);
  // The DDC path is the combined model at every sample, including the
  // software-dim curve's sample points. A floor still changes the split.
  const long samples[] = {0, 25, 50, 75, 100};
  for (int i = 0; i < 5; i++) {
    long sample = samples[i];
    nsExternalBrightness(kNSDDCProbeControllable, sample, 0, &hw, &sw);
    nsCombinedLevels(sample, 0, &combinedHw, &combinedSw);
    CHECK_EQ(hw, combinedHw);
    CHECK_EQ(sw, combinedSw);
    nsExternalBrightness(kNSDDCProbeControllable, sample, 20, &hw, &sw);
    nsCombinedLevels(sample, 20, &combinedHw, &combinedSw);
    CHECK_EQ(hw, combinedHw);
    CHECK_EQ(sw, combinedSw);
  }

  // Readback stays at 42. nsDDCNear would accept it; the probe must not.
  ProbePanel cached = probePanel(42, 100);
  cached.sticky = true;
  current = 99;
  max = 99;
  io.ctx = &cached;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(cached.panel, 42);
  CHECK_EQ(cached.writes, 2);
  CHECK_EQ(cached.written[0], 44);
  CHECK_EQ(cached.written[1], 42);
  CHECK(strcmp(nsDDCControlLabel(kNSDDCProbeSoftware), "Software dimming") == 0);
  CHECK(strcmp(nsDDCControlLabel(kNSDDCProbeSoftware), "DDC/CI connected") != 0);
  // p^(1/2.2), rounded. 50 is 73, brighter than a linear 50. Ends stay put.
  CHECK_EQ(nsSoftwareDimShade(0), 0);
  CHECK_EQ(nsSoftwareDimShade(25), 53);
  CHECK_EQ(nsSoftwareDimShade(50), 73);
  CHECK_EQ(nsSoftwareDimShade(75), 88);
  CHECK_EQ(nsSoftwareDimShade(100), 100);
  CHECK(nsSoftwareDimShade(50) > 50);
  long prevShade = 0;
  for (long percent = 0; percent <= 100; percent += 1) {
    long shade = nsSoftwareDimShade(percent);
    nsExternalBrightness(kNSDDCProbeSoftware, percent, 20, &hw, &sw);
    CHECK_EQ(hw, -1);
    CHECK_EQ(sw, shade);
    CHECK(sw >= prevShade);
    if (percent > 0 && percent < 100) {
      CHECK(sw > percent);
    }
    // The floor is a backlight idea. Software dimming ignores it.
    nsExternalBrightness(kNSDDCProbeSoftware, percent, 0, &hw, &sw);
    CHECK_EQ(hw, -1);
    CHECK_EQ(sw, shade);
    prevShade = shade;
  }
  nsExternalBrightness(kNSDDCProbeSoftware, -5, 20, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, 0);
  nsExternalBrightness(kNSDDCProbeSoftware, 130, 20, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, 100);
  // Above the combined switch is still the curve, not a backlight write.
  nsExternalBrightness(kNSDDCProbeSoftware, 76, 0, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, 88);
  CHECK(sw > 76);
  nsExternalBrightness(kNSDDCProbeSoftware, 56, 0, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, 77);
  CHECK(sw > 56);

  // The number the UI saved (76) is not a panel read. Writing 78 and reading
  // 76 again is a miss, even though 76 is what listing displays would show.
  ProbePanel saved = probePanel(42, 100);
  saved.echoSaved = true;
  saved.savedPercent = 76;
  io.ctx = &saved;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(saved.writes, 2);
  CHECK_EQ(saved.written[0], 78);
  CHECK_EQ(saved.written[1], 76);
  CHECK_EQ(saved.panel, 42);

  ProbePanel deadRead = probePanel(42, 100);
  deadRead.failRead = true;
  io.ctx = &deadRead;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(deadRead.writes, 0);
  CHECK(strcmp(nsDDCControlLabel(kNSDDCProbeSoftware), "DDC/CI connected") != 0);

  ProbePanel deadWrite = probePanel(42, 100);
  deadWrite.failWrite = true;
  io.ctx = &deadWrite;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(deadWrite.writes, 1);
  CHECK_EQ(deadWrite.panel, 42);

  ProbePanel deadSecond = probePanel(50, 100);
  deadSecond.failSecondRead = true;
  io.ctx = &deadSecond;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(deadSecond.writes, 2);
  CHECK_EQ(deadSecond.written[1], 50);
  CHECK_EQ(deadSecond.panel, 50);

  ProbePanel top = probePanel(100, 100);
  io.ctx = &top;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(top.written[0], 98);
  CHECK_EQ(top.written[1], 100);
  CHECK_EQ(top.panel, 100);
  CHECK_EQ(current, 100);

  ProbePanel wide = probePanel(100, 255);
  io.ctx = &wide;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(wide.written[0], 102);
  CHECK_EQ(wide.panel, 100);
  CHECK_EQ(max, 255);

  io.ctx = NULL;
  io.read = NULL;
  CHECK_EQ(nsDDCProbeControl(NULL, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(nsDDCProbeControl(&io, NULL, NULL), kNSDDCProbeSoftware);
  ProbePanel empty = probePanel(0, 0);
  io.read = probeRead;
  io.write = probeWrite;
  io.ctx = &empty;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(empty.writes, 0);

  // The first brightness reads fail; a later one is the panel. Still DDC.
  ProbePanel late = probePanel(42, 100);
  late.failFirst = 2;
  io.ctx = &late;
  io.framed = probeFramed;
  late.framed = true;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(late.reads, 4);
  CHECK_EQ(late.framedCalls, 0);
  CHECK_EQ(late.written[0], 44);
  CHECK_EQ(late.written[1], 42);
  CHECK_EQ(io.evidence, kNSDDCEvidenceRead);
  CHECK_EQ(current, 42);
  CHECK_EQ(max, 100);

  // Brightness reads fail, a capabilities/VCP frame is valid, and the write
  // path accepts the last-known value. That is DDC, not software dimming.
  ProbePanel linked = probePanel(42, 100);
  linked.failRead = true;
  linked.framed = true;
  io.ctx = &linked;
  io.framed = probeFramed;
  io.fallbackCurrent = 40;
  io.fallbackMax = 100;
  current = -1;
  max = -1;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(linked.writes, 1);
  CHECK_EQ(linked.written[0], 40);
  CHECK_EQ(linked.framedCalls, 1);
  CHECK_EQ(current, 40);
  CHECK_EQ(max, 100);
  CHECK_EQ(io.evidence, kNSDDCEvidenceFramed);
  nsExternalBrightness(kNSDDCProbeControllable, 40, 0, &hw, &sw);
  nsCombinedLevels(40, 0, &combinedHw, &combinedSw);
  CHECK_EQ(hw, combinedHw);
  CHECK_EQ(sw, combinedSw);

  // No last-known level: keep full scale, not black.
  ProbePanel linkedFull = probePanel(10, 100);
  linkedFull.failRead = true;
  linkedFull.framed = true;
  io.ctx = &linkedFull;
  io.fallbackCurrent = 0;
  io.fallbackMax = 0;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(current, 100);
  CHECK_EQ(max, 100);
  CHECK_EQ(linkedFull.written[0], 100);
  CHECK_EQ(nsDDCProbeKeep(0, 0, NULL), 100);
  int keptScale = 0;
  CHECK_EQ(nsDDCProbeKeep(40, 100, &keptScale), 40);
  CHECK_EQ(keptScale, 100);
  CHECK_EQ(nsDDCProbeKeep(0, 100, &keptScale), 100);

  // The frame is real but the write is refused. Stay on software dimming.
  ProbePanel framedDead = probePanel(42, 100);
  framedDead.failRead = true;
  framedDead.framed = true;
  framedDead.failWrite = true;
  io.ctx = &framedDead;
  io.fallbackCurrent = 40;
  io.fallbackMax = 100;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(framedDead.writes, 1);
  CHECK_EQ(io.evidence, kNSDDCEvidenceNone);
  CHECK_EQ(current, 0);
  CHECK_EQ(max, 0);

  // Write would return success and brightness reads fail. No framed reply:
  // that is not evidence, and the lamp is not written.
  ProbePanel writeOnly = probePanel(42, 100);
  writeOnly.failRead = true;
  writeOnly.framed = false;
  io.ctx = &writeOnly;
  io.framed = probeFramed;
  io.fallbackCurrent = 40;
  io.fallbackMax = 100;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(writeOnly.writes, 0);
  CHECK_EQ(writeOnly.framedCalls, 1);
  CHECK_EQ(io.evidence, kNSDDCEvidenceWriteOnly);
  CHECK_EQ(current, 0);
  nsExternalBrightness(kNSDDCProbeSoftware, 50, 20, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, 73);

  // A stuck readback is negative evidence. A framed callback must not
  // overturn it, and the software curve stays the one on main.
  ProbePanel stuckFrame = probePanel(42, 100);
  stuckFrame.sticky = true;
  stuckFrame.framed = true;
  io.ctx = &stuckFrame;
  io.framed = probeFramed;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(stuckFrame.framedCalls, 0);
  CHECK_EQ(io.evidence, kNSDDCEvidenceUnchanged);
  CHECK_EQ(stuckFrame.panel, 42);
  nsExternalBrightness(kNSDDCProbeSoftware, 50, 0, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, nsSoftwareDimShade(50));

  NSDDCProbeFacts readOk;
  memset(&readOk, 0, sizeof(readOk));
  readOk.evidence = kNSDDCEvidenceRead;
  readOk.writeOk = true;
  readOk.current = 42;
  readOk.max = 100;
  CHECK_EQ(nsDDCProbeDecide(&readOk, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(current, 42);
  CHECK_EQ(max, 100);

  NSDDCProbeFacts framedFacts;
  memset(&framedFacts, 0, sizeof(framedFacts));
  framedFacts.evidence = kNSDDCEvidenceFramed;
  framedFacts.writeOk = true;
  framedFacts.fallbackCurrent = 40;
  framedFacts.fallbackMax = 100;
  CHECK_EQ(nsDDCProbeDecide(&framedFacts, &current, &max), kNSDDCProbeControllable);
  CHECK_EQ(current, 40);
  CHECK_EQ(max, 100);

  NSDDCProbeFacts writeOnlyFacts;
  memset(&writeOnlyFacts, 0, sizeof(writeOnlyFacts));
  writeOnlyFacts.evidence = kNSDDCEvidenceWriteOnly;
  writeOnlyFacts.writeOk = true;
  writeOnlyFacts.fallbackCurrent = 40;
  writeOnlyFacts.fallbackMax = 100;
  CHECK_EQ(nsDDCProbeDecide(&writeOnlyFacts, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(current, 0);
  CHECK_EQ(max, 0);
  nsExternalBrightness(kNSDDCProbeSoftware, 25, 0, &hw, &sw);
  CHECK_EQ(hw, -1);
  CHECK_EQ(sw, nsSoftwareDimShade(25));

  NSDDCProbeFacts nothing;
  memset(&nothing, 0, sizeof(nothing));
  nothing.evidence = kNSDDCEvidenceNone;
  CHECK_EQ(nsDDCProbeDecide(&nothing, &current, &max), kNSDDCProbeSoftware);
  NSDDCProbeFacts noService;
  memset(&noService, 0, sizeof(noService));
  noService.evidence = kNSDDCEvidenceNoService;
  noService.writeOk = true;
  CHECK_EQ(nsDDCProbeDecide(&noService, &current, &max), kNSDDCProbeSoftware);
  NSDDCProbeFacts unchanged;
  memset(&unchanged, 0, sizeof(unchanged));
  unchanged.evidence = kNSDDCEvidenceUnchanged;
  unchanged.writeOk = true;
  unchanged.current = 42;
  unchanged.max = 100;
  CHECK_EQ(nsDDCProbeDecide(&unchanged, &current, &max), kNSDDCProbeSoftware);
  framedFacts.writeOk = false;
  CHECK_EQ(nsDDCProbeDecide(&framedFacts, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(nsDDCProbeDecide(NULL, &current, &max), kNSDDCProbeSoftware);

  uint8_t vcp[11] = {0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 42, 0};
  uint8_t sum = 0x50;
  for (int i = 0; i < 10; i++) {
    sum ^= vcp[i];
  }
  vcp[10] = sum;
  CHECK(nsDDCFrameValid(vcp, 11));
  vcp[10] ^= 0xFF;
  CHECK(!nsDDCFrameValid(vcp, 11));
  uint8_t caps[8] = {0x6E, 0x86, 0xE3, 0x00, 0x00, '(', 'p', 0};
  sum = 0x50;
  for (int i = 0; i < 7; i++) {
    sum ^= caps[i];
  }
  caps[7] = sum;
  CHECK(nsDDCFrameValid(caps, 8));
  caps[2] = 0x00;
  CHECK(!nsDDCFrameValid(caps, 8));
  uint8_t garbage[11];
  memset(garbage, 0, sizeof(garbage));
  CHECK(!nsDDCFrameValid(garbage, 11));
  CHECK(!nsDDCFrameValid(NULL, 11));

  char line[64];
  CHECK(nsDDCDebugLine(7, 1, kNSDDCProbeControllable, kNSDDCEvidenceRead, line, sizeof(line)));
  CHECK(strcmp(line, "ddc 7 1 0 1") == 0);
  CHECK(nsDDCDebugLine(9, -1, kNSDDCProbeSoftware, kNSDDCEvidenceNoService, line, sizeof(line)));
  CHECK(strcmp(line, "ddc 9 -1 1 4") == 0);
  CHECK(!nsDDCDebugLine(7, 1, 0, 1, line, 4));
  CHECK(line[0] == '\0');
  CHECK(!nsDDCDebugLine(7, 1, 3, 1, line, sizeof(line)));
  CHECK(!nsDDCDebugLine(7, 1, 0, 9, line, sizeof(line)));
  CHECK(nsDDCDebugLine(3, -1, kNSDDCProbeSoftware, kNSDDCEvidenceNotProbed, line, sizeof(line)));
  CHECK(strcmp(line, "ddc 3 -1 1 6") == 0);
  CHECK(nsDDCDebugLine(2, -1, kNSDDCProbeSoftware, kNSDDCEvidenceInFlight, line, sizeof(line)));
  CHECK(strcmp(line, "ddc 2 -1 1 7") == 0);

  // The 11-byte frame above is brightness 42 of 100 once the checksum is put
  // back. Checksum seed is 0x50. A seed of 0x6E must not pass.
  vcp[10] ^= 0xFF;
  NSDDCReply decoded;
  CHECK(nsDDCDecodeReply(vcp, 11, &decoded));
  CHECK(decoded.brightness);
  CHECK_EQ(decoded.current, 42);
  CHECK_EQ(decoded.max, 100);
  uint8_t wrongSeed[11];
  memcpy(wrongSeed, vcp, 11);
  wrongSeed[10] = 0x6E;
  for (int i = 0; i < 10; i++) {
    wrongSeed[10] ^= vcp[i];
  }
  CHECK(!nsDDCDecodeReply(wrongSeed, 11, &decoded));
  CHECK(!decoded.valid);

  // Length byte 0x88: the 0x80 flag is masked off (length 8, not 136) and
  // the address byte is absent, which is what a shifted HDMI read looks like.
  uint8_t shifted[10] = {0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 42, 0};
  sum = 0x50;
  for (int i = 0; i < 9; i++) {
    sum ^= shifted[i];
  }
  shifted[9] = sum;
  CHECK(nsDDCDecodeReply(shifted, 10, &decoded));
  CHECK(decoded.brightness);
  CHECK_EQ(decoded.current, 42);
  CHECK_EQ(decoded.max, 100);
  CHECK(nsDDCFrameValid(shifted, 10));

  // 0x89 is 0x80|9, so the checksum is inside the length. Masking is required.
  uint8_t masked[11] = {0x6E, 0x89, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 42, 0};
  sum = 0x50;
  for (int i = 0; i < 10; i++) {
    sum ^= masked[i];
  }
  masked[10] = sum;
  CHECK(nsDDCDecodeReply(masked, 11, &decoded));
  CHECK_EQ(decoded.current, 42);
  CHECK_EQ(decoded.max, 100);

  // A 12-byte read at data address 0x51 can echo 0x51 in the length byte.
  // The checksum is 0x50 XOR every byte except the last.
  uint8_t echoed[12] = {0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 42, 0x00, 0};
  sum = 0x50;
  for (int i = 0; i < 11; i++) {
    sum ^= echoed[i];
  }
  echoed[11] = sum;
  CHECK(nsDDCDecodeReply(echoed, 12, &decoded));
  CHECK(decoded.brightness);
  CHECK_EQ(decoded.current, 42);
  CHECK_EQ(decoded.max, 100);
  echoed[11] ^= 0xFF;
  CHECK(!nsDDCDecodeReply(echoed, 12, &decoded));

  // A leading data-address byte is not part of the frame.
  uint8_t prefixed[12];
  prefixed[0] = 0x51;
  memcpy(prefixed + 1, vcp, 11);
  CHECK(nsDDCDecodeReply(prefixed, 12, &decoded));
  CHECK(decoded.brightness);
  CHECK_EQ(decoded.current, 42);
  prefixed[1] = 0x6F;
  sum = 0x50;
  for (int i = 1; i < 11; i++) {
    sum ^= prefixed[i];
  }
  prefixed[11] = sum;
  CHECK(nsDDCDecodeReply(prefixed, 12, &decoded));
  CHECK_EQ(decoded.current, 42);

  NSDDCProbeFacts pendingFacts;
  memset(&pendingFacts, 0, sizeof(pendingFacts));
  pendingFacts.evidence = kNSDDCEvidenceNotProbed;
  pendingFacts.writeOk = true;
  CHECK_EQ(nsDDCProbeDecide(&pendingFacts, &current, &max), kNSDDCProbeSoftware);
  pendingFacts.evidence = kNSDDCEvidenceInFlight;
  CHECK_EQ(nsDDCProbeDecide(&pendingFacts, &current, &max), kNSDDCProbeSoftware);

  uint32_t displays[3] = {1, 3, 2};
  int builtin[3] = {1, 0, 0};
  NSDDCDebugRow rows[2];
  memset(rows, 0, sizeof(rows));
  rows[0].display = 3;
  rows[0].service = 0;
  rows[0].verdict = kNSDDCProbeSoftware;
  rows[0].evidence = kNSDDCEvidenceWriteOnly;
  rows[1].display = 2;
  rows[1].service = 1;
  rows[1].verdict = kNSDDCProbeSoftware;
  rows[1].evidence = kNSDDCEvidenceInFlight;
  char report[128];
  CHECK_EQ(nsDDCDebugReport(displays, builtin, 3, rows, 1, report, sizeof(report)), 2);
  CHECK(strcmp(report, "ddc 3 0 1 3\nddc 2 -1 1 6\n") == 0);
  CHECK_EQ(nsDDCDebugReport(displays, builtin, 3, rows, 2, report, sizeof(report)), 2);
  CHECK(strcmp(report, "ddc 3 0 1 3\nddc 2 1 1 7\n") == 0);
  CHECK_EQ(nsDDCDebugReport(NULL, NULL, 0, NULL, 0, report, sizeof(report)), 0);
  CHECK(report[0] == '\0');

  // Offset 0 first. 0x51 and 0x50 only after an empty offset-0 reply, and
  // only while the display deadline still has time left.
  CHECK_EQ(nsDDCNextReadOffset(0, kNSDDCOffsetEmpty, true), 0);
  CHECK_EQ(nsDDCNextReadOffset(0, kNSDDCOffsetEmpty, false), -1);
  CHECK_EQ(nsDDCNextReadOffset(1, kNSDDCOffsetEmpty, true), 0x51);
  CHECK_EQ(nsDDCNextReadOffset(2, kNSDDCOffsetEmpty, true), 0x50);
  CHECK_EQ(nsDDCNextReadOffset(3, kNSDDCOffsetEmpty, true), -1);
  CHECK_EQ(nsDDCNextReadOffset(1, kNSDDCOffsetEmpty, false), -1);
  CHECK_EQ(nsDDCNextReadOffset(1, kNSDDCOffsetTimedOut, true), -1);
  CHECK_EQ(nsDDCNextReadOffset(1, kNSDDCOffsetFrame, true), -1);

  CHECK(nsDDCDebugLine(3, 0, kNSDDCProbeSoftware, kNSDDCEvidenceTimedOut, line, sizeof(line)));
  CHECK(strcmp(line, "ddc 3 0 1 8") == 0);
  NSDDCProbeFacts timed;
  memset(&timed, 0, sizeof(timed));
  timed.evidence = kNSDDCEvidenceTimedOut;
  timed.writeOk = true;
  timed.fallbackCurrent = 40;
  timed.fallbackMax = 100;
  CHECK_EQ(nsDDCProbeDecide(&timed, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(current, 0);
  CHECK_EQ(max, 0);

  // A read that does not return must not fall through into the full-scale
  // keep write, even when a framed reply would otherwise allow it.
  ProbePanel stalled = probePanel(42, 100);
  io.ctx = &stalled;
  io.read = probeRead;
  io.write = probeWrite;
  io.framed = probeFramed;
  io.budget = probeBudget;
  stalled.failRead = true;
  stalled.framed = true;
  stalled.overran = true;
  io.fallbackCurrent = 0;
  io.fallbackMax = 0;
  current = 99;
  max = 99;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(stalled.writes, 0);
  CHECK_EQ(stalled.framedCalls, 0);
  CHECK_EQ(io.evidence, kNSDDCEvidenceTimedOut);
  CHECK_EQ(current, 0);
  CHECK_EQ(max, 0);

  // The read returned nothing, then the capabilities read overran. Still no
  // brightness write, and the code is the timeout, not write-only.
  ProbePanel lateHang = probePanel(42, 100);
  lateHang.failRead = true;
  io.ctx = &lateHang;
  io.framed = probeFramedOverrun;
  io.budget = probeBudget;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(lateHang.framedCalls, 1);
  CHECK_EQ(lateHang.writes, 0);
  CHECK_EQ(io.evidence, kNSDDCEvidenceTimedOut);

  // Nudge went out, confirmation read overran: still put 42 back.
  ProbePanel confirmHang = probePanel(42, 100);
  io.ctx = &confirmHang;
  io.read = probeReadConfirmOverrun;
  io.framed = NULL;
  io.budget = probeBudget;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(confirmHang.writes, 2);
  CHECK_EQ(confirmHang.written[0], 44);
  CHECK_EQ(confirmHang.written[1], 42);
  CHECK_EQ(confirmHang.panel, 42);
  CHECK_EQ(io.evidence, kNSDDCEvidenceTimedOut);

  // No saved scale, so the probe writes full scale. The write lands and the
  // call then times out. The level from before the probe is written back.
  ProbePanel fullHang = probePanel(30, 100);
  fullHang.failRead = true;
  fullHang.framed = true;
  fullHang.hangAfterWrite = true;
  io.ctx = &fullHang;
  io.read = probeRead;
  io.write = probeWrite;
  io.framed = probeFramed;
  io.budget = probeBudget;
  io.fallbackCurrent = 30;
  io.fallbackMax = 0;
  CHECK_EQ(nsDDCProbeControl(&io, &current, &max), kNSDDCProbeSoftware);
  CHECK_EQ(fullHang.writes, 2);
  CHECK_EQ(fullHang.written[0], 100);
  CHECK_EQ(fullHang.written[1], 30);
  CHECK_EQ(fullHang.panel, 30);
  CHECK_EQ(io.evidence, kNSDDCEvidenceTimedOut);
  io.budget = NULL;
  io.read = probeRead;
  io.framed = probeFramed;
  io.fallbackCurrent = 0;
  io.fallbackMax = 0;
}

int main(void) {
  checkTapRecovery();
  checkMediaKeys();
  checkBrightnessChord();
  checkRamp();
  checkMatching();
  checkSlots();
  checkReadback();
  checkSplit();
  checkSafety();
  checkCommandWarmth();
  checkProbe();
  checkHosts();
  checkWorkspaceOpens();
  if (gFailures != 0) {
    fprintf(stderr, "logic: %d of %d checks failed\n", gFailures, gChecks);
    return 1;
  }
  printf("logic: %d checks passed\n", gChecks);
  return 0;
}
