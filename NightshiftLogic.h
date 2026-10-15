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

// Pure logic the daemon uses, kept free of AppKit, IOKit and globals so the
// unit tests can call it. Plain C: tests/logic.m builds on macOS and Linux.

#ifndef NIGHTSHIFT_LOGIC_H
#define NIGHTSHIFT_LOGIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// MARK: Evening ramp

// 1 in the first half of the glide, 2 in the second, 3 once it has arrived.
int nsGlideStage(int fromMinute, int toMinute, int now);
// Where a glide that starts now should end: Full at when it comes before the
// schedule ends, else glideMinutes from now, never past the schedule's end.
int nsGlideEnd(int now, int scheduleEnd, int fullAt, int glideMinutes);
// clock falls inside the schedule, its end included.
bool nsClockInSchedule(int start, int end, int clock);
// clock comes after now and no later than the next turn-on.
bool nsAheadOfTurnOn(int now, int start, int clock);
// The Full at an evening uses: the saved clock when it is inside the
// schedule, else rampMinutes after the start (or the schedule's end when it
// is shorter). -1 for an empty schedule.
int nsDefaultFullAt(int start, int end, int rampClock, int rampMinutes);

// MARK: DDC monitor matching

// One DCPAVServiceProxy that might belong to a display.
typedef struct {
  uint32_t vendor;   // EDID bytes 8-9, big-endian PNP ID, as CGDisplayVendorNumber
  uint32_t product;  // EDID bytes 10-11
  uint32_t serial;   // EDID bytes 12-15, 0 when the monitor leaves it unset
  bool external;     // "Location" is "External", or the property is missing
  char port[32];     // "dispext0" from the parent "dispext0:dcpav-service-epic:0"
} DDCCandidate;

// What CoreGraphics knows about the display being matched.
typedef struct {
  uint32_t vendor;
  uint32_t model;
  uint32_t serial;
  char port[32];      // "dispext0" from CoreDisplay's IODisplayLocation, "" if unknown
  int twins;          // online displays with this vendor and model, this one included
  bool serialShared;  // another of those twins reports the same nonzero serial
} DDCTarget;

// Copies the part of name before stop ("dispext0" from "dispext0@88000000").
bool nsDDCPortName(const char *name, char stop, char *out, size_t cap);
// The index of the one candidate that is certainly this display, or -1 when
// it is ambiguous and the shade should be used. Never trades a known brand
// for a guess.
int nsDDCPickCandidate(const DDCCandidate *candidates, int count, const DDCTarget *target);

// MARK: DDC slots and readback

// The slot a display's channel belongs in: its own slot when it has one, else
// the first free one (display 0), else -1. Looking for its own slot first
// keeps a freed lower slot from becoming a second slot for the display.
int nsDDCSlotFor(const uint32_t *displays, int count, uint32_t display);
int nsDDCValue(long percent, int scale);
long nsDDCRawPercent(int raw, int scale);
bool nsDDCNear(int got, int want, int scale);
// The lowest raw value the lamp goes to, updated after a write of wanted
// (lamp percent asked for: percent) moved the lamp from before to landed.
// -1 means unknown. A floor is learned only from a readback that two reads
// agreed on (stable) and only when the lamp really moved down, so a stale
// reply that still shows the old level can't become a permanent floor. A
// reading below the floor always clears it.
int nsDDCLearnFloor(int floorRaw, int before, int wanted, int landed, int scale, long percent,
                    bool stable);

// MARK: Backlight and overlay

// Brightness percents at or above this move the lamp; below it the lamp sits
// at its floor and the overlay (shade) dims the picture.
extern const long kNSCombinedSwitch;
// The dimmest the overlay goes for any percent above 0. Only 0 is black.
extern const long kNSShadeFloor;
// The lowest percent restored at launch, after wake or replug. Black and
// near-black are for this session only.
extern const long kNSRestoreMinimum;

long nsLampToCombined(long lamp, long floor);

// Patch review N9: what a revalidation (after wake or a screen change) does
// when it reads a confirmed lamp. current and target are raw values on
// scale; the ages are seconds since the display's last brightness change
// and since the Mac last woke, negative for never.
//   kNSRevalidateKeep     on target, or changed in the last
//                         kNSUserQuietSeconds (a write may still be settling
//                         and the user's value stands)
//   kNSRevalidateReapply  just woke (kNSWakeWindowSeconds) and at least
//                         kNSResetGap points off: the monitor reset itself
//                         while asleep or power-cycled
//   kNSRevalidateAdopt    anything else: the monitor's own buttons moved it,
//                         so its value becomes the shown one
typedef enum {
  kNSRevalidateKeep = 0,
  kNSRevalidateReapply = 1,
  kNSRevalidateAdopt = 2,
} NSRevalidateAction;
extern const double kNSUserQuietSeconds;
extern const double kNSWakeWindowSeconds;
extern const long kNSResetGap;
NSRevalidateAction nsRevalidateAction(int current, int target, int scale,
                                      double sinceChange, double sinceWake);
