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
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

extern int DisplayServicesGetBrightness(uint32_t display, float *brightness);
extern int DisplayServicesSetBrightness(uint32_t display, float brightness);
extern int DisplayServicesCanChangeBrightness(uint32_t display);

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator,
                                                   io_service_t service);
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef service, CFDataRef *edid);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chip,
                                   uint32_t offset, void *buffer, uint32_t length);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chip,
                                    uint32_t address, void *buffer, uint32_t length);

static BOOL brightnessKeysReady(void);
static long readPercent(uint32_t display);
static BOOL ddcReportsCombined(uint32_t display);
static long ddcShownPercent(uint32_t display);
static void noteCursorBrightness(uint32_t display, long percent);
static void noteCursorDisplaysOffline(void);
static void startBrightnessKeys(void);
static BOOL handleControl(const char *buf, int fd);
extern int SLSGetAppearanceThemeLegacy(void);
extern void SLSSetAppearanceThemeLegacy(int theme);
extern void SLSSetAppearanceThemeSwitchesAutomatically(int automatic);

@interface CBTrueToneClient : NSObject
- (BOOL)supported;
- (BOOL)available;
- (BOOL)enabled;
- (BOOL)setEnabled:(BOOL)enabled;
@end

@interface CBBlueLightClient (NightshiftSchedule)
- (BOOL)setMode:(int)mode;
@end

@interface NightshiftBrightnessClient : NSObject
- (BOOL)activateWithError:(NSError **)error;
- (id)copyPropertyForKey:(NSString *)key andDisplay:(unsigned long long)display;
- (BOOL)setProperty:(id)property withKey:(NSString *)key andDisplay:(unsigned long long)display;
@end
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <time.h>
#import <unistd.h>

@interface UNMutableNotificationContent (NightshiftBanner)
- (void)setShouldDisplayActionsInline:(BOOL)display;
- (void)setShouldPreventNotificationDismissalAfterDefaultAction:(BOOL)prevent;
@end

static const int kModeCustom = 2;
static const int kRampMinutes = 120;
static const int kGlideMinutes = 30;
static const int kArmMinutes = 2;

static CBBlueLightClient *gClient = nil;
static NSString *gMaxPath = nil;
static NSString *gRampPath = nil;
static NSString *gBrightnessPath = nil;
static int gRampClock = -1;
static NSString *gPending = nil;
static long gMax = 50;
static BOOL gMaxKnown = NO;
static BOOL gBannerReady = NO;
static BOOL gBannerDenied = NO;
static int gFromMinute = -1;
static long gFromValue = 1;
static int gToMinute = -1;
static int gFullAt = -1;
static int gScheduleStart = -1;
static BOOL gEarly = NO;
static long gApplied = -1;
static long gSeenWarmth = -1;
static BOOL gLaunched = NO;
static int gArmedStart = -1;
static int gNotified = 0;
static BOOL gSuspended = NO;
static BOOL gLoggedSchedule = NO;
static NSString *const kSetMaxAction = @"set-max";
static NSString *const kFullAtAction = @"full-at";
static NSString *const kCategory = @"controls";

static void clearRamp(void) {
  gFromMinute = -1;
  gToMinute = -1;
  gFullAt = -1;
  gApplied = -1;
  gNotified = 0;
  gSuspended = NO;
  gEarly = NO;
}

static int minutesNow(void) {
  time_t now = time(NULL);
  struct tm local;
  if (localtime_r(&now, &local) == NULL) {
    return -1;
  }
  return local.tm_hour * 60 + local.tm_min;
}

static BOOL readMax(long *value) {
  NSString *text = [NSString stringWithContentsOfFile:gMaxPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  if (text == nil) {
    return NO;
  }
  const char *s = text.UTF8String;
  if (s == NULL) {
    return NO;
  }
  char *end = NULL;
  long parsed = strtol(s, &end, 10);
  if (end == s) {
    return NO;
  }
  while (*end == ' ' || *end == '\n' || *end == '\r') {
    end++;
  }
  if (*end != '\0' || parsed < 1 || parsed > 100) {
    return NO;
  }
  *value = parsed;
  return YES;
}

static BOOL writeMax(long value) {
  NSString *text = [NSString stringWithFormat:@"%ld\n", value];
  if (![text writeToFile:gMaxPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL]) {
    return NO;
  }
  return chmod(gMaxPath.fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
}

static BOOL rememberMax(long value) {
  if (value < 1 || value > 100 || !writeMax(value)) {
    fprintf(stderr, "failed to save max\n");
    return NO;
  }
  gMax = value;
  gMaxKnown = YES;
  return YES;
}

static BOOL readRampClock(int *minute) {
  NSString *text = [NSString stringWithContentsOfFile:gRampPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  if (text == nil) {
    return NO;
  }
  const char *s = text.UTF8String;
  if (s == NULL) {
    return NO;
  }
  char *end = NULL;
  long parsed = strtol(s, &end, 10);
  if (end == s) {
    return NO;
  }
  while (*end == ' ' || *end == '\n' || *end == '\r') {
    end++;
  }
  if (*end != '\0' || parsed < 0 || parsed >= 1440) {
    return NO;
  }
  *minute = (int)parsed;
  return YES;
}

static BOOL rememberRampClock(int minute) {
  if (minute < 0 || minute >= 1440) {
    return NO;
  }
  NSString *text = [NSString stringWithFormat:@"%d\n", minute];
  if (![text writeToFile:gRampPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL] ||
      chmod(gRampPath.fileSystemRepresentation, S_IRUSR | S_IWUSR) != 0) {
    fprintf(stderr, "failed to save full at\n");
    return NO;
  }
  gRampClock = minute;
  return YES;
}

static void raiseMax(long value) {
  if (value < 1) {
    return;
  }
  if (!gMaxKnown || value > gMax) {
    rememberMax(value);
  }
}

static long glideValue(int now) {
  return glideWarmth(gFromMinute, gToMinute, gFromValue, gMax, now);
}

static int glideStage(int now) {
  int span = minutesBetween(gFromMinute, gToMinute);
  int elapsed = minutesBetween(gFromMinute, now);
  if (span == 0 || elapsed >= span) {
    return 3;
  }
  if (elapsed * 2 >= span) {
    return 2;
  }
  return 1;
}

static int glideEnd(int now, int scheduleEnd) {
  int untilEnd = minutesBetween(now, scheduleEnd);
  if (untilEnd == 0) {
    return now;
  }
  if (gFullAt >= 0) {
    int untilFull = minutesBetween(now, gFullAt);
    if (untilFull > 0 && untilFull <= untilEnd) {
      return gFullAt;
    }
  }
  if (untilEnd <= kGlideMinutes) {
    return scheduleEnd;
  }
  return (now + kGlideMinutes) % 1440;
}

static void sendBanner(NSString *body) {
  UNMutableNotificationContent *content =
      [[UNMutableNotificationContent alloc] init];
  content.title = @"Night Shift";
  content.body = body;
  content.categoryIdentifier = kCategory;
  if ([content respondsToSelector:@selector(setShouldDisplayActionsInline:)]) {
    [content setShouldDisplayActionsInline:YES];
  }
  if ([content respondsToSelector:@selector
               (setShouldPreventNotificationDismissalAfterDefaultAction:)]) {
    [content setShouldPreventNotificationDismissalAfterDefaultAction:YES];
  }  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:@"ramp"
                                           content:content
                                           trigger:nil];
  [[UNUserNotificationCenter currentNotificationCenter]
      addNotificationRequest:request
       withCompletionHandler:^(NSError *error) {
         if (error != nil) {
           fprintf(stderr, "notification failed: %s\n",
                   error.localizedDescription.UTF8String);
         }
       }];
}

static void notify(NSString *body) {
  fprintf(stderr, "%s\n", body.UTF8String);
  if (gBannerReady) {
    sendBanner(body);
    return;
  }
  if (NSBundle.mainBundle.bundleIdentifier != nil && !gBannerDenied) {
    gPending = body;
  }
}

static void reportWarmth(long warmth) {
  gSeenWarmth = warmth;
  if (warmth <= 0) {
    notify(@"Night Shift is off");
    return;
  }
  notify([NSString stringWithFormat:@"Warmth is at %ld%%", warmth]);
}

static void announce(int now) {
  if (gFromMinute < 0 || now < 0 || gNotified >= 3) {
    return;
  }
  int stage = glideStage(now);
  if (stage <= gNotified) {
    return;
  }
  if (NSBundle.mainBundle.bundleIdentifier != nil && !gBannerReady &&
      !gBannerDenied) {
    return;
  }
  gNotified = stage;
  long warmth = gApplied >= 0 ? gApplied : gFromValue;
  gSeenWarmth = warmth;
  if (warmth == gMax) {
    notify([NSString stringWithFormat:@"Warmth is at %ld%%", warmth]);
    return;
  }
  if (stage >= 3) {
    notify([NSString stringWithFormat:@"Warmth is at %ld%%, max %ld%%", warmth,
                                      gMax]);
    return;
  }
  notify([NSString
      stringWithFormat:@"Warmth is at %ld%%, reaching %ld%% at %@", warmth,
                       gMax, clockString(gToMinute)]);
}

static BOOL clockInSchedule(int start, int end, int clock) {
  int length = minutesBetween(start, end);
  if (length == 0 || clock < 0 || clock >= 1440) {
    return NO;
  }
  return minutesBetween(start, clock) <= length;
}

static BOOL aheadOfTurnOn(int now, int start, int clock) {
  int untilStart = minutesBetween(now, start);
  int untilClock = minutesBetween(now, clock);
  return untilStart > 0 && untilClock > 0 && untilClock <= untilStart;
}

static void ensureFullAt(int start, int end) {
  if (gFullAt >= 0) {
    return;
  }
  int length = minutesBetween(start, end);
  if (length == 0) {
    return;
  }
  if (gRampClock >= 0 && clockInSchedule(start, end, gRampClock)) {
    gFullAt = gRampClock;
    return;
  }
  int ramp = length < kRampMinutes ? length : kRampMinutes;
  gFullAt = (start + ramp) % 1440;
}

static BOOL adoptCurrentMax(long current) {
  if (gMaxKnown) {
    return YES;
  }
  if (current < 1 || current > 100) {
    return NO;
  }
  return rememberMax(current);
}

static void beginEvening(int start, int end) {
  if (!gMaxKnown) {
    return;
  }
  ensureFullAt(start, end);
  if (gFullAt < 0) {
    return;
  }
  gFromMinute = start;
  gFromValue = 1;
  gToMinute = gFullAt;
  gNotified = 0;
}

static void retarget(int now, long fromValue, int scheduleEnd) {
  if (fromValue < 1) {
    fromValue = 1;
  }
  if (fromValue > 100) {
    fromValue = 100;
  }
  gFromMinute = now;
  gFromValue = fromValue;
  gApplied = fromValue;
  gSuspended = NO;
  gToMinute = fromValue == gMax ? now : glideEnd(now, scheduleEnd);
  gNotified = 0;
  announce(now);
}

static void reportOutsideWarmth(BOOL enabled) {
  if (!gLaunched) {
    return;
  }
  if (!enabled) {
    if (gSeenWarmth != 0) {
      reportWarmth(0);
    }
    return;
  }
  long current = 0;
  if (readStrength(gClient, &current) && current != gSeenWarmth) {
    reportWarmth(current);
  }
}

static void refreshMenu(void);
static CFAbsoluteTime gLicenseFetchedAt = 0;

static void refreshSavedLicense(void) {
  if (!rampLicenseNeedsRefresh()) {
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (gLicenseFetchedAt != 0 && now - gLicenseFetchedAt < 3600) {
    return;
  }
  gLicenseFetchedAt = now;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString *out = nil;
    NSString *err = nil;
    if (rampTakeLicenseUpdate(&out, &err) != 0) {
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      refreshMenu();
    });
  });
}

static void rampTick(void) {
  BLStatus status;
  if (!readStatus(gClient, &status)) {
    return;
  }
  refreshSavedLicense();
  if (!rampLicensed()) {
    if (gFromMinute >= 0 || gSuspended || gEarly) {
      clearRamp();
    }
    if (status.mode == kModeCustom) {
      int now = minutesNow();
      if (now >= 0) {
        int start = status.schedule.from.hour * 60 + status.schedule.from.minute;
        int end = status.schedule.to.hour * 60 + status.schedule.to.minute;
        if (!insideWindow(start, end, now)) {
          reportOutsideWarmth(status.enabled);
        }
      }
    }
    return;
  }
  if (status.mode != kModeCustom) {
    if (!gLoggedSchedule) {
      fprintf(stderr, "evening ramp needs a Custom Night Shift schedule\n");
      gLoggedSchedule = YES;
    }
    clearRamp();
    gScheduleStart = -1;
    gArmedStart = -1;
    return;
  }
  gLoggedSchedule = NO;

  int now = minutesNow();
  if (now < 0) {
    return;
  }
  int start = status.schedule.from.hour * 60 + status.schedule.from.minute;
  int end = status.schedule.to.hour * 60 + status.schedule.to.minute;
  BOOL inside = insideWindow(start, end, now);
  if (gScheduleStart != start) {
    gScheduleStart = start;
    gFromMinute = -1;
    gFullAt = -1;
    gNotified = 0;
    gArmedStart = -1;
    gSuspended = NO;
    gEarly = NO;
  }

  if (!inside) {
    if (gEarly && gFromMinute >= 0 && gRampClock >= 0) {
      long current = 0;
      if (!readStrength(gClient, &current)) {
        return;
      }
      if (gApplied >= 0 && current != gApplied) {
        raiseMax(current);
        retarget(now, current > 0 ? current : 1, end);
      }
      long value = glideValue(now);
      long stored = 0;
      if (value >= 0 && value != gApplied &&
          applyStrength(gClient, value, &stored)) {
        gApplied = stored;
      }
      if (gApplied >= 0) {
        announce(now);
      }
      return;
    }
    clearRamp();
    int untilStart = minutesBetween(now, start);
    if (!status.enabled && untilStart >= 1 && untilStart <= kArmMinutes &&
        gArmedStart != start && stageStrength(gClient, 1)) {
      gArmedStart = start;
    }
    reportOutsideWarmth(status.enabled);
    return;
  }

  gEarly = NO;

  if (!status.enabled) {
    gSuspended = YES;
    gApplied = -1;
    return;
  }

  long current = 0;
  if (!readStrength(gClient, &current)) {
    return;
  }
  if (gSuspended) {
    if (!adoptCurrentMax(current)) {
      return;
    }
    ensureFullAt(start, end);
    retarget(now, current, end);
    return;
  }

  if (gFromMinute < 0 && !gMaxKnown) {
    if (!adoptCurrentMax(current)) {
      return;
    }
    ensureFullAt(start, end);
    retarget(now, current, end);
    return;
  }
  if (gFromMinute < 0) {
    beginEvening(start, end);
  }
  if (gFromMinute < 0) {
    return;
  }
  if (gApplied >= 0 && current != gApplied) {
    raiseMax(current);
    retarget(now, current, end);
    return;
  }

  long value = glideValue(now);
  long stored = 0;
  if (value >= 0 && value != gApplied &&
      applyStrength(gClient, value, &stored)) {
    gApplied = stored;
  }
  if (gApplied >= 0) {
    announce(now);
  }
}

static BOOL scheduleNow(int *start, int *end, int *now, BOOL *inWindow,
                           BOOL *enabled) {
  BLStatus status;
  *now = minutesNow();
  if (*now < 0 || !readStatus(gClient, &status) || status.mode != kModeCustom) {
    return NO;
  }
  *start = status.schedule.from.hour * 60 + status.schedule.from.minute;
  *end = status.schedule.to.hour * 60 + status.schedule.to.minute;
  *inWindow = insideWindow(*start, *end, *now);
  if (enabled != NULL) {
    *enabled = status.enabled;
  }
  return YES;
}

static BOOL warmthStatus(long *now, long *maxv, const char **state, int *full) {
  long current = 0;
  if (!readStrength(gClient, &current)) {
    return NO;
  }
  BLStatus status;
  const char *name = "idle";
  int arrival = -1;
  if (!readStatus(gClient, &status) || !status.enabled) {
    name = "off";
  } else if (gFromMinute >= 0) {
    int minute = minutesNow();
    name = minute >= 0 && glideStage(minute) >= 3 ? "holding" : "ramping";
    arrival = gToMinute;
  }
  *now = current;
  *maxv = gMaxKnown ? gMax : -1L;
  *state = name;
  *full = arrival;
  return YES;
}

static void writeStatus(int fd) {
  long now = 0;
  long maxv = 0;
  const char *state = "idle";
  int full = -1;
  if (!warmthStatus(&now, &maxv, &state, &full)) {
    dprintf(fd, "failed\n");
    return;
  }
  dprintf(fd, "%ld %ld %s %d\n", now, maxv, state, full);
}

static void noteMax(long value) {
  int start = 0;
  int end = 0;
  int now = 0;
  BOOL inWindow = NO;
  BOOL enabled = NO;
  if (scheduleNow(&start, &end, &now, &inWindow, &enabled) && inWindow &&
      enabled) {
    ensureFullAt(start, end);
    long current = gApplied >= 0 ? gApplied : value;
    readStrength(gClient, &current);
    retarget(now, current, end);
    return;
  }
  notify([NSString stringWithFormat:@"Max set to %ld%%", value]);
}

static BOOL commitMax(long value) {
  if (!rememberMax(value)) {
    return NO;
  }
  noteMax(value);
  return YES;
}

static void setMax(long value, int fd) {
  if (!commitMax(value)) {
    dprintf(fd, "failed\n");
    return;
  }
  dprintf(fd, "%ld\n", gMax);
}

static BOOL applyWarmth(long value, long *storedOut) {
  long stored = 0;
  if (!applyStrength(gClient, value, &stored)) {
    return NO;
  }
  if (storedOut != NULL) {
    *storedOut = stored;
  }
  if (!rampLicensed()) {
    clearRamp();
    gApplied = value == 0 ? -1 : stored;
    reportWarmth(stored);
    return YES;
  }
  int start = 0;
  int end = 0;
  int now = 0;
  BOOL inWindow = NO;
  BOOL scheduled = scheduleNow(&start, &end, &now, &inWindow, NULL);
  if (value == 0) {
    gApplied = -1;
    gSuspended = scheduled && inWindow;
    reportWarmth(0);
    return YES;
  }
  raiseMax(value);
  if (scheduled && inWindow) {
    ensureFullAt(start, end);
    retarget(now, stored, end);
  } else {
    reportWarmth(stored);
  }
  gApplied = stored;
  gSuspended = NO;
  return YES;
}

static BOOL setRampClock(int minute) {
  int start = 0;
  int end = 0;
  int now = 0;
  BOOL inWindow = NO;
  BOOL enabled = NO;
  BOOL scheduled = scheduleNow(&start, &end, &now, &inWindow, &enabled);
  if (scheduled && aheadOfTurnOn(now, start, minute)) {
    if (!rememberRampClock(minute)) {
      notify(@"Could not save the time");
      return NO;
    }
    long current = 0;
    if (!readStrength(gClient, &current)) {
      current = gApplied >= 0 ? gApplied : 0;
    }
    if (!gMaxKnown && !adoptCurrentMax(current)) {
      gEarly = NO;
      gFullAt = -1;
      notify([NSString stringWithFormat:@"Full at %@", clockString(minute)]);
      return YES;
    }
    gEarly = YES;
    gFullAt = minute;
    retarget(now, current > 0 ? current : 1, end);
    return YES;
  }
  if (scheduled && !clockInSchedule(start, end, minute)) {
    notify(@"That time is outside the Night Shift schedule");
    return NO;
  }
  if (!rememberRampClock(minute)) {
    notify(@"Could not save the time");
    return NO;
  }
  if (!scheduled || !inWindow || !enabled) {
    gFullAt = -1;
    notify([NSString stringWithFormat:@"Full at %@", clockString(minute)]);
    return YES;
  }
  gFullAt = minute;
  long current = 0;
  if (!readStrength(gClient, &current)) {
    current = gApplied >= 0 ? gApplied : 0;
  }
  int until = minutesBetween(now, minute);
  int untilEnd = minutesBetween(now, end);
  if (until == 0 || until > untilEnd) {
    if (!adoptCurrentMax(current)) {
      notify([NSString stringWithFormat:@"Full at %@", clockString(minute)]);
      return YES;
    }
    long stored = 0;
    if (applyStrength(gClient, gMax, &stored)) {
      gApplied = stored;
      current = stored;
    }
    gFromMinute = now;
    gFromValue = current > 0 ? current : 1;
    gToMinute = now;
    gSuspended = NO;
    gNotified = 0;
    announce(now);
    return YES;
  }
  retarget(now, current > 0 ? current : 1, end);
  return YES;
}

