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
#import "NightshiftLogic.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

extern const CFStringRef kSecAttrKeyTypeEd25519;
extern const SecKeyAlgorithm kSecKeyAlgorithmEdDSASignatureMessageCurve25519SHA512;

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

BOOL holdingFullAt(int start, int end, int fullAt, int now) {
  int length = minutesBetween(start, end);
  if (fullAt < 0 || now < 0 || length == 0 || !insideWindow(start, end, now)) {
    return NO;
  }
  int untilFull = minutesBetween(start, fullAt);
  if (untilFull > length) {
    return NO;
  }
  return minutesBetween(start, now) >= untilFull;
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

long warmthCappedByMax(long now, long maxv) {
  return maxv < now ? maxv : now;
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

void useHourCycleForTests(int cycle) {
  if (cycle == 0 || cycle == 12 || cycle == 24) {
    gHourCycle = cycle;
  }
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

static const uint8_t kRampPublicKey[32] = {
    0x19, 0xd8, 0x9f, 0xd0, 0xa0, 0xa2, 0xf9, 0xe5, 0xb9, 0xc4, 0x65,
    0xdd, 0x1d, 0x25, 0xab, 0x87, 0x76, 0xfd, 0xad, 0xf9, 0x85, 0xe3,
    0xb0, 0x71, 0x8c, 0x0a, 0x71, 0x5e, 0x33, 0x08, 0x44, 0xe2};

static uint8_t gTestRampKey[32];
static BOOL gUseTestRampKey = NO;

static void forgetVerifiedTokens(void);

void useRampPublicKeyForTests(const uint8_t *key) {
  forgetVerifiedTokens();
  if (key == NULL) {
    gUseTestRampKey = NO;
    return;
  }
  memcpy(gTestRampKey, key, sizeof(gTestRampKey));
  gUseTestRampKey = YES;
}

#ifdef NIGHTSHIFT_TEST_KEYS
// Test builds only (make nightshift-testkey, used by server/prove.js): the
// public key comes from NIGHTSHIFT_TEST_PUBLIC_KEY (64 hex digits), so the
// proof can sign with a throwaway key. Release builds never read it.
static void useTestKeyFromEnvironment(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *hex = getenv("NIGHTSHIFT_TEST_PUBLIC_KEY");
    if (hex == NULL || strlen(hex) != 64) {
      return;
    }
    uint8_t key[32];
    for (int i = 0; i < 32; i++) {
      unsigned byte = 0;
      if (sscanf(hex + i * 2, "%2x", &byte) != 1) {
        return;
      }
      key[i] = (uint8_t)byte;
    }
    useRampPublicKeyForTests(key);
  });
}
#endif

NSString *rampOffer(void) {
  return @"The ramp is a paid feature. Unlock it with nightshift license";
}

static NSString *supportDir(void) {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"];
}

static NSString *licensePath(void) {
  return [supportDir() stringByAppendingPathComponent:@"license"];
}

static BOOL ensureSupportDir(void) {
  if (![[NSFileManager defaultManager] createDirectoryAtPath:supportDir()
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL]) {
    return NO;
  }
  chmod(supportDir().fileSystemRepresentation, S_IRWXU);
  return YES;
}

static NSDateFormatter *utcDayFormatter(void) {
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
  fmt.dateFormat = @"yyyy-MM-dd";
  fmt.lenient = NO;
  return fmt;
}

static BOOL rampDayValid(NSString *day) {
  if (day.length != 10) {
    return NO;
  }
  for (NSUInteger i = 0; i < 10; i++) {
    unichar c = [day characterAtIndex:i];
    if (i == 4 || i == 7) {
      if (c != '-') {
        return NO;
      }
    } else if (c < '0' || c > '9') {
      return NO;
    }
  }
  return [utcDayFormatter() dateFromString:day] != nil;
}

// Today is the later of this Mac's clock and the newest server time the
// hourly refresh saved, so setting the clock back can't keep an expired
// license alive. A server time can only make today later, never earlier.
static NSString *rampToday(void) {
  NSDate *now = [NSDate date];
  long long server = rampSavedServerTime();
  if (server > (long long)now.timeIntervalSince1970) {
    now = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)server];
  }
  return [utcDayFormatter() stringFromDate:now];
}