// Splits a brightness percent into a lamp percent (hardware) and an overlay
// percent (software, 100 = no overlay, 0 = black).
void nsCombinedLevels(long percent, long floor, long *hardware, long *software);

// MARK: Proving a monitor follows DDC

// read and write talk to the panel (raw VCP 0x10). They must not answer from
// Nightshift's saved brightness or the number the UI is showing.
typedef struct {
  bool (*read)(void *ctx, int *current, int *max);
  bool (*write)(void *ctx, int value);
  void *ctx;
} NSDDCProbeIO;

typedef enum {
  kNSDDCProbeControllable = 0,  // the panel followed a write
  kNSDDCProbeSoftware = 1,      // unchanged readback, or a read/write error
} NSDDCProbeVerdict;

// Raw brightness to write: two steps from current when that stays on the
// scale, otherwise one. -1 when the scale cannot move. The step is raw, not
// a percent, so the flash stays small.
int nsDDCProbeTarget(int current, int max);
// True only when the second read is the written value and is not the first
// read. Exact, not nsDDCNear: a one- or two-step nudge sits inside that
// tolerance, so a cached read of the old value would look close enough.
bool nsDDCProbeLanded(int before, int written, int after);
// Read, write nsDDCProbeTarget, read again, then write the original back.
// The confirmation read is tried up to four times: a slow panel can still
// answer with the old value once. Controllable only when one of those reads
// is the written value. A read or write error, or a readback that never
// leaves the first value, is software-only. When the first read works,
// *current and *max receive it (the value written back). Either pointer may
// be NULL.
NSDDCProbeVerdict nsDDCProbeControl(const NSDDCProbeIO *io, int *current, int *max);
// Settings label. Controllable is "DDC/CI connected". Software is
// "Software dimming" and is never the connected label.
const char *nsDDCControlLabel(NSDDCProbeVerdict verdict);
// Power for the software-only shade. 1 is a linear map (slider percent in,
// same percent out). 2.2 lifts the middle. See nsSoftwareDimShade.
extern const double kNSSoftwareDimExponent;
// Gamma percent for a display that is not DDC-controllable. 0 is fully
// dimmed, 100 is undimmed, and a higher value is brighter. Linear percent is
// too dark through the lower half, so this is p^(1/kNSSoftwareDimExponent):
// 50 lands near 73. Set the exponent to 1 to restore a linear map.
long nsSoftwareDimShade(long percent);
// Controllable keeps nsCombinedLevels. Software uses nsSoftwareDimShade
// across the whole 0-100 slider and does not write the lamp (*hardware is -1).
void nsExternalBrightness(NSDDCProbeVerdict verdict, long percent, long floor,
                          long *hardware, long *software);
// One brightness-key step on a scale of stops.
long nsSteppedPercent(long percent, int direction, long stops);
// The percent a display may actually be set to. 0 (black) is refused for an
// external display unless another online display is still lit, so the user
// can never lose every screen; it becomes 1, the dimmest visible level.
long nsSafeBrightness(long percent, bool builtin, int otherLitDisplays);

// Another online display, as seen when deciding whether one may go black.
typedef struct {
  bool builtin;   // the built-in panel
  bool hardware;  // brightness read from the display itself: confirmed DDC,
                  // DisplayServices or CoreBrightness. Not the software shade.
  bool asleep;
  bool mirrored;  // in the same mirror set as the display going black
  long percent;   // -1 when it can't be read
} NSOtherDisplay;
// Whether a display is trusted to still show a picture (patch review N6).
// The built-in panel counts unless it reads 0. Anything else counts only
// when its brightness comes from the display itself and is above 0: a
// dummy HDMI plug, a virtual or DisplayLink display, or a monitor that is
// off but still listed has only the software shade, which says nothing
// about whether anyone can see it.
bool nsCountsAsLit(NSOtherDisplay display);
int nsLitDisplays(const NSOtherDisplay *others, int count);
// What is written to the brightness file: never 0.
long nsPersistedBrightness(long percent);
// What a saved percent is restored as.
long nsRestoredBrightness(long saved);

// MARK: License server and purchase pages