static void handleLine(const char *buf, int fd) {
  if (strcmp(buf, "status") == 0) {
    writeStatus(fd);
    return;
  }
  if (strncmp(buf, "max ", 4) == 0 || strncmp(buf, "ramp ", 5) == 0) {
    if (!rampLicensed()) {
      dprintf(fd, "locked\n");
      return;
    }
  }
  if (strncmp(buf, "max ", 4) == 0) {
    long value = 0;
    if (!parseNumber(buf + 4, 1, 100, &value)) {
      dprintf(fd, "failed\n");
      return;
    }
    setMax(value, fd);
    return;
  }
  if (strncmp(buf, "ramp ", 5) == 0) {
    long minute = 0;
    if (!parseNumber(buf + 5, 0, 1439, &minute) ||
        !setRampClock((int)minute)) {
      dprintf(fd, "failed\n");
      return;
    }
    dprintf(fd, "%ld\n", minute);
    return;
  }
  if (handleControl(buf, fd)) {
    return;
  }

  long value = 0;
  long stored = 0;
  if (!parseNumber(buf, 0, 100, &value) || !applyWarmth(value, &stored)) {
    dprintf(fd, "failed\n");
    return;
  }
  dprintf(fd, "%ld\n", stored);
}

@interface RampDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation RampDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions))completionHandler {
  (void)center;
  (void)notification;
  completionHandler(UNNotificationPresentationOptionBanner |
                    UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
  (void)center;
  if (![response.actionIdentifier isEqualToString:kSetMaxAction] &&
      ![response.actionIdentifier isEqualToString:kFullAtAction]) {
    completionHandler();
    return;
  }
  NSString *action = response.actionIdentifier;
  NSString *text = nil;
  if ([response isKindOfClass:[UNTextInputNotificationResponse class]]) {
    text = ((UNTextInputNotificationResponse *)response).userText;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!rampLicensed()) {
      notify(rampOffer());
      completionHandler();
      return;
    }
    if ([action isEqualToString:kSetMaxAction]) {
      long value = 0;
      if (text == nil || !parseMaxText(text, &value)) {
        notify(@"Enter a number from 1 to 100");
      } else if (!rememberMax(value)) {
        notify(@"Could not save the max");
      } else {
        noteMax(value);
      }
    } else {
      int minute = 0;
      if (text == nil || !parseClockText(text, &minute)) {
        notify(@"Use a time like 8:30 PM");
      } else {
        setRampClock(minute);
      }
    }
    completionHandler();
  });
}
@end

static RampDelegate *gDelegate = nil;
static dispatch_source_t gTimer = nil;
static dispatch_source_t gListener = nil;

static BOOL sliderSettled(void) {
  NSEvent *event = NSApp.currentEvent;
  if (event == nil) {
    return YES;
  }
  return event.type == NSEventTypeLeftMouseUp || event.type == NSEventTypeKeyDown;
}

static BOOL customSchedule(void) {
  BLStatus status;
  return readStatus(gClient, &status) && status.mode == kModeCustom;
}

static CBTrueToneClient *trueToneClient(void) {
  static CBTrueToneClient *client = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    client = [[CBTrueToneClient alloc] init];
  });
  return client;
}

static BOOL trueToneAvailable(void) {
  CBTrueToneClient *client = trueToneClient();
  return [client supported] && [client available];
}

static BOOL darkModeOn(void) {
  return SLSGetAppearanceThemeLegacy() == 1;
}

static void setDarkMode(BOOL on) {
  SLSSetAppearanceThemeSwitchesAutomatically(0);
  SLSSetAppearanceThemeLegacy(on ? 1 : 0);
}

static BOOL selectorMatches(id object, SEL sel, const char *expected) {
  if (object == nil || sel == NULL || expected == NULL) {
    return NO;
  }
  Method method = class_getInstanceMethod([object class], sel);
  const char *encoding = method == NULL ? NULL : method_getTypeEncoding(method);
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

static BOOL setBlueLightMode(int mode) {
  if (gClient == nil || (mode != 0 && mode != 1 && mode != 2)) {
    return NO;
  }
  if (!selectorMatches(gClient, @selector(setMode:), "B20@0:8i16")) {
    return NO;
  }
  return [gClient setMode:mode];
}

static NightshiftBrightnessClient *brightnessClient(void) {
  static NightshiftBrightnessClient *client = nil;
  static BOOL ready = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class cls = NSClassFromString(@"BrightnessSystemClient");
    if (cls == Nil) {
      return;
    }
    client = [[cls alloc] init];
    if (!selectorMatches(client, @selector(activateWithError:), "B24@0:8^@16") ||
        !selectorMatches(client, @selector(copyPropertyForKey:andDisplay:),
                         "@32@0:8@16Q24") ||
        !selectorMatches(client, @selector(setProperty:withKey:andDisplay:),
                         "B40@0:8@16@24Q32")) {
      client = nil;
      return;
    }
    NSError *error = nil;
    if (![client activateWithError:&error]) {
      client = nil;
      return;
    }
    ready = YES;
  });
  return ready ? client : nil;
}

static BOOL readCoreBrightness(uint32_t display, float *level) {
  NightshiftBrightnessClient *client = brightnessClient();
  if (client == nil || level == NULL) {
    return NO;
  }
  id value = [client copyPropertyForKey:@"DisplayServicesBrightness"
                              andDisplay:display];
  if (![value isKindOfClass:[NSNumber class]]) {
    return NO;
  }
  *level = [(NSNumber *)value floatValue];
  return YES;
}

static NSString *displayTitle(uint32_t display) {
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (number.unsignedIntValue == display && screen.localizedName.length > 0) {
      return screen.localizedName;
    }
  }
  return [NSString stringWithFormat:@"Display %u", display];
}

static int orderedDisplays(uint32_t *ids, int cap) {
  uint32_t count = 0;
  CGDirectDisplayID online[16];
  if (cap <= 0 || CGGetOnlineDisplayList(16, online, &count) != kCGErrorSuccess) {
    return 0;
  }
  int written = 0;
  for (int pass = 0; pass < 2; pass++) {
    for (uint32_t i = 0; i < count && written < cap; i++) {
      BOOL builtin = CGDisplayIsBuiltin(online[i]) != 0;
      if ((pass == 0) == builtin) {
        ids[written++] = online[i];
      }
    }
  }
  return written;
}

static NSMutableDictionary<NSNumber *, NSNumber *> *gSoftwareBrightness;
static NSMutableDictionary<NSString *, NSNumber *> *gBrightnessSaved;
static NSMutableSet<NSString *> *gCombinedBrightness;
static NSScreen *screenForDisplay(uint32_t display);

static NSString *displayBrightnessKey(uint32_t display) {
  return [NSString stringWithFormat:@"%u %u %u", CGDisplayVendorNumber(display),
                                    CGDisplayModelNumber(display),
                                    CGDisplaySerialNumber(display)];
}

static void loadBrightness(void) {
  gBrightnessSaved = [NSMutableDictionary dictionary];
  gCombinedBrightness = [NSMutableSet set];
  if (gBrightnessPath == nil) {
    return;
  }
  NSString *text = [NSString stringWithContentsOfFile:gBrightnessPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
  if (text == nil) {
    return;
  }
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    unsigned vendor = 0;
    unsigned model = 0;
    unsigned serial = 0;
    int percent = 0;
    char kind[16] = "";
    int count = sscanf(line.UTF8String, "%u %u %u %d %15s", &vendor, &model, &serial, &percent,
                        kind);
    if (count < 4) {
      continue;
    }
    if (percent < 0 || percent > 100) {
      continue;
    }
    NSString *key = [NSString stringWithFormat:@"%u %u %u", vendor, model, serial];
    gBrightnessSaved[key] = @(percent / 100.0);
    if (count >= 5 && strcmp(kind, "combined") == 0) {
      [gCombinedBrightness addObject:key];
    }
  }
}

static BOOL saveBrightness(void) {
  if (gBrightnessPath == nil || gBrightnessSaved == nil) {
    return YES;
  }
  NSMutableString *text = [NSMutableString string];
  for (NSString *key in gBrightnessSaved) {
    long percent = lround(gBrightnessSaved[key].doubleValue * 100.0);
    if (gCombinedBrightness != nil && [gCombinedBrightness containsObject:key]) {
      [text appendFormat:@"%@ %ld combined\n", key, percent];
    } else {
      [text appendFormat:@"%@ %ld\n", key, percent];
    }
  }
  if (![text writeToFile:gBrightnessPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL]) {
    return NO;
  }
  return chmod(gBrightnessPath.fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
}

static BOOL noteBrightness(uint32_t display, long percent) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  if (gBrightnessSaved == nil) {
    gBrightnessSaved = [NSMutableDictionary dictionary];
  }
  if (gSoftwareBrightness == nil) {
    gSoftwareBrightness = [NSMutableDictionary dictionary];
  }
  NSNumber *level = @(percent / 100.0);
  NSString *key = displayBrightnessKey(display);
  gBrightnessSaved[key] = level;
  gSoftwareBrightness[@(display)] = level;
  if (ddcReportsCombined(display)) {
    if (gCombinedBrightness == nil) {
      gCombinedBrightness = [NSMutableSet set];
    }
    [gCombinedBrightness addObject:key];
  }
  return saveBrightness();
}

static BOOL finishBrightness(uint32_t display, long percent) {
  noteCursorBrightness(display, percent);
  if (noteBrightness(display, percent)) {
    return YES;
  }
  notify(@"Could not save brightness");
  return NO;
}

static const int kGammaCount = 256;

typedef struct {
  uint32_t display;
  int count;
  CGGammaValue red[256];
  CGGammaValue green[256];
  CGGammaValue blue[256];
  BOOL saved;
} GammaSlot;

static GammaSlot gGamma[8];

static GammaSlot *gammaSlot(uint32_t display, BOOL create) {
  GammaSlot *freeSlot = NULL;
  for (int i = 0; i < 8; i++) {
    if (gGamma[i].saved && gGamma[i].display == display) {
      return &gGamma[i];
    }
    if (!gGamma[i].saved && freeSlot == NULL) {
      freeSlot = &gGamma[i];
    }
  }
  if (!create || freeSlot == NULL) {
    return NULL;
  }
  CGDisplayCount count = 0;
  if (CGGetDisplayTransferByTable(display, kGammaCount, freeSlot->red, freeSlot->green,
                                  freeSlot->blue, &count) != kCGErrorSuccess ||
      count == 0 || count > kGammaCount) {
    return NULL;
  }
  freeSlot->display = display;
  freeSlot->count = (int)count;
  freeSlot->saved = YES;
  return freeSlot;
}

static void restoreGamma(uint32_t display) {
  GammaSlot *slot = gammaSlot(display, NO);
  if (slot == NULL) {
    return;
  }
  CGSetDisplayTransferByTable(display, (CGDisplayCount)slot->count, slot->red, slot->green,
                              slot->blue);
}

static BOOL setGammaLevel(uint32_t display, float level) {
  if (level < 0) {
    level = 0;
  }
  if (level > 1) {
    level = 1;
  }
  GammaSlot *slot = gammaSlot(display, YES);
  if (slot == NULL) {
    return NO;
  }
  if (level >= 0.999f) {
    return CGSetDisplayTransferByTable(display, (CGDisplayCount)slot->count, slot->red,
                                       slot->green, slot->blue) == kCGErrorSuccess;
  }
  CGGammaValue red[256], green[256], blue[256];
  for (int i = 0; i < slot->count; i++) {
    red[i] = slot->red[i] * level;
    green[i] = slot->green[i] * level;
    blue[i] = slot->blue[i] * level;
  }
  return CGSetDisplayTransferByTable(display, (CGDisplayCount)slot->count, red, green,
                                     blue) == kCGErrorSuccess;
}

typedef struct {
  uint32_t display;
  int max;
  int current;
  int floorRaw;
  int combined;
  IOAVServiceRef service;
} DDCSlot;

static DDCSlot gDDC[8];
static BOOL gDDCBusy = NO;
static BOOL gDDCAgain = NO;
static CFAbsoluteTime gDDCLast = 0;
static uint32_t gRestoredDisplays[8];
static int gRestoredCount = 0;
static int gPendingKeySteps = 0;

static uint8_t ddcChecksum(const uint8_t *bytes, int count) {
  uint8_t sum = (uint8_t)(0x6E ^ 0x51);
  for (int i = 0; i < count; i++) {
    sum ^= bytes[i];
  }
  return sum;
}

static IOAVServiceRef serviceMatching(uint32_t model, uint32_t serial) {
  io_iterator_t iter = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                   &iter) != KERN_SUCCESS) {
    return NULL;
  }
  io_service_t service;
  IOAVServiceRef exact = NULL;
  IOAVServiceRef modelOnly = NULL;
  int modelHits = 0;
  while ((service = IOIteratorNext(iter))) {
    IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    IOObjectRelease(service);
    if (av == NULL) {
      continue;
    }
    CFDataRef edid = NULL;
    if (IOAVServiceCopyEDID(av, &edid) != 0 || edid == NULL ||
        CFDataGetLength(edid) < 16) {
      if (edid != NULL) {
        CFRelease(edid);
      }
      CFRelease(av);
      continue;
    }
    const uint8_t *bytes = CFDataGetBytePtr(edid);
    uint32_t product = (uint32_t)(bytes[10] | (bytes[11] << 8));
    uint32_t edidSerial = (uint32_t)(bytes[12] | (bytes[13] << 8) | (bytes[14] << 16) |
                                     (bytes[15] << 24));
    BOOL sameModel = product == model;
    BOOL sameSerial = serial != 0 && edidSerial == serial;
    CFRelease(edid);
    if (!sameModel) {
      CFRelease(av);
      continue;
    }
    modelHits++;
    if (sameSerial && exact == NULL) {
      exact = av;
    } else if (modelOnly == NULL) {
      modelOnly = av;
    } else {
      CFRelease(av);
    }
  }
  IOObjectRelease(iter);
  if (exact != NULL) {
    if (modelOnly != NULL && modelOnly != exact) {
      CFRelease(modelOnly);
    }
    return exact;
  }
  if (modelHits == 1) {
    return modelOnly;
  }
  if (modelOnly != NULL) {
    CFRelease(modelOnly);
  }
  return NULL;
}

static BOOL ddcReadOnce(IOAVServiceRef service, int *current, int *max) {
  uint8_t request[4] = {0x82, 0x01, 0x10, 0};
  request[3] = (uint8_t)(0x6E ^ request[0] ^ request[1] ^ request[2]);
  if (IOAVServiceWriteI2C(service, 0x37, 0x51, request, 4) != 0) {
    return NO;
  }
  usleep(50000);
  uint8_t reply[11];
  memset(reply, 0, sizeof(reply));
  if (IOAVServiceReadI2C(service, 0x37, 0, reply, 11) != 0) {
    return NO;
  }
  if ((reply[0] != 0x6E && reply[0] != 0x6e) || reply[2] != 0x02 || reply[3] != 0x00 ||
      reply[4] != 0x10) {
    return NO;
  }
  uint8_t sum = 0x50;
  for (int i = 0; i < 10; i++) {
    sum ^= reply[i];
  }
  if (sum != reply[10]) {
    return NO;
  }
  int maxValue = (reply[6] << 8) | reply[7];
  int currentValue = (reply[8] << 8) | reply[9];
  if (maxValue <= 0 || currentValue < 0 || currentValue > maxValue) {
    return NO;
  }
  *current = currentValue;
  *max = maxValue;
  return YES;
}

static void clearDDCSlot(int i) {
  __atomic_store_n(&gDDC[i].max, 0, __ATOMIC_RELEASE);
  IOAVServiceRef service = gDDC[i].service;
  gDDC[i].service = NULL;
  gDDC[i].display = 0;
  gDDC[i].current = 0;
  gDDC[i].floorRaw = -1;
  gDDC[i].combined = -1;
  if (service != NULL) {
    CFRelease(service);
  }
}

static void publishDDC(uint32_t display, IOAVServiceRef service, int current, int max) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display != display && gDDC[i].display != 0) {
      continue;
    }
    if (gDDC[i].service != NULL && gDDC[i].service != service) {
      CFRelease(gDDC[i].service);
    }
    if (gDDC[i].display != display) {
      gDDC[i].floorRaw = -1;
      gDDC[i].combined = -1;
    }
    gDDC[i].display = display;
    gDDC[i].service = service;
    gDDC[i].current = current;
    __atomic_store_n(&gDDC[i].max, max, __ATOMIC_RELEASE);
    return;
  }
  if (service != NULL) {
    CFRelease(service);
  }
}

static BOOL ddcReady(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display &&
        __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE) > 0) {
      return YES;
    }
  }
  return NO;
}

static BOOL ddcFailed(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display &&
        __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE) < 0) {
      return YES;
    }
  }
  return NO;
}

static BOOL ddcUnconfirmed(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display && gDDC[i].service != NULL &&
        __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE) <= 0) {
      return YES;
    }
  }
  return NO;
}

static BOOL ddcHasService(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display && gDDC[i].service != NULL) {
      return YES;
    }
  }
  return NO;
}

static BOOL ddcPending(uint32_t display) {
  if (display == 0 || CGDisplayIsBuiltin(display)) {
    return NO;
  }
  return !ddcReady(display) && !ddcFailed(display) && !ddcUnconfirmed(display);
}

static BOOL ddcNeedsProbe(void) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  for (int i = 0; i < count; i++) {
    if (ddcPending(ids[i])) {
      return YES;
    }
  }
  return NO;
}

static void restoreSavedBrightness(void);
static void refreshMenu(void);
static BOOL stepActiveBrightness(int direction);

static void applyPendingBrightnessKeys(void) {
  int steps = gPendingKeySteps;
  gPendingKeySteps = 0;
  if (steps == 0) {
    return;
  }
  int direction = steps > 0 ? 1 : -1;
  int count = steps > 0 ? steps : -steps;
  if (count > 16) {
    count = 16;
  }
  for (int i = 0; i < count; i++) {
    stepActiveBrightness(direction);
  }
}

static void probeDDC(void) {
  if (gDDCBusy) {
    gDDCAgain = YES;
    return;
  }
  if (!ddcNeedsProbe() && gDDCLast != 0 && CFAbsoluteTimeGetCurrent() - gDDCLast < 3) {
    return;
  }
  gDDCBusy = YES;
  gDDCLast = CFAbsoluteTimeGetCurrent();
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    uint32_t ids[16];
    int count = orderedDisplays(ids, 16);
    uint32_t targets[8];
    uint32_t models[8];
    uint32_t serials[8];
    int pending = 0;
    for (int i = 0; i < count && pending < 8; i++) {
      if (CGDisplayIsBuiltin(ids[i]) || ddcReady(ids[i])) {
        continue;
      }
      targets[pending] = ids[i];
      models[pending] = CGDisplayModelNumber(ids[i]);
      serials[pending] = CGDisplaySerialNumber(ids[i]);
      pending++;
    }
    typedef struct {
      uint32_t display;
      int current;
      int max;
      IOAVServiceRef service;
    } DDCResult;
    DDCResult *results = pending > 0 ? calloc((size_t)pending, sizeof(DDCResult)) : NULL;
    for (int i = 0; i < pending; i++) {
      IOAVServiceRef service = serviceMatching(models[i], serials[i]);
      int current = 0;
      int max = 0;
      BOOL ok = NO;
      if (service != NULL) {
        for (int attempt = 0; attempt < 4 && !ok; attempt++) {
          ok = ddcReadOnce(service, &current, &max);
        }
      }
      results[i].display = targets[i];
      results[i].current = ok ? current : 0;
      results[i].max = ok ? max : (service != NULL ? 0 : -1);
      results[i].service = service;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      for (int i = 0; i < pending; i++) {
        if (results[i].service == NULL && ddcHasService(results[i].display)) {
          continue;
        }
        publishDDC(results[i].display, results[i].service, results[i].current,
                   results[i].max);
      }
      free(results);
      gDDCBusy = NO;
      BOOL again = gDDCAgain;
      gDDCAgain = NO;
      restoreSavedBrightness();
      applyPendingBrightnessKeys();
      refreshMenu();
      if (again) {
        probeDDC();
      }
    });
  });
}

static BOOL ddcCached(uint32_t display, float *level) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display != display) {
      continue;
    }
    int max = __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE);
    if (max <= 0) {
      return NO;
    }
    if (level != NULL) {
      *level = (float)gDDC[i].current / (float)max;
    }
    return YES;
  }
  return NO;
}

static const int kDDCAssumeScale = 100;

static int ddcScale(int storedMax) {
  return storedMax > 0 ? storedMax : kDDCAssumeScale;
}

static int ddcValue(long percent, int scale) {
  int value = (int)llround((percent / 100.0) * scale);
  if (value < 0) {
    value = 0;
  }
  if (value > scale) {
    value = scale;
  }
  return value;
}

