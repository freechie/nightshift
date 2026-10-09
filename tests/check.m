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
#import <mach-o/dyld.h>
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
  expectBool(@"before full at", holdingFullAt(18 * 60, 8 * 60, 22 * 60, 21 * 60), NO);
  expectBool(@"at full at", holdingFullAt(18 * 60, 8 * 60, 22 * 60, 22 * 60), YES);
  expectBool(@"after full at", holdingFullAt(18 * 60, 8 * 60, 22 * 60, 23 * 60 + 30), YES);
  expectBool(@"holding next morning", holdingFullAt(18 * 60, 8 * 60, 22 * 60, 7 * 60), YES);
  expectBool(@"holding outside", holdingFullAt(18 * 60, 8 * 60, 22 * 60, 12 * 60), NO);
  expectBool(@"full at outside", holdingFullAt(18 * 60, 8 * 60, 10 * 60, 23 * 60), NO);

  expectLong(@"glide unset", glideWarmth(-1, 120, 1, 90, 0), -1);
  expectLong(@"glide done", glideWarmth(0, 0, 1, 90, 0), 90);
  expectLong(@"glide up", glideWarmth(0, 120, 1, 90, 60), 45);
  expectLong(@"glide down", glideWarmth(0, 90, 60, 40, 30), 54);
  expectLong(@"glide floor", glideWarmth(0, 10, 0, 5, 0), 1);
  expectLong(@"glide cap", glideWarmth(0, 2, 100, 200, 1), 100);
  expectLong(@"now stays below max", warmthCappedByMax(40, 90), 40);
  expectLong(@"now stays at max", warmthCappedByMax(90, 90), 90);
  expectLong(@"now follows max down", warmthCappedByMax(70, 40), 40);
  expectLong(@"off stays off", warmthCappedByMax(0, 1), 0);
  expectLong(@"now follows max to 1", warmthCappedByMax(100, 1), 1);

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
  useHourCycleForTests(0);
  expectBool(@"cycle follows mac", hourCycleIs24(),
             [[NSDateFormatter dateFormatFromTemplate:@"j"
                                              options:0
                                               locale:[NSLocale currentLocale]]
                 rangeOfString:@"a"]
                     .location == NSNotFound);
  expectBool(@"clock string present", clockString(22 * 60).length > 0, YES);

  useHourCycleForTests(24);
  expectBool(@"cycle is 24", hourCycleIs24(), YES);
  expectText(@"clock 22:00", clockString(22 * 60), @"22:00");
  expectText(@"ramping sentence",
             warmthSentence(40, 90, "ramping", 22 * 60),
             @"Warmth is at 40%, reaching 90% at 22:00");

  useHourCycleForTests(12);
  expectBool(@"cycle is 12", hourCycleIs24(), NO);
  expectText(@"clock 10:00 PM", plainSpaces(clockString(22 * 60)), @"10:00 PM");

  expectBool(@"write junk cycle", writeHourCycle(13), NO);
  expectText(@"no max", warmthSentence(40, -1, "idle", -1), @"40, no max set");
  expectText(@"off", warmthSentence(0, 90, "off", -1), @"off, max 90");
  expectText(@"at max", warmthSentence(90, 90, "holding", -1),
             @"Warmth is at 90%");
  expectText(@"holding", warmthSentence(40, 90, "holding", 22 * 60),
             @"Warmth is at 40%, max 90%");
}

static NSString *tokenFor(NSString *payload, const uint8_t *sig) {
  NSString *body = [[payload dataUsingEncoding:NSUTF8StringEncoding]
      base64EncodedStringWithOptions:0];
  NSString *signature = [[NSData dataWithBytes:sig length:64]
      base64EncodedStringWithOptions:0];
  return [NSString stringWithFormat:@"%@.%@", body, signature];
}

