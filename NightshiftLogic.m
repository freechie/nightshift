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

NSWarmthShortcut nsWarmthShortcut(unsigned hotKeyID) {
  const unsigned mods = kNSHotKeyCommand | kNSHotKeyOption | kNSHotKeyControl;
  NSWarmthShortcut none = {0, 0, ""};
  if (hotKeyID == 1) {
    NSWarmthShortcut lower = {kNSKeyCodeMinus, mods, "\u2303\u2325\u2318\u2212"};
    return lower;
  }
  if (hotKeyID == 2) {
    NSWarmthShortcut raise = {kNSKeyCodeEqual, mods, "\u2303\u2325\u2318="};
    return raise;
  }
  return none;
}

int nsWarmthShortcutFailure(unsigned hotKeyID, char *buf, size_t size) {
  NSWarmthShortcut shortcut = nsWarmthShortcut(hotKeyID);
  const char *name = shortcut.name[0] != '\0' ? shortcut.name : "A warmth shortcut";
  return snprintf(buf, size, "%s is already used by another app", name);
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
