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

#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L  // mkstemp and fchmod under -std=c11 on glibc
#endif

#include "NightshiftLogic.h"
#include <limits.h>
#include <errno.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

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

bool nsShortcutHeld(unsigned modifiers, bool keyDown, unsigned heldModifiers) {
  return keyDown && heldModifiers == modifiers;
}

bool nsHotKeyDuringMenu(double eventTime, double openedAt, double closedAt, bool polled) {
  if (!polled || openedAt < 0 || eventTime < openedAt) {
    return false;
  }
  return closedAt < openedAt || eventTime <= closedAt;
}

static const unsigned kShortcutModifiers =
    kNSHotKeyCommand | kNSHotKeyShift | kNSHotKeyOption | kNSHotKeyControl;

static bool isFunctionKey(unsigned keyCode) {
  switch (keyCode) {
    case 0x7A: case 0x78: case 0x63: case 0x76: case 0x60: case 0x61:
    case 0x62: case 0x64: case 0x65: case 0x6D: case 0x67: case 0x6F:
      return true;
    default:
      return false;
  }
}

static const unsigned kShortcutStrong = kNSHotKeyCommand | kNSHotKeyOption | kNSHotKeyControl;

static unsigned bitCount(unsigned value) {
  unsigned n = 0;
  for (; value != 0; value &= value - 1) {
    n++;
  }
  return n;
}

bool nsShortcutAllowed(unsigned keyCode, unsigned modifiers) {
  if (keyCode >= 128 || (modifiers & ~kShortcutModifiers) != 0) {
    return false;
  }
  unsigned strong = modifiers & kShortcutStrong;
  if (strong == 0) {
    return false;
  }
  // These hotkeys are global, so one of ⌘, ⌥ or ⌃ with any other key would
  // take ⌘Q, ⌘W, ⌥E, ⌃C, ⌃D, ⌃A and the like from every app and Terminal.
  // ⇧ doesn't help, since ⌘⇧Z and ⌃⇧A are app shortcuts too. Only F-keys
  // get by with one; every other key, arrows and Space included, needs two.
  return isFunctionKey(keyCode) || bitCount(strong) >= 2;
}

const char *nsShortcutKeyLabel(unsigned keyCode) {
  switch (keyCode) {
    case kNSKeyCodeMinus: return "\u2212";
    case 0x7A: return "F1";
    case 0x78: return "F2";
    case 0x63: return "F3";
    case 0x76: return "F4";
    case 0x60: return "F5";
    case 0x61: return "F6";
    case 0x62: return "F7";
    case 0x64: return "F8";
    case 0x65: return "F9";
    case 0x6D: return "F10";
    case 0x67: return "F11";
    case 0x6F: return "F12";
    case 0x7B: return "\u2190";
    case 0x7C: return "\u2192";
    case 0x7D: return "\u2193";
    case 0x7E: return "\u2191";
    case 0x31: return "Space";
    case 0x24: return "\u21A9";
    case 0x30: return "\u21E5";
    case 0x33: return "\u232B";
    case 0x35: return "\u238B";
    default: return NULL;
  }
}

static bool labelAllowed(const char *key) {
  if (key == NULL) {
    return false;
  }
  size_t n = strlen(key);
  if (n == 0 || n > 8) {
    return false;
  }
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)key[i];
    if (c <= 0x20 || c == 0x7F) {
      return false;
    }
  }
  return true;
}

static const char *shortcutLabel(unsigned keyCode, const char *key) {
  const char *label = nsShortcutKeyLabel(keyCode);
  return label != NULL ? label : key;
}

bool nsShortcutName(unsigned keyCode, unsigned modifiers, const char *key, char *buf,
                    size_t size) {
  const char *label = shortcutLabel(keyCode, key);
  if (buf == NULL || size == 0 || !labelAllowed(label)) {
    return false;
  }
  int n = snprintf(buf, size, "%s%s%s%s%s", (modifiers & kNSHotKeyControl) ? "\u2303" : "",
                   (modifiers & kNSHotKeyOption) ? "\u2325" : "",
                   (modifiers & kNSHotKeyShift) ? "\u21E7" : "",
                   (modifiers & kNSHotKeyCommand) ? "\u2318" : "", label);
  return n >= 0 && (size_t)n < size;
}

