// Unit tests for NightshiftLogic. Plain C so it also builds off macOS:
//   cc -x c -std=c11 -I. tests/logic.m -x c NightshiftLogic.m -lm
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L  // mkdtemp under -std=c11 on glibc
#endif

#include "NightshiftLogic.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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


// ⌃⌥⌘− / ⌃⌥⌘=: the Current slider, five percent at a time, clamped
// to 0...100. Minus lowers, equals raises.
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
  // Accessibility settings are no longer opened: the hotkeys need no tap.
  CHECK(!workspaceOK(
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

// Warmth shortcuts: defaults, what may be recorded, the saved file, and the
// notice and Settings label for each way registering can fail.
static void checkWarmthShortcuts(void) {
  NSShortcut lower;
  NSShortcut raise;
  CHECK(nsShortcutDefault(1, &lower));
  CHECK(nsShortcutDefault(2, &raise));
  CHECK_EQ(lower.keyCode, 27);   // kVK_ANSI_Minus
  CHECK_EQ(raise.keyCode, 24);   // kVK_ANSI_Equal
  CHECK_EQ(lower.modifiers, 0x1900);  // cmdKey | optionKey | controlKey
  CHECK_EQ(raise.modifiers, 0x1900);
  CHECK(strcmp(lower.name, "\u2303\u2325\u2318\u2212") == 0);
  CHECK(strcmp(raise.name, "\u2303\u2325\u2318=") == 0);
  CHECK_EQ(nsCommandWarmthDirection(1), -1);
  CHECK_EQ(nsCommandWarmthDirection(2), 1);
  NSShortcut none;
  CHECK(!nsShortcutDefault(3, &none));
  CHECK_EQ(none.keyCode, 0);
  CHECK(strcmp(none.name, "") == 0);

  // A modifier other than shift is required; only four modifiers count.
  CHECK(!nsShortcutAllowed(0x00, 0));
  CHECK(!nsShortcutAllowed(0x00, kNSHotKeyShift));
  CHECK(nsShortcutAllowed(0x00, kNSHotKeyControl));
  CHECK(!nsShortcutAllowed(0x00, kNSHotKeyShift | kNSHotKeyCommand));
  CHECK(nsShortcutAllowed(0x00, kNSHotKeyShift | kNSHotKeyControl));
  CHECK(!nsShortcutAllowed(0x00, kNSHotKeyCommand | (1 << 7)));
  CHECK(!nsShortcutAllowed(128, kNSHotKeyCommand));
  // Global hotkeys: a lone ⌘ or ⌥ with a letter, digit or arrow is refused so
  // ⌘Q, ⌘W, ⌘C and ⌥E keep working in every app. F-keys and ⌃ are fine.
  CHECK(!nsShortcutAllowed(0x0C, kNSHotKeyCommand));  // ⌘Q
  CHECK(!nsShortcutAllowed(0x0D, kNSHotKeyCommand));  // ⌘W
  CHECK(!nsShortcutAllowed(0x08, kNSHotKeyCommand));  // ⌘C
  CHECK(!nsShortcutAllowed(0x12, kNSHotKeyCommand));  // ⌘1
  CHECK(!nsShortcutAllowed(0x7B, kNSHotKeyCommand));  // ⌘←
  CHECK(!nsShortcutAllowed(0x0E, kNSHotKeyOption));   // ⌥E
  CHECK(nsShortcutAllowed(0x7A, kNSHotKeyCommand));   // ⌘F1
  CHECK(nsShortcutAllowed(0x78, kNSHotKeyOption));    // ⌥F2
  CHECK(nsShortcutAllowed(0x0C, kNSHotKeyControl));   // ⌃Q
  CHECK(nsShortcutAllowed(0x0C, kNSHotKeyOption | kNSHotKeyCommand));  // ⌥⌘Q
  // ⇧ is not the second modifier: ⌘⇧Z, ⌘⇧T and ⌥⇧K stay with apps.
  CHECK(!nsShortcutAllowed(0x06, kNSHotKeyCommand | kNSHotKeyShift));  // ⌘⇧Z
  CHECK(!nsShortcutAllowed(0x11, kNSHotKeyCommand | kNSHotKeyShift));  // ⌘⇧T
  CHECK(!nsShortcutAllowed(0x28, kNSHotKeyOption | kNSHotKeyShift));   // ⌥⇧K
  CHECK(nsShortcutAllowed(0x7A, kNSHotKeyCommand | kNSHotKeyShift));   // ⌘⇧F1
  CHECK(nsShortcutAllowed(0x06, kNSHotKeyOption | kNSHotKeyCommand | kNSHotKeyShift));  // ⌥⇧⌘Z

  NSShortcut made;
  CHECK(nsShortcutMake(0x0B, kNSHotKeyShift | kNSHotKeyCommand | kNSHotKeyOption |
                                 kNSHotKeyControl, "B", &made));
  CHECK(strcmp(made.name, "\u2303\u2325\u21E7\u2318B") == 0);
  CHECK(strcmp(made.key, "B") == 0);
  CHECK(nsShortcutMake(0x7A, kNSHotKeyOption, "\xef\x9c\x84", &made));  // F1's private glyph
  CHECK(strcmp(made.name, "\u2325F1") == 0);
  NSShortcut kept = made;
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyControl, "", &made));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyControl, "a b", &made));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyControl, "\t", &made));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyControl, "TOOLONGKEY", &made));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyControl, NULL, &made));
  CHECK(!nsShortcutMake(0x0B, 0, "B", &made));
  CHECK(nsShortcutSame(&made, &kept));

  // The saved file round-trips, and anything wrong keeps the default.
  NSShortcut pair[2];
  CHECK_EQ(nsShortcutsParse(NULL, pair), 0);
  CHECK(nsShortcutSame(&pair[0], &lower) && nsShortcutSame(&pair[1], &raise));
  CHECK(nsShortcutMake(0x7B, kNSHotKeyControl | kNSHotKeyCommand, NULL, &pair[0]));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyOption, "B", &pair[1]));
  CHECK(!nsShortcutMake(0x0B, kNSHotKeyOption | kNSHotKeyShift, "B", &pair[1]));
  CHECK(nsShortcutMake(0x0B, kNSHotKeyOption | kNSHotKeyControl, "B", &pair[1]));
  char text[128];
  int n = nsShortcutsFormat(pair, text, sizeof text);
  CHECK_EQ(n, (long)strlen(text));
  CHECK(strcmp(text, "lower 123 4352 \u2190\nraise 11 6144 B\n") == 0);
  NSShortcut back[2];
  CHECK_EQ(nsShortcutsParse(text, back), 3);
  CHECK(nsShortcutSame(&back[0], &pair[0]) && nsShortcutSame(&back[1], &pair[1]));
  CHECK(strcmp(back[0].name, pair[0].name) == 0);
  CHECK(strcmp(back[1].name, "\u2303\u2325B") == 0);
  CHECK_EQ(nsShortcutsParse("raise 11 6144 B\n", back), 2);
  CHECK(nsShortcutSame(&back[0], &lower));
  CHECK_EQ(nsShortcutsParse("lower 11 0 B\nraise 11 6144 B extra\n", back), 0);
  CHECK(nsShortcutSame(&back[0], &lower) && nsShortcutSame(&back[1], &raise));
  CHECK_EQ(nsShortcutsParse("lower 999 256 B\nbogus\n\n", back), 0);
  CHECK_EQ(nsShortcutsParse("lower 11 6144 B\nraise 11 6144 B\n", back), 0);
  CHECK(nsShortcutSame(&back[0], &lower) && nsShortcutSame(&back[1], &raise));
  CHECK_EQ(nsShortcutsParse("lower 11 6144 B\nlower 12 6144 Q\n", back), 1);
  CHECK(strcmp(back[0].key, "B") == 0);
  // A saved file from an editor (CRLF, trailing blanks) still loads.
  CHECK_EQ(nsShortcutsParse("lower 11 6144 B\r\nraise 12 6144 Q \t\r\n", back), 3);
  CHECK(strcmp(back[1].key, "Q") == 0);
  // Numbers are plain decimal and in range; %u would have wrapped these.
  CHECK_EQ(nsShortcutsParse("lower 4294967307 6144 B\n", back), 0);
  CHECK_EQ(nsShortcutsParse("lower 11 18446744073709551616 B\n", back), 0);
  CHECK_EQ(nsShortcutsParse("lower -1 6144 B\nraise +11 6144 B\n", back), 0);
  CHECK_EQ(nsShortcutsParse("lower 11 256 B\n", back), 0);  // lone ⌘ from an old file
  CHECK_EQ(nsShortcutsParse("lower 11 768 B\n", back), 0);  // ⌘⇧ from an old file
  CHECK(nsShortcutSame(&back[0], &lower));
  char tiny[4];
  n = nsShortcutsFormat(pair, tiny, sizeof tiny);
  CHECK(n > 3 && tiny[3] == '\0');

  // Each failure says which key and why.
  char buf[160];
  CHECK_EQ(nsShortcutNotice(1, lower.name, kNSShortcutReady, buf, sizeof buf), 0);
  CHECK(buf[0] == '\0');
  nsShortcutNotice(1, lower.name, kNSShortcutTakenBySystem, buf, sizeof buf);
  CHECK(strcmp(buf, "\u2303\u2325\u2318\u2212 (lower warmth) is a macOS shortcut. Pick "
                    "another in Settings.") == 0);
  nsShortcutNotice(2, raise.name, kNSShortcutTakenByApp, buf, sizeof buf);
  CHECK(strcmp(buf, "\u2303\u2325\u2318= (raise warmth) is already used by another app.") == 0);
  n = nsShortcutNotice(9, NULL, kNSShortcutFailed, buf, sizeof buf);
  CHECK(strcmp(buf, "A warmth shortcut (warmth) couldn't be turned on.") == 0);
  CHECK_EQ(n, (long)strlen(buf));
  n = nsShortcutNotice(2, raise.name, kNSShortcutTakenByApp, tiny, sizeof tiny);
  CHECK(n > 3 && tiny[3] == '\0');
  CHECK(strcmp(nsShortcutStateLabel(kNSShortcutReady), "On") == 0);
  CHECK(strcmp(nsShortcutStateLabel(kNSShortcutTakenBySystem), "Used by macOS") == 0);
  CHECK(strcmp(nsShortcutStateLabel(kNSShortcutTakenByApp), "Used by another app") == 0);
  CHECK(strcmp(nsShortcutStateLabel(kNSShortcutFailed), "Couldn't turn on") == 0);
}