static BOOL rampDayCurrent(NSString *day) {
  return rampDayValid(day) && [day compare:rampToday()] != NSOrderedAscending;
}

// Finding 6 / patch review N2: a token names the install it unlocks and
// its last day, "ramp:<install-id>:<YYYY-MM-DD>". The old unbound tokens,
// "ramp" and "ramp:<day>", were only ever test tokens and are refused.
NSString *rampPayloadDay(NSString *payload, NSString *installID) {
  if (![payload hasPrefix:@"ramp:"]) {
    return nil;
  }
  NSString *rest = [payload substringFromIndex:5];
  NSString *day = nil;
  if (rest.length != 47 || [rest characterAtIndex:36] != ':' || installID.length != 36) {
    return nil;
  }
  NSString *bound = [rest substringToIndex:36];
  day = [rest substringFromIndex:37];
  if (![bound isEqualToString:installID.lowercaseString] || !rampDayValid(day)) {
    return nil;
  }
  return day;
}

static BOOL rampPayloadCurrent(NSData *payload) {
  NSString *text = [[NSString alloc] initWithData:payload
                                         encoding:NSUTF8StringEncoding];
  NSString *day = rampPayloadDay(text, rampInstallID());
  return day != nil && [day compare:rampToday()] != NSOrderedAscending;
}

static const uint8_t *rampPublicKey(void) {
#ifdef NIGHTSHIFT_TEST_KEYS
  useTestKeyFromEnvironment();
#endif
  return gUseTestRampKey ? gTestRampKey : kRampPublicKey;
}

// Tokens whose signature already checked out, so the ramp tick, the menu
// and the hourly refresh don't run Ed25519 on every call. Dates and the
// install binding are still checked each time. Any thread.
static NSMutableSet<NSString *> *gVerifiedTokens;

static void forgetVerifiedTokens(void) {
  @synchronized([NSString class]) {
    gVerifiedTokens = nil;
  }
}

static BOOL tokenVerifiedBefore(NSString *token) {
  @synchronized([NSString class]) {
    return [gVerifiedTokens containsObject:token];
  }
}

static void rememberVerifiedToken(NSString *token) {
  @synchronized([NSString class]) {
    if (gVerifiedTokens == nil || gVerifiedTokens.count > 16) {
      gVerifiedTokens = [NSMutableSet set];
    }
    [gVerifiedTokens addObject:[token copy]];
  }
}

// "<base64 payload>.<base64 signature>", split and decoded, or NO.
static BOOL splitToken(NSString *token, NSData **payload, NSData **signature) {
  if (token.length == 0) {
    return NO;
  }
  NSRange dot = [token rangeOfString:@"."];
  if (dot.location == NSNotFound || dot.location == 0 ||
      dot.location + 1 >= token.length ||
      [token rangeOfString:@"." options:0
                     range:NSMakeRange(dot.location + 1,
                                       token.length - dot.location - 1)]
              .location != NSNotFound) {
    return NO;
  }
  *payload = [[NSData alloc]
      initWithBase64EncodedString:[token substringToIndex:dot.location]
                          options:0];
  *signature = [[NSData alloc]
      initWithBase64EncodedString:[token substringFromIndex:dot.location + 1]
                          options:0];
  return (*payload).length > 0 && (*signature).length == 64;
}

// Ed25519 over payload with the license key, cached by token.
static BOOL signatureValid(NSString *token, NSData *payload, NSData *signature) {
  if (tokenVerifiedBefore(token)) {
    return YES;
  }
  NSData *keyData = [NSData dataWithBytes:rampPublicKey() length:32];
  NSDictionary *attrs = @{
    (__bridge id)kSecAttrKeyType : (__bridge id)kSecAttrKeyTypeEd25519,
    (__bridge id)kSecAttrKeyClass : (__bridge id)kSecAttrKeyClassPublic,
  };
  CFErrorRef error = NULL;
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)keyData,
                                       (__bridge CFDictionaryRef)attrs, &error);
  if (key == NULL) {
    if (error != NULL) {
      CFRelease(error);
    }
    return NO;
  }
  BOOL ok = SecKeyVerifySignature(
      key, kSecKeyAlgorithmEdDSASignatureMessageCurve25519SHA512,
      (__bridge CFDataRef)payload, (__bridge CFDataRef)signature, &error);
  CFRelease(key);
  if (error != NULL) {
    CFRelease(error);
  }
  if (ok) {
    rememberVerifiedToken(token);
  }
  return ok;
}