static BOOL ddcNear(int got, int want, int scale) {
  int tol = scale / 20;
  if (tol < 2) {
    tol = 2;
  }
  int diff = got - want;
  if (diff < 0) {
    diff = -diff;
  }
  return diff <= tol;
}

static BOOL ddcWriteOnce(IOAVServiceRef service, int value) {
  uint8_t request[6] = {0x84, 0x03, 0x10, (uint8_t)((value >> 8) & 0xFF),
                        (uint8_t)(value & 0xFF), 0};
  request[5] = ddcChecksum(request, 5);
  BOOL wrote = NO;
  for (int cycle = 0; cycle < 2; cycle++) {
    usleep(10000);
    if (IOAVServiceWriteI2C(service, 0x37, 0x51, request, 6) == 0) {
      wrote = YES;
    }
  }
  return wrote;
}

static BOOL ddcCommit(DDCSlot *slot, int current, int max) {
  slot->current = current;
  __atomic_store_n(&slot->max, max, __ATOMIC_RELEASE);
  return YES;
}

static DDCSlot *ddcSlot(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display && gDDC[i].service != NULL) {
      return &gDDC[i];
    }
  }
  return NULL;
}

static long ddcRawPercent(int raw, int scale) {
  if (scale <= 0) {
    return 0;
  }
  long percent = (long)llround((raw * 100.0) / (double)scale);
  if (percent < 0) {
    return 0;
  }
  if (percent > 100) {
    return 100;
  }
  return percent;
}

static void ddcNoteMove(DDCSlot *slot, int before, int wanted, int landed, int scale,
                        long percent) {
  int tol = scale / 20;
  if (tol < 2) {
    tol = 2;
  }
  if (percent <= 0 && landed > 0 && wanted < before) {
    if (slot->floorRaw < 0 || landed < slot->floorRaw) {
      slot->floorRaw = landed;
    }
    return;
  }
  if (landed > wanted + tol) {
    int far = (scale * 15) / 100;
    if (far < tol + 1) {
      far = tol + 1;
    }
    BOOL movedDown = before - landed > tol;
    BOOL askedFar = wanted < before && landed - wanted > far;
    if (movedDown || askedFar || slot->floorRaw == landed) {
      if (slot->floorRaw < 0 || landed < slot->floorRaw) {
        slot->floorRaw = landed;
      }
    }
    return;
  }
  if (slot->floorRaw > landed) {
    slot->floorRaw = wanted <= tol ? 0 : -1;
  }
}

static long ddcFloorPercent(uint32_t display) {
  DDCSlot *slot = ddcSlot(display);
  if (slot == NULL || slot->floorRaw < 0) {
    return -1;
  }
  if (slot->floorRaw == 0) {
    return 0;
  }
  int scale = ddcScale(__atomic_load_n(&slot->max, __ATOMIC_ACQUIRE));
  return ddcRawPercent(slot->floorRaw, scale);
}

static const long kCombinedSwitch = 50;

static long lampToCombined(long lamp, long floor) {
  if (floor < 0) {
    floor = 0;
  }
  if (lamp < floor) {
    lamp = floor;
  }
  if (lamp > 100) {
    lamp = 100;
  }
  long room = 100 - floor;
  if (room <= 0) {
    return kCombinedSwitch;
  }
  return kCombinedSwitch + ((lamp - floor) * (100 - kCombinedSwitch)) / room;
}

static void combinedLevels(long percent, long floor, long *hardware, long *software) {
  if (floor < 0) {
    floor = 0;
  }
  if (floor > 99) {
    floor = 99;
  }
  if (percent >= kCombinedSwitch) {
    long rise = percent - kCombinedSwitch;
    *hardware = floor + ((100 - floor) * rise) / (100 - kCombinedSwitch);
    *software = 100;
    return;
  }
  *hardware = floor;
  *software = (percent * 100) / kCombinedSwitch;
}

static long ddcShownPercent(uint32_t display) {
  DDCSlot *slot = ddcSlot(display);
  if (slot == NULL) {
    return -1;
  }
  if (slot->combined >= 0 && slot->combined <= 100) {
    return slot->combined;
  }
  int max = __atomic_load_n(&slot->max, __ATOMIC_ACQUIRE);
  if (max <= 0) {
    return -1;
  }
  long floor = slot->floorRaw > 0 ? ddcRawPercent(slot->floorRaw, max) : 0;
  return lampToCombined(ddcRawPercent(slot->current, max), floor);
}

static void ddcRememberCombined(uint32_t display, long percent) {
  DDCSlot *slot = ddcSlot(display);
  if (slot == NULL) {
    return;
  }
  slot->combined = (int)percent;
}

static BOOL ddcReportsCombined(uint32_t display) {
  DDCSlot *slot = ddcSlot(display);
  return slot != NULL && slot->combined >= 0;
}

static BOOL ddcSet(uint32_t display, long percent, long *landedPercent) {
  DDCSlot *slot = ddcSlot(display);
  if (slot == NULL) {
    return NO;
  }
  int scale = ddcScale(__atomic_load_n(&slot->max, __ATOMIC_ACQUIRE));
  int before = slot->current;
  int value = ddcValue(percent, scale);
  if (!ddcWriteOnce(slot->service, value)) {
    return NO;
  }
  int readCurrent = 0;
  int readMax = 0;
  if (!ddcReadOnce(slot->service, &readCurrent, &readMax) || readMax <= 0) {
    ddcCommit(slot, value, scale);
    if (landedPercent != NULL) {
      *landedPercent = percent;
    }
    return YES;
  }
  int wanted = ddcValue(percent, readMax);
  if (wanted != value && ddcNear(readCurrent, value, readMax) &&
      ddcWriteOnce(slot->service, wanted)) {
    int corrected = 0;
    int correctedMax = 0;
    if (ddcReadOnce(slot->service, &corrected, &correctedMax) && correctedMax > 0) {
      readCurrent = corrected;
      readMax = correctedMax;
      wanted = ddcValue(percent, readMax);
    } else {
      ddcCommit(slot, wanted, readMax);
      if (landedPercent != NULL) {
        *landedPercent = percent;
      }
      return YES;
    }
  }
  ddcCommit(slot, readCurrent, readMax);
  ddcNoteMove(slot, before, wanted, readCurrent, readMax, percent);
  if (landedPercent != NULL) {
    *landedPercent = ddcRawPercent(readCurrent, readMax);
  }
  return YES;
}

static BOOL externalNeedsDDC(void) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == 0) {
      continue;
    }
    int max = __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE);
    if (max < 0 || (gDDC[i].service != NULL && max <= 0)) {
      return YES;
    }
  }
  return NO;
}

static BOOL shadeLogical(uint32_t display, float *level);

static BOOL readDisplayBrightness(uint32_t display, float *level, BOOL *writable) {
  float value = 0;
  long shown = ddcShownPercent(display);
  if (shown >= 0) {
    if (level != NULL) {
      *level = (float)shown / 100.0f;
    }
    if (writable != NULL) {
      *writable = YES;
    }
    return YES;
  }
  if (!DisplayServicesCanChangeBrightness(display) && shadeLogical(display, &value)) {
    if (level != NULL) {
      *level = value;
    }
    if (writable != NULL) {
      *writable = YES;
    }
    return YES;
  }
  if (DisplayServicesGetBrightness(display, &value) == 0) {
    if (level != NULL) {
      *level = value;
    }
    if (writable != NULL) {
      *writable = DisplayServicesCanChangeBrightness(display) != 0;
    }
    return YES;
  }
  if (readCoreBrightness(display, &value)) {
    if (level != NULL) {
      *level = value;
    }
    if (writable != NULL) {
      *writable = YES;
    }
    return YES;
  }
  if (ddcCached(display, &value)) {
    if (level != NULL) {
      *level = value;
    }
    if (writable != NULL) {
      *writable = YES;
    }
    return YES;
  }
  if ((ddcFailed(display) || ddcUnconfirmed(display)) &&
      screenForDisplay(display) != nil) {
    NSNumber *saved = gSoftwareBrightness[@(display)];
    if (level != NULL) {
      *level = saved == nil ? 1.0f : saved.floatValue;
    }
    if (writable != NULL) {
      *writable = YES;
    }
    return YES;
  }
  if (writable != NULL) {
    *writable = NO;
  }
  return NO;
}

@interface DimWindow : NSWindow
@end

@implementation DimWindow
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

static NSMutableDictionary<NSNumber *, NSWindow *> *gShades = nil;
static void liftBrightnessHUD(void);

static NSScreen *screenForDisplay(uint32_t display) {
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (number.unsignedIntValue == display) {
      return screen;
    }
  }
  return nil;
}

static void applyDim(uint32_t display, long percent) {
  if (gShades == nil) {
    gShades = [NSMutableDictionary dictionary];
  }
  if (gSoftwareBrightness == nil) {
    gSoftwareBrightness = [NSMutableDictionary dictionary];
  }
  NSNumber *key = @(display);
  NSWindow *shade = gShades[key];
  if (percent >= 100) {
    [shade orderOut:nil];
    [gSoftwareBrightness removeObjectForKey:key];
    liftBrightnessHUD();
    return;
  }
  NSScreen *screen = screenForDisplay(display);
  if (screen == nil) {
    return;
  }
  if (shade == nil) {
    shade = [[DimWindow alloc] initWithContentRect:screen.frame
                                         styleMask:NSWindowStyleMaskBorderless
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    shade.opaque = NO;
    shade.backgroundColor = NSColor.blackColor;
    shade.ignoresMouseEvents = YES;
    shade.hasShadow = NO;
    shade.level = kCGMaximumWindowLevel;
    shade.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle;
    shade.releasedWhenClosed = NO;
    gShades[key] = shade;
  }
  [shade setFrame:screen.frame display:NO];
  shade.level = kCGMaximumWindowLevel;
  CGFloat alpha = (CGFloat)(100 - percent) / 100.0;
  if (shade.isVisible) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.12;
      shade.animator.alphaValue = alpha;
    }];
  } else {
    shade.alphaValue = alpha;
  }
  [shade orderFront:nil];
  gSoftwareBrightness[key] = @((float)percent / 100.0f);
  liftBrightnessHUD();
}

static BOOL shadeLogical(uint32_t display, float *level) {
  NSWindow *shade = gShades[@(display)];
  if (shade == nil || !shade.isVisible) {
    return NO;
  }
  NSNumber *saved = gSoftwareBrightness[@(display)];
  if (saved == nil) {
    return NO;
  }
  if (level != NULL) {
    *level = saved.floatValue;
  }
  return YES;
}

static const long kSoftwareDimFloor = 10;

static long softwareDimPercent(uint32_t display, long percent) {
  if (percent < kSoftwareDimFloor && ddcFailed(display) &&
      !DisplayServicesCanChangeBrightness(display)) {
    return kSoftwareDimFloor;
  }
  return percent;
}

static BOOL setDisplayBrightness(uint32_t display, long percent) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  float level = (float)percent / 100.0f;
  if (DisplayServicesCanChangeBrightness(display)) {
    if (DisplayServicesSetBrightness(display, level) != 0) {
      return NO;
    }
    restoreGamma(display);
    applyDim(display, 100);
    return finishBrightness(display, percent);
  }
  float current = 0;
  if (readCoreBrightness(display, &current)) {
    NightshiftBrightnessClient *client = brightnessClient();
    if (client != nil && [client setProperty:@(level)
                                     withKey:@"DisplayServicesBrightness"
                                  andDisplay:display]) {
      restoreGamma(display);
      applyDim(display, 100);
      return finishBrightness(display, percent);
    }
  }
  long floor = ddcFloorPercent(display);
  long hardware = percent;
  long software = 100;
  combinedLevels(percent, floor, &hardware, &software);
  long landed = hardware;
  if (ddcSet(display, hardware, &landed)) {
    restoreGamma(display);
    long learned = ddcFloorPercent(display);
    if (learned != floor) {
      combinedLevels(percent, learned, &hardware, &software);
      if (hardware != landed && !ddcSet(display, hardware, &landed)) {
        return NO;
      }
    }
    ddcRememberCombined(display, percent);
    applyDim(display, software);
    return finishBrightness(display, percent);
  }
  if (ddcReady(display)) {
    return NO;
  }
  if ((ddcFailed(display) || ddcUnconfirmed(display)) &&
      screenForDisplay(display) != nil) {
    restoreGamma(display);
    if (ddcUnconfirmed(display) && percent < kSoftwareDimFloor) {
      percent = kSoftwareDimFloor;
    } else {
      percent = softwareDimPercent(display, percent);
    }
    applyDim(display, percent);
    return finishBrightness(display, percent);
  }
  if (screenForDisplay(display) != nil) {
    return NO;
  }
  if (setGammaLevel(display, level)) {
    return finishBrightness(display, percent);
  }
  return NO;
}

static BOOL displayWasRestored(uint32_t display) {
  for (int i = 0; i < gRestoredCount; i++) {
    if (gRestoredDisplays[i] == display) {
      return YES;
    }
  }
  return NO;
}

static void markDisplayRestored(uint32_t display) {
  if (displayWasRestored(display) || gRestoredCount >= 8) {
    return;
  }
  gRestoredDisplays[gRestoredCount++] = display;
}

static void forgetOfflineDisplays(void) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  int kept = 0;
  for (int i = 0; i < gRestoredCount; i++) {
    BOOL online = NO;
    for (int j = 0; j < count; j++) {
      if (ids[j] == gRestoredDisplays[i]) {
        online = YES;
        break;
      }
    }
    if (online) {
      gRestoredDisplays[kept++] = gRestoredDisplays[i];
    }
  }
  gRestoredCount = kept;
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == 0) {
      continue;
    }
    BOOL listed = NO;
    for (int j = 0; j < count; j++) {
      if (ids[j] == gDDC[i].display) {
        listed = YES;
        break;
      }
    }
    if (!listed) {
      clearDDCSlot(i);
    }
  }
  for (NSNumber *key in gShades.allKeys) {
    BOOL online = NO;
    for (int j = 0; j < count; j++) {
      if (ids[j] == key.unsignedIntValue) {
        online = YES;
        break;
      }
    }
    if (online) {
      continue;
    }
    [gShades[key] orderOut:nil];
    [gShades removeObjectForKey:key];
    [gSoftwareBrightness removeObjectForKey:key];
  }
  liftBrightnessHUD();
  noteCursorDisplaysOffline();
}

static void refitDimWindows(void) {
  for (NSNumber *key in gShades) {
    NSWindow *shade = gShades[key];
    if (!shade.isVisible) {
      continue;
    }
    NSScreen *screen = screenForDisplay(key.unsignedIntValue);
    if (screen == nil) {
      continue;
    }
    [shade setFrame:screen.frame display:NO];
    [shade orderFront:nil];
  }
  liftBrightnessHUD();
}

static void restoreSavedBrightness(void) {
  forgetOfflineDisplays();
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  if (gSoftwareBrightness == nil) {
    gSoftwareBrightness = [NSMutableDictionary dictionary];
  }
  for (int i = 0; i < count; i++) {
    if (displayWasRestored(ids[i])) {
      continue;
    }
    NSNumber *saved = gBrightnessSaved[displayBrightnessKey(ids[i])];
    if (saved == nil || CGDisplayIsBuiltin(ids[i])) {
      markDisplayRestored(ids[i]);
      continue;
    }
    gSoftwareBrightness[@(ids[i])] = saved;
    long percent = lround(saved.doubleValue * 100.0);
    NSString *savedKey = displayBrightnessKey(ids[i]);
    if (gCombinedBrightness == nil || ![gCombinedBrightness containsObject:savedKey]) {
      percent = lampToCombined(percent, 0);
    }
    if (percent >= 100) {
      markDisplayRestored(ids[i]);
      continue;
    }
    float live = 0;
    if (DisplayServicesGetBrightness(ids[i], &live) == 0 &&
        DisplayServicesCanChangeBrightness(ids[i])) {
      markDisplayRestored(ids[i]);
      continue;
    }
    if (readCoreBrightness(ids[i], &live)) {
      markDisplayRestored(ids[i]);
      continue;
    }
    if (setDisplayBrightness(ids[i], percent)) {
      markDisplayRestored(ids[i]);
    }
  }
}

static BOOL loginItemOn(void) {
  return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}

static const CGFloat kBrightnessHUDWidth = 312;
static const CGFloat kBrightnessHUDHeight = 80;

@interface BrightnessMeter : NSView
@property(nonatomic) long percent;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) void (^onScrub)(long percent);
@property(nonatomic, copy) void (^onScrubBegan)(void);
@property(nonatomic, copy) void (^onScrubEnd)(void);
@end

@implementation BrightnessMeter

- (BOOL)isOpaque {
  return NO;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self setNeedsDisplay:YES];
}

- (void)drawSymbol:(NSString *)name inRect:(NSRect)rect pointSize:(CGFloat)size
             color:(NSColor *)color {
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  if (image == nil) {
    return;
  }
  NSImageSymbolConfiguration *config =
      [NSImageSymbolConfiguration configurationWithPointSize:size
                                                      weight:NSFontWeightMedium];
  image = [image imageWithSymbolConfiguration:config];
  NSImage *tinted = [image copy];
  [tinted lockFocus];
  [color set];
  NSRectFillUsingOperation(NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
                           NSCompositingOperationSourceAtop);
  [tinted unlockFocus];
  [tinted drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1];
}

- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  NSRect bounds = self.bounds;
  NSColor *label = NSColor.labelColor;
  NSString *name = self.displayName.length > 0 ? self.displayName : @"Display";
  NSFont *nameFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  NSString *percentText = [NSString stringWithFormat:@"%ld%%", self.percent];
  NSFont *percentFont = [NSFont monospacedDigitSystemFontOfSize:13
                                                         weight:NSFontWeightSemibold];
  NSDictionary *percentAttrs = @{
    NSFontAttributeName : percentFont,
    NSForegroundColorAttributeName : label
  };
  NSSize percentSize = [percentText sizeWithAttributes:percentAttrs];
  CGFloat pad = 22;
  NSSize nameSize = [name sizeWithAttributes:@{NSFontAttributeName : nameFont}];
  CGFloat titleY = bounds.size.height - 16 - nameSize.height;
  CGFloat titleMax = bounds.size.width - pad * 2 - percentSize.width - 12;
  if (titleMax < 40) {
    titleMax = 40;
  }
  NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
  titleStyle.lineBreakMode = NSLineBreakByTruncatingTail;
  [name drawInRect:NSMakeRect(pad, titleY, titleMax, nameSize.height)
      withAttributes:@{
        NSFontAttributeName : nameFont,
        NSForegroundColorAttributeName : label,
        NSParagraphStyleAttributeName : titleStyle
      }];
  [percentText drawAtPoint:NSMakePoint(bounds.size.width - pad - percentSize.width,
                                       titleY + (nameSize.height - percentSize.height) / 2.0)
            withAttributes:percentAttrs];

  NSRect track = [self trackRect];
  CGFloat sliderY = NSMidY(track);
  CGFloat leftSun = 14;
  CGFloat rightSun = 17;
  NSRect leftRect = NSMakeRect(pad, sliderY - leftSun / 2.0, leftSun, leftSun);
  NSRect rightRect =
      NSMakeRect(bounds.size.width - pad - rightSun, sliderY - rightSun / 2.0, rightSun, rightSun);
  [self drawSymbol:@"sun.min" inRect:leftRect pointSize:12 color:label];
  [self drawSymbol:@"sun.max" inRect:rightRect pointSize:15 color:label];

  CGFloat fillX = track.origin.x + track.size.width * ((CGFloat)self.percent / 100.0);
  CGFloat knobSize = 16;
  int dots = 12;
  for (int i = 0; i < dots; i++) {
    CGFloat x = track.origin.x + track.size.width * ((CGFloat)i / (CGFloat)(dots - 1));
    if (x <= fillX || fabs(x - fillX) < knobSize / 2.0) {
      continue;
    }
    NSRect dot = NSMakeRect(x - 1.4, sliderY - 1.4, 2.8, 2.8);
    [[label colorWithAlphaComponent:0.55] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
  }
  CGFloat fillWidth = fillX - track.origin.x;
  if (fillWidth < knobSize / 2.0) {
    fillWidth = knobSize / 2.0;
  }
  NSRect fill = NSMakeRect(track.origin.x, sliderY - 2.5, fillWidth, 5);
  [label setFill];
  [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2.5 yRadius:2.5] fill];

  NSRect knobRect = NSMakeRect(fillX - knobSize / 2.0, sliderY - knobSize / 2.0, knobSize, knobSize);
  NSBezierPath *knob = [NSBezierPath bezierPathWithOvalInRect:knobRect];
  [[NSColor.whiteColor colorWithAlphaComponent:0.96] setFill];
  [knob fill];
}