// A pretend panel. sticky reads ignore writes (a cached brightness). echo
static bool writeFile(const char *dir, const char *name, const char *text) {
  char path[1024];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  FILE *file = fopen(path, "w");
  if (file == NULL) {
    return false;
  }
  bool ok = fputs(text, file) >= 0;
  return fclose(file) == 0 && ok;
}

static bool fileIs(const char *dir, const char *name, const char *want) {
  char path[1024];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  FILE *file = fopen(path, "r");
  if (file == NULL) {
    return false;
  }
  char got[256];
  size_t used = fread(got, 1, sizeof(got) - 1, file);
  fclose(file);
  got[used] = '\0';
  return strcmp(got, want) == 0;
}

// A support folder left by a build that still had brightness: per-display
// brightness in "brightness" and a collapsed "brightness" menu section.
// Warmth (max, full) must load from it unchanged, the old section name must
// drop out, and the next save must succeed without touching the old file.
static void checkOldBrightnessSettings(void) {
  char dir[] = "/tmp/nightshift-logic-XXXXXX";
  CHECK(mkdtemp(dir) != NULL);
  const char *oldBrightness = "1552 41001 0 55\n610 41159 16843009 30 combined\n";
  CHECK(writeFile(dir, "max", "40\n"));
  CHECK(writeFile(dir, "full", "1260\n"));
  CHECK(writeFile(dir, "brightness", oldBrightness));
  CHECK(writeFile(dir, "sections", "appearance\nbrightness\nramp\n"));
  char maxPath[1024];
  char fullPath[1024];
  char brightPath[1024];
  snprintf(maxPath, sizeof(maxPath), "%s/max", dir);
  snprintf(fullPath, sizeof(fullPath), "%s/full", dir);
  snprintf(brightPath, sizeof(brightPath), "%s/brightness", dir);

  long max = -1;
  long full = -1;
  CHECK(nsReadSavedNumber(maxPath, 1, 100, &max));
  CHECK_EQ(max, 40);
  CHECK(nsReadSavedNumber(fullPath, 0, 1439, &full));
  CHECK_EQ(full, 1260);
  // The brightness file is not a warmth number and is never taken as one.
  long stray = -1;
  CHECK(!nsReadSavedNumber(brightPath, 1, 100, &stray));
  CHECK_EQ(stray, -1);

  CHECK(nsSectionKept("ramp"));
  CHECK(nsSectionKept("appearance"));
  CHECK(!nsSectionKept("brightness"));
  CHECK(!nsSectionKept(""));
  CHECK(!nsSectionKept(NULL));

  // The next save works, round-trips, is owner-only, and leaves the rest.
  CHECK(nsWriteSavedNumber(maxPath, 45));
  max = -1;
  CHECK(nsReadSavedNumber(maxPath, 1, 100, &max));
  CHECK_EQ(max, 45);
  CHECK(fileIs(dir, "max", "45\n"));
  struct stat info;
  CHECK(stat(maxPath, &info) == 0 && (info.st_mode & 0777) == 0600);
  CHECK(nsWriteSavedNumber(fullPath, 1290));
  CHECK(nsReadSavedNumber(fullPath, 0, 1439, &full));
  CHECK_EQ(full, 1290);
  CHECK(fileIs(dir, "brightness", oldBrightness));

  // Malformed and out-of-range values are refused, never half-read.
  CHECK(writeFile(dir, "max", "0\n"));
  CHECK(!nsReadSavedNumber(maxPath, 1, 100, &max));
  CHECK(writeFile(dir, "max", "40 brightness\n"));
  CHECK(!nsReadSavedNumber(maxPath, 1, 100, &max));
  CHECK(!nsReadSavedNumber("/nonexistent/nightshift/max", 1, 100, &max));
  CHECK(!nsWriteSavedNumber("/nonexistent/nightshift/max", 40));

  const char *names[] = {"max", "full", "brightness", "sections"};
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
    unlink(path);
  }
  CHECK(rmdir(dir) == 0);
}