bool nsShortcutMake(unsigned keyCode, unsigned modifiers, const char *key, NSShortcut *out) {
  if (out == NULL || !nsShortcutAllowed(keyCode, modifiers)) {
    return false;
  }
  NSShortcut made = {keyCode, modifiers, "", ""};
  if (!nsShortcutName(keyCode, modifiers, key, made.name, sizeof made.name)) {
    return false;
  }
  snprintf(made.key, sizeof made.key, "%s", shortcutLabel(keyCode, key));
  *out = made;
  return true;
}

bool nsShortcutDefault(unsigned hotKeyID, NSShortcut *out) {
  NSShortcut none = {0, 0, "", ""};
  if (out == NULL) {
    return false;
  }
  *out = none;
  const unsigned mods = kNSHotKeyCommand | kNSHotKeyOption | kNSHotKeyControl;
  if (hotKeyID == 1) {
    return nsShortcutMake(kNSKeyCodeMinus, mods, NULL, out);
  }
  if (hotKeyID == 2) {
    return nsShortcutMake(kNSKeyCodeEqual, mods, "=", out);
  }
  return false;
}

bool nsShortcutSame(const NSShortcut *a, const NSShortcut *b) {
  return a != NULL && b != NULL && a->keyCode == b->keyCode && a->modifiers == b->modifiers;
}

static const char *const kShortcutWords[2] = {"lower", "raise"};

// Decimal digits only; false on anything else or a value past UINT_MAX.
static bool parseUnsigned(const char *text, unsigned *out) {
  if (text[0] < '0' || text[0] > '9') {
    return false;
  }
  errno = 0;
  char *end = NULL;
  unsigned long value = strtoul(text, &end, 10);
  if (errno != 0 || *end != '\0' || value > UINT_MAX) {
    return false;
  }
  *out = (unsigned)value;
  return true;
}

unsigned nsShortcutsParse(const char *text, NSShortcut out[2]) {
  return nsShortcutsParseRefused(text, out, NULL);
}

unsigned nsShortcutsParseRefused(const char *text, NSShortcut out[2], char refused[][40]) {
  if (refused != NULL) {
    refused[0][0] = '\0';
    refused[1][0] = '\0';
  }
  nsShortcutDefault(1, &out[0]);
  nsShortcutDefault(2, &out[1]);
  unsigned found = 0;
  const char *line = text;
  while (line != NULL && *line != '\0') {
    const char *nl = strchr(line, '\n');
    size_t len = nl != NULL ? (size_t)(nl - line) : strlen(line);
    char buf[96];
    if (len < sizeof buf) {
      memcpy(buf, line, len);
      while (len > 0 && (buf[len - 1] == '\r' || buf[len - 1] == ' ' || buf[len - 1] == '\t')) {
        len--;
      }
      buf[len] = '\0';
      char word[8];
      char codeText[16];
      char modText[16];
      unsigned keyCode = 0;
      unsigned modifiers = 0;
      char key[16];
      int used = 0;
      if (sscanf(buf, "%7s %15s %15s %15s%n", word, codeText, modText, key, &used) == 4 &&
          buf[used] == '\0' && parseUnsigned(codeText, &keyCode) &&
          parseUnsigned(modText, &modifiers)) {
        for (unsigned i = 0; i < 2; i++) {
          NSShortcut made;
          if (strcmp(word, kShortcutWords[i]) != 0 || (found & (1u << i))) {
            continue;
          }
          if (nsShortcutMake(keyCode, modifiers, key, &made)) {
            out[i] = made;
            found |= 1u << i;
          } else if (refused != NULL && refused[i][0] == '\0' && keyCode < 128 &&
                     (modifiers & ~kShortcutModifiers) == 0 &&
                     !nsShortcutAllowed(keyCode, modifiers) &&
                     !nsShortcutName(keyCode, modifiers, key, refused[i], 40)) {
            refused[i][0] = '\0';
          }
        }
      }
    }
    line = nl != NULL ? nl + 1 : NULL;
  }
  if (refused != NULL) {
    for (unsigned i = 0; i < 2; i++) {
      if (found & (1u << i)) {
        refused[i][0] = '\0';
      }
    }
  }
  if (nsShortcutSame(&out[0], &out[1])) {
    nsShortcutDefault(1, &out[0]);
    nsShortcutDefault(2, &out[1]);
    return 0;
  }
  return found;
}

