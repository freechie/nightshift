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

// Hotkey id 1 lowers Night Shift intensity, id 2 raises it.
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

// The warmth hotkeys, as RegisterEventHotKey takes them. The values are
// Carbon's (kVK_ANSI_Minus / kVK_ANSI_Equal, cmdKey, shiftKey, optionKey,
// controlKey); nightshiftd.m checks them against Carbon at compile time,
// so this file stays plain C.
enum {
  kNSKeyCodeMinus = 0x1B,
  kNSKeyCodeEqual = 0x18,
  kNSHotKeyCommand = 1 << 8,
  kNSHotKeyShift = 1 << 9,
  kNSHotKeyOption = 1 << 11,
  kNSHotKeyControl = 1 << 12,
};
// One warmth shortcut. name is UTF-8 for Settings and notices: the modifier
// glyphs in Apple's order (⌃⌥⇧⌘) and then the key's label.
typedef struct {
  unsigned keyCode;
  unsigned modifiers;
  char key[12];   // the key's label alone, as saved
  char name[40];  // modifiers and key, as shown
} NSShortcut;
// id 1 lowers warmth (default ⌃⌥⌘−), id 2 raises it (default ⌃⌥⌘=).
// false and an all-zero shortcut for any other id.
bool nsShortcutDefault(unsigned hotKeyID, NSShortcut *out);
// A shortcut Nightshift will register: a key code below 128, only the four
// modifiers above, and at least two of ⌃, ⌥ and ⌘ for every key but
// F1...F12, which need one. ⇧ never counts. A lone ⌘, ⌥ or ⌃ with a letter,
// digit, arrow, Space, Return or punctuation, even with ⇧, would take ⌘Q,
// ⌘⇧Z, ⌥E, ⌃C, ⌃D, ⌃A and the like from every app and from Terminal.
bool nsShortcutAllowed(unsigned keyCode, unsigned modifiers);
// The label for keys whose typed character is not one (F1...F12, arrows,
// Space, Return, Tab, Delete, Escape, and − for kNSKeyCodeMinus), else NULL.
const char *nsShortcutKeyLabel(unsigned keyCode);
// Builds out from a recorded key. key is the typed label for keys
// nsShortcutKeyLabel does not name: 1...8 bytes, no spaces or control
// characters. false, out untouched, when the shortcut or label is not allowed.
bool nsShortcutMake(unsigned keyCode, unsigned modifiers, const char *key, NSShortcut *out);
// The name nsShortcutMake would show (⌃⌥⇧⌘ and the label), allowed or not,
// so a refusal can say what was pressed. false when the label is not one.
bool nsShortcutName(unsigned keyCode, unsigned modifiers, const char *key, char *buf,
                    size_t size);
// The saved shortcuts file: one "lower" or "raise" line each,
// "<word> <keyCode> <modifiers> <label>". A missing, broken or not allowed
// line keeps that id's default; the same shortcut on both lines keeps both
// defaults. Returns a bit per id (1 << (id - 1)) read from text.
unsigned nsShortcutsParse(const char *text, NSShortcut out[2]);
// nsShortcutsParse, and refused[i] is the name of id i + 1's line when it was
// well formed but this build's rule refuses it (an old lone ⌃K, ⌘⇧K, ⌥⇧K),
// so its default is in use; "" otherwise. refused may be NULL.
unsigned nsShortcutsParseRefused(const char *text, NSShortcut out[2], char refused[][40]);
// The one notice for refused saved lines: "Your shortcut ⌃K no longer works.
// Now using ⌃⌥⌘=." or, for both, "Your shortcuts ⌃K and ⌃J no longer work.
// Now using ⌃⌥⌘− and ⌃⌥⌘=." NULL or "" old names are skipped; 0 and "" when
// none. Returns the full length, like snprintf.
int nsShortcutDroppedNotice(const char *oldLower, const char *nowLower, const char *oldRaise,
                            const char *nowRaise, char *buf, size_t size);
// Whether a candidate shortcut is free right now (no macOS or app clash).
typedef bool (*NSShortcutUsable)(const NSShortcut *shortcut, void *context);
// A shortcut to suggest instead of keyCode with modifiers: the same key (and
// ⇧, if pressed) with ⌃⌥, ⌥⌘, ⌃⌘ or ⌃⌥⌘, those that keep every pressed
// modifier first, fewest added first. Each must pass nsShortcutMake, differ
// from what was pressed and from other (may be NULL), and pass usable (may
// be NULL). false, out untouched, when none does.
bool nsShortcutSuggest(unsigned keyCode, unsigned modifiers, const char *key,
                       const NSShortcut *other, NSShortcutUsable usable, void *context,
                       NSShortcut *out);
// Why the recorder refused a key, for the note under the shortcut.
typedef enum {
  kNSRefusalOtherApps = 0,  // lone ⌘: "Other apps use ⌘K."
  kNSRefusalModifiers,      // too few modifiers: "Add two of ⌃ ⌥ ⌘."
  kNSRefusalSystem,         // a macOS shortcut: "Your Mac uses ⌃⌘Q."
  kNSRefusalApp,            // another app's hotkey: "Another app has ⌥⌘K."
  kNSRefusalOtherKey,       // the other warmth key has it
  kNSRefusalKey,            // no usable label, or registering failed
  kNSRefusalSave,           // the shortcuts file was not written
} NSShortcutRefusal;
// The note for why, NUL-terminated and cut to fit. pressed is the pressed
// shortcut's name. The first four end in "Try <suggestion>." when suggestion
// is a name, else "Pick a new one." Returns the full length, like snprintf.
int nsShortcutRefusal(NSShortcutRefusal why, const char *pressed, const char *suggestion,
                      char *buf, size_t size);
// The file text for shortcuts, NUL-terminated and cut to fit. Returns the
// full length, like snprintf.
int nsShortcutsFormat(const NSShortcut shortcuts[2], char *buf, size_t size);
bool nsShortcutSame(const NSShortcut *a, const NSShortcut *b);

typedef enum {
  kNSShortcutReady = 0,
  kNSShortcutTakenBySystem,  // a macOS shortcut (CopySymbolicHotKeys)
  kNSShortcutTakenByApp,     // eventHotKeyExistsErr: another app has it
  kNSShortcutFailed,         // any other registration error
} NSShortcutState;
// Short status for Settings: "On" when ready.
const char *nsShortcutStateLabel(NSShortcutState state);
// The notice for id's shortcut in state, NUL-terminated and cut to fit.
// Returns the full length, like snprintf; 0 and "" for ready.
int nsShortcutNotice(unsigned hotKeyID, const char *name, NSShortcutState state, char *buf,
                     size_t size);

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

#endif
