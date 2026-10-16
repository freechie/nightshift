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

// Pure logic the daemon uses, kept free of AppKit and globals so the
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

// Cmd+F1 lowers Night Shift intensity (id 1), Cmd+F2 raises it (id 2).
// 0 is any other id. The chord is a Carbon hotkey, which does not repeat,
// so a hold repeats on a timer. The value is the Current slider: whole
// percents, clamped to 0...100, one step of nsCommandWarmthStep.
int nsCommandWarmthDirection(unsigned hotKeyID);
long nsCommandWarmthStep(void);
// One step of that size, then clamped to 0...100. direction 0 only clamps.
long nsCommandWarmthNext(long percent, int direction);
// Seconds between hold repeats. Never faster than 0.02s, so a hold cannot
// spin the run loop if the system repeat interval is tiny.
double nsCommandWarmthRepeatGap(double seconds);

// A media brightness key (fnState off: Command does not become F1/F2) and
// the Carbon hotkey can both observe one physical press. The hotkey does
// not repeat. The media key does, and it has its own down and up. Begin
// steps once and starts the hold. Repeat, or another down while that
// direction is already held, does not step: the hold timer does. A repeat
// with nothing held does not start a hold. End saves once. A release that
// is not the held direction does not save again.
typedef enum {
  kNSWarmthMediaIgnore = 0,
  kNSWarmthMediaBegin,
  kNSWarmthMediaRepeat,
  kNSWarmthMediaEnd,
} NSWarmthMediaAction;
NSWarmthMediaAction nsCommandWarmthMediaAction(int direction, bool down, bool repeat,
                                               int heldDirection);

// MARK: Daemon socket commands

// The first word of one socket line. Anything else, including the removed
// "brightness", "ddc" and "keys", is kNSCommandUnknown and is answered
// "failed" before any handler runs. status is exact. max and ramp need a
// value. schedule, clock, login, dark and tone are the word alone or the
// word, a space, and a value. A line that starts with a number (after
// spaces, an optional sign) is a warmth; its value is checked later.
typedef enum {
  kNSCommandUnknown = 0,
  kNSCommandStatus,
  kNSCommandMax,
  kNSCommandRamp,
  kNSCommandSchedule,
  kNSCommandClock,
  kNSCommandLogin,
  kNSCommandDark,
  kNSCommandTone,
  kNSCommandWarmth,
} NSDaemonCommand;
NSDaemonCommand nsDaemonCommand(const char *line);

// MARK: Saved settings

// The warmth settings in the support folder are one number per file: max
// (1-100) and full (Full at, minutes 0-1439). Older builds also left a
// "brightness" file there, and "brightness" in the sections file. Nothing
// reads the brightness file any more; it is left in place, never parsed,
// and never rewritten, so it cannot affect warmth.
//
// Reads path: one decimal number, optional trailing spaces and newlines,
// within lo...hi. False for a missing, empty or malformed file.
bool nsReadSavedNumber(const char *path, long lo, long hi, long *value);
// Writes "value\n" to path through a temporary file and a rename, owner
// read/write only. False when any step fails; the old file then stays.
bool nsWriteSavedNumber(const char *path, long value);
// Whether a name from the collapsed-sections file is a menu section that
// still exists ("ramp", "appearance"). The old "brightness" is not, so it is
// dropped on load and gone after the next save.
bool nsSectionKept(const char *name);

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

// Device-independent modifier bits, the same positions as CGEventFlags.
// Caps lock, numeric pad, and the device-dependent low bits are not a chord:
// Command alone still steps intensity when those are set.
enum {
  kNSModifierShift = 1 << 17,
  kNSModifierControl = 1 << 18,
  kNSModifierOption = 1 << 19,
  kNSModifierCommand = 1 << 20,
  kNSModifierHelp = 1 << 22,
  kNSModifierFunction = 1 << 23,
};

// What the session tap does with a subtype-8 media key. Command alone on a
// brightness key is the Cmd+F1 / Cmd+F2 intensity chord (fnState off, where
// RegisterEventHotKey never sees F1/F2). No Command is the plain brightness
// key (kNSMediaRouteBrightness): Nightshift does not control brightness, so
// the tap hands it back to macOS untouched. Command plus Shift, Control,
// Option, Help, or Function is left untouched. Any other key (volume, mute)
// is None.
typedef enum {
  kNSMediaRouteNone = 0,
  kNSMediaRouteBrightness = 1,
  kNSMediaRouteIntensity = 2,
  kNSMediaRouteUntouched = 3,
} NSMediaRoute;
NSMediaRoute nsMediaBrightnessRoute(long data1, uint64_t modifierFlags, bool *down);

// A media key (NX_SYSDEFINED, subtype 8) from its data1: the key code is
// bits 16-31, the state bits 8-15 (0xA down, 0xB up). Returns 1 for
// brightness up (code 2), -1 for brightness down (code 3), 0 for any other
// key (volume up 0, down 1, mute 7, play...), which must reach macOS
// unchanged. *down is set for a press or repeat.
int nsMediaBrightnessKey(long data1, bool *down);
// Low byte of data1. 0 is the first press or the release. Any other value
// is a repeat while the key is held. Direction ignores it.
bool nsMediaKeyRepeat(long data1);

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