static bool named(const char *name) {
  return name != NULL && name[0] != '\0';
}

int nsShortcutDroppedNotice(const char *oldLower, const char *nowLower, const char *oldRaise,
                            const char *nowRaise, char *buf, size_t size) {
  bool lower = named(oldLower);
  bool raise = named(oldRaise);
  if (lower && raise) {
    return snprintf(buf, size,
                    "Your shortcuts %s and %s no longer work. Now using %s and %s.", oldLower,
                    oldRaise, nowLower != NULL ? nowLower : "", nowRaise != NULL ? nowRaise : "");
  }
  if (lower || raise) {
    const char *now = lower ? nowLower : nowRaise;
    return snprintf(buf, size, "Your shortcut %s no longer works. Now using %s.",
                    lower ? oldLower : oldRaise, now != NULL ? now : "");
  }
  if (size > 0) {
    buf[0] = '\0';
  }
  return 0;
}

bool nsShortcutSuggest(unsigned keyCode, unsigned modifiers, const char *key,
                       const NSShortcut *other, NSShortcutUsable usable, void *context,
                       NSShortcut *out) {
  static const unsigned candidates[4] = {
      kNSHotKeyControl | kNSHotKeyOption,
      kNSHotKeyOption | kNSHotKeyCommand,
      kNSHotKeyControl | kNSHotKeyCommand,
      kNSHotKeyControl | kNSHotKeyOption | kNSHotKeyCommand,
  };
  if (out == NULL) {
    return false;
  }
  unsigned pressed = modifiers & kShortcutStrong;
  unsigned shift = modifiers & kNSHotKeyShift;
  // First the candidates that keep every pressed modifier (⌘K suggests
  // ⌥⌘K), then the rest; the list is already fewest modifiers first.
  for (int pass = 0; pass < 2; pass++) {
    for (int i = 0; i < 4; i++) {
      bool keeps = (candidates[i] & pressed) == pressed;
      if (keeps != (pass == 0)) {
        continue;
      }
      unsigned mods = candidates[i] | shift;
      NSShortcut made;
      if (mods == modifiers || !nsShortcutMake(keyCode, mods, key, &made) ||
          (other != NULL && nsShortcutSame(&made, other)) ||
          (usable != NULL && !usable(&made, context))) {
        continue;
      }
      *out = made;
      return true;
    }
  }
  return false;
}

int nsShortcutRefusal(NSShortcutRefusal why, const char *pressed, const char *suggestion,
                      char *buf, size_t size) {
  const char *pick = "That key won't work. Pick a new one.";
  char first[96];
  switch (why) {
    case kNSRefusalModifiers:
      snprintf(first, sizeof first, "Add two of \u2303 \u2325 \u2318.");
      break;
    case kNSRefusalOtherApps:
    case kNSRefusalSystem:
    case kNSRefusalApp:
      if (!named(pressed)) {
        return snprintf(buf, size, "%s", pick);
      }
      snprintf(first, sizeof first, "%s %s.",
               why == kNSRefusalOtherApps ? "Other apps use"
               : why == kNSRefusalSystem  ? "Your Mac uses"
                                          : "Another app has",
               pressed);
      break;
    case kNSRefusalOtherKey:
      if (!named(pressed)) {
        return snprintf(buf, size, "%s", pick);
      }
      return snprintf(buf, size, "The other key has %s. Pick a new one.", pressed);
    case kNSRefusalSave:
      return snprintf(buf, size, "That didn't save. Try again.");
    case kNSRefusalKey:
    default:
      return snprintf(buf, size, "%s", pick);
  }
  if (named(suggestion)) {
    return snprintf(buf, size, "%s Try %s.", first, suggestion);
  }
  return snprintf(buf, size, "%s Pick a new one.", first);
}

int nsShortcutsFormat(const NSShortcut shortcuts[2], char *buf, size_t size) {
  return snprintf(buf, size, "%s %u %u %s\n%s %u %u %s\n", kShortcutWords[0],
                  shortcuts[0].keyCode, shortcuts[0].modifiers, shortcuts[0].key,
                  kShortcutWords[1], shortcuts[1].keyCode, shortcuts[1].modifiers,
                  shortcuts[1].key);
}

