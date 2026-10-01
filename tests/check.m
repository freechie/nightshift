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
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

static int gFailed = 0;

static void fail(NSString *name, NSString *detail) {
  fprintf(stderr, "fail %s: %s\n", name.UTF8String, detail.UTF8String);
  gFailed++;
}

static void expectLong(NSString *name, long got, long want) {
  if (got != want) {
    fail(name, [NSString stringWithFormat:@"got %ld want %ld", got, want]);
  }
}

static void expectBool(NSString *name, BOOL got, BOOL want) {
  if (got != want) {
    fail(name, [NSString stringWithFormat:@"got %d want %d", got, want]);
  }
}

static void expectText(NSString *name, NSString *got, NSString *want) {
  if (got == nil || ![got isEqualToString:want]) {
    fail(name, [NSString stringWithFormat:@"got [%@] want [%@]", got, want]);
  }
}

static NSString *plainSpaces(NSString *text) {
  NSMutableString *raw = [NSMutableString stringWithString:text ?: @""];
  for (NSString *mark in @[ @"\u00a0", @"\u202f", @"\u2007", @"\u2009" ]) {
    [raw replaceOccurrencesOfString:mark
                          withString:@" "
                             options:0
                               range:NSMakeRange(0, raw.length)];
  }
  return raw;
}

static void checkParsers(void) {
  long number = -1;
  expectBool(@"parseNumber 40", parseNumber("40", 0, 100, &number), YES);
  expectLong(@"parseNumber 40 value", number, 40);
  expectBool(@"parseNumber 0", parseNumber("0", 0, 100, &number), YES);
  expectLong(@"parseNumber 0 value", number, 0);
  expectBool(@"parseNumber 100", parseNumber("100", 0, 100, &number), YES);
  expectBool(@"parseNumber 101", parseNumber("101", 0, 100, &number), NO);
  expectBool(@"parseNumber -1", parseNumber("-1", 0, 100, &number), NO);
  expectBool(@"parseNumber trailing", parseNumber("40x", 0, 100, &number), NO);
  expectBool(@"parseNumber empty", parseNumber("", 0, 100, &number), NO);
  expectBool(@"parseNumber null", parseNumber(NULL, 0, 100, &number), NO);

  long maxv = 0;
  expectBool(@"parseMax 60", parseMaxText(@"60", &maxv), YES);
  expectLong(@"parseMax 60 value", maxv, 60);
  expectBool(@"parseMax percent", parseMaxText(@"60%", &maxv), YES);
  expectLong(@"parseMax percent value", maxv, 60);
  expectBool(@"parseMax spaced", parseMaxText(@" 60 % ", &maxv), YES);
  expectLong(@"parseMax spaced value", maxv, 60);
  expectBool(@"parseMax 1", parseMaxText(@"1", &maxv), YES);
  expectBool(@"parseMax 100", parseMaxText(@"100", &maxv), YES);
  expectBool(@"parseMax 0", parseMaxText(@"0", &maxv), NO);
  expectBool(@"parseMax 101", parseMaxText(@"101", &maxv), NO);
  expectBool(@"parseMax inject", parseMaxText(@"60;reboot", &maxv), NO);

  int minute = -1;
  expectBool(@"clock 8:30pm", parseClockText(@"8:30pm", &minute), YES);
  expectLong(@"clock 8:30pm value", minute, 20 * 60 + 30);
  expectBool(@"clock 8:30 PM", parseClockText(@"8:30 PM", &minute), YES);
  expectLong(@"clock 8:30 PM value", minute, 20 * 60 + 30);
  expectBool(@"clock 20:30", parseClockText(@"20:30", &minute), YES);
  expectLong(@"clock 20:30 value", minute, 20 * 60 + 30);
  expectBool(@"clock 12am", parseClockText(@"12:00am", &minute), YES);
  expectLong(@"clock 12am value", minute, 0);
  expectBool(@"clock 12pm", parseClockText(@"12:00pm", &minute), YES);
  expectLong(@"clock 12pm value", minute, 12 * 60);
  expectBool(@"clock 0:00", parseClockText(@"0:00", &minute), YES);
  expectLong(@"clock 0:00 value", minute, 0);
  expectBool(@"clock 8:30 bare", parseClockText(@"8:30", &minute), NO);
  expectBool(@"clock 24:00", parseClockText(@"24:00", &minute), NO);
  expectBool(@"clock inject", parseClockText(@"8:30pm;id", &minute), NO);
  expectBool(@"clock 8:60pm", parseClockText(@"8:60pm", &minute), NO);
  expectBool(@"clock 0:30am", parseClockText(@"0:30am", &minute), NO);
}

