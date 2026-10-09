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
#import <Security/Security.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

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

void useRampPublicKeyForTests(const uint8_t *key) {
  if (key == NULL) {
    gUseTestRampKey = NO;
    return;
  }
  memcpy(gTestRampKey, key, sizeof(gTestRampKey));
  gUseTestRampKey = YES;
}

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

static BOOL rampDayCurrent(NSString *day) {
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
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
  fmt.dateFormat = @"yyyy-MM-dd";
  fmt.lenient = NO;
  if ([fmt dateFromString:day] == nil) {
    return NO;
  }
  NSString *today = [fmt stringFromDate:[NSDate date]];
  return [day compare:today] != NSOrderedAscending;
}

static BOOL rampPayloadCurrent(NSData *payload) {
  NSString *text = [[NSString alloc] initWithData:payload
                                         encoding:NSUTF8StringEncoding];
  if ([text isEqualToString:@"ramp"]) {
    return YES;
  }
  if (text.length != 15 || ![text hasPrefix:@"ramp:"]) {
    return NO;
  }
  return rampDayCurrent([text substringFromIndex:5]);
}

static const uint8_t *rampPublicKey(void) {
  return gUseTestRampKey ? gTestRampKey : kRampPublicKey;
}

BOOL rampLicenseAllows(NSString *token) {
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
  NSData *payload = [[NSData alloc]
      initWithBase64EncodedString:[token substringToIndex:dot.location]
                          options:0];
  NSData *signature = [[NSData alloc]
      initWithBase64EncodedString:[token substringFromIndex:dot.location + 1]
                          options:0];
  if (payload.length == 0 || signature.length != 64) {
    return NO;
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
  return ok && rampPayloadCurrent(payload);
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
  NSString *text = tokenPayload(trimmed);
  if (text.length != 15 || ![text hasPrefix:@"ramp:"]) {
    return nil;
  }
  return [text substringFromIndex:5];
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
  if (rampLicensed() && rampLicenseUntil() == nil) {
    return NO;
  }
  NSString *text = [NSString stringWithContentsOfFile:licensePath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  NSString *payload = tokenPayload(text);
  if (payload.length == 15 && [payload hasPrefix:@"ramp:"]) {
    return !rampDayCurrent([payload substringFromIndex:5]);
  }
  return NO;
}

BOOL rampSaveNewerLicense(NSString *token) {
  NSString *trimmed = [token stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!rampLicenseAllows(trimmed)) {
    return NO;
  }
  if (rampLicensed() && rampLicenseUntil() == nil &&
      rampLicenseUntilToken(trimmed) != nil) {
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

static BOOL writeSupportFile(NSString *name, NSString *text) {
  if (!ensureSupportDir()) {
    return NO;
  }
  NSString *path = [supportDir() stringByAppendingPathComponent:name];
  if (![[text stringByAppendingString:@"\n"] writeToFile:path
                                               atomically:YES
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL]) {
    return NO;
  }
  return chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
}

NSString *rampInstallID(void) {
  NSString *existing = readSupportFile(@"install-id");
  if (existing.length == 36) {
    return existing.lowercaseString;
  }
  NSString *created = [NSUUID UUID].UUIDString.lowercaseString;
  if (!writeSupportFile(@"install-id", created)) {
    return nil;
  }
  return created;
}

NSString *rampServerOrigin(void) {
  NSString *saved = readSupportFile(@"server");
  if ([saved hasPrefix:@"http://"] || [saved hasPrefix:@"https://"]) {
    if ([saved hasSuffix:@"/"]) {
      return [saved substringToIndex:saved.length - 1];
    }
    return saved;
  }
  return @"http://127.0.0.1:8787";
}

static NSData *httpJSON(NSString *method, NSString *urlString, NSData *body,
                        NSInteger *status) {
  NSURL *url = [NSURL URLWithString:urlString];
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
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  __block NSData *data = nil;
  __block NSInteger code = 0;
  __block NSError *failed = nil;
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *received, NSURLResponse *response, NSError *error) {
          failed = error;
          if (error == nil) {
            data = received;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
              code = ((NSHTTPURLResponse *)response).statusCode;
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
  return data;
}

static NSString *unlockedLine(void) {
  NSString *until = rampLicenseUntil();
  if (until != nil) {
    return [NSString stringWithFormat:@"Ramp is unlocked through %@", until];
  }
  return @"Ramp is unlocked";
}

static BOOL datedCannotReplaceForever(NSString *token) {
  return token != nil && rampLicensed() && rampLicenseUntil() == nil &&
         rampLicenseUntilToken(token) != nil;
}

static BOOL tokenOlderThanSaved(NSString *token) {
  NSString *have = rampLicenseUntil();
  NSString *next = token == nil ? nil : rampLicenseUntilToken(token);
  return have != nil && next != nil && [next compare:have] == NSOrderedAscending;
}

static NSInteger fetchLicense(NSString **tokenOut) {
  if (tokenOut != NULL) {
    *tokenOut = nil;
  }
  NSString *installID = rampInstallID();
  if (installID == nil) {
    return -1;
  }
  NSString *url = [NSString stringWithFormat:@"%@/license?install_id=%@", rampServerOrigin(),
                                             installID];
  NSInteger status = 0;
  NSData *received = httpJSON(@"GET", url, nil, &status);
  if (status < 0 || status == 0) {
    return -1;
  }
  if (status != 200 || received == nil) {
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
  NSData *received =
      httpJSON(@"POST", [rampServerOrigin() stringByAppendingString:@"/checkout"], json, &status);
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
  return [url isKindOfClass:[NSString class]] && url.length > 0 ? url : nil;
}

NSString *rampCheckoutURL(void) {
  NSInteger status = 0;
  NSString *url = checkoutOrPortal(&status);
  return status == 200 ? url : nil;
}

NSString *rampFetchLicenseToken(void) {
  NSString *token = nil;
  return fetchLicense(&token) == 200 ? token : nil;
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
  if (datedCannotReplaceForever(trimmed)) {
    if (stdoutLine != NULL) {
      *stdoutLine = @"Ramp is unlocked";
    }
    if (stderrLine != NULL) {
      *stderrLine = @"a dated license cannot replace it";
    }
    return 0;
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
  NSInteger status = fetchLicense(&token);
  if (status < 0 || status == 503 || status == 204) {
    return 1;
  }
  if (status != 200 || token == nil) {
    return 1;
  }
  if (datedCannotReplaceForever(token)) {
    if (stdoutLine != NULL) {
      *stdoutLine = @"Ramp is unlocked";
    }
    if (stderrLine != NULL) {
      *stderrLine = @"a dated license cannot replace it";
    }
    return 0;
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
  if (rampLicensed() && rampLicenseUntil() == nil) {
    if (stdoutLine != NULL) {
      *stdoutLine = @"Ramp is unlocked";
    }
    return 0;
  }
  NSString *token = nil;
  NSInteger status = fetchLicense(&token);
  if (status < 0 || status == 503) {
    if (stderrLine != NULL) {
      *stderrLine = @"could not reach the license server";
    }
    return 2;
  }
  BOOL renew = NO;
  if (status == 200 && token != nil) {
    if (datedCannotReplaceForever(token)) {
      if (stdoutLine != NULL) {
        *stdoutLine = @"Ramp is unlocked";
      }
      if (stderrLine != NULL) {
        *stderrLine = @"a dated license cannot replace it";
      }
      return 0;
    }
    if (tokenOlderThanSaved(token)) {
      if (stderrLine != NULL) {
        *stderrLine =
            [NSString stringWithFormat:@"kept the license through %@", rampLicenseUntil()];
      }
      return 2;
    }
    if (rampLicenseAllows(token) && rampSaveNewerLicense(token)) {
      renew = rampLicenseRenewingSoon();
      if (!renew) {
        if (stdoutLine != NULL) {
          *stdoutLine = unlockedLine();
        }
        return 0;
      }
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
    if (stderrLine != NULL) {
      *stderrLine = @"could not open checkout";
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