- (NSRect)trackRect {
  NSRect bounds = self.bounds;
  CGFloat pad = 22;
  CGFloat leftSun = 14;
  CGFloat rightSun = 17;
  CGFloat trackLeft = pad + leftSun + 12;
  CGFloat trackRight = bounds.size.width - pad - rightSun - 12;
  return NSMakeRect(trackLeft, 10, MAX(1, trackRight - trackLeft), 34);
}

- (long)percentForX:(CGFloat)x {
  NSRect track = [self trackRect];
  CGFloat span = track.size.width;
  CGFloat t = span <= 0 ? 0 : (x - track.origin.x) / span;
  if (t < 0) {
    t = 0;
  }
  if (t > 1) {
    t = 1;
  }
  return (long)llround(t * 100.0);
}

- (void)scrubToPoint:(NSPoint)point {
  long next = [self percentForX:point.x];
  if (next == self.percent) {
    return;
  }
  self.percent = next;
  [self setNeedsDisplay:YES];
  if (self.onScrub != nil) {
    self.onScrub(next);
  }
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (point.y > NSMaxY([self trackRect])) {
    return;
  }
  if (self.onScrubBegan != nil) {
    self.onScrubBegan();
  }
  [[NSCursor resizeLeftRightCursor] push];
  [self scrubToPoint:point];
  while (YES) {
    NSEvent *next = [self.window
        nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
    if (next == nil || next.type == NSEventTypeLeftMouseUp) {
      break;
    }
    [self scrubToPoint:[self convertPoint:next.locationInWindow fromView:nil]];
  }
  [NSCursor pop];
  if (self.onScrubEnd != nil) {
    self.onScrubEnd();
  }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:[self trackRect] cursor:[NSCursor resizeLeftRightCursor]];
}

- (BOOL)isAccessibilityElement {
  return YES;
}

- (NSString *)accessibilityLabel {
  return [NSString stringWithFormat:@"%@ brightness %ld percent", self.displayName,
                                    self.percent];
}
@end

@interface BrightnessPanel : NSPanel
@end

@implementation BrightnessPanel
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}
@end

@interface BrightnessGlass : NSGlassEffectView
@end

@implementation BrightnessGlass
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  if (hit == self && self.contentView != nil) {
    return self.contentView;
  }
  return hit;
}
@end

static void refreshMenu(void);
static void hideBrightnessHUD(void);
static NSRect menuBarIconFrame(void);

static BrightnessPanel *gBrightnessPanel = nil;
static BrightnessMeter *gBrightnessMeter = nil;
static NSGlassEffectView *gBrightnessGlass = nil;
static NSTimer *gBrightnessHide = nil;
static int gBrightnessHUDGeneration = 0;
static uint32_t gBrightnessDisplay = 0;
static uint32_t gBrightnessAnchor = 0;

static void liftBrightnessHUD(void) {
  if (gBrightnessPanel == nil) {
    return;
  }
  NSWindow *shade = gShades[@(gBrightnessAnchor)];
  BOOL shadeUp = shade != nil && shade.isVisible;
  gBrightnessPanel.level = shadeUp ? kCGMaximumWindowLevel : NSStatusWindowLevel + 2;
  if (shadeUp && gBrightnessPanel.isVisible) {
    [gBrightnessPanel orderFrontRegardless];
  }
}

static void scheduleBrightnessHide(void) {
  [gBrightnessHide invalidate];
  gBrightnessHide = [NSTimer scheduledTimerWithTimeInterval:2
                                                    repeats:NO
                                                      block:^(NSTimer *timer) {
                                                        (void)timer;
                                                        hideBrightnessHUD();
                                                      }];
}

static void hideBrightnessHUD(void) {
  [gBrightnessHide invalidate];
  gBrightnessHide = nil;
  BrightnessPanel *panel = gBrightnessPanel;
  if (panel == nil || !panel.isVisible) {
    return;
  }
  int generation = ++gBrightnessHUDGeneration;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = 0.18;
    panel.animator.alphaValue = 0;
  }
      completionHandler:^{
        if (generation != gBrightnessHUDGeneration || panel.alphaValue > 0.05) {
          return;
        }
        [panel orderOut:nil];
      }];
}

static void showBrightnessHUD(uint32_t display, long percent) {
  NSScreen *screen = screenForDisplay(display);
  if (screen == nil) {
    return;
  }
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  gBrightnessHUDGeneration++;
  if (gBrightnessPanel == nil) {
    NSRect content = NSMakeRect(0, 0, kBrightnessHUDWidth, kBrightnessHUDHeight);
    gBrightnessMeter = [[BrightnessMeter alloc] initWithFrame:content];
    gBrightnessMeter.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    gBrightnessGlass = [[BrightnessGlass alloc] initWithFrame:content];
    gBrightnessGlass.style = NSGlassEffectViewStyleRegular;
    gBrightnessGlass.tintColor = nil;
    gBrightnessGlass.cornerRadius = kBrightnessHUDHeight / 2.0;
    if (@available(macOS 27.0, *)) {
      gBrightnessGlass.effectIsInteractive = YES;
    }
    gBrightnessGlass.contentView = gBrightnessMeter;
    gBrightnessMeter.onScrubBegan = ^{
      gBrightnessHUDGeneration++;
      if (gBrightnessPanel != nil) {
        gBrightnessPanel.alphaValue = 1;
      }
      [gBrightnessHide invalidate];
      gBrightnessHide = nil;
    };
    gBrightnessMeter.onScrub = ^(long value) {
      if (gBrightnessDisplay == 0) {
        return;
      }
      setDisplayBrightness(gBrightnessDisplay, value);
      refreshMenu();
    };
    gBrightnessMeter.onScrubEnd = ^{
      scheduleBrightnessHide();
    };
    gBrightnessPanel = [[BrightnessPanel alloc]
        initWithContentRect:content
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    gBrightnessPanel.opaque = NO;
    gBrightnessPanel.backgroundColor = NSColor.clearColor;
    gBrightnessPanel.hasShadow = NO;
    gBrightnessPanel.level = NSStatusWindowLevel + 2;
    gBrightnessPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                          NSWindowCollectionBehaviorStationary |
                                          NSWindowCollectionBehaviorFullScreenAuxiliary |
                                          NSWindowCollectionBehaviorIgnoresCycle;
    gBrightnessPanel.hidesOnDeactivate = NO;
    gBrightnessPanel.releasedWhenClosed = NO;
    gBrightnessPanel.contentView = gBrightnessGlass;
  }
  NSRect icon = menuBarIconFrame();
  NSScreen *anchor = screen;
  if (icon.size.width > 1) {
    NSPoint iconCenter = NSMakePoint(NSMidX(icon), NSMidY(icon));
    for (NSScreen *candidate in [NSScreen screens]) {
      if (NSPointInRect(iconCenter, candidate.frame)) {
        anchor = candidate;
        break;
      }
    }
  }
  NSNumber *anchorID = anchor.deviceDescription[@"NSScreenNumber"];
  gBrightnessAnchor = anchorID.unsignedIntValue;
  NSRect visible = anchor.visibleFrame;
  CGFloat width = MIN(kBrightnessHUDWidth, visible.size.width - 16);
  CGFloat height = MIN(kBrightnessHUDHeight, visible.size.height - 16);
  NSSize size = NSMakeSize(width, height);
  [gBrightnessGlass setFrameSize:size];
  gBrightnessGlass.cornerRadius = height / 2.0;
  gBrightnessDisplay = display;
  gBrightnessMeter.displayName = displayTitle(display);
  gBrightnessMeter.percent = percent;
  [gBrightnessMeter setNeedsDisplay:YES];
  CGFloat gap = 4;
  CGFloat x = icon.size.width > 1 ? NSMidX(icon) - size.width / 2.0
                                  : NSMaxX(visible) - 8 - size.width;
  CGFloat y = icon.size.height > 1 ? NSMinY(icon) - gap - size.height
                                  : NSMaxY(visible) - gap - size.height;
  CGFloat minX = NSMinX(visible) + 8;
  CGFloat maxX = NSMaxX(visible) - 8 - size.width;
  if (x < minX) {
    x = minX;
  }
  if (x > maxX) {
    x = maxX;
  }
  if (y < NSMinY(visible) + 8) {
    y = NSMinY(visible) + 8;
  }
  NSRect frame = NSMakeRect(x, y, size.width, size.height);
  [gBrightnessPanel setFrame:frame display:YES];
  gBrightnessPanel.alphaValue = 1;
  [gBrightnessPanel orderFrontRegardless];
  liftBrightnessHUD();
  scheduleBrightnessHide();
}

static const char *scheduleName(int mode) {
  if (mode == 0) {
    return "off";
  }
  if (mode == 2) {
    return "custom";
  }
  if (mode == 1) {
    return "sunset";
  }
  return NULL;
}

static int scheduleMode(const char *name) {
  if (strcmp(name, "off") == 0) {
    return 0;
  }
  if (strcmp(name, "custom") == 0) {
    return 2;
  }
  if (strcmp(name, "sunset") == 0) {
    return 1;
  }
  return -1;
}

static int parsedOnOff(const char *name) {
  if (strcmp(name, "on") == 0) {
    return 1;
  }
  if (strcmp(name, "off") == 0) {
    return 0;
  }
  return -1;
}

static BOOL writeBrightnessLine(int fd, uint32_t display) {
  float level = 0;
  BOOL writable = NO;
  if (!readDisplayBrightness(display, &level, &writable)) {
    return NO;
  }
  long percent = (long)llround(level * 100.0);
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  char name[128];
  const char *raw = displayTitle(display).UTF8String;
  size_t used = 0;
  if (raw != NULL) {
    for (size_t i = 0; raw[i] != '\0' && used + 1 < sizeof(name); i++) {
      unsigned char c = (unsigned char)raw[i];
      name[used++] = c < 32 ? ' ' : (char)c;
    }
  }
  name[used] = '\0';
  if (used == 0) {
    snprintf(name, sizeof(name), "Display %u", display);
  }
  float ignored = 0;
  const char *kind = "picture";
  if (DisplayServicesCanChangeBrightness(display) ||
      readCoreBrightness(display, &ignored) || ddcReady(display)) {
    kind = "backlight";
  }
  dprintf(fd, "%u %s %ld %s\n", display, name, percent, kind);
  return YES;
}

static BOOL knownDisplay(uint32_t display) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  for (int i = 0; i < count; i++) {
    if (ids[i] == display) {
      return YES;
    }
  }
  return NO;
}

static BOOL handleControl(const char *buf, int fd) {
  if (strcmp(buf, "schedule") == 0) {
    BLStatus status;
    const char *name = NULL;
    if (!readStatus(gClient, &status) || (name = scheduleName(status.mode)) == NULL) {
      dprintf(fd, "failed\n");
      return YES;
    }
    dprintf(fd, "%s\n", name);
    return YES;
  }
  if (strncmp(buf, "schedule ", 9) == 0) {
    int mode = scheduleMode(buf + 9);
    if (mode < 0 || !setBlueLightMode(mode)) {
      dprintf(fd, "failed\n");
      return YES;
    }
    dprintf(fd, "%s\n", scheduleName(mode));
    return YES;
  }
  if (strcmp(buf, "clock") == 0) {
    dprintf(fd, "%s\n", hourCycleIs24() ? "24" : "12");
    return YES;
  }
  if (strncmp(buf, "clock ", 6) == 0) {
    int cycle = 0;
    if (strcmp(buf + 6, "24") == 0) {
      cycle = 24;
    } else if (strcmp(buf + 6, "12") == 0) {
      cycle = 12;
    }
    if (cycle == 0 || !writeHourCycle(cycle)) {
      dprintf(fd, "failed\n");
      return YES;
    }
    dprintf(fd, "%d\n", cycle);
    return YES;
  }
  if (strcmp(buf, "login") == 0) {
    dprintf(fd, "%s\n", loginItemOn() ? "on" : "off");
    return YES;
  }
  if (strncmp(buf, "login ", 6) == 0) {
    int on = parsedOnOff(buf + 6);
    if (on < 0) {
      dprintf(fd, "failed\n");
      return YES;
    }
    if (loginItemOn() != on) {
      SMAppService *service = [SMAppService mainAppService];
      NSError *error = nil;
      BOOL ok = on ? [service registerAndReturnError:&error]
                   : [service unregisterAndReturnError:&error];
      (void)ok;
      if (service.status == SMAppServiceStatusRequiresApproval) {
        dprintf(fd, "approval\n");
        return YES;
      }
      if (loginItemOn() != on) {
        dprintf(fd, "failed\n");
        return YES;
      }
    }
    dprintf(fd, "%s\n", on ? "on" : "off");
    return YES;
  }
  if (strcmp(buf, "dark") == 0) {
    dprintf(fd, "%s\n", darkModeOn() ? "on" : "off");
    return YES;
  }
  if (strncmp(buf, "dark ", 5) == 0) {
    int on = parsedOnOff(buf + 5);
    if (on < 0) {
      dprintf(fd, "failed\n");
      return YES;
    }
    setDarkMode(on);
    if (darkModeOn() != on) {
      dprintf(fd, "failed\n");
      return YES;
    }
    dprintf(fd, "%s\n", on ? "on" : "off");
    return YES;
  }
  if (strcmp(buf, "tone") == 0) {
    if (!trueToneAvailable()) {
      dprintf(fd, "unsupported\n");
      return YES;
    }
    dprintf(fd, "%s\n", [trueToneClient() enabled] ? "on" : "off");
    return YES;
  }
  if (strncmp(buf, "tone ", 5) == 0) {
    int on = parsedOnOff(buf + 5);
    if (on < 0) {
      dprintf(fd, "failed\n");
      return YES;
    }
    if (!trueToneAvailable() || ![trueToneClient() setEnabled:on]) {
      dprintf(fd, "%s\n", trueToneAvailable() ? "failed" : "unsupported");
      return YES;
    }
    dprintf(fd, "%s\n", on ? "on" : "off");
    return YES;
  }
  if (strcmp(buf, "brightness") == 0) {
    uint32_t ids[16];
    int count = orderedDisplays(ids, 16);
    int written = 0;
    for (int i = 0; i < count; i++) {
      if (writeBrightnessLine(fd, ids[i])) {
        written++;
      }
    }
    if (written == 0) {
      dprintf(fd, "failed\n");
    }
    return YES;
  }
  if (strncmp(buf, "brightness ", 11) == 0) {
    unsigned display = 0;
    long percent = 0;
    int consumed = 0;
    if (sscanf(buf + 11, "%u %ld%n", &display, &percent, &consumed) != 2 ||
        buf[11 + consumed] != '\0' || percent < 0 || percent > 100 ||
        !knownDisplay(display) || !setDisplayBrightness(display, percent)) {
      dprintf(fd, "failed\n");
      return YES;
    }
    long shown = readPercent(display);
    if (shown < 0) {
      shown = softwareDimPercent(display, percent);
    }
    showBrightnessHUD(display, shown);
    dprintf(fd, "%u %ld\n", display, shown);
    return YES;
  }
  if (strcmp(buf, "keys") == 0) {
    if (!brightnessKeysReady()) {
      startBrightnessKeys();
    }
    dprintf(fd, "%s\n", brightnessKeysReady() ? "on" : "off");
    return YES;
  }
  return NO;
}

@interface RampClock : NSView
@property(nonatomic) BOOL hour24;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) NSInteger field;
@property(nonatomic) int hour;
@property(nonatomic) int minute;
@property(nonatomic) BOOL pm;
@property(nonatomic) BOOL hourReady;
@property(nonatomic) BOOL minuteReady;
@property(nonatomic) int typed;
@property(nonatomic) int partial;
@property(nonatomic) int published;
@property(nonatomic, copy) void (^changed)(RampClock *clock);
@property(nonatomic, copy) void (^cycleChanged)(BOOL hour24);
- (void)showMinute:(int)minute hour24:(BOOL)hour24;
- (int)clockMinute;
- (BOOL)isComplete;
- (BOOL)handleKey:(NSEvent *)event;
@end

@implementation RampClock {
  NSRect _hourRect;
  NSRect _minuteRect;
  NSRect _hourHit;
  NSRect _minuteHit;
  NSRect _colonRect;
  NSRect _amRect;
  NSRect _pmRect;
  NSRect _cycleRect;
  NSRect _confirmRect;
  NSString *_hourString;
  NSString *_minuteString;
  BOOL _hourPlaceholder;
  BOOL _minutePlaceholder;
  BOOL _savedFlash;
  int _savedFlashGeneration;
  int _recentDigit;
  CFAbsoluteTime _recentDigitAt;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self == nil) {
    return nil;
  }
  self.enabled = YES;
  self.field = -1;
  self.hourReady = YES;
  self.minuteReady = YES;
  self.published = -1;
  self.hour = 12;
  self.pm = YES;
  _recentDigit = -1;
  [self setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationVertical];
  [self setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationVertical];
  return self;
}

- (NSSize)intrinsicContentSize {
  CGFloat column = 20 * 2 + 3;
  NSSize digit = [@"00" sizeWithAttributes:@{NSFontAttributeName : [self digitFont]}];
  CGFloat row = MAX(column, digit.height + 4);
  return NSMakeSize(248, row + 32);
}

- (BOOL)hasUnconfirmedEdit {
  if (self.published < 0) {
    return NO;
  }
  if (self.typed > 0 || !self.hourReady || !self.minuteReady) {
    return YES;
  }
  int minute = [self clockMinute];
  return minute >= 0 && minute != self.published;
}

- (BOOL)isConfirmed {
  return self.field < 0 && [self isComplete] && [self clockMinute] == self.published &&
         self.published >= 0;
}

- (BOOL)isComplete {
  return self.hourReady && self.minuteReady && self.typed == 0;
}

- (int)clockMinute {
  if (![self isComplete]) {
    return -1;
  }
  return joinClock(self.hour24, self.hour, self.minute, self.pm);
}

- (void)showMinute:(int)minute hour24:(BOOL)hour24 {
  if (minute < 0) {
    minute = 0;
  }
  if (minute > 1439) {
    minute = 1439;
  }
  if ((self.field >= 0 || [self hasUnconfirmedEdit]) && self.hour24 == hour24) {
    return;
  }
  BOOL cycle = self.hour24 != hour24;
  self.hour24 = hour24;
  int hour = 0;
  int min = 0;
  BOOL pm = NO;
  splitClock(minute, hour24, &hour, &min, &pm);
  self.hour = hour;
  self.minute = min;
  self.pm = pm;
  self.hourReady = YES;
  self.minuteReady = YES;
  self.typed = 0;
  self.field = -1;
  self.published = joinClock(hour24, hour, min, pm);
  if (cycle) {
    [self invalidateIntrinsicContentSize];
  }
  self.needsDisplay = YES;
}

- (void)publish {
  if (self.changed == nil || ![self isComplete]) {
    return;
  }
  int minute = [self clockMinute];
  if (minute < 0 || minute == self.published) {
    return;
  }
  self.published = minute;
  self.changed(self);
}

- (NSFont *)digitFont {
  return [NSFont monospacedDigitSystemFontOfSize:34 weight:NSFontWeightSemibold];
}

- (NSString *)hourText:(BOOL *)placeholder {
  if (self.field == 0 && self.typed == 1) {
    *placeholder = NO;
    return [NSString stringWithFormat:@"%d", self.partial];
  }
  if (!self.hourReady) {
    *placeholder = YES;
    return self.hour24 ? @"\u2013\u2013" : @"\u2013";
  }
  *placeholder = NO;
  if (self.hour24) {
    return [NSString stringWithFormat:@"%02d", self.hour];
  }
  return [NSString stringWithFormat:@"%d", self.hour];
}

- (NSString *)minuteText:(BOOL *)placeholder {
  if (self.field == 1 && self.typed == 1) {
    *placeholder = NO;
    return [NSString stringWithFormat:@"%d\u2013", self.partial];
  }
  if (!self.minuteReady) {
    *placeholder = YES;
    return @"\u2013\u2013";
  }
  *placeholder = NO;
  return [NSString stringWithFormat:@"%02d", self.minute];
}