static void checkMath(void) {
  expectLong(@"between same", minutesBetween(100, 100), 0);
  expectLong(@"between midnight", minutesBetween(23 * 60, 60), 120);
  expectBool(@"window start", insideWindow(22 * 60, 6 * 60, 22 * 60), YES);
  expectBool(@"window inside", insideWindow(22 * 60, 6 * 60, 23 * 60), YES);
  expectBool(@"window end", insideWindow(22 * 60, 6 * 60, 6 * 60), NO);
  expectBool(@"window empty", insideWindow(10 * 60, 10 * 60, 10 * 60), NO);

  expectLong(@"glide unset", glideWarmth(-1, 120, 1, 90, 0), -1);
  expectLong(@"glide done", glideWarmth(0, 0, 1, 90, 0), 90);
  expectLong(@"glide up", glideWarmth(0, 120, 1, 90, 60), 45);
  expectLong(@"glide down", glideWarmth(0, 90, 60, 40, 30), 54);
  expectLong(@"glide floor", glideWarmth(0, 10, 0, 5, 0), 1);
  expectLong(@"glide cap", glideWarmth(0, 2, 100, 200, 1), 100);

  int hour = 0;
  int min = 0;
  BOOL pm = NO;
  splitClock(0, NO, &hour, &min, &pm);
  expectLong(@"split 12am hour", hour, 12);
  expectLong(@"split 12am min", min, 0);
  expectBool(@"split 12am pm", pm, NO);
  expectLong(@"join 12am", joinClock(NO, 12, 0, NO), 0);

  splitClock(12 * 60, NO, &hour, &min, &pm);
  expectLong(@"split 12pm hour", hour, 12);
  expectBool(@"split 12pm pm", pm, YES);
  expectLong(@"join 12pm", joinClock(NO, 12, 0, YES), 12 * 60);

  splitClock(20 * 60 + 30, NO, &hour, &min, &pm);
  expectLong(@"split 8:30 hour", hour, 8);
  expectLong(@"split 8:30 min", min, 30);
  expectBool(@"split 8:30 pm", pm, YES);
  expectLong(@"join 8:30", joinClock(NO, 8, 30, YES), 20 * 60 + 30);

  splitClock(20 * 60 + 30, YES, &hour, &min, &pm);
  expectLong(@"split 20:30 hour", hour, 20);
  expectLong(@"split 20:30 min", min, 30);
  expectLong(@"join 20:30", joinClock(YES, 20, 30, NO), 20 * 60 + 30);
}

static void checkSentences(void) {
  char home[] = "/tmp/nightshift-test-XXXXXX";
  if (mkdtemp(home) == NULL) {
    fail(@"temp home", @"mkdtemp");
    return;
  }
  setenv("HOME", home, 1);
  NSString *dir = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"];
  NSError *error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error]) {
    fail(@"temp dir", error.localizedDescription);
    return;
  }

  readHourCycle();
  expectBool(@"cycle follows mac", hourCycleIs24(),
             [[NSDateFormatter dateFormatFromTemplate:@"j"
                                              options:0
                                               locale:[NSLocale currentLocale]]
                 rangeOfString:@"a"]
                     .location == NSNotFound);
  expectBool(@"clock string present", clockString(22 * 60).length > 0, YES);

  expectBool(@"write 24", writeHourCycle(24), YES);
  expectBool(@"cycle is 24", hourCycleIs24(), YES);
  expectText(@"clock 22:00", clockString(22 * 60), @"22:00");
  expectText(@"ramping sentence",
             warmthSentence(40, 90, "ramping", 22 * 60),
             @"Warmth is at 40%, reaching 90% at 22:00");

  expectBool(@"write 12", writeHourCycle(12), YES);
  expectBool(@"cycle is 12", hourCycleIs24(), NO);
  expectText(@"clock 10:00 PM", plainSpaces(clockString(22 * 60)), @"10:00 PM");

  expectBool(@"write junk cycle", writeHourCycle(13), NO);
  expectText(@"no max", warmthSentence(40, -1, "idle", -1), @"40, no max set");
  expectText(@"off", warmthSentence(0, 90, "off", -1), @"off, max 90");
  expectText(@"at max", warmthSentence(90, 90, "holding", -1),
             @"Warmth is at 90%");
  expectText(@"holding", warmthSentence(40, 90, "holding", 22 * 60),
             @"Warmth is at 40%, max 90%");

  [[NSFileManager defaultManager] removeItemAtPath:@(home) error:NULL];
}

int main(void) {
  @autoreleasepool {
    checkParsers();
    checkMath();
    checkSentences();
    if (gFailed != 0) {
      fprintf(stderr, "%d failed\n", gFailed);
      return 1;
    }
    printf("unit ok\n");
    return 0;
  }
}