static void checkLicense(void) {
  static const uint8_t key[32] = {
      0xcd, 0xc9, 0x09, 0x4f, 0xd8, 0xad, 0x92, 0x37, 0xbf, 0xf1, 0xb4,
      0x45, 0xbc, 0x5a, 0x7b, 0x42, 0x61, 0x98, 0x8b, 0x45, 0xff, 0x00,
      0x07, 0x7d, 0x22, 0x34, 0x11, 0x43, 0xce, 0x35, 0x7c, 0x32};
  static const uint8_t forever[64] = {
      0x68, 0xb2, 0xdb, 0x5f, 0x9d, 0x86, 0x3a, 0x86, 0x8c, 0xb5, 0x8f,
      0x0b, 0x56, 0x73, 0x67, 0xd8, 0xee, 0x09, 0x0b, 0x7f, 0xeb, 0x1d,
      0x8f, 0x7b, 0xdb, 0x7d, 0x4d, 0x8a, 0xef, 0xe5, 0x72, 0xb7, 0x42,
      0x66, 0xdc, 0x8e, 0x4f, 0xc7, 0x96, 0x2b, 0xfd, 0x46, 0x8d, 0xc2,
      0xa5, 0x6b, 0xf4, 0x3b, 0x15, 0x94, 0x7f, 0x14, 0xf0, 0xb7, 0xae,
      0x59, 0x3a, 0xec, 0xd0, 0x3c, 0x77, 0x48, 0x2f, 0x06};
  static const uint8_t later[64] = {
      0xc7, 0x35, 0xfa, 0x71, 0xb8, 0x1d, 0xa1, 0x70, 0xf1, 0xef, 0x50,
      0xe8, 0x28, 0xe8, 0xa1, 0xe0, 0x96, 0x2e, 0xf7, 0x0d, 0x7d, 0x85,
      0xf7, 0x55, 0xde, 0xea, 0x88, 0x9c, 0xb6, 0xd5, 0xc5, 0x8d, 0x06,
      0x88, 0x6f, 0xd3, 0xe0, 0x98, 0xc8, 0x05, 0xfa, 0x27, 0xc7, 0xc2,
      0x6c, 0x01, 0x16, 0xd6, 0x5a, 0xb3, 0x37, 0xe6, 0x6c, 0x16, 0xa6,
      0xf0, 0x05, 0x3f, 0x85, 0x85, 0xc0, 0x52, 0xa0, 0x0c};
  static const uint8_t earlier[64] = {
      0x00, 0x75, 0x24, 0xf9, 0x4a, 0xb4, 0x37, 0x8f, 0xa4, 0x98, 0x0f,
      0x68, 0xbf, 0x3e, 0x5b, 0xe3, 0x62, 0xbd, 0x36, 0x80, 0x58, 0xd0,
      0xa3, 0xef, 0xec, 0xd3, 0xbc, 0xce, 0xd0, 0x1f, 0x67, 0x72, 0xfe,
      0xfd, 0xcb, 0xd3, 0xf6, 0x4c, 0xdd, 0x34, 0x76, 0x50, 0x81, 0xf1,
      0x37, 0x1e, 0xe3, 0x43, 0x65, 0x0d, 0xb9, 0x72, 0x5a, 0xae, 0x9d,
      0x2d, 0x60, 0x51, 0xd4, 0x16, 0x37, 0x56, 0x1c, 0x04};
  useRampPublicKeyForTests(key);
  expectBool(@"ramp token", rampLicenseAllows(tokenFor(@"ramp", forever)), YES);
  expectBool(@"dated ramp token",
             rampLicenseAllows(tokenFor(@"ramp:2099-01-01", later)), YES);
  expectText(@"ramp until",
             rampLicenseUntilToken(tokenFor(@"ramp:2099-01-01", later)),
             @"2099-01-01");
  expectBool(@"forever has no until",
             rampLicenseUntilToken(tokenFor(@"ramp", forever)) == nil, YES);
  expectBool(@"expired ramp token",
             rampLicenseAllows(tokenFor(@"ramp:2020-01-01", earlier)), NO);
  expectBool(@"reject empty license", rampLicenseAllows(@""), NO);
  expectBool(@"reject tampered license",
             rampLicenseAllows(tokenFor(@"ramp-extra", forever)), NO);

  NSString *home = [NSHomeDirectory() stringByStandardizingPath];
  if (home == nil || ![home hasPrefix:@"/tmp/nslic"]) {
    fail(@"license save home", home ?: @"nil");
    useRampPublicKeyForTests(NULL);
    return;
  }
  NSString *foreverToken = tokenFor(@"ramp", forever);
  NSString *laterToken = tokenFor(@"ramp:2099-01-01", later);
  NSString *earlierToken = tokenFor(@"ramp:2020-01-01", earlier);
  expectBool(@"save dated license", rampSaveNewerLicense(laterToken), YES);
  expectText(@"dated license until", rampLicenseUntil(), @"2099-01-01");
  expectBool(@"forever replaces dated", rampSaveNewerLicense(foreverToken), YES);
  expectBool(@"forever has no saved until", rampLicenseUntil() == nil, YES);
  expectBool(@"dated does not replace forever", rampSaveNewerLicense(laterToken), NO);
  expectBool(@"forever still has no until", rampLicenseUntil() == nil, YES);
  expectBool(@"expired does not replace forever",
             rampSaveNewerLicense(earlierToken), NO);
  expectBool(@"forever remains licensed", rampLicensed(), YES);
  useRampPublicKeyForTests(NULL);
}

static void isolateHome(void) {
  if (getenv("NIGHTSHIFT_LICENSE_TEST") != NULL) {
    return;
  }
  char templ[] = "/tmp/nslicXXXXXX";
  if (mkdtemp(templ) == NULL) {
    fprintf(stderr, "fail license home: mkdtemp\n");
    exit(1);
  }
  setenv("HOME", templ, 1);
  setenv("CFFIXED_USER_HOME", templ, 1);
  setenv("NIGHTSHIFT_LICENSE_TEST", "1", 1);
  char path[4096];
  uint32_t size = sizeof(path);
  if (_NSGetExecutablePath(path, &size) != 0) {
    fprintf(stderr, "fail license home: executable path\n");
    exit(1);
  }
  char *argv[] = {path, NULL};
  execv(path, argv);
  fprintf(stderr, "fail license home: exec\n");
  exit(1);
}

int main(void) {
  isolateHome();
  @autoreleasepool {
    checkParsers();
    checkMath();
    checkSentences();
    checkLicense();
    if (gFailed != 0) {
      fprintf(stderr, "%d failed\n", gFailed);
      return 1;
    }
    printf("unit ok\n");
    return 0;
  }
}