- (void)updateGeometry {
  _hourString = [self hourText:&_hourPlaceholder];
  _minuteString = [self minuteText:&_minutePlaceholder];
  NSFont *font = [self digitFont];
  NSDictionary *measure = @{NSFontAttributeName : font};
  NSSize hourSize = [_hourString sizeWithAttributes:measure];
  NSSize minuteSize = [_minuteString sizeWithAttributes:measure];
  NSSize colonSize = [@":" sizeWithAttributes:measure];
  CGFloat padX = 2;
  CGFloat padY = 2;
  CGFloat hourW = hourSize.width + padX * 2;
  CGFloat minuteW = minuteSize.width + padX * 2;
  CGFloat digitH = MAX(hourSize.height, minuteSize.height) + padY * 2;
  CGFloat buttonW = 38;
  CGFloat buttonH = 20;
  CGFloat buttonGap = 3;
  CGFloat sideGap = 8;
  CGFloat columnH = buttonH * 2 + buttonGap;
  CGFloat rowH = MAX(digitH, columnH);
  CGFloat confirmW = 92;
  CGFloat confirmH = 24;
  CGFloat cycleW = 74;
  CGFloat cycleGap = 6;
  CGFloat pairW = cycleW + cycleGap + confirmW;
  CGFloat pairX = NSMidX(self.bounds) - pairW / 2.0;
  _cycleRect = NSMakeRect(pairX, 2, cycleW, confirmH);
  _confirmRect = NSMakeRect(NSMaxX(_cycleRect) + cycleGap, 2, confirmW, confirmH);
  CGFloat digitsW = hourW + colonSize.width + minuteW;
  CGFloat groupW = digitsW + sideGap + buttonW;
  CGFloat x = NSMidX(self.bounds) - groupW / 2.0;
  CGFloat rowY = NSMaxY(_confirmRect) + 6;
  CGFloat digitY = rowY + (rowH - digitH) / 2.0;
  _hourRect = NSMakeRect(x, digitY, hourW, digitH);
  _colonRect = NSMakeRect(NSMaxX(_hourRect), digitY, colonSize.width, digitH);
  _minuteRect = NSMakeRect(NSMaxX(_colonRect), digitY, minuteW, digitH);
  CGFloat buttonX = NSMaxX(_minuteRect) + sideGap;
  CGFloat buttonTop = rowY + rowH;
  _amRect = NSMakeRect(buttonX, buttonTop - buttonH, buttonW, buttonH);
  _pmRect = NSMakeRect(buttonX, NSMinY(_amRect) - buttonGap - buttonH, buttonW, buttonH);
  CGFloat split = NSMidX(_colonRect);
  _hourHit = NSMakeRect(NSMinX(_hourRect) - 10, rowY, MAX(1, split - (NSMinX(_hourRect) - 10)), rowH);
  _minuteHit = NSMakeRect(split, rowY, MAX(1, NSMaxX(_minuteRect) + 10 - split), rowH);
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}

- (NSColor *)digitColor:(BOOL)placeholder {
  if (placeholder) {
    return [NSColor.labelColor colorWithAlphaComponent:0.35];
  }
  return NSColor.labelColor;
}

- (void)drawText:(NSString *)text
          inRect:(NSRect)rect
           color:(NSColor *)color
            font:(NSFont *)font {
  NSDictionary *attributes = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
  };
  NSSize size = [text sizeWithAttributes:attributes];
  NSPoint origin = NSMakePoint(NSMidX(rect) - size.width / 2.0,
                               NSMidY(rect) - size.height / 2.0);
  [text drawAtPoint:origin withAttributes:attributes];
}

- (void)fillRound:(NSRect)rect radius:(CGFloat)radius selected:(BOOL)selected {
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                        xRadius:radius
                                                        yRadius:radius];
  NSColor *color = selected
                       ? NSColor.systemOrangeColor
                       : [NSColor.quaternaryLabelColor colorWithAlphaComponent:0.45];
  [color setFill];
  [path fill];
}

- (void)drawPeriod:(NSString *)title rect:(NSRect)rect selected:(BOOL)selected {
  [self fillRound:rect radius:5 selected:selected];
  NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  NSColor *color = selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
  [self drawText:title inRect:rect color:color font:font];
}

- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  [self updateGeometry];
  NSFont *font = [self digitFont];
  if (self.enabled && self.field == 0) {
    [self fillRound:_hourRect radius:8 selected:YES];
  }
  if (self.enabled && self.field == 1) {
    [self fillRound:_minuteRect radius:8 selected:YES];
  }
  [self drawText:_hourString
          inRect:_hourRect
           color:[self digitColor:_hourPlaceholder]
            font:font];
  [self drawText:@":" inRect:_colonRect color:NSColor.secondaryLabelColor font:font];
  [self drawText:_minuteString
          inRect:_minuteRect
           color:[self digitColor:_minutePlaceholder]
            font:font];
  [self drawPeriod:@"AM" rect:_amRect selected:!self.hour24 && !self.pm];
  [self drawPeriod:@"PM" rect:_pmRect selected:!self.hour24 && self.pm];
  [self drawPeriod:@"24-hour" rect:_cycleRect selected:self.hour24];
  [self drawConfirm];
}

- (void)drawConfirm {
  BOOL pending = self.enabled && [self isComplete] && [self hasUnconfirmedEdit];
  NSString *title = @"Confirm";
  NSColor *fill = [NSColor.quaternaryLabelColor colorWithAlphaComponent:0.45];
  NSColor *text = NSColor.secondaryLabelColor;
  if (_savedFlash) {
    title = @"Saved";
    fill = NSColor.systemGreenColor;
    text = NSColor.whiteColor;
  } else if (pending) {
    fill = NSColor.systemGreenColor;
    text = NSColor.whiteColor;
  }
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:_confirmRect xRadius:6 yRadius:6];
  [fill setFill];
  [path fill];
  [self drawText:title
          inRect:_confirmRect
           color:text
            font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
}

- (void)clearSaved {
  _savedFlash = NO;
  _savedFlashGeneration++;
}

- (void)showSaved {
  _savedFlash = YES;
  _savedFlashGeneration++;
  int generation = _savedFlashGeneration;
  self.needsDisplay = YES;
  __weak RampClock *clock = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   RampClock *strong = clock;
                   if (strong == nil || generation != strong->_savedFlashGeneration) {
                     return;
                   }
                   strong->_savedFlash = NO;
                   strong.needsDisplay = YES;
                 });
}

- (void)confirm {
  if (!self.enabled) {
    return;
  }
  if (self.typed > 0) {
    [self acceptTyped];
  }
  if (![self isComplete]) {
    self.needsDisplay = YES;
    return;
  }
  self.field = -1;
  int minute = [self clockMinute];
  if (minute < 0) {
    self.needsDisplay = YES;
    return;
  }
  if (minute == self.published) {
    self.needsDisplay = YES;
    return;
  }
  self.published = minute;
  [self showSaved];
  if (self.changed != nil) {
    self.changed(self);
  }
  if (self.published != minute || ![self isConfirmed]) {
    [self clearSaved];
    self.needsDisplay = YES;
  }
}

- (void)acceptTyped {
  if (self.typed <= 0) {
    return;
  }
  if (self.field == 0) {
    BOOL ok = self.hour24 ? (self.partial >= 0 && self.partial <= 23)
                          : (self.partial >= 1 && self.partial <= 12);
    if (ok) {
      self.hour = self.partial;
      self.hourReady = YES;
    }
  } else if (self.partial >= 0 && self.partial <= 59) {
    self.minute = self.partial;
    self.minuteReady = YES;
  }
  self.typed = 0;
}

- (void)moveToField:(NSInteger)next {
  [self clearSaved];
  if (next < 0) {
    next = 0;
  }
  if (next > 1) {
    next = 1;
  }
  if (self.typed > 0) {
    [self acceptTyped];
  }
  self.field = next;
  self.typed = 0;
  self.needsDisplay = YES;
}

- (void)typeMinute:(int)digit {
  self.field = 1;
  if (self.typed == 0) {
    if (digit <= 5) {
      self.partial = digit;
      self.typed = 1;
      self.minuteReady = NO;
      return;
    }
    self.minute = digit;
    self.minuteReady = YES;
    self.typed = 0;
    return;
  }
  self.minute = self.partial * 10 + digit;
  self.minuteReady = YES;
  self.typed = 0;
}

- (void)typeHour:(int)digit {
  if (self.typed == 0) {
    if (!self.hour24 && digit == 0) {
      return;
    }
    if (self.hour24 ? digit <= 2 : digit == 1) {
      self.partial = digit;
      self.typed = 1;
      self.hourReady = NO;
      return;
    }
    self.hour = digit;
    self.hourReady = YES;
    self.typed = 0;
    self.field = 1;
    return;
  }
  int value = self.partial * 10 + digit;
  BOOL valid = self.hour24 ? value <= 23 : (value >= 1 && value <= 12);
  if (valid) {
    self.hour = value;
    self.hourReady = YES;
    self.typed = 0;
    self.field = 1;
    return;
  }
  self.hour = self.partial;
  self.hourReady = YES;
  self.typed = 0;
  self.field = 1;
  [self typeMinute:digit];
}

- (void)typeDigit:(int)digit {
  [self clearSaved];
  if (self.field < 0) {
    self.field = 0;
  }
  if (self.field == 0) {
    [self typeHour:digit];
  } else {
    [self typeMinute:digit];
  }
  self.needsDisplay = YES;
}

- (void)backspace {
  [self clearSaved];
  if (self.typed > 0) {
    self.typed = 0;
    if (self.field == 0) {
      self.hourReady = NO;
    } else {
      self.minuteReady = NO;
    }
    self.needsDisplay = YES;
    return;
  }
  if (self.field == 0) {
    if (self.hourReady) {
      self.hourReady = NO;
      self.needsDisplay = YES;
    }
    return;
  }
  if (self.minuteReady) {
    self.minuteReady = NO;
    self.needsDisplay = YES;
    return;
  }
  self.field = 0;
  self.typed = 0;
  self.needsDisplay = YES;
}

- (void)setPeriod:(BOOL)pm {
  if (self.hour24 || self.pm == pm) {
    return;
  }
  [self clearSaved];
  self.pm = pm;
  self.needsDisplay = YES;
}

- (void)choose24 {
  if (!self.enabled || self.hour24 || self.cycleChanged == nil) {
    return;
  }
  [self clearSaved];
  self.cycleChanged(YES);
}

- (void)choosePeriod:(BOOL)pm {
  if (!self.enabled) {
    return;
  }
  if (!self.hour24) {
    [self setPeriod:pm];
    return;
  }
  [self clearSaved];
  int source = self.published >= 0 ? self.published : 0;
  int hour = 0;
  int min = 0;
  BOOL current = NO;
  splitClock(source, NO, &hour, &min, &current);
  self.hour = hour;
  self.minute = min;
  self.pm = pm;
  self.hourReady = YES;
  self.minuteReady = YES;
  self.typed = 0;
  self.field = -1;
  self.hour24 = NO;
  self.needsDisplay = YES;
  if (self.cycleChanged != nil) {
    self.cycleChanged(NO);
  }
}

- (void)mouseDown:(NSEvent *)event {
  if (!self.enabled) {
    return;
  }
  [self updateGeometry];
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(point, _confirmRect)) {
    [self confirm];
    return;
  }
  if (NSPointInRect(point, _hourHit)) {
    [self moveToField:0];
    [self.window makeFirstResponder:self];
    return;
  }
  if (NSPointInRect(point, _minuteHit)) {
    [self moveToField:1];
    [self.window makeFirstResponder:self];
    return;
  }
  if (NSPointInRect(point, _amRect)) {
    [self choosePeriod:NO];
  } else if (NSPointInRect(point, _pmRect)) {
    [self choosePeriod:YES];
  } else if (NSPointInRect(point, _cycleRect)) {
    [self choose24];
  }
}

- (BOOL)acceptsFirstResponder {
  return self.enabled;
}

- (void)keyDown:(NSEvent *)event {
  if (![self handleKey:event]) {
    [super keyDown:event];
  }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (event.type != NSEventTypeKeyDown) {
    return NO;
  }
  return [self handleKey:event];
}

- (BOOL)canTakeKeys {
  if (!self.enabled || self.hidden || self.window == nil || !self.window.isVisible) {
    return NO;
  }
  return YES;
}

- (BOOL)takeDigit:(int)digit {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (digit == _recentDigit && now - _recentDigitAt < 0.02) {
    return YES;
  }
  _recentDigit = digit;
  _recentDigitAt = now;
  [self typeDigit:digit];
  return YES;
}

- (BOOL)handleKey:(NSEvent *)event {
  if (![self canTakeKeys]) {
    return NO;
  }
  NSEventModifierFlags blocked = NSEventModifierFlagCommand |
                                  NSEventModifierFlagControl |
                                  NSEventModifierFlagOption;
  if ((event.modifierFlags & blocked) != 0) {
    return NO;
  }
  NSString *chars = event.charactersIgnoringModifiers;
  if (chars.length == 0) {
    chars = event.characters;
  }
  if (chars.length > 0) {
    unichar character = [chars characterAtIndex:0];
    if (character >= '0' && character <= '9') {
      return [self takeDigit:character - '0'];
    }
    if (character == NSBackspaceCharacter || character == NSDeleteCharacter) {
      [self backspace];
      return YES;
    }
    if (character == NSCarriageReturnCharacter || character == NSEnterCharacter) {
      [self confirm];
      return YES;
    }
    if (character == NSLeftArrowFunctionKey) {
      [self moveToField:self.field - 1];
      return YES;
    }
    if (character == NSRightArrowFunctionKey) {
      [self moveToField:self.field + 1];
      return YES;
    }
  }
  int keypad = [self digitForKeyCode:event.keyCode];
  if (keypad >= 0) {
    return [self takeDigit:keypad];
  }
  return NO;
}

- (int)digitForKeyCode:(unsigned short)keyCode {
  switch (keyCode) {
    case 29: return 0;
    case 18: return 1;
    case 19: return 2;
    case 20: return 3;
    case 21: return 4;
    case 23: return 5;
    case 22: return 6;
    case 26: return 7;
    case 28: return 8;
    case 25: return 9;
    case 82: return 0;
    case 83: return 1;
    case 84: return 2;
    case 85: return 3;
    case 86: return 4;
    case 87: return 5;
    case 88: return 6;
    case 89: return 7;
    case 91: return 8;
    case 92: return 9;
    default: return -1;
  }
}
@end

@interface ReleaseSlider : NSSlider
@end

@implementation ReleaseSlider
- (void)mouseDown:(NSEvent *)event {
  [super mouseDown:event];
  [self sendAction:self.action to:self.target];
}
@end

@interface DisplayRow : NSObject
@property(nonatomic) uint32_t display;
@property(nonatomic, strong) NSSlider *slider;
@property(nonatomic, strong) NSTextField *valueLabel;
@end

@implementation DisplayRow
@end

@interface StatusPanel : NSViewController
@property(nonatomic, strong) NSSlider *nowSlider;
@property(nonatomic, strong) NSSlider *maxSlider;
@property(nonatomic, strong) NSTextField *nowValue;
@property(nonatomic, strong) NSTextField *maxValue;
@property(nonatomic) long savedMax;
@property(nonatomic, strong) RampClock *rampClock;
@property(nonatomic, strong) NSStackView *maxRow;
@property(nonatomic, strong) NSStackView *fullRow;
@property(nonatomic, strong) NSImageView *fullChevron;
@property(nonatomic, strong) NSTextField *fullTime;
@property(nonatomic) BOOL fullCollapsed;
@property(nonatomic, copy) void (^fullToggled)(void);
@property(nonatomic, strong) NSBox *rule;
@property(nonatomic, strong) NSView *clockWell;
@property(nonatomic, strong) NSTextField *payLabel;
@property(nonatomic, strong) NSButton *payButton;
@property(nonatomic, strong) NSSegmentedControl *scheduleControl;
@property(nonatomic, strong) NSButton *darkSwitch;
@property(nonatomic, strong) NSButton *toneSwitch;
@property(nonatomic, strong) NSTextField *brightTitle;
@property(nonatomic, strong) NSStackView *brightRows;
@property(nonatomic, strong) NSTextField *ddcNote;
@property(nonatomic, strong) NSButton *keyButton;
@property(nonatomic, strong) NSMutableArray<DisplayRow *> *displayRows;
@property(nonatomic) uint32_t trackingDisplay;
- (void)syncSliders;
- (void)syncClock;
- (void)syncDisplay;
- (void)applyRampAccess;
- (void)previewMax:(long)value;
- (void)previewNow:(long)value;
- (int)clockMinute;
@end

static BOOL gSettingsKeepsOpenForOtherApp = NO;

static void openBrightnessKeyAccess(void) {
  for (NSWindow *window in NSApp.windows) {
    if (window.isVisible && [window.title isEqualToString:@"Nightshift Settings"]) {
      gSettingsKeepsOpenForOtherApp = YES;
    }
  }
  [NSApp activate];
  NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
  AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings."
                                    @"PrivacySecurity.extension?Privacy_Accessibility"];
  if (url != nil) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
  startBrightnessKeys();
}

@implementation StatusPanel
- (NSTextField *)valueLabel {
  NSTextField *value = [NSTextField labelWithString:@"0%"];
  value.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                 weight:NSFontWeightRegular];
  value.alignment = NSTextAlignmentRight;
  [value setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [value.widthAnchor constraintEqualToConstant:40].active = YES;
  return value;
}

- (NSButton *)appearanceButton {
  NSButton *button = [NSButton buttonWithTitle:@"" target:nil action:NULL];
  button.buttonType = NSButtonTypeMomentaryChange;
  button.bordered = NO;
  button.imagePosition = NSImageLeading;
  button.alignment = NSTextAlignmentLeft;
  button.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  [button.widthAnchor constraintEqualToConstant:248].active = YES;
  return button;
}

