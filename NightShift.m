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

#import "NightShift.h"
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static BOOL methodMatches(id client, SEL sel, const char *expected) {
  Method method = class_getInstanceMethod([client class], sel);
  const char *encoding = method ? method_getTypeEncoding(method) : NULL;
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

CBBlueLightClient *makeClient(void) {
  CBBlueLightClient *client = [[CBBlueLightClient alloc] init];
  if (client == nil ||
      !methodMatches(client, @selector(setStrength:commit:), "B24@0:8f16B20") ||
      !methodMatches(client, @selector(setEnabled:), "B20@0:8B16") ||
      !methodMatches(client, @selector(getStrength:), "B24@0:8^f16")) {
    return nil;
  }
  return client;
}

BOOL readStrength(CBBlueLightClient *client, long *stored) {
  float actual = 0;
  if (![client getStrength:&actual]) {
    return NO;
  }
  *stored = lroundf(actual * 100.0f);
  return YES;
}

BOOL applyStrength(CBBlueLightClient *client, long value, long *stored) {
  if (value == 0) {
    if (![client setStrength:0 commit:YES] || ![client setEnabled:NO]) {
      return NO;
    }
    *stored = 0;
    return YES;
  }
  float strength = (float)value / 100.0f;
  if (![client setStrength:strength commit:YES] || ![client setEnabled:YES]) {
    return NO;
  }
  return readStrength(client, stored);
}

BOOL stageStrength(CBBlueLightClient *client, long value) {
  if (value < 1 || value > 100) {
    return NO;
  }
  return [client setStrength:(float)value / 100.0f commit:YES];
}

BOOL readStatus(CBBlueLightClient *client, BLStatus *status) {
  if (!methodMatches(client, @selector(getBlueLightStatus:),
                     "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16")) {
    return NO;
  }
  memset(status, 0, sizeof(*status));
  return [client getBlueLightStatus:status];
}

static BOOL onlyChars(NSString *text, NSString *allowed, NSUInteger maxLen) {
  if (text == nil || text.length == 0 || text.length > maxLen) {
    return NO;
  }
  NSCharacterSet *ok =
      [NSCharacterSet characterSetWithCharactersInString:allowed];
  return [text rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

BOOL parseNumber(const char *s, long min, long max, long *out) {
  if (s == NULL || out == NULL) {
    return NO;
  }
  char *end = NULL;
  long value = strtol(s, &end, 10);
  if (end == s || *end != '\0' || value < min || value > max) {
    return NO;
  }
  *out = value;
  return YES;
}

BOOL parseMaxText(NSString *text, long *out) {
  if (!onlyChars(text, @"0123456789% \t", 8)) {
    return NO;
  }
  NSString *trimmed = [text
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                           whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasSuffix:@"%"]) {
    trimmed = [[trimmed substringToIndex:trimmed.length - 1]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  }
  return parseNumber(trimmed.UTF8String, 1, 100, out);
}

BOOL parseClockText(NSString *text, int *out) {
  if (out == NULL ||
      !onlyChars(text, @"0123456789:apmAPM. \u00a0\u202f\u2007\u2009", 32)) {
    return NO;
  }
  NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSMutableString *raw = [NSMutableString stringWithString:text];
  for (NSString *mark in @[ @"\u00a0", @"\u202f", @"\u2007", @"\u2009" ]) {
    [raw replaceOccurrencesOfString:mark
                          withString:@" "
                             options:0
                               range:NSMakeRange(0, raw.length)];
  }
  NSString *flat = [[[raw componentsSeparatedByCharactersInSet:spaces]
      componentsJoinedByString:@""] lowercaseString];
  flat = [flat stringByReplacingOccurrencesOfString:@"." withString:@""];
  if (flat.length == 0) {
    return NO;
  }
  int ampm = 0;
  if ([flat hasSuffix:@"am"]) {
    ampm = 1;
    flat = [flat substringToIndex:flat.length - 2];
  } else if ([flat hasSuffix:@"pm"]) {
    ampm = 2;
    flat = [flat substringToIndex:flat.length - 2];
  }
  NSArray<NSString *> *parts = [flat componentsSeparatedByString:@":"];
  if (parts.count < 1 || parts.count > 2 || (ampm == 0 && parts.count == 1)) {
    return NO;
  }
  long hour = 0;
  long minute = 0;
  if (!parseNumber(parts[0].UTF8String, 0, 23, &hour)) {
    return NO;
  }
  if (parts.count == 2 && !parseNumber(parts[1].UTF8String, 0, 59, &minute)) {
    return NO;
  }
  if (ampm != 0) {
    if (hour < 1 || hour > 12) {
      return NO;
    }
    if (hour == 12) {
      hour = 0;
    }
    if (ampm == 2) {
      hour += 12;
    }
  } else if (hour >= 1 && hour <= 12) {
    return NO;
  }
  *out = (int)(hour * 60 + minute);
  return YES;
}

int minutesBetween(int from, int to) {
  return (to - from + 1440) % 1440;
}

BOOL insideWindow(int start, int end, int now) {
  int length = minutesBetween(start, end);
  if (length == 0) {
    return NO;
  }
  return minutesBetween(start, now) < length;
}

long glideWarmth(int fromMinute, int toMinute, long fromValue, long maxv,
                 int now) {
  if (fromMinute < 0 || toMinute < 0) {
    return -1;
  }
  int span = minutesBetween(fromMinute, toMinute);
  int elapsed = minutesBetween(fromMinute, now);
  if (span == 0 || elapsed >= span) {
    return maxv;
  }
  long value = fromValue + (maxv - fromValue) * elapsed / span;
  if (value < 1) {
    return 1;
  }
  if (value > 100) {
    return 100;
  }
  return value;
}

void splitClock(int minute, BOOL h24, int *hour, int *min, BOOL *pm) {
  int h = minute / 60;
  *min = minute % 60;
  *pm = h >= 12;
  if (h24) {
    *hour = h;
    return;
  }
  int hr = h % 12;
  *hour = hr == 0 ? 12 : hr;
}

int joinClock(BOOL h24, int hour, int min, BOOL pm) {
  if (h24) {
    return hour * 60 + min;
  }
  int h = hour % 12;
  if (pm) {
    h += 12;
  }
  return h * 60 + min;
}

static int gHourCycle = 0;

static NSString *clockPath(void) {
  return [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"]
      stringByAppendingPathComponent:@"clock"];
}

static BOOL macUses24Hour(void) {
  NSString *format =
      [NSDateFormatter dateFormatFromTemplate:@"j"
                                      options:0
                                       locale:[NSLocale currentLocale]];
  return [format rangeOfString:@"a"].location == NSNotFound;
}

BOOL hourCycleIs24(void) {
  if (gHourCycle == 24) {
    return YES;
  }
  if (gHourCycle == 12) {
    return NO;
  }
  return macUses24Hour();
}

void readHourCycle(void) {
  NSString *text = [NSString stringWithContentsOfFile:clockPath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  if ([text hasPrefix:@"24"]) {
    gHourCycle = 24;
  } else if ([text hasPrefix:@"12"]) {
    gHourCycle = 12;
  } else {
    gHourCycle = 0;
  }
}

BOOL writeHourCycle(int cycle) {
  if (cycle != 12 && cycle != 24) {
    return NO;
  }
  NSString *text = [NSString stringWithFormat:@"%d\n", cycle];
  if (![text writeToFile:clockPath()
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL]) {
    return NO;
  }
  [[NSFileManager defaultManager]
      setAttributes:@{NSFilePosixPermissions : @0600}
           ofItemAtPath:clockPath()
                  error:NULL];
  gHourCycle = cycle;
  return YES;
}

NSString *clockString(int minute) {
  if (minute < 0 || minute >= 1440) {
    return @"";
  }
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  if (gHourCycle == 24) {
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"HH:mm";
  } else if (gHourCycle == 12) {
    fmt.locale = [NSLocale currentLocale];
    fmt.dateFormat = @"h:mm a";
  } else {
    fmt.timeStyle = NSDateFormatterShortStyle;
    fmt.dateStyle = NSDateFormatterNoStyle;
  }
  NSDateComponents *parts = [[NSDateComponents alloc] init];
  parts.year = 2026;
  parts.month = 1;
  parts.day = 1;
  parts.hour = minute / 60;
  parts.minute = minute % 60;
  NSDate *date = [[NSCalendar currentCalendar] dateFromComponents:parts];
  if (date == nil) {
    return @"";
  }
  return [fmt stringFromDate:date];
}

NSString *warmthSentence(long now, long maxv, const char *state, int full) {
  if (maxv < 0) {
    return [NSString stringWithFormat:@"%ld, no max set", now];
  }
  if (state != NULL && strcmp(state, "off") == 0) {
    return [NSString stringWithFormat:@"off, max %ld", maxv];
  }
  if (now == maxv) {
    return [NSString stringWithFormat:@"Warmth is at %ld%%", now];
  }
  if (full >= 0 && state != NULL && strcmp(state, "ramping") == 0) {
    return [NSString
        stringWithFormat:@"Warmth is at %ld%%, reaching %ld%% at %@", now,
                         maxv, clockString(full)];
  }
  return [NSString stringWithFormat:@"Warmth is at %ld%%, max %ld%%", now,
                                    maxv];
}