const char *nsShortcutStateLabel(NSShortcutState state) {
  switch (state) {
    case kNSShortcutReady: return "On";
    case kNSShortcutTakenBySystem: return "Used by macOS";
    case kNSShortcutTakenByApp: return "Used by another app";
    case kNSShortcutFailed: return "Couldn't turn on";
  }
  return "Couldn't turn on";
}

int nsShortcutNotice(unsigned hotKeyID, const char *name, NSShortcutState state, char *buf,
                     size_t size) {
  const char *what = hotKeyID == 1 ? "lower warmth" : hotKeyID == 2 ? "raise warmth" : "warmth";
  const char *shown = name != NULL && name[0] != '\0' ? name : "A warmth shortcut";
  switch (state) {
    case kNSShortcutReady:
      if (size > 0) {
        buf[0] = '\0';
      }
      return 0;
    case kNSShortcutTakenBySystem:
      return snprintf(buf, size, "%s (%s) is a macOS shortcut. Pick another in Settings.", shown,
                      what);
    case kNSShortcutTakenByApp:
      return snprintf(buf, size, "%s (%s) is already used by another app.", shown, what);
    case kNSShortcutFailed:
      break;
  }
  return snprintf(buf, size, "%s (%s) couldn't be turned on.", shown, what);
}

// MARK: Daemon socket commands

static bool commandWord(const char *line, const char *word, bool bare, bool valued) {
  size_t n = strlen(word);
  if (strncmp(line, word, n) != 0) {
    return false;
  }
  if (line[n] == '\0') {
    return bare;
  }
  return valued && line[n] == ' ';
}

NSDaemonCommand nsDaemonCommand(const char *line) {
  if (line == NULL) {
    return kNSCommandUnknown;
  }
  if (strcmp(line, "status") == 0) {
    return kNSCommandStatus;
  }
  if (commandWord(line, "max", false, true)) {
    return kNSCommandMax;
  }
  if (commandWord(line, "ramp", false, true)) {
    return kNSCommandRamp;
  }
  static const struct {
    const char *word;
    NSDaemonCommand command;
  } words[] = {
      {"schedule", kNSCommandSchedule}, {"clock", kNSCommandClock}, {"login", kNSCommandLogin},
      {"dark", kNSCommandDark},         {"tone", kNSCommandTone},
  };
  for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
    if (commandWord(line, words[i].word, true, true)) {
      return words[i].command;
    }
  }
  const char *p = line;
  while (*p == ' ' || *p == '\t') {
    p++;
  }
  if (*p == '+' || *p == '-') {
    p++;
  }
  if (*p >= '0' && *p <= '9') {
    return kNSCommandWarmth;
  }
  return kNSCommandUnknown;
}

// MARK: Saved settings

bool nsReadSavedNumber(const char *path, long lo, long hi, long *value) {
  if (path == NULL || value == NULL) {
    return false;
  }
  FILE *file = fopen(path, "r");
  if (file == NULL) {
    return false;
  }
  char text[64];
  size_t used = fread(text, 1, sizeof(text) - 1, file);
  bool more = fgetc(file) != EOF;
  fclose(file);
  if (more) {
    return false;
  }
  text[used] = '\0';
  if (strlen(text) != used) {
    return false;
  }
  char *end = NULL;
  long parsed = strtol(text, &end, 10);
  if (end == text) {
    return false;
  }
  while (*end == ' ' || *end == '\n' || *end == '\r') {
    end++;
  }
  if (*end != '\0' || parsed < lo || parsed > hi) {
    return false;
  }
  *value = parsed;
  return true;
}

bool nsWriteSavedNumber(const char *path, long value) {
  if (path == NULL) {
    return false;
  }
  char temp[1100];
  if (snprintf(temp, sizeof(temp), "%s.XXXXXX", path) >= (int)sizeof(temp)) {
    return false;
  }
  int fd = mkstemp(temp);
  if (fd < 0) {
    return false;
  }
  char text[32];
  int length = snprintf(text, sizeof(text), "%ld\n", value);
  bool ok = length > 0 && write(fd, text, (size_t)length) == (ssize_t)length &&
            fchmod(fd, S_IRUSR | S_IWUSR) == 0;
  ok = close(fd) == 0 && ok;
  if (!ok || rename(temp, path) != 0) {
    unlink(temp);
    return false;
  }
  return true;
}

bool nsSectionKept(const char *name) {
  return name != NULL && (strcmp(name, "ramp") == 0 || strcmp(name, "appearance") == 0);
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