- (NSStackView *)sliderRowTitled:(NSString *)title
                          slider:(NSSlider *)slider
                           value:(NSTextField *)value
                       nameWidth:(CGFloat)nameWidth
                            name:(NSTextField * __strong *)nameOut {
  NSTextField *name = [NSTextField labelWithString:title];
  name.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  name.lineBreakMode = NSLineBreakByTruncatingTail;
  name.maximumNumberOfLines = 1;
  [name setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name.widthAnchor constraintEqualToConstant:nameWidth].active = YES;
  if (nameOut != NULL) {
    *nameOut = name;
  }
  [slider setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *row = [NSStackView stackViewWithViews:@[ name, slider, value ]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.spacing = 8;
  [row setCustomSpacing:4 afterView:slider];
  row.alignment = NSLayoutAttributeCenterY;
  [row.widthAnchor constraintEqualToConstant:248].active = YES;
  return row;
}

- (NSTextField *)sectionLabel:(NSString *)title {
  NSTextField *label = [NSTextField labelWithString:title];
  label.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  label.textColor = NSColor.secondaryLabelColor;
  return label;
}

- (void)loadView {
  self.nowSlider = [[ReleaseSlider alloc] initWithFrame:NSZeroRect];
  self.nowSlider.minValue = 0;
  self.nowSlider.maxValue = 100;
  self.nowSlider.doubleValue = 0;
  self.maxSlider = [[ReleaseSlider alloc] initWithFrame:NSZeroRect];
  self.maxSlider.minValue = 1;
  self.maxSlider.maxValue = 100;
  self.maxSlider.doubleValue = 1;
  self.nowSlider.continuous = YES;
  self.maxSlider.continuous = YES;
  self.nowSlider.accessibilityLabel = @"Current";
  self.maxSlider.accessibilityLabel = @"Max";
  self.nowValue = [self valueLabel];
  self.maxValue = [self valueLabel];

  self.rampClock = [[RampClock alloc] initWithFrame:NSZeroRect];
  self.rampClock.accessibilityLabel = @"Full at";

  NSImageView *chevron = [NSImageView imageViewWithImage:[[NSImage alloc] init]];
  chevron.imageScaling = NSImageScaleProportionallyUpOrDown;
  chevron.translatesAutoresizingMaskIntoConstraints = NO;
  [chevron.widthAnchor constraintEqualToConstant:11].active = YES;
  [chevron.heightAnchor constraintEqualToConstant:11].active = YES;
  self.fullChevron = chevron;
  NSTextField *fullTitle = [self sectionLabel:@"Full at"];
  NSTextField *fullTime = [NSTextField labelWithString:@""];
  fullTime.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
  fullTime.textColor = NSColor.secondaryLabelColor;
  [fullTime setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.fullTime = fullTime;
  NSStackView *fullRow = [NSStackView stackViewWithViews:@[ chevron, fullTitle, fullTime ]];
  fullRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  fullRow.alignment = NSLayoutAttributeCenterY;
  fullRow.spacing = 6;
  [fullRow setCustomSpacing:8 afterView:fullTitle];
  [fullRow.widthAnchor constraintEqualToConstant:248].active = YES;
  [fullTitle setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSClickGestureRecognizer *fullClick =
      [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullAt:)];
  [fullRow addGestureRecognizer:fullClick];
  self.fullRow = fullRow;
  NSBox *rule = [[NSBox alloc] initWithFrame:NSZeroRect];
  rule.boxType = NSBoxSeparator;
  rule.translatesAutoresizingMaskIntoConstraints = NO;
  [rule.widthAnchor constraintEqualToConstant:248].active = YES;
  self.rule = rule;
  NSTextField *pay = [NSTextField wrappingLabelWithString:@""];
  pay.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  pay.textColor = NSColor.secondaryLabelColor;
  pay.preferredMaxLayoutWidth = 248;
  pay.hidden = YES;
  self.payLabel = pay;
  NSButton *buy = [NSButton buttonWithTitle:@"Unlock the ramp"
                                     target:nil
                                     action:NULL];
  buy.bezelStyle = NSBezelStyleRounded;
  buy.hidden = YES;
  self.payButton = buy;

  self.rampClock.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *clockWell = [[NSView alloc] initWithFrame:NSZeroRect];
  self.clockWell = clockWell;
  [clockWell.widthAnchor constraintEqualToConstant:248].active = YES;
  [clockWell addSubview:self.rampClock];
  [NSLayoutConstraint activateConstraints:@[
    [self.rampClock.leadingAnchor constraintEqualToAnchor:clockWell.leadingAnchor],
    [self.rampClock.trailingAnchor constraintEqualToAnchor:clockWell.trailingAnchor],
    [self.rampClock.topAnchor constraintEqualToAnchor:clockWell.topAnchor],
    [self.rampClock.bottomAnchor constraintEqualToAnchor:clockWell.bottomAnchor],
  ]];

  NSStackView *nowRow = [self sliderRowTitled:@"Current"
                                       slider:self.nowSlider
                                        value:self.nowValue
                                    nameWidth:62
                                         name:NULL];
  NSStackView *maxRow = [self sliderRowTitled:@"Max"
                                       slider:self.maxSlider
                                        value:self.maxValue
                                    nameWidth:62
                                         name:NULL];
  self.maxRow = maxRow;

  NSSegmentedControl *schedule = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"Off", @"Custom", @"Sunset to Sunrise" ]
                    trackingMode:NSSegmentSwitchTrackingSelectOne
                          target:nil
                          action:NULL];
  schedule.segmentDistribution = NSSegmentDistributionFillProportionally;
  schedule.controlSize = NSControlSizeSmall;
  schedule.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  schedule.accessibilityLabel = @"Night Shift schedule";
  [schedule.widthAnchor constraintEqualToConstant:248].active = YES;
  self.scheduleControl = schedule;

  NSBox *displayRule = [[NSBox alloc] initWithFrame:NSZeroRect];
  displayRule.boxType = NSBoxSeparator;
  displayRule.translatesAutoresizingMaskIntoConstraints = NO;
  [displayRule.widthAnchor constraintEqualToConstant:248].active = YES;
  self.darkSwitch = [self appearanceButton];
  self.toneSwitch = [self appearanceButton];
  NSTextField *brightTitle = [self sectionLabel:@"Brightness"];
  self.brightTitle = brightTitle;
  NSStackView *brightRows = [[NSStackView alloc] initWithFrame:NSZeroRect];
  brightRows.orientation = NSUserInterfaceLayoutOrientationVertical;
  brightRows.alignment = NSLayoutAttributeLeading;
  brightRows.spacing = 8;
  [brightRows.widthAnchor constraintEqualToConstant:248].active = YES;
  self.brightRows = brightRows;
  self.displayRows = [NSMutableArray array];
  NSTextField *ddcNote = [NSTextField
      wrappingLabelWithString:@"Turn on DDC/CI in the monitor menu to change the backlight."];
  ddcNote.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  ddcNote.textColor = NSColor.secondaryLabelColor;
  ddcNote.preferredMaxLayoutWidth = 248;
  [ddcNote.widthAnchor constraintEqualToConstant:248].active = YES;
  ddcNote.hidden = YES;
  self.ddcNote = ddcNote;
  NSButton *keyButton = [NSButton buttonWithTitle:@"Allow brightness keys"
                                           target:self
                                           action:@selector(allowKeys:)];
  keyButton.bezelStyle = NSBezelStyleRounded;
  keyButton.controlSize = NSControlSizeSmall;
  keyButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  keyButton.hidden = brightnessKeysReady();
  self.keyButton = keyButton;

  NSTextField *nightTitle = [self sectionLabel:@"Night Shift Intensity"];
  NSTextField *appearanceTitle = [self sectionLabel:@"Appearance"];
  NSStackView *stack = [NSStackView stackViewWithViews:@[
    nightTitle, nowRow, maxRow, pay, buy, schedule, fullRow, clockWell,
    displayRule, brightTitle, brightRows, ddcNote, keyButton, rule, appearanceTitle,
    self.darkSwitch,
    self.toneSwitch
  ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.detachesHiddenViews = YES;
  [stack setCustomSpacing:12 afterView:maxRow];
  [stack setCustomSpacing:8 afterView:pay];
  [stack setCustomSpacing:12 afterView:buy];
  [stack setCustomSpacing:8 afterView:schedule];
  [stack setCustomSpacing:2 afterView:fullRow];
  [stack setCustomSpacing:8 afterView:clockWell];
  [stack setCustomSpacing:12 afterView:displayRule];
  [stack setCustomSpacing:8 afterView:brightTitle];
  [stack setCustomSpacing:14 afterView:brightRows];
  [stack setCustomSpacing:12 afterView:rule];

  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 276, 280)];
  [root addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [root.widthAnchor constraintEqualToConstant:276],
  ]];
  self.view = root;
}

- (void)applyRampAccess {
  BOOL paid = rampLicensed();
  BOOL soon = rampLicenseRenewingSoon();
  NSString *until = rampLicenseUntil();
  self.maxRow.hidden = !paid;
  self.maxSlider.enabled = paid;
  self.rule.hidden = NO;
  self.fullRow.hidden = !paid;
  self.clockWell.hidden = !paid || self.fullCollapsed;
  [self styleFullHeader];
  self.payLabel.hidden = until == nil;
  self.payLabel.stringValue =
      until == nil ? @"" : [NSString stringWithFormat:@"Ramp through %@", until];
  self.payButton.hidden = paid && !soon;
  self.payButton.title = soon ? @"Renew the ramp" : @"Unlock the ramp";
}

- (void)showCheck:(NSButton *)button
             title:(NSString *)title
            symbol:(NSString *)symbol
                on:(BOOL)on {
  NSColor *color = on ? NSColor.controlAccentColor : NSColor.labelColor;
  NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                             accessibilityDescription:nil];
  NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
      configurationWithPointSize:13
                          weight:NSFontWeightRegular];
  image = [image imageWithSymbolConfiguration:config];
  image.template = YES;
  button.image = image;
  button.imagePosition = NSImageLeading;
  button.contentTintColor = color;
  button.attributedTitle = [[NSAttributedString alloc]
      initWithString:[@"  " stringByAppendingString:title]
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize],
            NSForegroundColorAttributeName : color
          }];
}

- (void)syncDisplay {
  [self showCheck:self.darkSwitch
            title:@"Dark mode"
           symbol:@"circle.lefthalf.filled"
               on:darkModeOn()];
  BOOL tone = trueToneAvailable();
  self.toneSwitch.hidden = !tone;
  if (tone) {
    [self showCheck:self.toneSwitch
              title:@"True Tone"
             symbol:@"lightspectrum.horizontal"
                 on:[trueToneClient() enabled]];
  }
  [self syncSchedule];
  [self syncBrightness];
  self.keyButton.hidden = brightnessKeysReady();
  self.ddcNote.hidden = !externalNeedsDDC();
}

- (void)allowKeys:(id)sender {
  (void)sender;
  openBrightnessKeyAccess();
}

- (void)syncSchedule {
  BLStatus status;
  if (!readStatus(gClient, &status)) {
    return;
  }
  NSInteger segment = -1;
  if (status.mode == 0) {
    segment = 0;
  } else if (status.mode == 2) {
    segment = 1;
  } else if (status.mode == 1) {
    segment = 2;
  }
  if (self.scheduleControl.selectedSegment != segment) {
    self.scheduleControl.selectedSegment = segment;
  }
}

- (BOOL)rowsMatchDisplays:(uint32_t *)ids count:(int)count {
  if ((int)self.displayRows.count != count) {
    return NO;
  }
  for (int i = 0; i < count; i++) {
    if (self.displayRows[i].display != ids[i]) {
      return NO;
    }
  }
  return YES;
}

- (void)rebuildBrightness:(uint32_t *)ids count:(int)count {
  NSArray<NSView *> *old = [self.brightRows.arrangedSubviews copy];
  for (NSView *view in old) {
    [self.brightRows removeArrangedSubview:view];
    [view removeFromSuperview];
  }
  self.displayRows = [NSMutableArray array];
  for (int i = 0; i < count; i++) {
    float level = 0;
    BOOL writable = NO;
    BOOL readable = readDisplayBrightness(ids[i], &level, &writable);
    ReleaseSlider *slider = [[ReleaseSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = 0;
    slider.maxValue = 100;
    slider.continuous = YES;
    slider.enabled = readable && writable;
    slider.tag = (NSInteger)ids[i];
    NSString *title = displayTitle(ids[i]);
    slider.accessibilityLabel = title;
    NSTextField *value = [self valueLabel];
    NSTextField *name = [NSTextField labelWithString:title];
    name.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.maximumNumberOfLines = 1;
    [name.widthAnchor constraintEqualToConstant:248].active = YES;
    NSStackView *controls = [NSStackView stackViewWithViews:@[ slider, value ]];
    controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controls.spacing = 8;
    [controls setCustomSpacing:4 afterView:slider];
    controls.alignment = NSLayoutAttributeCenterY;
    [controls.widthAnchor constraintEqualToConstant:248].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[ name, controls ]];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 2;
    [row.widthAnchor constraintEqualToConstant:248].active = YES;
    long percent = 0;
    if (readable) {
      percent = (long)llround(level * 100.0);
      if (percent < 0) {
        percent = 0;
      }
      if (percent > 100) {
        percent = 100;
      }
      slider.doubleValue = percent;
      value.stringValue = [NSString stringWithFormat:@"%ld%%", percent];
    } else {
      slider.doubleValue = 0;
      value.stringValue = @"—";
    }
    DisplayRow *info = [[DisplayRow alloc] init];
    info.display = ids[i];
    info.slider = slider;
    info.valueLabel = value;
    [self.displayRows addObject:info];
    [self.brightRows addArrangedSubview:row];
  }
}

- (void)syncBrightness {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  self.brightTitle.hidden = count == 0;
  self.brightRows.hidden = count == 0;
  if (self.trackingDisplay != 0) {
    return;
  }
  if (![self rowsMatchDisplays:ids count:count]) {
    [self rebuildBrightness:ids count:count];
    return;
  }
  for (DisplayRow *row in self.displayRows) {
    float level = 0;
    BOOL writable = NO;
    BOOL readable = readDisplayBrightness(row.display, &level, &writable);
    row.slider.enabled = readable && writable;
    if (!readable) {
      row.valueLabel.stringValue = @"—";
      continue;
    }
    long percent = (long)llround(level * 100.0);
    if (percent < 0) {
      percent = 0;
    }
    if (percent > 100) {
      percent = 100;
    }
    if (llround(row.slider.doubleValue) != percent) {
      row.slider.doubleValue = percent;
    }
    row.valueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", percent];
  }
}

- (void)syncSliders {
  long now = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  if (!warmthStatus(&now, &maxv, &state, &full)) {
    return;
  }
  self.savedMax = maxv;
  self.nowSlider.doubleValue = now < 0 ? 0 : (now > 100 ? 100 : now);
  self.nowValue.stringValue = [NSString stringWithFormat:@"%ld%%", now];
  if (maxv >= 1) {
    self.maxSlider.doubleValue = maxv;
    self.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", maxv];
  } else {
    long shown = now >= 1 && now <= 100 ? now : 50;
    self.maxSlider.doubleValue = shown;
    self.maxValue.stringValue = @"—";
  }
}

- (void)previewMax:(long)value {
  if (llround(self.maxSlider.doubleValue) != value) {
    self.maxSlider.doubleValue = value;
  }
  self.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
}

- (void)previewNow:(long)value {
  if (llround(self.nowSlider.doubleValue) != value) {
    self.nowSlider.doubleValue = value;
  }
  self.nowValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
}

- (void)styleFullHeader {
  NSString *symbol = self.fullCollapsed ? @"chevron.right" : @"chevron.down";
  NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
  NSImageSymbolConfiguration *config =
      [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold];
  image = [image imageWithSymbolConfiguration:config];
  image.template = YES;
  self.fullChevron.image = image;
  self.fullChevron.contentTintColor = NSColor.secondaryLabelColor;
  self.fullRow.accessibilityLabel =
      self.fullCollapsed ? @"Full at, collapsed" : @"Full at, expanded";
}

- (void)toggleFullAt:(id)sender {
  (void)sender;
  if (self.fullRow.hidden) {
    return;
  }
  self.fullCollapsed = !self.fullCollapsed;
  self.clockWell.hidden = self.fullCollapsed;
  [self styleFullHeader];
  if (self.fullToggled != nil) {
    self.fullToggled();
  }
}

- (void)syncClock {
  BOOL h24 = hourCycleIs24();
  int minute = gRampClock >= 0 ? gRampClock : gFullAt;
  if (minute < 0) {
    minute = minutesNow();
  }
  if (minute < 0) {
    minute = 0;
  }
  [self.rampClock showMinute:minute hour24:h24];
  self.fullTime.stringValue = clockString(minute);
  BOOL on = customSchedule();
  self.rampClock.enabled = on;
  self.rampClock.alphaValue = on ? 1 : 0.4;
}

- (int)clockMinute {
  return [self.rampClock clockMinute];
}
@end

@interface SidebarHost : NSVisualEffectView
@property(nonatomic, copy) void (^appearanceChanged)(void);
@end

@implementation SidebarHost
- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  if (self.appearanceChanged != nil) {
    self.appearanceChanged();
  }
}
@end

@interface SettingsPanel : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSButton *generalButton;
@property(nonatomic, strong) NSButton *displaysButton;
@property(nonatomic, strong) NSButton *proButton;
@property(nonatomic, strong) NSView *generalPage;
@property(nonatomic, strong) NSView *displaysPage;
@property(nonatomic, strong) NSView *proPage;
@property(nonatomic, strong) NSButton *loginCheck;
@property(nonatomic, strong) NSButton *cycleCheck;
@property(nonatomic, strong) NSTextField *keysStatus;
@property(nonatomic, strong) NSButton *keysButton;
@property(nonatomic, strong) NSTextField *licenseStatus;
@property(nonatomic, strong) NSButton *buyButton;
@property(nonatomic, copy) void (^becameKey)(void);
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL stayOpen;
@property(nonatomic, strong) id outsideMonitor;
@property(nonatomic, strong) id localOutsideMonitor;
- (void)showPage:(NSInteger)index;
- (void)syncPaid:(BOOL)paid soon:(BOOL)soon until:(NSString *)until buying:(BOOL)buying;
@end

@implementation SettingsPanel
- (NSTextField *)heading:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  label.textColor = NSColor.labelColor;
  return label;
}

- (NSTextField *)bodyLabel:(NSString *)text {
  NSTextField *label = [NSTextField wrappingLabelWithString:text];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  label.textColor = NSColor.secondaryLabelColor;
  label.preferredMaxLayoutWidth = 350;
  return label;
}

- (NSView *)pageWithViews:(NSArray<NSView *> *)views {
  NSStackView *stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 10;
  stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *page = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 240)];
  [page addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:page.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:page.topAnchor],
  ]];
  return page;
}

- (instancetype)init {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  self.loginCheck = [NSButton checkboxWithTitle:@"Open at login" target:nil action:NULL];
  self.loginCheck.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  self.cycleCheck = [NSButton checkboxWithTitle:@"24-hour time" target:nil action:NULL];
  self.cycleCheck.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  NSButton *notifications = [NSButton buttonWithTitle:@"Notification style"
                                               target:self
                                               action:@selector(openNotifications:)];
  notifications.bezelStyle = NSBezelStyleRounded;
  NSTextField *loginBody =
      [self bodyLabel:@"Nightshift starts when you log in and keeps the evening ramp running."];
  NSTextField *clockBody = [self bodyLabel:@"Full at in the menu uses 24-hour time."];
  NSView *general = [self pageWithViews:@[
    [self heading:@"Startup"], self.loginCheck, loginBody, [self heading:@"Clock"],
    self.cycleCheck, clockBody, [self heading:@"Notifications"], notifications,
    [self bodyLabel:@"Warmth banners can stay on screen. Choose Alerts for Nightshift."]
  ]];
  NSStackView *generalStack = general.subviews.firstObject;
  [generalStack setCustomSpacing:18 afterView:loginBody];
  [generalStack setCustomSpacing:18 afterView:clockBody];

  self.keysStatus = [NSTextField wrappingLabelWithString:@"Brightness keys need Accessibility."];
  self.keysStatus.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  self.keysStatus.preferredMaxLayoutWidth = 350;
  self.keysButton = [NSButton buttonWithTitle:@"Allow brightness keys" target:nil action:NULL];
  self.keysButton.bezelStyle = NSBezelStyleRounded;
  NSTextField *keysBody = [self
      bodyLabel:@"The brightness keys change the display under the pointer."];
  NSView *displays = [self pageWithViews:@[
    [self heading:@"Brightness keys"], self.keysStatus, self.keysButton, keysBody,
    [self heading:@"External displays"],
    [self bodyLabel:@"The lower half of the range dims the picture after the backlight "
                    @"is as low as it will go. Turn on DDC/CI in the monitor menu to change "
                    @"the backlight."]
  ]];
  NSStackView *displaysStack = displays.subviews.firstObject;
  [displaysStack setCustomSpacing:18 afterView:keysBody];

  self.licenseStatus = [NSTextField wrappingLabelWithString:@"The ramp is a paid feature."];
  self.licenseStatus.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  self.licenseStatus.preferredMaxLayoutWidth = 350;
  self.buyButton = [NSButton buttonWithTitle:@"Unlock the ramp" target:nil action:NULL];
  self.buyButton.bezelStyle = NSBezelStyleRounded;
  NSView *pro = [self pageWithViews:@[
    self.licenseStatus,
    [self bodyLabel:@"Pro unlocks the evening ramp. On a Custom schedule, warmth starts at 1 "
                    @"and climbs to Max over two hours, or by Full at. After Full at, Current "
                    @"and Max move together. Warmth, brightness, Dark mode, and True Tone stay free."],
    self.buyButton
  ]];

  self.generalPage = general;
  self.displaysPage = displays;
  self.proPage = pro;
  self.generalButton = [self sidebarButton:@"General" page:0];
  self.displaysButton = [self sidebarButton:@"Displays" page:1];
  self.proButton = [self sidebarButton:@"Nightshift Pro" page:2];

  SidebarHost *sidebar = [[SidebarHost alloc] initWithFrame:NSZeroRect];
  sidebar.material = NSVisualEffectMaterialSidebar;
  sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  sidebar.translatesAutoresizingMaskIntoConstraints = NO;
  NSStackView *rows = [NSStackView
      stackViewWithViews:@[ self.generalButton, self.displaysButton, self.proButton ]];
  rows.orientation = NSUserInterfaceLayoutOrientationVertical;
  rows.alignment = NSLayoutAttributeLeading;
  rows.spacing = 2;
  rows.edgeInsets = NSEdgeInsetsMake(12, 8, 12, 8);
  rows.translatesAutoresizingMaskIntoConstraints = NO;
  [sidebar addSubview:rows];

  NSBox *divider = [[NSBox alloc] initWithFrame:NSZeroRect];
  divider.boxType = NSBoxSeparator;
  divider.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *host = [[NSView alloc] initWithFrame:NSZeroRect];
  host.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSView *page in @[ general, displays, pro ]) {
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
      [page.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
      [page.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
      [page.topAnchor constraintEqualToAnchor:host.topAnchor],
      [page.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
  }

  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
  root.translatesAutoresizingMaskIntoConstraints = NO;
  [root addSubview:sidebar];
  [root addSubview:divider];
  [root addSubview:host];
  [NSLayoutConstraint activateConstraints:@[
    [root.widthAnchor constraintEqualToConstant:560],
    [root.heightAnchor constraintEqualToConstant:420],
    [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
    [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [sidebar.widthAnchor constraintEqualToConstant:168],
    [rows.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
    [rows.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    [rows.topAnchor constraintEqualToAnchor:sidebar.topAnchor],
    [divider.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    [divider.topAnchor constraintEqualToAnchor:root.topAnchor],
    [divider.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [divider.widthAnchor constraintEqualToConstant:1],
    [host.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
    [host.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [host.topAnchor constraintEqualToAnchor:root.topAnchor],
    [host.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
  ]];

  NSViewController *controller = [[NSViewController alloc] init];
  controller.view = root;
  controller.preferredContentSize = NSMakeSize(560, 420);
  self.window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 560, 420)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.title = @"Nightshift Settings";
  self.window.releasedWhenClosed = NO;
  self.window.hidesOnDeactivate = NO;
  self.window.canHide = NO;
  self.window.opaque = YES;
  self.window.backgroundColor = NSColor.windowBackgroundColor;
  self.window.contentMinSize = NSMakeSize(560, 420);
  self.window.contentViewController = controller;
  self.window.delegate = self;
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(appResigned:)
             name:NSApplicationDidResignActiveNotification
           object:nil];
  [self.window center];
  [self applyPage:0];
  __weak SettingsPanel *panel = self;
  sidebar.appearanceChanged = ^{
    [panel paintSidebar];
  };
  return self;
}

- (NSButton *)sidebarButton:(NSString *)title page:(NSInteger)page {
  NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(sidebarClicked:)];
  button.tag = page;
  button.identifier = title;
  button.bordered = NO;
  button.alignment = NSTextAlignmentLeft;
  button.lineBreakMode = NSLineBreakByTruncatingTail;
  button.font = [NSFont systemFontOfSize:13];
  button.wantsLayer = YES;
  button.layer.cornerRadius = 6;
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [button.widthAnchor constraintEqualToConstant:152].active = YES;
  [button.heightAnchor constraintEqualToConstant:28].active = YES;
  return button;
}

- (void)sidebarClicked:(NSButton *)button {
  [self applyPage:button.tag];
}

- (void)applyPage:(NSInteger)index {
  if (index < 0 || index > 2) {
    index = 0;
  }
  self.page = index;
  self.generalPage.hidden = self.page != 0;
  self.displaysPage.hidden = self.page != 1;
  self.proPage.hidden = self.page != 2;
  [self paintSidebar];
}

- (void)paintSidebar {
  [self.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
    [self paintButton:self.generalButton selected:self.page == 0];
    [self paintButton:self.displaysButton selected:self.page == 1];
    [self paintButton:self.proButton selected:self.page == 2];
  }];
}

- (void)paintButton:(NSButton *)button selected:(BOOL)selected {
  NSColor *fill = selected ? NSColor.selectedContentBackgroundColor : NSColor.clearColor;
  button.layer.backgroundColor = fill.CGColor;
  NSColor *text = selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.alignment = NSTextAlignmentLeft;
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  style.firstLineHeadIndent = 10;
  button.attributedTitle = [[NSAttributedString alloc]
      initWithString:button.identifier
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:13
                                                    weight:selected ? NSFontWeightSemibold
                                                                    : NSFontWeightRegular],
            NSForegroundColorAttributeName : text,
            NSParagraphStyleAttributeName : style,
          }];
}

- (void)showPage:(NSInteger)index {
  [self applyPage:index];
  self.stayOpen = YES;
  [NSApp activate];
  [self.window makeKeyAndOrderFront:nil];
  [self watchOutsideClicks];
}

- (void)watchOutsideClicks {
  if (self.outsideMonitor != nil) {
    return;
  }
  __weak SettingsPanel *panel = self;
  self.outsideMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                     handler:^(NSEvent *event) {
                                       (void)event;
                                       [panel closeIfClickedAway];
                                     }];
  self.localOutsideMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                   handler:^NSEvent *(NSEvent *event) {
                                     (void)event;
                                     [panel closeIfClickedAway];
                                     return event;
                                   }];
}

- (void)stopOutsideClicks {
  if (self.outsideMonitor != nil) {
    [NSEvent removeMonitor:self.outsideMonitor];
    self.outsideMonitor = nil;
  }
  if (self.localOutsideMonitor != nil) {
    [NSEvent removeMonitor:self.localOutsideMonitor];
    self.localOutsideMonitor = nil;
  }
}

- (BOOL)frontAppIsSystemSettings {
  NSString *bundle = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
  return [bundle isEqualToString:@"com.apple.systempreferences"] ||
         [bundle isEqualToString:@"com.apple.SystemSettings"];
}

- (void)closeIfClickedAway {
  if (!self.stayOpen || !self.window.isVisible) {
    return;
  }
  if (NSPointInRect(NSEvent.mouseLocation, self.window.frame)) {
    return;
  }
  if (gSettingsKeepsOpenForOtherApp && [self frontAppIsSystemSettings]) {
    return;
  }
  gSettingsKeepsOpenForOtherApp = NO;
  [self.window close];
}

- (void)appResigned:(NSNotification *)notification {
  (void)notification;
  if (!self.stayOpen) {
    return;
  }
  NSWindow *window = self.window;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.stayOpen || window.isVisible) {
      return;
    }
    [window orderFrontRegardless];
  });
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  self.stayOpen = NO;
  gSettingsKeepsOpenForOtherApp = NO;
  [self stopOutsideClicks];
}