// Why a URL was refused. The checks run in this order and the first that
// fails is reported, so each rule can be tested on its own.
typedef enum {
  kNSLinkOK = 0,
  kNSLinkEmpty,        // NULL or no bytes
  kNSLinkControl,      // a NUL or other control character (0x00-0x1f, 0x7f)
  kNSLinkNotASCII,     // a space or a byte above 0x7f
  kNSLinkBackslash,    // "\" anywhere
  kNSLinkNoScheme,     // no "scheme://"
  kNSLinkUserinfo,     // "@" in the authority
  kNSLinkBadPort,      // a port that isn't 1-65535 in digits
  kNSLinkPortLeadingZero,  // a port written with a leading 0 ("08443")
  kNSLinkBadHost,      // empty host, leading or doubled dot, other characters
  kNSLinkTrailingDot,  // host ending in "."
  kNSLinkPath,         // origin only: a path, query or fragment
  kNSLinkUppercase,    // origin only: a capital letter in the scheme or host
  kNSLinkPort,         // purchase page only: any port
  kNSLinkScheme,       // not https (or loopback http where allowed)
  kNSLinkHost,         // purchase page only: not a Stripe page host
} NSLinkVerdict;

// The length is explicit: every byte of the string is checked, so an
// embedded NUL is refused instead of ending the string early.
//
// origin is a license server origin the app may talk to: "https://host" or
// "https://host:port", optionally ending in one "/", in lowercase, with no
// userinfo, path, query or fragment, and no leading 0 in the port. With allowLoopbackHTTP (test-key builds only),
// "http://127.0.0.1[:port]" and "http://localhost[:port]" too.
NSLinkVerdict nsLicenseOriginVerdict(const char *origin, size_t length, bool allowLoopbackHTTP);
bool nsLicenseOriginAllowed(const char *origin, size_t length, bool allowLoopbackHTTP);
// Why verdict refused a URL, as a phrase: "its port starts with 0". Used by
// make package and make install, so they report the app's own rule.
const char *nsLinkVerdictText(NSLinkVerdict verdict);
// url may be opened as Stripe Checkout or the billing portal: https, host
// exactly checkout.stripe.com or billing.stripe.com (any case), no
// userinfo, no port, nothing that isn't printable ASCII.
NSLinkVerdict nsPurchaseURLVerdict(const char *url, size_t length);
bool nsPurchaseURLAllowed(const char *url, size_t length);
// Whether NSWorkspace may open url. Every call reads nsPurchaseURLVerdict
// and nsLicenseOriginVerdict. A purchase page may open. A license-server
// origin may not: the app talks to it and does not browse it. Settings and
// the project pages are exact strings.
bool nsWorkspaceOpenAllowed(const char *url, size_t length, bool allowLoopbackHTTP);

// A media key (NX_SYSDEFINED, subtype 8) from its data1: the key code is
// bits 16-31, the state bits 8-15 (0xA down, 0xB up). Returns 1 for
// brightness up (code 2), -1 for brightness down (code 3), 0 for any other
// key (volume up 0, down 1, mute 7, play...), which must reach macOS
// unchanged. *down is set for a press or repeat.
int nsMediaBrightnessKey(long data1, bool *down);

// Mask for the one Session tap: event type 14 (system-defined) and nothing
// else. Bit 10 is key-down and is not set. Volume and mute use this same
// mask; nsMediaBrightnessKey returns 0 for them, so the tap hands them back.
uint64_t nsMediaTapMaskBits(void);
bool nsMediaTapMaskAllowed(uint64_t bits);

// What to do when macOS disables the key taps (timeout or user input).
// trusted is AXIsProcessTrusted() now; recent counts the disables in the
// last minute, this one included. Returns the seconds to wait before
// re-enabling (0.25, 0.5, 1, 2, 4), or -1 to remove the taps and let the
// permission poll re-create them: always when Accessibility was revoked,
// and after more than five disables a minute. Never re-enables at once.
double nsTapRecoveryDelay(bool trusted, int recent);

// Seconds before the next try at creating the key taps while
// Accessibility is missing: every 2 s for the first 30 tries (about a
// minute), then every 30 s for as long as Nightshift runs.
double nsTapRetryDelay(int tries);

// What the once-a-second Accessibility check does. trusted is
// AXIsProcessTrusted() now; haveTaps is whether the key taps exist. Drop
// when access is gone and taps remain (macOS would otherwise stall all
// input until it times them out), rebuild when access is back and they
// are missing, otherwise keep.
typedef enum {
  kNSAccessKeep = 0,
  kNSAccessDrop,
  kNSAccessRebuild,
} NSAccessAction;
NSAccessAction nsAccessAction(bool trusted, bool haveTaps);

#endif