// The socket's commands after brightness came out. The removed brightness
// commands, and anything unknown, get the clean "failed" reply.
static void checkDaemonCommands(void) {
  const char *gone[] = {"ddc", "brightness", "brightness 3 40", "brightness 3", "keys",
                        "keys on", "", "bright", "statusx", "status ", "max", "ramp",
                        "maxx 3", "schedulex", "dark-on", "DDC", "Brightness 1 2", "\x01"};
  for (size_t i = 0; i < sizeof(gone) / sizeof(gone[0]); i++) {
    CHECK_EQ(nsDaemonCommand(gone[i]), kNSCommandUnknown);
  }
  CHECK_EQ(nsDaemonCommand(NULL), kNSCommandUnknown);
  CHECK_EQ(nsDaemonCommand("status"), kNSCommandStatus);
  CHECK_EQ(nsDaemonCommand("max 60"), kNSCommandMax);
  CHECK_EQ(nsDaemonCommand("ramp 1230"), kNSCommandRamp);
  CHECK_EQ(nsDaemonCommand("schedule"), kNSCommandSchedule);
  CHECK_EQ(nsDaemonCommand("schedule custom"), kNSCommandSchedule);
  CHECK_EQ(nsDaemonCommand("clock"), kNSCommandClock);
  CHECK_EQ(nsDaemonCommand("clock 24"), kNSCommandClock);
  CHECK_EQ(nsDaemonCommand("login on"), kNSCommandLogin);
  CHECK_EQ(nsDaemonCommand("dark"), kNSCommandDark);
  CHECK_EQ(nsDaemonCommand("tone off"), kNSCommandTone);
  CHECK_EQ(nsDaemonCommand("40"), kNSCommandWarmth);
  CHECK_EQ(nsDaemonCommand("0"), kNSCommandWarmth);
  CHECK_EQ(nsDaemonCommand("-1"), kNSCommandWarmth);
}

int main(void) {
  checkWarmthShortcuts();
  checkRamp();
  checkCommandWarmth();
  checkOldBrightnessSettings();
  checkDaemonCommands();
  checkHosts();
  checkWorkspaceOpens();
  if (gFailures != 0) {
    fprintf(stderr, "logic: %d of %d checks failed\n", gFailures, gChecks);
    return 1;
  }
  printf("logic: %d checks passed\n", gChecks);
  return 0;
}