- (void)syncPaid:(BOOL)paid
            soon:(BOOL)soon
           until:(NSString *)until
         buying:(BOOL)buying {
  if (paid && until == nil) {
    self.licenseStatus.stringValue = @"Nightshift Pro is unlocked.";
  } else if (until != nil) {
    self.licenseStatus.stringValue =
        [NSString stringWithFormat:@"Ramp through %@.", until];
  } else {
    self.licenseStatus.stringValue = @"The ramp is a paid feature.";
  }
  self.buyButton.hidden = paid && !soon;
  self.buyButton.title = soon ? @"Renew the ramp" : @"Unlock the ramp";
  self.buyButton.enabled = !buying;
  self.loginCheck.state =
      loginItemOn() ? NSControlStateValueOn : NSControlStateValueOff;
  self.cycleCheck.state =
      hourCycleIs24() ? NSControlStateValueOn : NSControlStateValueOff;
  BOOL keys = brightnessKeysReady();
  self.keysStatus.stringValue =
      keys ? @"Brightness keys are allowed." : @"Brightness keys need Accessibility.";
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  if (self.becameKey != nil) {
    self.becameKey();
  }
}

- (void)openNotifications:(id)sender {
  (void)sender;
  gSettingsKeepsOpenForOtherApp = YES;
  NSURL *url = [NSURL URLWithString:
      @"x-apple.systempreferences:com.apple.Notifications-Settings.extension"];
  [[NSWorkspace sharedWorkspace] openURL:url];
}
@end

@interface MenuBar : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) StatusPanel *panel;
@property(nonatomic) BOOL tracking;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic) BOOL buying;
@property(nonatomic) long pendingMax;
@property(nonatomic, strong) id clockKeyMonitor;
@property(nonatomic, strong) SettingsPanel *settings;
- (void)refresh;
- (void)syncLoginItem;
@end

@implementation MenuBar
- (instancetype)init {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  NSImageSymbolConfiguration *symbol = [NSImageSymbolConfiguration
      configurationWithPointSize:16
                          weight:NSFontWeightRegular];
  NSImage *image = [[NSImage imageWithSystemSymbolName:@"sun.horizon"
                              accessibilityDescription:@"Nightshift"]
      imageWithSymbolConfiguration:symbol];
  self.item = [[NSStatusBar systemStatusBar]
      statusItemWithLength:NSSquareStatusItemLength];
  self.item.autosaveName = @"nightshift";
  self.item.button.toolTip = @"Nightshift";
  if (image != nil) {
    image.template = YES;
    self.item.button.image = image;
  } else {
    self.item.button.title = @"NS";
  }

  self.panel = [[StatusPanel alloc] initWithNibName:nil bundle:nil];
  (void)self.panel.view;
  self.panel.nowSlider.target = self;
  self.panel.nowSlider.action = @selector(nowMoved:);
  self.panel.maxSlider.target = self;
  self.panel.maxSlider.action = @selector(maxMoved:);
  self.panel.payButton.target = self;
  self.panel.payButton.action = @selector(showPro:);
  self.panel.darkSwitch.target = self;
  self.panel.darkSwitch.action = @selector(toggleDark:);
  self.panel.toneSwitch.target = self;
  self.panel.toneSwitch.action = @selector(toggleTone:);
  self.panel.scheduleControl.target = self;
  self.panel.scheduleControl.action = @selector(scheduleChanged:);
  __weak MenuBar *menu = self;
  self.panel.rampClock.changed = ^(RampClock *clock) {
    (void)clock;
    [menu commitClock];
  };
  self.panel.rampClock.cycleChanged = ^(BOOL hour24) {
    MenuBar *strong = menu;
    if (strong == nil || hourCycleIs24() == hour24) {
      return;
    }
    if (!writeHourCycle(hour24 ? 24 : 12)) {
      [strong refresh];
      return;
    }
    strong.tracking = NO;
    [strong refresh];
  };
  self.panel.fullToggled = ^{
    [menu sizeMenuView];
  };
  [self refresh];
  [self sizeMenuView];
  self.menu = [[NSMenu alloc] init];
  self.menu.autoenablesItems = NO;
  self.menu.delegate = self;
  NSMenuItem *content = [[NSMenuItem alloc] init];
  content.view = self.panel.view;
  [self.menu addItem:content];
  NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                    action:@selector(showSettings:)
                                             keyEquivalent:@""];
  settings.target = self;
  [self.menu addItem:settings];
  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Nightshift"
                                                action:@selector(quitApp:)
                                         keyEquivalent:@""];
  quit.target = self;
  [self.menu addItem:quit];
  self.item.menu = self.menu;
  return self;
}

- (void)sizeMenuView {
  [self.panel.view layoutSubtreeIfNeeded];
  NSSize fit = self.panel.view.fittingSize;
  if (fit.width < 260) {
    fit.width = 276;
  }
  if (fit.height < 40) {
    fit.height = 240;
  }
  self.panel.view.frame = NSMakeRect(0, 0, fit.width, fit.height);
}

- (void)menuWillOpen:(NSMenu *)menu {
  (void)menu;
  self.menuOpen = YES;
  self.tracking = NO;
  probeDDC();
  [self refresh];
  [self armClockKeys];
  __weak MenuBar *menuBar = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MenuBar *ready = menuBar;
    if (ready == nil || !ready.menuOpen) {
      return;
    }
    [ready.panel.rampClock.window makeFirstResponder:ready.panel.rampClock];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   MenuBar *strong = menuBar;
                   if (strong != nil && strong.menuOpen && !strong.tracking) {
                     [strong refresh];
                   }
                 });
}

- (void)armClockKeys {
  if (self.clockKeyMonitor != nil) {
    return;
  }
  __weak MenuBar *menu = self;
  self.clockKeyMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                    handler:^NSEvent *(NSEvent *event) {
                                      MenuBar *strong = menu;
                                      RampClock *clock =
                                          strong == nil ? nil : strong.panel.rampClock;
                                      if (clock == nil || ![clock handleKey:event]) {
                                        return event;
                                      }
                                      strong.tracking = clock.field >= 0 || ![clock isComplete];
                                      return nil;
                                    }];
}

- (void)disarmClockKeys {
  id monitor = self.clockKeyMonitor;
  self.clockKeyMonitor = nil;
  if (monitor != nil) {
    [NSEvent removeMonitor:monitor];
  }
}

- (BOOL)holdingFull {
  int start = 0;
  int end = 0;
  int now = 0;
  BOOL inWindow = NO;
  BOOL enabled = NO;
  if (!rampLicensed() ||
      !scheduleNow(&start, &end, &now, &inWindow, &enabled) || !inWindow ||
      !enabled) {
    return NO;
  }
  ensureFullAt(start, end);
  return holdingFullAt(start, end, gFullAt, now);
}

- (BOOL)coupleToMax:(long)value live:(long)live {
  if (!rememberMax(value)) {
    return NO;
  }
  if (value == live) {
    return YES;
  }
  return applyWarmth(value, NULL);
}

- (void)finishMax:(long)value known:(BOOL)known live:(long)live {
  self.pendingMax = 0;
  self.tracking = NO;
  if (!known) {
    [self refresh];
    return;
  }
  if ([self holdingFull]) {
    if (![self coupleToMax:value live:live]) {
      [self refresh];
      return;
    }
    [self refresh];
    return;
  }
  long warmth = warmthCappedByMax(live, value);
  if (warmth != live) {
    if (value != self.panel.savedMax && !rememberMax(value)) {
      [self refresh];
      return;
    }
    if (!applyWarmth(warmth, NULL)) {
      [self refresh];
      return;
    }
  } else if (value != self.panel.savedMax && !commitMax(value)) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)commitPendingMax {
  long value = self.pendingMax;
  self.pendingMax = 0;
  BOOL wasTracking = self.tracking;
  self.tracking = NO;
  if (!wasTracking || value < 1 || !rampLicensed()) {
    return;
  }
  long live = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  BOOL known = warmthStatus(&live, &maxv, &state, &full);
  [self finishMax:value known:known live:live];
}

- (void)menuDidClose:(NSMenu *)menu {
  (void)menu;
  self.menuOpen = NO;
  [self disarmClockKeys];
  if (self.panel.trackingDisplay != 0) {
    for (DisplayRow *row in self.panel.displayRows) {
      if (row.display == self.panel.trackingDisplay) {
        setDisplayBrightness(row.display, (long)llround(row.slider.doubleValue));
        break;
      }
    }
    self.panel.trackingDisplay = 0;
  }
  [self commitPendingMax];
}

- (void)refresh {
  if (self.tracking) {
    return;
  }
  [self.panel applyRampAccess];
  [self.panel syncSliders];
  [self.panel syncClock];
  [self.panel syncDisplay];
  [self attachBrightnessSliders];
  [self syncLoginItem];
  [self sizeMenuView];
}

- (SettingsPanel *)makeSettings {
  if (self.settings == nil) {
    self.settings = [[SettingsPanel alloc] init];
    self.settings.loginCheck.target = self;
    self.settings.loginCheck.action = @selector(toggleLogin:);
    self.settings.cycleCheck.target = self;
    self.settings.cycleCheck.action = @selector(toggleCycle:);
    self.settings.keysButton.target = self;
    self.settings.keysButton.action = @selector(allowKeys:);
    self.settings.buyButton.target = self;
    self.settings.buyButton.action = @selector(buyRamp:);
    __weak MenuBar *menu = self;
    self.settings.becameKey = ^{
      [menu syncLoginItem];
    };
  }
  return self.settings;
}

- (void)syncLoginItem {
  if (self.settings == nil) {
    return;
  }
  [self.settings syncPaid:rampLicensed()
                     soon:rampLicenseRenewingSoon()
                    until:rampLicenseUntil()
                  buying:self.buying];
}

- (void)showSettings:(id)sender {
  (void)sender;
  [[self makeSettings] showPage:0];
  [self syncLoginItem];
}

- (void)showPro:(id)sender {
  (void)sender;
  [[self makeSettings] showPage:2];
  [self syncLoginItem];
}

- (void)attachBrightnessSliders {
  for (DisplayRow *row in self.panel.displayRows) {
    row.slider.target = self;
    row.slider.action = @selector(brightMoved:);
  }
}

- (void)nowMoved:(NSSlider *)slider {
  long value = (long)llround(slider.doubleValue);
  self.panel.nowValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
  long saved = self.panel.savedMax;
  if ([self holdingFull] || (rampLicensed() && saved >= 1 && value > saved)) {
    [self.panel previewMax:value];
  } else if (saved >= 1) {
    [self.panel previewMax:saved];
  }
  if (!sliderSettled()) {
    self.tracking = YES;
    return;
  }
  self.tracking = NO;
  long live = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  if (!warmthStatus(&live, &maxv, &state, &full)) {
    [self refresh];
    return;
  }
  if ([self holdingFull]) {
    if (![self coupleToMax:value live:live]) {
      [self refresh];
      return;
    }
    [self refresh];
    return;
  }
  BOOL raise = maxv >= 1 && value > maxv;
  if (value == live && !raise) {
    [self refresh];
    return;
  }
  if (!applyWarmth(value, NULL)) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)maxMoved:(NSSlider *)slider {
  if (!rampLicensed()) {
    [self refresh];
    return;
  }
  long value = (long)llround(slider.doubleValue);
  self.panel.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
  long live = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  BOOL known = warmthStatus(&live, &maxv, &state, &full);
  if (known) {
    long coupled = [self holdingFull] ? value : warmthCappedByMax(live, value);
    if (coupled != (long)llround(self.panel.nowSlider.doubleValue)) {
      [self.panel previewNow:coupled];
    }
  }
  if (!sliderSettled()) {
    self.tracking = YES;
    self.pendingMax = value;
    return;
  }
  [self finishMax:value known:known live:live];
}

- (void)commitClock {
  self.tracking = NO;
  if (!rampLicensed() || !customSchedule()) {
    [self refresh];
    return;
  }
  int minute = [self.panel clockMinute];
  if (minute < 0) {
    [self refresh];
    return;
  }
  if (minute == gRampClock) {
    notify([NSString stringWithFormat:@"Full at %@", clockString(minute)]);
    [self refresh];
    return;
  }
  if (!setRampClock(minute)) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)buyRamp:(NSButton *)button {
  (void)button;
  if (self.buying) {
    return;
  }
  self.buying = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *url = nil;
    BOOL portal = NO;
    __block NSString *out = nil;
    __block NSString *err = nil;
    int step = rampBeginPurchase(&url, &portal, &out, &err);
    if (step != 1 || url == nil) {
      NSString *body = err != nil ? err : out;
      dispatch_async(dispatch_get_main_queue(), ^{
        self.buying = NO;
        if (body != nil) {
          notify(body);
        }
        [self refresh];
      });
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL *page = [NSURL URLWithString:url];
      BOOL opened = page != nil && [[NSWorkspace sharedWorkspace] openURL:page];
      if (!opened) {
        self.buying = NO;
        notify(@"could not open checkout");
        [self refresh];
        return;
      }
      if (portal) {
        self.buying = NO;
        if (out != nil) {
          notify(out);
        }
        [self refresh];
        return;
      }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 90; i++) {
          sleep(2);
          int got = rampTakeLicenseUpdate(&out, &err);
          if (got == 0 || got == 2) {
            NSString *body = err != nil ? err : out;
            dispatch_async(dispatch_get_main_queue(), ^{
              self.buying = NO;
              if (body != nil) {
                notify(body);
              }
              [self refresh];
            });
            return;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          self.buying = NO;
          notify(@"Checkout did not finish");
          [self refresh];
        });
      });
    });
  });
}

- (void)brightMoved:(NSSlider *)slider {
  uint32_t display = (uint32_t)slider.tag;
  long value = softwareDimPercent(display, (long)llround(slider.doubleValue));
  slider.doubleValue = value;
  for (DisplayRow *row in self.panel.displayRows) {
    if (row.display == display) {
      row.valueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", value];
      break;
    }
  }
  self.panel.trackingDisplay = sliderSettled() ? 0 : display;
  if (!setDisplayBrightness(display, value)) {
    self.panel.trackingDisplay = 0;
    [self refresh];
    return;
  }
  if (sliderSettled()) {
    long shown = readPercent(display);
    if (shown >= 0) {
      slider.doubleValue = shown;
      for (DisplayRow *row in self.panel.displayRows) {
        if (row.display == display) {
          row.valueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", shown];
          break;
        }
      }
    }
    self.panel.trackingDisplay = 0;
  }
}

- (void)scheduleChanged:(NSSegmentedControl *)control {
  int modes[3] = {0, 2, 1};
  NSInteger segment = control.selectedSegment;
  if (segment < 0 || segment > 2 || !setBlueLightMode(modes[segment])) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)toggleDark:(NSButton *)button {
  (void)button;
  setDarkMode(!darkModeOn());
  [self refresh];
}

- (void)toggleTone:(NSButton *)button {
  (void)button;
  CBTrueToneClient *client = trueToneClient();
  [client setEnabled:![client enabled]];
  [self refresh];
}

- (void)toggleLogin:(id)sender {
  (void)sender;
  SMAppService *service = [SMAppService mainAppService];
  NSError *error = nil;
  BOOL want = !loginItemOn();
  BOOL ok = want ? [service registerAndReturnError:&error]
                 : [service unregisterAndReturnError:&error];
  if (!ok || service.status == SMAppServiceStatusRequiresApproval) {
    notify(@"Allow Nightshift in Login Items");
  }
  [self syncLoginItem];
  [self refresh];
}

- (void)quitApp:(id)sender {
  [NSApp terminate:sender];
}

- (void)toggleCycle:(NSButton *)button {
  (void)button;
  int cycle = hourCycleIs24() ? 12 : 24;
  if (!writeHourCycle(cycle)) {
    [self refresh];
    return;
  }
  self.tracking = NO;
  [self refresh];
}

- (void)allowKeys:(id)sender {
  (void)sender;
  openBrightnessKeyAccess();
  [self syncLoginItem];
}

@end

static MenuBar *gMenu = nil;