BOOL rampLicenseAllows(NSString *token) {
  NSData *payload = nil;
  NSData *signature = nil;
  if (!splitToken(token, &payload, &signature)) {
    return NO;
  }
  if (!rampPayloadCurrent(payload)) {
    return NO;
  }
  return signatureValid(token, payload, signature);
}

BOOL rampLicensed(void) {
  NSString *text = [NSString stringWithContentsOfFile:licensePath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  return rampLicenseAllows([text stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
}

BOOL installRampLicense(NSString *token) {
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!rampLicenseAllows(trimmed)) {
    return NO;
  }
  if (!ensureSupportDir()) {
    return NO;
  }
  NSString *saved = [trimmed stringByAppendingString:@"\n"];
  if (![saved writeToFile:licensePath()
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:NULL]) {
    return NO;
  }
  return chmod(licensePath().fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
}

static NSString *tokenPayload(NSString *token) {
  NSRange dot = [token rangeOfString:@"."];
  if (dot.location == NSNotFound || dot.location == 0) {
    return nil;
  }
  NSData *payload = [[NSData alloc]
      initWithBase64EncodedString:[token substringToIndex:dot.location]
                          options:0];
  if (payload == nil) {
    return nil;
  }
  return [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
}

NSString *rampLicenseUntilToken(NSString *token) {
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!rampLicenseAllows(trimmed)) {
    return nil;
  }
  return rampPayloadDay(tokenPayload(trimmed), rampInstallID());
}

NSString *rampLicenseUntil(void) {
  NSString *text = [NSString stringWithContentsOfFile:licensePath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  return rampLicenseUntilToken(text);
}

BOOL rampLicenseRenewingSoon(void) {
  NSString *until = rampLicenseUntil();
  if (until == nil) {
    return NO;
  }
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
  fmt.dateFormat = @"yyyy-MM-dd";
  fmt.lenient = NO;
  NSDate *end = [fmt dateFromString:until];
  NSDate *today = [fmt dateFromString:[fmt stringFromDate:[NSDate date]]];
  if (end == nil || today == nil) {
    return NO;
  }
  NSTimeInterval gap = [end timeIntervalSinceDate:today];
  return gap >= 0 && gap <= 14 * 24 * 60 * 60;
}

BOOL rampLicenseNeedsRefresh(void) {
  if (rampLicenseRenewingSoon()) {
    return YES;
  }
  NSString *text = [NSString stringWithContentsOfFile:licensePath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  NSString *payload = tokenPayload([text stringByTrimmingCharactersInSet:
                                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
  if (payload == nil) {
    return NO;
  }
  NSString *day = rampPayloadDay(payload, rampInstallID());
  return day != nil && !rampDayCurrent(day);
}

BOOL rampSaveNewerLicense(NSString *token) {
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!rampLicenseAllows(trimmed)) {
    return NO;
  }
  NSString *have = rampLicenseUntil();
  NSString *next = rampLicenseUntilToken(trimmed);
  if (have != nil && next != nil &&
      [next compare:have] == NSOrderedAscending) {
    return NO;
  }
  return installRampLicense(trimmed);
}

static NSString *readSupportFile(NSString *name) {
  return [[NSString stringWithContentsOfFile:[supportDir()
                                                 stringByAppendingPathComponent:name]
                                     encoding:NSUTF8StringEncoding
                                        error:NULL]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// The clock-rollback fix: the hourly refresh carries a server time signed
// with the license key, "nightshift-time:<install-id>:<unix seconds>", in
// the same "<payload>.<signature>" form as a license. Bound to the install,
// so one Mac's time can't be replayed on another.
long long rampServerTimeFromToken(NSString *token, NSString *installID) {
  NSData *payload = nil;
  NSData *signature = nil;
  if (installID.length != 36 || !splitToken(token, &payload, &signature)) {
    return -1;
  }
  NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
  NSString *prefix =
      [NSString stringWithFormat:@"nightshift-time:%@:", installID.lowercaseString];
  if (![text hasPrefix:prefix]) {
    return -1;
  }
  NSString *digits = [text substringFromIndex:prefix.length];
  if (digits.length == 0 || digits.length > 12) {
    return -1;
  }
  long long seconds = 0;
  for (NSUInteger i = 0; i < digits.length; i++) {
    unichar c = [digits characterAtIndex:i];
    if (c < '0' || c > '9') {
      return -1;
    }
    seconds = seconds * 10 + (c - '0');
  }
  return signatureValid(token, payload, signature) ? seconds : -1;
}

// The saved server time, or -1 when the file is missing, garbled or fails
// verification; then expiry falls back to the local clock.
long long rampSavedServerTime(void) {
  return rampServerTimeFromToken(readSupportFile(@"server-time"), rampInstallID());
}

// Saves a verified server time beside the license, only when it is newer
// than the one saved.
BOOL rampSaveServerTime(NSString *token) {
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  long long next = rampServerTimeFromToken(trimmed, rampInstallID());
  if (next < 0 || next <= rampSavedServerTime() || !ensureSupportDir()) {
    return NO;
  }
  NSString *path = [supportDir() stringByAppendingPathComponent:@"server-time"];
  if (![[trimmed stringByAppendingString:@"\n"] writeToFile:path
                                                  atomically:YES
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL]) {
    return NO;
  }
  return chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
}

// N3: the install ID and secret are created once and never replaced. A
// license is bound to the ID, so a file that exists but can't be read (a
// permissions problem, a truncated or garbled file) is left alone and
// reported, never overwritten with a new ID. Creation goes through link(2),
// so two processes (the app and the CLI) can't each create a different one.
static BOOL createSupportFileOnce(NSString *name, NSString *text, BOOL *exists) {
  *exists = NO;
  if (!ensureSupportDir()) {
    return NO;
  }
  NSString *path = [supportDir() stringByAppendingPathComponent:name];
  NSString *tmp = [path stringByAppendingFormat:@".%d.new", (int)getpid()];
  unlink(tmp.fileSystemRepresentation);
  int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR);
  if (fd < 0) {
    return NO;
  }
  NSData *bytes = [[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  BOOL wrote = write(fd, bytes.bytes, bytes.length) == (ssize_t)bytes.length && fsync(fd) == 0;
  close(fd);
  int linked = wrote ? link(tmp.fileSystemRepresentation, path.fileSystemRepresentation) : -1;
  int linkError = errno;
  unlink(tmp.fileSystemRepresentation);
  if (linked != 0 && wrote && linkError == EEXIST) {
    *exists = YES;
  }
  return linked == 0;
}

// The trimmed text of a support file that must not be replaced: the file's
// text when valid, make()'s when there was no file (created now), else nil.
static NSString *readOrCreateOnce(NSString *name, BOOL (^valid)(NSString *),
                                  NSString * (^make)(void)) {
  NSString *path = [supportDir() stringByAppendingPathComponent:name];
  for (int attempt = 0; attempt < 2; attempt++) {
    NSString *text = readSupportFile(name);
    if (text != nil) {
      return valid(text) ? text : nil;
    }
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0 || errno != ENOENT) {
      return nil;
    }
    NSString *created = make();
    if (created == nil) {
      return nil;
    }
    BOOL exists = NO;
    if (createSupportFileOnce(name, created, &exists)) {
      return created;
    }
    if (!exists) {
      return nil;
    }
    // Another process created it first: read theirs.
  }
  return nil;
}

static NSString *gInstallID;

void forgetInstallIdentityForTests(void) {
  @synchronized([NSUUID class]) {
    gInstallID = nil;
  }
}

NSString *rampInstallIDPath(void) {
  return [supportDir() stringByAppendingPathComponent:@"install-id"];
}

// Serialized and cached: license checks run on the main thread and on
// background queues, and the ramp tick asks on every pass.
NSString *rampInstallID(void) {
  @synchronized([NSUUID class]) {
    if (gInstallID == nil) {
      NSString *text = readOrCreateOnce(
          @"install-id",
          ^BOOL(NSString *existing) {
            return existing.length == 36 && [[NSUUID alloc] initWithUUIDString:existing] != nil;
          },
          ^NSString * {
            return [NSUUID UUID].UUIDString.lowercaseString;
          });
      gInstallID = text.lowercaseString;
    }
    return gInstallID;
  }
}

static BOOL validInstallSecret(NSString *text) {
  if (text.length != 64) {
    return NO;
  }
  for (NSUInteger i = 0; i < 64; i++) {
    unichar c = [text characterAtIndex:i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
      return NO;
    }
  }
  return YES;
}

// Finding 10: a per-install secret, sent in a header (never a URL) with
// license and checkout requests. The server keeps only its SHA-256, taken
// at payment; it serves the license and the billing portal only to it.
// Read from the file every time, not cached: `nightshift license secret
// --replace` can change it under a running app.
NSString *rampInstallSecret(void) {
  @synchronized([NSUUID class]) {
    return readOrCreateOnce(@"install-secret", ^BOOL(NSString *existing) {
      return validInstallSecret(existing);
    }, ^NSString * {
      uint8_t bytes[32];
      if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        return nil;
      }
      NSMutableString *created = [NSMutableString stringWithCapacity:64];
      for (size_t i = 0; i < sizeof(bytes); i++) {
        [created appendFormat:@"%02x", bytes[i]];
      }
      return created;
    });
  }
}

// A secret from support (node admin.js grant or reset-secret), entered with
// `nightshift license secret`. Like the install ID, an existing secret is
// never replaced unless asked; a replacement is written to a 0600 temporary
// file and renamed over the old one, so the file is always whole.
BOOL rampSaveInstallSecret(NSString *value, BOOL replace, NSString **error) {
  NSString *secret = [value stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         .lowercaseString;
  if (!validInstallSecret(secret)) {
    if (error) {
      *error = @"that isn't an install secret (64 hexadecimal characters)";
    }
    return NO;
  }
  @synchronized([NSUUID class]) {
    if (!replace) {
      BOOL exists = NO;
      if (createSupportFileOnce(@"install-secret", secret, &exists)) {
        return YES;
      }
      if (exists && [readSupportFile(@"install-secret") isEqualToString:secret]) {
        return YES;
      }
      if (error) {
        *error = exists ? @"this Mac already has an install secret; to replace it, "
                          @"run again with --replace"
                        : @"couldn't save the install secret";
      }
      return NO;
    }
    NSString *path = [supportDir() stringByAppendingPathComponent:@"install-secret"];
    NSString *tmp = [path stringByAppendingFormat:@".%d.new", (int)getpid()];
    BOOL saved = NO;
    if (ensureSupportDir()) {
      unlink(tmp.fileSystemRepresentation);
      int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    S_IRUSR | S_IWUSR);
      if (fd >= 0) {
        NSData *bytes =
            [[secret stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        BOOL wrote =
            write(fd, bytes.bytes, bytes.length) == (ssize_t)bytes.length && fsync(fd) == 0;
        close(fd);
        saved = wrote && rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
        if (!saved) {
          unlink(tmp.fileSystemRepresentation);
        }
      }
    }
    if (!saved && error) {
      *error = @"couldn't save the install secret";
    }
    return saved;
  }
}

// Review finding 2: the license server is an https origin compiled in
// (make LICENSE_SERVER=https://...), optionally replaced by a "server" file
// in the support folder that passes the same check. Plain http is accepted
// only for 127.0.0.1 and localhost, and only in test-key builds. A build
// without a valid origin has no license server: buying and renewing report
// that it can't be reached.
#ifndef NIGHTSHIFT_LICENSE_SERVER
#ifdef NIGHTSHIFT_TEST_KEYS
#define NIGHTSHIFT_LICENSE_SERVER "http://127.0.0.1:8787"
#else
#define NIGHTSHIFT_LICENSE_SERVER ""
#endif
#endif
#ifdef NIGHTSHIFT_TEST_KEYS
static const bool kLoopbackLicenseServer = true;
#else
static const bool kLoopbackLicenseServer = false;
#endif

// Review v2: the C check and NSURL must judge the same text. NSURL
// percent-encodes a NUL ("https://checkout.stripe.com\0@evil.com/" parses
// with host evil.com) while a C string stops at it, so any control character
// (Unicode Cc or Cf, NUL included) is refused before either looks; the C
// check then reads every UTF-8 byte, length given; and the NSURL used must
// print back exactly as the text that was checked.
static NSData *plainURLBytes(NSString *text) {
  if (![text isKindOfClass:[NSString class]] || text.length == 0 ||
      [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
    return nil;
  }
  return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static NSURL *unchangedURL(NSString *text) {
  NSURL *url = [NSURL URLWithString:text];
  return url != nil && [url.absoluteString isEqualToString:text] ? url : nil;
}

static NSString *checkedOrigin(NSString *origin) {
  NSData *bytes = plainURLBytes(origin);
  if (bytes == nil ||
      !nsLicenseOriginAllowed(bytes.bytes, bytes.length, kLoopbackLicenseServer) ||
      unchangedURL(origin) == nil) {
    return nil;
  }
  return [origin hasSuffix:@"/"] ? [origin substringToIndex:origin.length - 1] : origin;
}

NSString *rampServerOrigin(void) {
  NSString *saved = checkedOrigin(readSupportFile(@"server"));
  return saved != nil ? saved : checkedOrigin(@NIGHTSHIFT_LICENSE_SERVER);
}

NSURL *rampPurchasePage(NSString *url) {
  NSData *bytes = plainURLBytes(url);
  if (bytes == nil || !nsPurchaseURLAllowed(bytes.bytes, bytes.length)) {
    return nil;
  }
  return unchangedURL(url);
}

NSURL *rampWorkspaceURL(NSString *text) {
  NSData *bytes = plainURLBytes(text);
  if (bytes == nil ||
      !nsWorkspaceOpenAllowed(bytes.bytes, bytes.length, kLoopbackLicenseServer)) {
    return nil;
  }
  NSURL *url = unchangedURL(text);
  if (url != nil) {
    return url;
  }
  // A purchase page must print back as the text that was checked. A Settings
  // or project link is an exact allowlisted string; URLWithString is how
  // those links were opened, including when a custom scheme does not
  // round-trip.
  if (nsPurchaseURLAllowed(bytes.bytes, bytes.length)) {
    return nil;
  }
  return [NSURL URLWithString:text];
}

BOOL rampPurchaseURLAllowed(NSString *url) {
  return rampPurchasePage(url) != nil;
}

// Review v2: license-server requests never follow a redirect, so the
// X-Nightshift-Secret header only ever goes to the checked origin. The 3xx
// itself comes back as the answer, which every caller treats as a failure.
@interface RampNoRedirects : NSObject <NSURLSessionTaskDelegate>
@end

@implementation RampNoRedirects
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
  (void)session;
  (void)task;
  (void)response;
  (void)request;
  completionHandler(nil);
}
@end

static NSURLSession *licenseSession(void) {
  static NSURLSession *session = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    session = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                        delegate:[[RampNoRedirects alloc] init]
                   delegateQueue:nil];
  });
  return session;
}

static NSData *httpJSON(NSString *method, NSString *urlString, NSData *body,
                        NSString *secret, NSInteger *status, NSString **serverTime) {
  NSURL *url = urlString != nil ? [NSURL URLWithString:urlString] : nil;
  if (url == nil) {
    return nil;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = method;
  request.timeoutInterval = 15;
  if (body != nil) {
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  if (secret != nil) {
    [request setValue:secret forHTTPHeaderField:@"X-Nightshift-Secret"];
  }
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  __block NSData *data = nil;
  __block NSInteger code = 0;
  __block NSString *time = nil;
  __block NSError *failed = nil;
  [[licenseSession()
      dataTaskWithRequest:request
        completionHandler:^(NSData *received, NSURLResponse *response, NSError *error) {
          failed = error;
          if (error == nil) {
            data = received;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
              code = ((NSHTTPURLResponse *)response).statusCode;
              time = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"X-Nightshift-Time"];
            }
          }
          dispatch_semaphore_signal(gate);
        }] resume];
  if (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0 ||
      failed != nil) {
    if (status != NULL) {
      *status = -1;
    }
    return nil;
  }
  if (status != NULL) {
    *status = code;
  }
  if (serverTime != NULL) {
    *serverTime = time;
  }
  return data;
}

static NSString *unlockedLine(void) {
  NSString *until = rampLicenseUntil();
  if (until != nil) {
    return [NSString stringWithFormat:@"Ramp is unlocked through %@", until];
  }
  return @"Ramp is unlocked";
}

static BOOL tokenOlderThanSaved(NSString *token) {
  NSString *have = rampLicenseUntil();
  NSString *next = token == nil ? nil : rampLicenseUntilToken(token);
  return have != nil && next != nil && [next compare:have] == NSOrderedAscending;
}

// The server's answer to a Mac whose purchase was held (it paid with a
// secret that doesn't own this install ID): pending until the purchase is
// cancelled and refunded, then refunded (v8). The text shown is fixed
// here, never taken from the server.
NSString *rampHeldPurchaseMessage(NSInteger status, NSData *body) {
  if (status != 409 || body == nil) {
    return nil;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  id error = ((NSDictionary *)parsed)[@"error"];
  if ([error isEqual:@"refunded"]) {
    return @"This purchase was refunded; contact support";
  }
  if ([error isEqual:@"pending"]) {
    return @"This purchase is being reversed; contact support";
  }
  return nil;
}

static NSInteger fetchLicense(NSString **tokenOut, NSString **heldOut) {
  if (tokenOut != NULL) {
    *tokenOut = nil;
  }
  if (heldOut != NULL) {
    *heldOut = nil;
  }
  NSString *installID = rampInstallID();
  if (installID == nil) {
    return -1;
  }
  // POST, so the install ID stays out of URLs and server logs (finding 10).
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"install_id" : installID}
                                                 options:0
                                                   error:NULL];
  NSInteger status = 0;
  NSString *serverTime = nil;
  NSData *received = httpJSON(@"POST", [rampServerOrigin() stringByAppendingString:@"/license"],
                              json, rampInstallSecret(), &status, &serverTime);
  // Any reply, lapsed (204, 410) included, may carry the signed server
  // time; it is verified and saved before the status is looked at. An old
  // server sends none, and nothing changes.
  if (serverTime != nil) {
    rampSaveServerTime(serverTime);
  }
  if (status < 0 || status == 0) {
    return -1;
  }
  if (status != 200 || received == nil) {
    if (heldOut != NULL) {
      *heldOut = rampHeldPurchaseMessage(status, received);
    }
    return status;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:received options:0 error:NULL];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return -1;
  }
  NSString *token = ((NSDictionary *)parsed)[@"token"];
  if (![token isKindOfClass:[NSString class]]) {
    return -1;
  }
  if (tokenOut != NULL) {
    *tokenOut = token;
  }
  return 200;
}

static NSString *checkoutOrPortal(NSInteger *statusOut) {
  if (statusOut != NULL) {
    *statusOut = -1;
  }
  NSString *installID = rampInstallID();
  if (installID == nil) {
    return nil;
  }
  NSDictionary *body = @{@"install_id" : installID};
  NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  NSInteger status = 0;
  NSData *received = httpJSON(@"POST", [rampServerOrigin() stringByAppendingString:@"/checkout"],
                              json, rampInstallSecret(), &status, NULL);
  if (statusOut != NULL) {
    *statusOut = status;
  }
  if ((status != 200 && status != 409) || received == nil) {
    return nil;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:received options:0 error:NULL];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  NSString *url = ((NSDictionary *)parsed)[@"url"];
  if (![url isKindOfClass:[NSString class]] || url.length == 0) {
    return nil;
  }
  // Review finding 2: only Stripe Checkout or the billing portal is opened,
  // whatever the server says. Anything else counts as a failed request.
  if (!rampPurchaseURLAllowed(url)) {
    if (statusOut != NULL) {
      *statusOut = -1;
    }
    return nil;
  }
  return url;
}

NSString *rampCheckoutURL(void) {
  NSInteger status = 0;
  NSString *url = checkoutOrPortal(&status);
  return status == 200 ? url : nil;
}

NSString *rampFetchLicenseToken(void) {
  NSString *token = nil;
  return fetchLicense(&token, NULL) == 200 ? token : nil;
}

int rampInstallReported(NSString *token, NSString **stdoutLine, NSString **stderrLine) {
  if (stdoutLine != NULL) {
    *stdoutLine = nil;
  }
  if (stderrLine != NULL) {
    *stderrLine = nil;
  }
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!rampLicenseAllows(trimmed)) {
    if (stderrLine != NULL) {
      *stderrLine = @"that license was rejected";
    }
    return 1;
  }
  if (tokenOlderThanSaved(trimmed)) {
    if (stderrLine != NULL) {
      *stderrLine =
          [NSString stringWithFormat:@"kept the license through %@", rampLicenseUntil()];
    }
    return 1;
  }
  if (!rampSaveNewerLicense(trimmed)) {
    if (stderrLine != NULL) {
      *stderrLine = @"could not save the license";
    }
    return 1;
  }
  if (stdoutLine != NULL) {
    *stdoutLine = unlockedLine();
  }
  return 0;
}

int rampTakeLicenseUpdate(NSString **stdoutLine, NSString **stderrLine) {
  if (stdoutLine != NULL) {
    *stdoutLine = nil;
  }
  if (stderrLine != NULL) {
    *stderrLine = nil;
  }
  NSString *token = nil;
  NSString *held = nil;
  NSInteger status = fetchLicense(&token, &held);
  // v5 L3, v8: this Mac's purchase was held (being reversed, or refunded);
  // say so, and keep any saved
  // license (an unsigned answer never removes one).
  if (held != nil) {
    if (stderrLine != NULL) {
      *stderrLine = held;
    }
    return 2;
  }
  // N4: an unsigned answer never removes a saved license. A 410 (revoked)
  // only means there is nothing newer; the saved token runs to its day.
  if (status < 0 || status == 503 || status == 204 || status == 410) {
    return 1;
  }
  if (status != 200 || token == nil) {
    return 1;
  }
  if (tokenOlderThanSaved(token)) {
    if (stderrLine != NULL) {
      *stderrLine =
          [NSString stringWithFormat:@"kept the license through %@", rampLicenseUntil()];
    }
    return 2;
  }
  if (!rampLicenseAllows(token)) {
    return 1;
  }
  if (!rampSaveNewerLicense(token)) {
    if (rampLicensed()) {
      if (stderrLine != NULL) {
        *stderrLine = @"could not save the license";
      }
      return 2;
    }
    return 1;
  }
  if (stdoutLine != NULL) {
    *stdoutLine = unlockedLine();
  }
  return 0;
}

int rampBeginPurchase(NSString **openURL, BOOL *portal, NSString **stdoutLine,
                      NSString **stderrLine) {
  if (openURL != NULL) {
    *openURL = nil;
  }
  if (portal != NULL) {
    *portal = NO;
  }
  if (stdoutLine != NULL) {
    *stdoutLine = nil;
  }
  if (stderrLine != NULL) {
    *stderrLine = nil;
  }
  NSString *token = nil;
  NSString *held = nil;
  NSInteger status = fetchLicense(&token, &held);
  if (held != nil) {
    if (stderrLine != NULL) {
      *stderrLine = held;
    }
    return 2;
  }
  if (status < 0 || status == 503) {
    if (stderrLine != NULL) {
      *stderrLine = @"could not reach the license server";
    }
    return 2;
  }
  if (status == 200 && token != nil) {
    if (tokenOlderThanSaved(token)) {
      if (stderrLine != NULL) {
        *stderrLine =
            [NSString stringWithFormat:@"kept the license through %@", rampLicenseUntil()];
      }
      return 2;
    }
    if (rampLicenseAllows(token) && rampSaveNewerLicense(token)) {
      if (stdoutLine != NULL) {
        *stdoutLine = unlockedLine();
      }
      return 0;
    } else if (rampLicensed() && rampLicenseAllows(token)) {
      if (stderrLine != NULL) {
        *stderrLine = @"could not save the license";
      }
      return 2;
    }
  } else if (status != 204 && status != 200) {
    if (stderrLine != NULL) {
      *stderrLine = @"could not reach the license server";
    }
    return 2;
  }
  NSInteger checkoutStatus = 0;
  NSString *url = checkoutOrPortal(&checkoutStatus);
  if (checkoutStatus == 409) {
    if (url != nil) {
      if (openURL != NULL) {
        *openURL = url;
      }
      if (portal != NULL) {
        *portal = YES;
      }
      if (stdoutLine != NULL && rampLicensed()) {
        *stdoutLine = unlockedLine();
      }
      return 1;
    }
    if (rampLicensed()) {
      if (stdoutLine != NULL) {
        *stdoutLine = unlockedLine();
      }
      return 0;
    }
    // The install ID is in use under another install secret, so the server
    // won't sell it from this Mac (patch review v5).
    if (stderrLine != NULL) {
      *stderrLine = @"this install ID already has a license under another install secret; "
                    @"contact support with nightshift license id";
    }
    return 2;
  }
  if (url == nil) {
    if (stderrLine != NULL) {
      *stderrLine = @"could not open checkout";
    }
    return 2;
  }
  if (openURL != NULL) {
    *openURL = url;
  }
  return 1;
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
