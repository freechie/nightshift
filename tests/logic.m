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

int main(void) {
  checkTapRecovery();
  checkMediaKeys();
  checkRamp();
  checkMatching();
  checkSlots();
  checkReadback();
  checkSplit();
  checkSafety();
  checkHosts();
  checkWorkspaceOpens();
  if (gFailures != 0) {
    fprintf(stderr, "logic: %d of %d checks failed\n", gFailures, gChecks);
    return 1;
  }
  printf("logic: %d checks passed\n", gChecks);
  return 0;
}