static NSRect menuBarIconFrame(void) {
  NSButton *button = gMenu.item.button;
  if (button == nil || button.window == nil) {
    return NSZeroRect;
  }
  return [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
}

static void refreshMenu(void) {
  if (gMenu == nil || !gMenu.menuOpen) {
    return;
  }
  [gMenu refresh];
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  (void)application;
  for (NSURL *url in urls) {
    if (![url.scheme isEqualToString:@"nightshift"]) {
      continue;
    }
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url
                                        resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in parts.queryItems) {
      if ([item.name isEqualToString:@"token"]) {
        NSString *out = nil;
        NSString *err = nil;
        if (rampInstallReported(item.value, &out, &err) == 0) {
          refreshMenu();
        }
        if (err != nil) {
          notify(err);
        }
      }
    }
  }
}
@end

static AppDelegate *gAppDelegate = nil;

static CFMachPortRef gBrightnessTaps[3];
static int gBrightnessTapCount = 0;
static long gBuiltinPercent = -1;
static CFAbsoluteTime gLastBrightnessKey = 0;
static BOOL gAskedForAccessibility = NO;
static BOOL gHIDWatching = NO;
static int gTapTries = 0;

static BOOL brightnessKeysReady(void) {
  return gBrightnessTapCount > 0;
}

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef void (*IOHIDEventCallback)(void *target, void *refcon, void *sender,
                                   IOHIDEventRef event);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientRegisterEventCallback(
    IOHIDEventSystemClientRef client, IOHIDEventCallback callback, void *target,
    void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(
    IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern uint32_t IOHIDEventGetType(IOHIDEventRef event);
extern int64_t IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef event);

static uint32_t displayUnderPointer(void) {
  NSPoint pointer = NSEvent.mouseLocation;
  for (NSScreen *screen in NSScreen.screens) {
    if (NSPointInRect(pointer, screen.frame)) {
      return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    }
  }
  return 0;
}

static uint32_t builtinDisplay(void) {
  uint32_t count = 0;
  CGDirectDisplayID ids[16];
  if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess) {
    return 0;
  }
  for (uint32_t i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(ids[i])) {
      return ids[i];
    }
  }
  return 0;
}

static uint32_t gCursorHiddenDisplay = 0;
static uint32_t gBlackCursorDisplay = 0;
static NSTimer *gCursorHideTimer = nil;
static id gCursorMonitor = nil;
static CFMachPortRef gCursorTap = NULL;

static void allowBackgroundCursor(void) {
  static BOOL ready = NO;
  if (ready) {
    return;
  }
  typedef int (*SetProp)(int, int, CFStringRef, CFTypeRef);
  typedef int (*Conn)(void);
  SetProp setp = dlsym(RTLD_DEFAULT, "SLSSetConnectionProperty");
  Conn conn = dlsym(RTLD_DEFAULT, "_SLSDefaultConnection");
  if (setp == NULL || conn == NULL) {
    return;
  }
  int cid = conn();
  if (setp(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue) == 0) {
    ready = YES;
  }
}

static void showHiddenCursor(void) {
  if (gCursorHiddenDisplay == 0) {
    return;
  }
  allowBackgroundCursor();
  CGDisplayShowCursor(gCursorHiddenDisplay);
  gCursorHiddenDisplay = 0;
}

static void hideCursorOn(uint32_t display) {
  if (display == 0 || gCursorHiddenDisplay == display) {
    return;
  }
  showHiddenCursor();
  allowBackgroundCursor();
  if (CGDisplayHideCursor(display) != kCGErrorSuccess) {
    return;
  }
  gCursorHiddenDisplay = display;
}

static void cancelCursorHide(void) {
  [gCursorHideTimer invalidate];
  gCursorHideTimer = nil;
}

static BOOL displayIsBlack(uint32_t display) {
  return display != 0 && display == gBlackCursorDisplay && !CGDisplayIsBuiltin(display) &&
         readPercent(display) == 0;
}

static void scheduleCursorHide(void) {
  if (gCursorHideTimer != nil) {
    [gCursorHideTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    return;
  }
  gCursorHideTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
                                                          (void)timer;
                                                          gCursorHideTimer = nil;
                                                          uint32_t under = displayUnderPointer();
                                                          if (displayIsBlack(under)) {
                                                            hideCursorOn(under);
                                                          }
                                                        }];
}

static void pokeCursor(void) {
  if (gBlackCursorDisplay == 0 && gCursorHiddenDisplay == 0) {
    return;
  }
  uint32_t under = displayUnderPointer();
  if (!displayIsBlack(under)) {
    cancelCursorHide();
    showHiddenCursor();
    return;
  }
  showHiddenCursor();
  scheduleCursorHide();
}

static CGEventRef cursorTapEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event,
                                 void *user) {
  (void)proxy;
  (void)user;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (gCursorTap != NULL) {
      CGEventTapEnable(gCursorTap, true);
    }
    return event;
  }
  if (gBlackCursorDisplay != 0 || gCursorHiddenDisplay != 0) {
    pokeCursor();
  }
  return event;
}

static void watchCursor(void) {
  if (gCursorTap == NULL) {
    CGEventMask moved = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                        CGEventMaskBit(kCGEventRightMouseDragged) |
                        CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventLeftMouseDown) |
                        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventOtherMouseDown) |
                        CGEventMaskBit(kCGEventScrollWheel);
    CGEventTapLocation places[2] = {kCGHIDEventTap, kCGSessionEventTap};
    for (int i = 0; i < 2 && gCursorTap == NULL; i++) {
      gCursorTap = CGEventTapCreate(places[i], kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                    moved, cursorTapEvent, NULL);
    }
    if (gCursorTap != NULL) {
      CFRunLoopSourceRef source =
          CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gCursorTap, 0);
      CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
      CFRelease(source);
      CGEventTapEnable(gCursorTap, true);
    }
  }
  if (gCursorMonitor != nil) {
    return;
  }
  NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                     NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
                     NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                     NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
  gCursorMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                                          handler:^(NSEvent *event) {
                                                            (void)event;
                                                            pokeCursor();
                                                          }];
}

static void noteCursorBrightness(uint32_t display, long percent) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      noteCursorBrightness(display, percent);
    });
    return;
  }
  if (display == 0 || CGDisplayIsBuiltin(display)) {
    return;
  }
  if (percent <= 0) {
    gBlackCursorDisplay = display;
    watchCursor();
    cancelCursorHide();
    if (displayUnderPointer() == display) {
      hideCursorOn(display);
    }
    return;
  }
  if (gBlackCursorDisplay == display) {
    gBlackCursorDisplay = 0;
    cancelCursorHide();
    showHiddenCursor();
  }
}

static void noteCursorDisplaysOffline(void) {
  if (gBlackCursorDisplay == 0 && gCursorHiddenDisplay == 0) {
    return;
  }
  BOOL online = NO;
  uint32_t watched = gBlackCursorDisplay != 0 ? gBlackCursorDisplay : gCursorHiddenDisplay;
  for (NSScreen *screen in NSScreen.screens) {
    if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == watched) {
      online = YES;
      break;
    }
  }
  if (!online) {
    gBlackCursorDisplay = 0;
    cancelCursorHide();
    showHiddenCursor();
  }
}

static long readPercent(uint32_t display) {
  float level = 0;
  BOOL writable = NO;
  if (display == 0 || !readDisplayBrightness(display, &level, &writable) ||
      !writable) {
    return -1;
  }
  return (long)llround(level * 100.0);
}

static long steppedPercent(long percent, int direction, long stops) {
  long steps = (percent * stops + stops / 2) / 100 + direction;
  if (steps < 0) {
    steps = 0;
  }
  if (steps > stops) {
    steps = stops;
  }
  long next = (steps * 100 + stops / 2) / stops;
  if (next == percent) {
    next = percent + direction;
  }
  if (next < 0) {
    next = 0;
  }
  if (next > 100) {
    next = 100;
  }
  return next;
}

static void rememberBuiltin(void) {
  gBuiltinPercent = readPercent(builtinDisplay());
}

static BOOL stepActiveBrightness(int direction) {
  uint32_t display = displayUnderPointer();
  uint32_t builtin = builtinDisplay();
  if (display == 0) {
    return NO;
  }
  long currentBuiltin = readPercent(builtin);
  if (display == builtin && gBuiltinPercent >= 0 && currentBuiltin >= 0 &&
      currentBuiltin != gBuiltinPercent) {
    gBuiltinPercent = currentBuiltin;
    showBrightnessHUD(display, currentBuiltin);
    if (gMenu != nil && gMenu.menuOpen && !gMenu.tracking) {
      [gMenu refresh];
    }
    return YES;
  }
  if (display != builtin && gBuiltinPercent >= 0 && currentBuiltin >= 0 &&
      currentBuiltin != gBuiltinPercent) {
    setDisplayBrightness(builtin, gBuiltinPercent);
  }
  long percent = readPercent(display);
  if (percent < 0) {
    if (ddcPending(display) && gPendingKeySteps > -16 && gPendingKeySteps < 16) {
      gPendingKeySteps += direction;
      return YES;
    }
    return NO;
  }
  long next = ddcReady(display) ? steppedPercent(percent, direction, 16)
                               : softwareDimPercent(display, steppedPercent(percent, direction, 32));
  if (next != percent && !setDisplayBrightness(display, next)) {
    return NO;
  }
  long shown = next;
  if (next != percent) {
    long landed = readPercent(display);
    if (landed >= 0) {
      shown = landed;
    }
  }
  rememberBuiltin();
  showBrightnessHUD(display, shown);
  if (gMenu != nil && gMenu.menuOpen && !gMenu.tracking) {
    [gMenu refresh];
  }
  return YES;
}

static BOOL deliverBrightness(int direction) {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now - gLastBrightnessKey < 0.02) {
    return YES;
  }
  if (![NSThread isMainThread]) {
    gLastBrightnessKey = now;
    dispatch_async(dispatch_get_main_queue(), ^{
      stepActiveBrightness(direction);
    });
    return YES;
  }
  if (!stepActiveBrightness(direction)) {
    return NO;
  }
  gLastBrightnessKey = now;
  return YES;
}

static int brightnessDirection(NSEvent *key) {
  if (key.type == NSEventTypeSystemDefined && key.subtype == 8) {
    NSInteger data = key.data1;
    NSInteger code = (data & 0xFFFF0000) >> 16;
    NSInteger flags = data & 0xFFFF;
    BOOL down = ((flags & 0xFF00) >> 8) == 0xA;
    if (!down) {
      return 0;
    }
    if (code == 2) {
      return 1;
    }
    if (code == 3) {
      return -1;
    }
  }
  if (key.type == NSEventTypeKeyDown) {
    if (key.keyCode == 144) {
      return 1;
    }
    if (key.keyCode == 145) {
      return -1;
    }
  }
  return 0;
}

static CGEventRef brightnessKey(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *user) {
  (void)proxy;
  (void)user;
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    for (int i = 0; i < gBrightnessTapCount; i++) {
      if (gBrightnessTaps[i] != NULL) {
        CGEventTapEnable(gBrightnessTaps[i], true);
      }
    }
    return event;
  }
  NSEvent *key = [NSEvent eventWithCGEvent:event];
  int direction = key == nil ? 0 : brightnessDirection(key);
  if (direction == 0) {
    return event;
  }
  return deliverBrightness(direction) ? NULL : event;
}

static void considerBrightnessEvent(IOHIDEventRef event) {
  if (event == NULL) {
    return;
  }
  if (IOHIDEventGetType(event) == 3) {
    int64_t page = IOHIDEventGetIntegerValue(event, 3u << 16);
    int64_t usage = IOHIDEventGetIntegerValue(event, (3u << 16) + 1);
    int64_t down = IOHIDEventGetIntegerValue(event, (3u << 16) + 2);
    if (page == 0x0C && down != 0 && (usage == 0x6F || usage == 0x70)) {
      deliverBrightness(usage == 0x6F ? 1 : -1);
    }
  }
  CFArrayRef children = IOHIDEventGetChildren(event);
  if (children == NULL) {
    return;
  }
  CFIndex count = CFArrayGetCount(children);
  for (CFIndex i = 0; i < count; i++) {
    considerBrightnessEvent((IOHIDEventRef)CFArrayGetValueAtIndex(children, i));
  }
}

static void hidBrightness(void *target, void *refcon, void *sender,
                          IOHIDEventRef event) {
  (void)target;
  (void)refcon;
  (void)sender;
  considerBrightnessEvent(event);
}

static void watchHIDBrightness(void) {
  IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  if (client == NULL) {
    return;
  }
  IOHIDEventSystemClientRegisterEventCallback(client, hidBrightness, NULL, NULL);
  IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(),
                                            kCFRunLoopCommonModes);
}

static BOOL installBrightnessTap(void) {
  if (gBrightnessTapCount > 0) {
    return YES;
  }
  CGEventMask mask = CGEventMaskBit(NSEventTypeSystemDefined) |
                     CGEventMaskBit(kCGEventKeyDown);
  CGEventTapLocation places[3] = {kCGSessionEventTap, kCGHIDEventTap,
                                  kCGAnnotatedSessionEventTap};
  for (int i = 0; i < 3; i++) {
    CFMachPortRef tap = CGEventTapCreate(places[i], kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault, mask, brightnessKey,
                                         NULL);
    if (tap == NULL) {
      continue;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(tap, true);
    gBrightnessTaps[gBrightnessTapCount++] = tap;
  }
  return gBrightnessTapCount > 0;
}

static void startBrightnessKeys(void) {
  if (!gHIDWatching) {
    gHIDWatching = YES;
    watchHIDBrightness();
    rememberBuiltin();
    probeDDC();
  }
  if (installBrightnessTap()) {
    if (gMenu != nil) {
      [gMenu refresh];
    }
    return;
  }
  if (!gAskedForAccessibility) {
    gAskedForAccessibility = YES;
    [NSApp activate];
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    notify(@"Allow Nightshift in Accessibility to use the brightness keys");
  }
  if (gTapTries++ >= 30) {
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   startBrightnessKeys();
                 });
}

static void installMenu(void) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  gAppDelegate = [[AppDelegate alloc] init];
  NSApp.delegate = gAppDelegate;
  [[NSNotificationCenter defaultCenter]
      addObserverForName:NSApplicationDidChangeScreenParametersNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *note) {
                (void)note;
                refitDimWindows();
                probeDDC();
              }];
  gMenu = [[MenuBar alloc] init];
  startBrightnessKeys();
  [gMenu refresh];
}

static char gSockPath[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void stopDaemon(int sig) {
  (void)sig;
  if (gCursorHiddenDisplay != 0) {
    CGDisplayShowCursor(gCursorHiddenDisplay);
    gCursorHiddenDisplay = 0;
  }
  if (gSockPath[0] != '\0') {
    unlink(gSockPath);
  }
  _exit(0);
}

static BOOL daemonAlreadyRunning(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return NO;
  }
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  BOOL running = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
  close(fd);
  return running;
}

static int listenSocket(const char *path) {
  if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    return -1;
  }
  if (daemonAlreadyRunning(path)) {
    return -1;
  }
  unlink(path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
      chmod(path, S_IRUSR | S_IWUSR) < 0 || listen(fd, 4) < 0) {
    close(fd);
    unlink(path);
    return -1;
  }
  return fd;
}

static BOOL readMessage(int fd, char *buf, size_t cap) {
  ssize_t n;
  do {
    n = read(fd, buf, cap - 1);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) {
    return NO;
  }
  buf[n] = '\0';
  char *nl = strchr(buf, '\n');
  if (nl == NULL || nl == buf) {
    return NO;
  }
  *nl = '\0';
  return YES;
}

static void deliverPending(BOOL granted) {
  if (granted) {
    gBannerReady = YES;
    if (gPending != nil) {
      NSString *pending = gPending;
      gPending = nil;
      gLaunched = YES;
      sendBanner(pending);
      return;
    }
  } else {
    gBannerDenied = YES;
    gPending = nil;
    return;
  }
  int notified = gNotified;
  announce(minutesNow());
  gLaunched = YES;
  if (gNotified == notified && gSeenWarmth < 0) {
    long warmth = 0;
    if (readStrength(gClient, &warmth)) {
      reportWarmth(warmth);
    } else {
      notify(@"Night Shift is running");
    }
  }
}

int main(void) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    gClient = makeClient();
    if (gClient == nil) {
      fprintf(stderr, "Night Shift is unavailable\n");
      return 1;
    }

    UNUserNotificationCenter *center =
        [UNUserNotificationCenter currentNotificationCenter];
    gDelegate = [[RampDelegate alloc] init];
    center.delegate = gDelegate;
    UNTextInputNotificationAction *maxAction = [UNTextInputNotificationAction
        actionWithIdentifier:kSetMaxAction
                       title:@"Set Max"
                     options:UNNotificationActionOptionNone
        textInputButtonTitle:@"Set"
        textInputPlaceholder:@"1–100"];
    UNTextInputNotificationAction *fullAction = [UNTextInputNotificationAction
        actionWithIdentifier:kFullAtAction
                       title:@"Set Time"
                     options:UNNotificationActionOptionNone
        textInputButtonTitle:@"Set"
        textInputPlaceholder:@"8:30 PM"];
    UNNotificationCategory *category = [UNNotificationCategory
        categoryWithIdentifier:kCategory
                       actions:@[ maxAction, fullAction ]
             intentIdentifiers:@[]
                       options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:category]];
    if (NSBundle.mainBundle.bundleIdentifier != nil) {
      [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                             completionHandler:^(BOOL granted, NSError *error) {
                               if (!granted) {
                                 fprintf(
                                     stderr,
                                     "notifications are not allowed: %s\n",
                                     error != nil
                                         ? error.localizedDescription.UTF8String
                                         : "turned off in System Settings");
                               }
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 deliverPending(granted);
                               });
                             }];
    }

    NSString *dir =
        [NSHomeDirectory() stringByAppendingPathComponent:
                               @"Library/Application Support/nightshift"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager]
                createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error]) {
      fprintf(stderr, "failed to create %s\n", dir.fileSystemRepresentation);
      return 1;
    }
    chmod(dir.fileSystemRepresentation, S_IRWXU);
    gMaxPath = [dir stringByAppendingPathComponent:@"max"];
    gRampPath = [dir stringByAppendingPathComponent:@"full"];
    gBrightnessPath = [dir stringByAppendingPathComponent:@"brightness"];
    loadBrightness();
    long saved = 0;
    if (readMax(&saved)) {
      gMax = saved;
      gMaxKnown = YES;
    }
    int savedClock = -1;
    if (readRampClock(&savedClock)) {
      gRampClock = savedClock;
    }
    readHourCycle();

    NSString *sock = [dir stringByAppendingPathComponent:@"nightshiftd.sock"];
    int server = listenSocket(sock.fileSystemRepresentation);
    if (server < 0) {
      fprintf(stderr, "failed to listen on %s\n",
              sock.fileSystemRepresentation);
      return 1;
    }
    fprintf(stderr, "listening on %s\n", sock.fileSystemRepresentation);
    int flags = fcntl(server, F_GETFL);
    if (flags < 0 || fcntl(server, F_SETFL, flags | O_NONBLOCK) < 0) {
      fprintf(stderr, "failed to configure %s\n",
              sock.fileSystemRepresentation);
      close(server);
      unlink(sock.fileSystemRepresentation);
      return 1;
    }

    strncpy(gSockPath, sock.fileSystemRepresentation, sizeof(gSockPath) - 1);
    struct sigaction stop;
    memset(&stop, 0, sizeof(stop));
    stop.sa_handler = stopDaemon;
    sigaction(SIGINT, &stop, NULL);
    sigaction(SIGTERM, &stop, NULL);

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_main_queue());
    dispatch_source_set_timer(gTimer, dispatch_walltime(NULL, 0),
                              60 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gTimer, ^{
      rampTick();
      refreshMenu();
    });
    dispatch_resume(gTimer);

    gListener = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)server, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(gListener, ^{
      int connection = accept(server, NULL, NULL);
      if (connection < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != ECONNABORTED &&
            errno != EINTR) {
          fprintf(stderr, "accept failed: %s\n", strerror(errno));
        }
        return;
      }
      uid_t uid = 0;
      gid_t gid = 0;
      int connFlags = fcntl(connection, F_GETFL);
      if (getpeereid(connection, &uid, &gid) != 0 || uid != getuid() ||
          connFlags < 0 ||
          fcntl(connection, F_SETFL, connFlags & ~O_NONBLOCK) < 0) {
        close(connection);
        return;
      }
      struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
      setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      char buf[128];
      if (!readMessage(connection, buf, sizeof(buf))) {
        dprintf(connection, "failed\n");
        close(connection);
        return;
      }
      handleLine(buf, connection);
      refreshMenu();
      if (gMenu != nil) {
        [gMenu syncLoginItem];
      }
      close(connection);
    });
    dispatch_resume(gListener);
    installMenu();
    [NSApp run];
  }
  return 0;
}
