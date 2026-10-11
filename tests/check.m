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
#import <sys/stat.h>
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
  // A throwaway test key; its private half was discarded after signing
  // these payloads. Never the production key.
  static const uint8_t key[32] = {
      0x64, 0x7e, 0xd6, 0x0e, 0xf3, 0x3f, 0x7d, 0x9b, 0x9d, 0xc8, 0x80,
      0x72, 0xb8, 0x80, 0x2f, 0x1f, 0xdb, 0x38, 0xd6, 0x80, 0x74, 0x62,
      0x91, 0x39, 0x50, 0xa9, 0x3f, 0xf1, 0xb7, 0x85, 0x2d, 0xac};
  static const uint8_t bound_sig[64] = {
      0x2e, 0xed, 0x96, 0x10, 0x76, 0xfa, 0x19, 0x17, 0xe8, 0xcb, 0x23,
      0x72, 0x9d, 0xca, 0xc7, 0xd0, 0xe1, 0xdd, 0xa4, 0x5f, 0xb9, 0x06,
      0x5d, 0x49, 0xec, 0x91, 0x85, 0xbf, 0x47, 0x1a, 0xe7, 0xea, 0x56,
      0x72, 0xa0, 0xb7, 0xf8, 0x5b, 0xca, 0x91, 0x8a, 0x61, 0x29, 0x44,
      0xe9, 0xb4, 0x5f, 0x70, 0x38, 0x84, 0x93, 0xa9, 0x7c, 0xa7, 0xf4,
      0x8d, 0xba, 0x6d, 0x82, 0x50, 0xe3, 0x9b, 0xbe, 0x04};
  static const uint8_t boundOlder[64] = {
      0x6b, 0x1a, 0xb2, 0x77, 0x4c, 0x31, 0xc3, 0x96, 0x0b, 0x65, 0x7d,
      0x75, 0x88, 0x2c, 0x68, 0xb1, 0xad, 0xd5, 0xbd, 0x99, 0xc6, 0xf8,
      0x5f, 0x22, 0x9f, 0xd4, 0xa5, 0xa6, 0x7c, 0x00, 0xc6, 0x66, 0x2a,
      0xde, 0xe6, 0xfa, 0x14, 0x53, 0x33, 0x1b, 0x1c, 0x3a, 0x20, 0xff,
      0x8a, 0xbd, 0x7b, 0xfe, 0xd7, 0x97, 0x53, 0xc7, 0x62, 0x25, 0xc1,
      0xcc, 0x6e, 0x3b, 0x4b, 0x98, 0xa0, 0x58, 0x36, 0x05};
  static const uint8_t boundExpired[64] = {
      0x2b, 0x93, 0x7d, 0x11, 0xed, 0xc8, 0xb0, 0x86, 0x38, 0xb5, 0x30,
      0xfe, 0x65, 0x85, 0x09, 0xf7, 0x8a, 0x4c, 0x86, 0xfc, 0x94, 0xb2,
      0x8c, 0xae, 0x87, 0x7e, 0x6e, 0xa7, 0xb6, 0x14, 0x01, 0x52, 0xe2,
      0xe0, 0xf3, 0x75, 0x27, 0x40, 0xb9, 0x30, 0xd5, 0x96, 0x03, 0x48,
      0xca, 0xde, 0x4c, 0x4a, 0xb4, 0x0a, 0x5b, 0x4e, 0x37, 0xfa, 0x12,
      0xad, 0x79, 0x80, 0xd7, 0x28, 0xe7, 0x1e, 0x59, 0x0f};
  static const uint8_t otherInstall[64] = {
      0x31, 0x22, 0x05, 0x10, 0xa1, 0xf2, 0xd3, 0x73, 0x16, 0xbf, 0xac,
      0xa4, 0x79, 0x3c, 0x30, 0xa1, 0xc2, 0xb0, 0x95, 0xa8, 0x22, 0x22,
      0x58, 0x85, 0x95, 0x7e, 0x2b, 0x1e, 0x46, 0x6b, 0x9c, 0xa5, 0x3b,
      0x1a, 0x71, 0x52, 0xe7, 0xb6, 0x06, 0x08, 0x9d, 0x87, 0xf5, 0x36,
      0x0e, 0x8d, 0xc2, 0xd5, 0x0e, 0x77, 0x82, 0x5e, 0x4c, 0x3e, 0x00,
      0x70, 0x91, 0x17, 0x8f, 0x3e, 0x28, 0x69, 0x0d, 0x0d};
  static const uint8_t legacyLate[64] = {
      0x67, 0xfa, 0xc2, 0xc8, 0x70, 0x11, 0xc3, 0xa0, 0x70, 0xa3, 0xbe,
      0xd0, 0x36, 0xc8, 0x24, 0x0a, 0xd9, 0xd5, 0x94, 0xe4, 0xe9, 0xd6,
      0x28, 0x62, 0x73, 0x7a, 0xb8, 0x34, 0x4e, 0x11, 0x1d, 0x3b, 0xc2,
      0x33, 0x22, 0xab, 0xcd, 0x19, 0x56, 0x02, 0xc0, 0x60, 0xd6, 0x6b,
      0xcf, 0xf8, 0x69, 0x8d, 0xb1, 0x89, 0x57, 0x55, 0x74, 0xb4, 0x4e,
      0xdd, 0x6a, 0x07, 0xd8, 0x2b, 0x51, 0x4b, 0x89, 0x0d};
  static const uint8_t bare[64] = {
      0x23, 0xfd, 0x7a, 0xcc, 0x43, 0xed, 0x0c, 0xd8, 0x26, 0x26, 0x18,
      0x9e, 0x07, 0x86, 0xa3, 0x8e, 0xe4, 0xd5, 0xba, 0x94, 0xdf, 0x6f,
      0x36, 0xbb, 0x30, 0x81, 0x26, 0x8f, 0x1b, 0xde, 0xac, 0x6c, 0x52,
      0xf3, 0xcf, 0x96, 0x09, 0x17, 0x2e, 0x34, 0xf2, 0xd8, 0xb5, 0xa0,
      0xb7, 0x59, 0x54, 0xbc, 0xb7, 0xf8, 0x29, 0x03, 0x74, 0x9d, 0xe5,
      0xd2, 0x46, 0x25, 0xb1, 0x73, 0x8c, 0x83, 0xab, 0x01};
  NSString *installID = @"5f0e1c2a-3b4d-4e6f-8a9b-0c1d2e3f4a5b";
  NSString *otherID = @"a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d";
  NSString *home = [NSHomeDirectory() stringByStandardizingPath];
  if (home == nil || ![home hasPrefix:@"/tmp/nslic"]) {
    fail(@"license save home", home ?: @"nil");
    return;
  }
  NSString *dir = [home stringByAppendingPathComponent:@"Library/Application Support/nightshift"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  NSString *idPath = [dir stringByAppendingPathComponent:@"install-id"];
  NSString *secretPath = [dir stringByAppendingPathComponent:@"install-secret"];
  NSString *licenseFile = [dir stringByAppendingPathComponent:@"license"];
  NSString *(^fileText)(NSString *) = ^NSString *(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  };
  void (^writeText)(NSString *, NSString *) = ^(NSString *path, NSString *text) {
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  };

  // N3: created only when absent, never overwritten, cached.
  [[NSFileManager defaultManager] removeItemAtPath:idPath error:NULL];
  forgetInstallIdentityForTests();
  NSString *created = rampInstallID();
  expectBool(@"install id created when absent", created.length == 36, YES);
  expectText(@"created id is saved", fileText(idPath), [created stringByAppendingString:@"\n"]);
  forgetInstallIdentityForTests();
  expectText(@"created id read back", rampInstallID(), created);
  for (NSString *bad in @[ @"not-an-install-id\n", @"", @"5f0e1c2a-3b4d-4e6f-8a9b\n" ]) {
    writeText(idPath, bad);
    forgetInstallIdentityForTests();
    expectBool([@"unreadable id is nil: " stringByAppendingString:bad],
               rampInstallID() == nil, YES);
    expectText([@"unreadable id left alone: " stringByAppendingString:bad], fileText(idPath), bad);
  }
  if (geteuid() != 0) {
    writeText(idPath, [created stringByAppendingString:@"\n"]);
    chmod(idPath.fileSystemRepresentation, 0);
    forgetInstallIdentityForTests();
    expectBool(@"unreadable id file is nil", rampInstallID() == nil, YES);
    chmod(idPath.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    expectText(@"unreadable id file left alone", fileText(idPath),
               [created stringByAppendingString:@"\n"]);
  }
  writeText(idPath, [installID.uppercaseString stringByAppendingString:@"\n"]);
  forgetInstallIdentityForTests();
  expectText(@"install id", rampInstallID(), installID);
  writeText(idPath, [otherID stringByAppendingString:@"\n"]);
  expectText(@"install id is cached", rampInstallID(), installID);
  writeText(idPath, [installID stringByAppendingString:@"\n"]);

  [[NSFileManager defaultManager] removeItemAtPath:secretPath error:NULL];
  NSString *secret = rampInstallSecret();
  expectBool(@"install secret created", secret.length == 64, YES);
  writeText(secretPath, @"short\n");
  forgetInstallIdentityForTests();
  expectBool(@"bad secret is nil", rampInstallSecret() == nil, YES);
  expectText(@"bad secret left alone", fileText(secretPath), @"short\n");

  // A secret from support (nightshift license secret): checked, never
  // replacing one without asking, and always a whole 0600 file.
  NSString *given = [@"0123456789ABCDEF" stringByPaddingToLength:64
                                                     withString:@"0123456789ABCDEF"
                                                startingAtIndex:0];
  NSString *givenLower = given.lowercaseString;
  NSString *other = [@"" stringByPaddingToLength:64 withString:@"9" startingAtIndex:0];
  NSString *err = nil;
  for (NSString *bad in @[ @"", @"short", [given stringByAppendingString:@"0"],
                           [given stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                          withString:@"g"] ]) {
    err = nil;
    expectBool([@"bad secret refused: " stringByAppendingString:bad],
               rampSaveInstallSecret(bad, YES, &err), NO);
    expectBool(@"bad secret says why", [err containsString:@"64 hexadecimal"], YES);
  }
  expectBool(@"nil secret refused", rampSaveInstallSecret(nil, YES, NULL), NO);
  expectText(@"bad secrets saved nothing", fileText(secretPath), @"short\n");
  err = nil;
  expectBool(@"secret over an unreadable one needs --replace",
             rampSaveInstallSecret(given, NO, &err), NO);
  expectBool(@"refusal names --replace", [err containsString:@"--replace"], YES);
  expectText(@"refused secret left the file alone", fileText(secretPath), @"short\n");
  [[NSFileManager defaultManager] removeItemAtPath:secretPath error:NULL];
  expectBool(@"secret saved when absent",
             rampSaveInstallSecret([NSString stringWithFormat:@"  %@\n", given], NO, NULL), YES);
  expectText(@"saved secret is trimmed and lower-case", fileText(secretPath),
             [givenLower stringByAppendingString:@"\n"]);
  struct stat secretStat;
  stat(secretPath.fileSystemRepresentation, &secretStat);
  expectLong(@"saved secret is 0600", secretStat.st_mode & 0777, 0600);
  expectText(@"saved secret is used", rampInstallSecret(), givenLower);
  expectBool(@"same secret again is fine", rampSaveInstallSecret(given, NO, NULL), YES);
  err = nil;
  expectBool(@"another secret needs --replace", rampSaveInstallSecret(other, NO, &err), NO);
  expectBool(@"another secret refusal names --replace", [err containsString:@"--replace"], YES);
  expectText(@"existing secret kept", fileText(secretPath),
             [givenLower stringByAppendingString:@"\n"]);
  chmod(secretPath.fileSystemRepresentation, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
  expectBool(@"--replace replaces", rampSaveInstallSecret(other, YES, NULL), YES);
  expectText(@"replaced secret saved", fileText(secretPath), [other stringByAppendingString:@"\n"]);
  stat(secretPath.fileSystemRepresentation, &secretStat);
  expectLong(@"replaced secret is 0600", secretStat.st_mode & 0777, 0600);
  expectText(@"replaced secret used without a restart", rampInstallSecret(), other);
  NSArray *left = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
  expectBool(@"no temporary secret files left",
             [[left filteredArrayUsingPredicate:
                        [NSPredicate predicateWithFormat:@"SELF ENDSWITH '.new'"]] count] == 0,
             YES);
  expectBool(@"bad secret doesn't replace", rampSaveInstallSecret(@"short", YES, NULL), NO);
  expectText(@"secret kept after a bad replace", rampInstallSecret(), other);
  forgetInstallIdentityForTests();
  expectText(@"install id after forgetting", rampInstallID(), installID);

  // v5 L3, v8: the server's held-purchase replies, shown with fixed text.
  NSData *(^json)(NSString *) = ^NSData *(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
  };
  expectText(@"refunded reply", rampHeldPurchaseMessage(409, json(@"{\"error\":\"refunded\","
                                                                  @"\"message\":\"anything\"}")),
             @"This purchase was refunded; contact support");
  expectText(@"pending reply", rampHeldPurchaseMessage(409, json(@"{\"error\":\"pending\","
                                                                 @"\"message\":\"anything\"}")),
             @"This purchase is being reversed; contact support");
  expectBool(@"contact-support reply isn't held",
             rampHeldPurchaseMessage(409, json(@"{\"error\":\"contact support\"}")) == nil, YES);
  expectBool(@"refunded needs 409",
             rampHeldPurchaseMessage(200, json(@"{\"error\":\"refunded\"}")) == nil, YES);
  expectBool(@"pending needs 409",
             rampHeldPurchaseMessage(200, json(@"{\"error\":\"pending\"}")) == nil, YES);
  expectBool(@"garbled reply isn't held", rampHeldPurchaseMessage(409, json(@"{")) == nil, YES);
  expectBool(@"non-object reply isn't held",
             rampHeldPurchaseMessage(409, json(@"[\"pending\"]")) == nil, YES);
  expectBool(@"empty reply isn't held", rampHeldPurchaseMessage(409, nil) == nil, YES);

  // Payload rules, no signature or clock involved.
  NSString *bound = [NSString stringWithFormat:@"ramp:%@:2099-01-01", installID];
  expectText(@"bound payload day", rampPayloadDay(bound, installID), @"2099-01-01");
  expectBool(@"bound payload, other install",
             rampPayloadDay(bound, otherID) == nil, YES);
  expectText(@"bound payload, upper-case id",
             rampPayloadDay(bound, installID.uppercaseString), @"2099-01-01");
  for (NSString *legacyPayload in @[ @"ramp:2026-12-31", @"ramp:2027-10-01",
                                      @"ramp:2028-10-01", @"ramp:2099-01-01" ]) {
    expectBool([@"legacy payload refused: " stringByAppendingString:legacyPayload],
               rampPayloadDay(legacyPayload, installID) == nil, YES);
  }
  expectBool(@"undated payload", rampPayloadDay(@"ramp", installID) == nil, YES);
  expectBool(@"bad day", rampPayloadDay(@"ramp:2027-02-30", installID) == nil, YES);
  expectBool(@"bad bound day",
             rampPayloadDay([NSString stringWithFormat:@"ramp:%@:2099-1-01x", installID],
                            installID) == nil,
             YES);
  expectBool(@"missing install separator",
             rampPayloadDay([NSString stringWithFormat:@"ramp:%@-2099-01-01", installID],
                            installID) == nil,
             YES);

  useRampPublicKeyForTests(key);
  NSString *boundToken = tokenFor(bound, bound_sig);
  NSString *olderToken =
      tokenFor([NSString stringWithFormat:@"ramp:%@:2098-06-01", installID], boundOlder);
  NSString *expiredToken =
      tokenFor([NSString stringWithFormat:@"ramp:%@:2020-01-01", installID], boundExpired);
  NSString *otherToken =
      tokenFor([NSString stringWithFormat:@"ramp:%@:2099-01-01", otherID], otherInstall);
  expectBool(@"bound token", rampLicenseAllows(boundToken), YES);
  // Twice: the second answer comes from the signature cache.
  expectBool(@"bound token again", rampLicenseAllows(boundToken), YES);
  expectText(@"bound until", rampLicenseUntilToken(boundToken), @"2099-01-01");
  expectBool(@"token for another install", rampLicenseAllows(otherToken), NO);
  expectBool(@"expired token", rampLicenseAllows(expiredToken), NO);
  expectBool(@"undated token", rampLicenseAllows(tokenFor(@"ramp", bare)), NO);
  expectBool(@"legacy token", rampLicenseAllows(tokenFor(@"ramp:2099-01-01", legacyLate)), NO);
  expectBool(@"reject empty license", rampLicenseAllows(@""), NO);
  expectBool(@"reject tampered license",
             rampLicenseAllows(tokenFor(bound, boundOlder)), NO);
  expectBool(@"reject a payload the key never signed",
             rampLicenseAllows(tokenFor([bound stringByReplacingOccurrencesOfString:@"2099"
                                                                        withString:@"2097"],
                                        bound_sig)),
             NO);

  expectBool(@"save bound license", rampSaveNewerLicense(olderToken), YES);
  expectText(@"saved until", rampLicenseUntil(), @"2098-06-01");
  expectBool(@"later license replaces it", rampSaveNewerLicense(boundToken), YES);
  expectText(@"later saved until", rampLicenseUntil(), @"2099-01-01");
  expectBool(@"earlier license does not replace it", rampSaveNewerLicense(olderToken), NO);
  expectBool(@"expired does not replace it", rampSaveNewerLicense(expiredToken), NO);
  expectBool(@"other install does not replace it", rampSaveNewerLicense(otherToken), NO);
  expectBool(@"bound license is licensed", rampLicensed(), YES);
  expectBool(@"no refresh years ahead", rampLicenseNeedsRefresh(), NO);

  // N2: no unbound token, legacy or undated, is accepted or replaces a
  // saved license, and a saved one doesn't ask the server for a swap.
  NSString *bareToken = tokenFor(@"ramp", bare);
  NSString *legacyToken = tokenFor(@"ramp:2099-01-01", legacyLate);
  expectBool(@"legacy token can't be saved", rampSaveNewerLicense(legacyToken), NO);
  expectBool(@"undated token can't be saved", rampSaveNewerLicense(bareToken), NO);
  expectText(@"bound license kept", rampLicenseUntil(), @"2099-01-01");
  expectBool(@"install a legacy token", installRampLicense(legacyToken), NO);
  writeText(licenseFile, [legacyToken stringByAppendingString:@"\n"]);
  expectBool(@"saved legacy token is not licensed", rampLicensed(), NO);
  expectBool(@"saved legacy token has no day", rampLicenseUntil() == nil, YES);
  expectBool(@"saved legacy token is not refreshed", rampLicenseNeedsRefresh(), NO);
  writeText(licenseFile, [bareToken stringByAppendingString:@"\n"]);
  expectBool(@"saved undated token is not licensed", rampLicensed(), NO);
  expectBool(@"saved undated token is not refreshed", rampLicenseNeedsRefresh(), NO);
  expectBool(@"a bound license replaces it", rampSaveNewerLicense(boundToken), YES);
  expectText(@"bound license saved", rampLicenseUntil(), @"2099-01-01");

  // Another key: the cache must not vouch for tokens the new key didn't sign.
  static const uint8_t otherKey[32] = {1};
  useRampPublicKeyForTests(otherKey);
  expectBool(@"cache cleared with the key", rampLicenseAllows(boundToken), NO);
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
