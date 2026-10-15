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
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#include <stdatomic.h>
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
static void refreshKeyDisplays(void);
static long ddcShownPercent(uint32_t display);
static void noteCursorBrightness(uint32_t display, long percent);
static void noteCursorDisplaysOffline(void);
static void teardownDaemon(void);
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
#import <pthread.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <sys/file.h>
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
static BOOL gPendingPlain = NO;
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

static int glideStage(int now) { return nsGlideStage(gFromMinute, gToMinute, now); }

static int glideEnd(int now, int scheduleEnd) {
  return nsGlideEnd(now, scheduleEnd, gFullAt, kGlideMinutes);
}

static void sendBanner(NSString *body, BOOL controls) {
  UNMutableNotificationContent *content =
      [[UNMutableNotificationContent alloc] init];
  content.title = @"Night Shift";
  content.body = body;
  if (controls) {
    content.categoryIdentifier = kCategory;
  }
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

static void postBanner(NSString *body, BOOL controls) {
  fprintf(stderr, "%s\n", body.UTF8String);
  if (gBannerReady) {
    sendBanner(body, controls);
    return;
  }
  if (NSBundle.mainBundle.bundleIdentifier != nil && !gBannerDenied) {
    gPending = body;
    gPendingPlain = !controls;
  }
}

static void notify(NSString *body) { postBanner(body, YES); }

// For banners that ask the user to do something elsewhere, such as granting
// a permission, where Set Max and Set Time make no sense.
static void notifyPlain(NSString *body) { postBanner(body, NO); }

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
  return nsClockInSchedule(start, end, clock);
}

static BOOL aheadOfTurnOn(int now, int start, int clock) {
  return nsAheadOfTurnOn(now, start, clock);
}

static void ensureFullAt(int start, int end) {
  if (gFullAt >= 0) {
    return;
  }
  int fullAt = nsDefaultFullAt(start, end, gRampClock, kRampMinutes);
  if (fullAt >= 0) {
    gFullAt = fullAt;
  }
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
      notifyPlain(@"Could not save the time");
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
    notifyPlain(@"Could not save the time");
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
      notifyPlain(rampOffer());
      completionHandler();
      return;
    }
    if ([action isEqualToString:kSetMaxAction]) {
      long value = 0;
      if (text == nil || !parseMaxText(text, &value)) {
        notify(@"Enter a number from 1 to 100");
      } else if (!rememberMax(value)) {
        notifyPlain(@"Could not save the max");
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

// Newest percent per display, for a few displays. Main thread only.
typedef struct {
  uint32_t display[8];
  long percent[8];
  int count;
} DisplayPercents;

static BOOL putDisplayPercent(DisplayPercents *table, uint32_t display, long percent) {
  for (int i = 0; i < table->count; i++) {
    if (table->display[i] == display) {
      table->percent[i] = percent;
      return YES;
    }
  }
  if (table->count >= 8) {
    return NO;
  }
  table->display[table->count] = display;
  table->percent[table->count] = percent;
  table->count++;
  return YES;
}

static void dropDisplayPercent(DisplayPercents *table, uint32_t display) {
  for (int i = 0; i < table->count; i++) {
    if (table->display[i] != display) {
      continue;
    }
    table->count--;
    table->display[i] = table->display[table->count];
    table->percent[i] = table->percent[table->count];
    return;
  }
}

// How finishBrightness treats a change. A drag holds each tick in memory and
// saves once on release. A release on a live DDC channel saves only once the
// worker reports the lamp write went through (ddcLanded).
typedef enum {
  kSaveNow,
  kSaveHeld,
  kSaveWhenLanded,
} BrightnessSaving;

static BrightnessSaving gBrightnessSaving = kSaveNow;
// Values a drag has applied but not saved yet, kept for teardown.
static DisplayPercents gHeldBrightness;
static void forgetLandedSave(uint32_t display);
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
  // Black is for this session only (finding 1): the file never holds 0.
  gBrightnessSaved[key] = @(nsPersistedBrightness(percent) / 100.0);
  gSoftwareBrightness[@(display)] = level;
  // Every save is the percent the user asked for. An unmarked line is a lamp
  // percent from before that split, and restore must not convert it twice.
  if (gCombinedBrightness == nil) {
    gCombinedBrightness = [NSMutableSet set];
  }
  [gCombinedBrightness addObject:key];
  return saveBrightness();
}

static BOOL finishBrightness(uint32_t display, long percent) {
  noteCursorBrightness(display, percent);
  // Anything newer replaces a release still waiting on its lamp write.
  forgetLandedSave(display);
  if (gBrightnessSaving == kSaveHeld) {
    if (gSoftwareBrightness == nil) {
      gSoftwareBrightness = [NSMutableDictionary dictionary];
    }
    gSoftwareBrightness[@(display)] = @(percent / 100.0);
    putDisplayPercent(&gHeldBrightness, display, percent);
    return YES;
  }
  dropDisplayPercent(&gHeldBrightness, display);
  if (noteBrightness(display, percent)) {
    return YES;
  }
  notifyPlain(@"Could not save brightness");
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
  // Main thread owns every field. The worker only reads seq (atomically) to
  // learn that a newer target has replaced the one it holds.
  int posted;       // raw lamp value last handed to the worker, -1 unknown
  unsigned seq;     // bumped for each new target; stale work is dropped
  unsigned settled; // seq whose readback last landed in this slot
  int retries;      // corrective writes since the user last moved
  long postFloor;   // floor the shade was predicted from
  BOOL saveWaiting; // a drag's release waits on the lamp write to save
  long savePercent; // the percent that release saves
  // An unconfirmed channel's brightness waits for its write: the shade and
  // the save happen when the job lands (ddcLanded), or fall back to the
  // shade alone when the write fails.
  // N9: when the brightness was last set (CFAbsoluteTime, 0 never), so a
  // revalidation never overrides a value that was just chosen.
  CFAbsoluteTime changedAt;
  BOOL applyWaiting;
  long applyPercent;
  int applySaving;  // BrightnessSaving the change was made with
} DDCSlot;

static DDCSlot gDDC[8];

// Every I2C transaction (probe reads, lamp writes, readbacks) runs on this
// one serial queue, so they never interleave on the bus and the main thread
// never sleeps on the monitor.
static dispatch_queue_t ddcQueue(void) {
  static dispatch_queue_t queue = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create(
        "nightshift.ddc", dispatch_queue_attr_make_with_qos_class(
                              DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

// One lamp target in flight. The job holds its own retain on service so a
// slot can be cleared or replaced while the worker is still using it.
typedef struct {
  uint32_t display;
  IOAVServiceRef service;
  unsigned seq;
  long percent;
  int scale;
  int value;
  BOOL wrote;
  BOOL read;
  BOOL stable; // two readbacks agreed on landed
  int landed;
  int max;
} DDCJob;
static BOOL gDDCBusy = NO;
static BOOL gDDCAgain = NO;
// The next probe reads ready channels too: after wake, a replug or a screen
// change the service may be dead or the monitor may have reset its lamp.
static BOOL gDDCRevalidate = NO;
// N9: when the Mac last woke (CFAbsoluteTime, 0 never).
static CFAbsoluteTime gWokeAt = 0;
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

// DDCCandidate and DDCTarget live in NightshiftLogic.h.

static BOOL ddcPortName(const char *name, char stop, char *out, size_t cap) {
  return nsDDCPortName(name, stop, out, cap);
}

static int ddcPickCandidate(const DDCCandidate *candidates, int count, const DDCTarget *target) {
  return nsDDCPickCandidate(candidates, count, target);
}

typedef CFDictionaryRef (*DisplayInfoFn)(CGDirectDisplayID display);

// Checks the framebuffer's DisplayAttributes against CG's vendor and product.
// Missing attributes are not a disagreement.
static BOOL framebufferAgrees(io_registry_entry_t framebuffer, uint32_t vendor, uint32_t model) {
  CFTypeRef attributes =
      IORegistryEntryCreateCFProperty(framebuffer, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0);
  if (attributes == NULL) {
    return YES;
  }
  BOOL agrees = YES;
  if (CFGetTypeID(attributes) == CFDictionaryGetTypeID()) {
    CFTypeRef product = CFDictionaryGetValue(attributes, CFSTR("ProductAttributes"));
    if (product != NULL && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
      CFTypeRef legacy = CFDictionaryGetValue(product, CFSTR("LegacyManufacturerID"));
      CFTypeRef productID = CFDictionaryGetValue(product, CFSTR("ProductID"));
      int64_t value = 0;
      if (legacy != NULL && CFGetTypeID(legacy) == CFNumberGetTypeID() &&
          CFNumberGetValue(legacy, kCFNumberSInt64Type, &value) && vendor != 0 &&
          vendor != 0xFFFFFFFFu && (uint32_t)value != vendor) {
        agrees = NO;
      }
      if (productID != NULL && CFGetTypeID(productID) == CFNumberGetTypeID() &&
          CFNumberGetValue(productID, kCFNumberSInt64Type, &value) && (uint32_t)value != model) {
        agrees = NO;
      }
    }
  }
  CFRelease(attributes);
  return agrees;
}

// Finds which display pipe ("dispext0") drives this display, through the private
// CoreDisplay info dictionary that MonitorControl also relies on. Leaves out empty
// when anything is missing or doesn't line up, so matching falls back to EDID data.
static void displayPort(CGDirectDisplayID display, uint32_t vendor, uint32_t model, char *out,
                        size_t cap) {
  static DisplayInfoFn info = NULL;
  static dispatch_once_t once;
  out[0] = '\0';
  dispatch_once(&once, ^{
    info = (DisplayInfoFn)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
    if (info == NULL) {
      void *lib = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
      if (lib != NULL) {
        info = (DisplayInfoFn)dlsym(lib, "CoreDisplay_DisplayCreateInfoDictionary");
      }
    }
  });
  if (info == NULL) {
    return;
  }
  CFDictionaryRef dict = info(display);
  if (dict == NULL) {
    return;
  }
  char path[512];
  CFTypeRef location = CFDictionaryGetValue(dict, CFSTR("IODisplayLocation"));
  BOOL ok = location != NULL && CFGetTypeID(location) == CFStringGetTypeID() &&
            CFStringGetCString(location, path, sizeof(path), kCFStringEncodingUTF8);
  CFRelease(dict);
  if (!ok) {
    return;
  }
  io_registry_entry_t framebuffer = IORegistryEntryFromPath(kIOMainPortDefault, path);
  if (framebuffer != MACH_PORT_NULL) {
    ok = framebufferAgrees(framebuffer, vendor, model);
    IOObjectRelease(framebuffer);
    if (!ok) {
      return;
    }
  }
  // ".../AppleT600xIO/dispext0@88000000/AppleCLCD2" -> "dispext0"
  char *last = strrchr(path, '/');
  if (last == NULL || last == path ||
      (strncmp(last + 1, "AppleCLCD2", 10) != 0 &&
       strncmp(last + 1, "IOMobileFramebufferShim", 23) != 0)) {
    return;
  }
  *last = '\0';
  char *pipe = strrchr(path, '/');
  ddcPortName(pipe != NULL ? pipe + 1 : path, '@', out, cap);
}

static IOAVServiceRef serviceMatching(const DDCTarget *target) {
  io_iterator_t iter = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                   &iter) != KERN_SUCCESS) {
    return NULL;
  }
  io_service_t service;
  IOAVServiceRef services[8];
  DDCCandidate candidates[8];
  int count = 0;
  while ((service = IOIteratorNext(iter))) {
    DDCCandidate c;
    memset(&c, 0, sizeof(c));
    c.external = YES;
    CFTypeRef location =
        IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
    if (location != NULL) {
      if (CFGetTypeID(location) == CFStringGetTypeID()) {
        c.external = CFEqual(location, CFSTR("External"));
      }
      CFRelease(location);
    }
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
      io_name_t name;
      if (IORegistryEntryGetName(parent, name) == KERN_SUCCESS) {
        ddcPortName(name, ':', c.port, sizeof(c.port));
      }
      IOObjectRelease(parent);
    }
    IOAVServiceRef av = NULL;
    if (c.external && count < 8) {
      av = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    }
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
    c.vendor = (uint32_t)((bytes[8] << 8) | bytes[9]);
    c.product = (uint32_t)(bytes[10] | (bytes[11] << 8));
    c.serial = (uint32_t)(bytes[12] | (bytes[13] << 8) | (bytes[14] << 16) |
                          ((uint32_t)bytes[15] << 24));
    CFRelease(edid);
    services[count] = av;
    candidates[count] = c;
    count++;
  }
  IOObjectRelease(iter);
  int pick = ddcPickCandidate(candidates, count, target);
  for (int i = 0; i < count; i++) {
    if (i != pick) {
      CFRelease(services[i]);
    }
  }
  return pick >= 0 ? services[pick] : NULL;
}

// DDC/CI wants a pause after a Set VCP before the monitor will answer the
// next message with the new value (MonitorControl: 10 ms between writes,
// 50 ms before a read, 20 ms between read retries). Worker only.
static const useconds_t kDDCAfterWrite = 60000;
static const useconds_t kDDCBetweenReads = 30000;
static const useconds_t kDDCRecheck = 100000;
static uint64_t gDDCWroteAt = 0;

static uint64_t ddcNow(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void ddcWaitAfterWrite(void) {
  if (gDDCWroteAt == 0) {
    return;
  }
  uint64_t elapsed = ddcNow() - gDDCWroteAt;
  uint64_t wait = (uint64_t)kDDCAfterWrite * 1000;
  if (elapsed < wait) {
    usleep((useconds_t)((wait - elapsed) / 1000));
  }
}

static BOOL ddcReadOnce(IOAVServiceRef service, int *current, int *max) {
  ddcWaitAfterWrite();
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

// Brightness for a display that waits for the current probe to land
// (setDisplayBrightnessThen, revalidateDDC). Main thread only.
static DisplayPercents gDeferredBrightness;

// Main thread. Callers waiting for a display's newest lamp write to land
// (the CLI's brightness command), fired once by ddcLanded, or with NO when
// the channel is cleared or replaced.
typedef void (^BrightnessDone)(BOOL ok);
static NSMutableDictionary<NSNumber *, NSMutableArray<BrightnessDone> *> *gDDCWaiters;

static void ddcAddWaiter(uint32_t display, BrightnessDone done) {
  if (gDDCWaiters == nil) {
    gDDCWaiters = [NSMutableDictionary dictionary];
  }
  NSMutableArray<BrightnessDone> *list = gDDCWaiters[@(display)];
  if (list == nil) {
    list = [NSMutableArray array];
    gDDCWaiters[@(display)] = list;
  }
  [list addObject:[done copy]];
}

static void ddcFireWaiters(uint32_t display, BOOL ok) {
  NSArray<BrightnessDone> *list = gDDCWaiters[@(display)];
  if (list.count == 0) {
    return;
  }
  [gDDCWaiters removeObjectForKey:@(display)];
  for (BrightnessDone done in list) {
    done(ok);
  }
}

static void clearDDCSlot(int i) {
  __atomic_store_n(&gDDC[i].max, 0, __ATOMIC_RELEASE);
  IOAVServiceRef service = gDDC[i].service;
  gDDC[i].service = NULL;
  gDDC[i].current = 0;
  gDDC[i].floorRaw = -1;
  gDDC[i].combined = -1;
  gDDC[i].posted = -1;
  gDDC[i].retries = 0;
  gDDC[i].saveWaiting = NO;
  gDDC[i].applyWaiting = NO;
  uint32_t display = gDDC[i].display;
  gDDC[i].display = 0;
  // Queued work for the old channel sees a new seq and drops out.
  gDDC[i].settled = __atomic_add_fetch(&gDDC[i].seq, 1, __ATOMIC_ACQ_REL);
  if (service != NULL) {
    CFRelease(service);
  }
  if (display != 0) {
    ddcFireWaiters(display, NO);
  }
}

// Finding 9: a display reuses its own slot even when a lower slot is free,
// so it never ends up with two.
static int ddcSlotIndexFor(uint32_t display) {
  uint32_t displays[8];
  for (int i = 0; i < 8; i++) {
    displays[i] = gDDC[i].display;
  }
  return nsDDCSlotFor(displays, 8, display);
}

static void publishDDC(uint32_t display, IOAVServiceRef service, int current, int max) {
  int i = ddcSlotIndexFor(display);
  if (i < 0) {
    if (service != NULL) {
      CFRelease(service);
    }
    return;
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
  gDDC[i].posted = max > 0 ? current : -1;
  gDDC[i].retries = 0;
  gDDC[i].saveWaiting = NO;
  if (gDDC[i].applyWaiting) {
    // The write this replaces never applied its change; do it after the probe.
    gDDC[i].applyWaiting = NO;
    putDisplayPercent(&gDeferredBrightness, display, gDDC[i].applyPercent);
  }
  gDDC[i].settled = __atomic_add_fetch(&gDDC[i].seq, 1, __ATOMIC_ACQ_REL);
  __atomic_store_n(&gDDC[i].max, max, __ATOMIC_RELEASE);
  // Anything waiting on a job this replaced hears now rather than timing out.
  ddcFireWaiters(display, max > 0);
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

// Main thread. The slots as they were when a probe was sent, so its results
// can tell whether a write, a clear or a replug moved a slot on while the
// reads were out. The worker reads only this copy, never gDDC.
typedef struct {
  uint32_t display[8];
  unsigned seq[8];
  int max[8];
} DDCSnapshot;

static DDCSnapshot ddcSnapshot(void) {
  DDCSnapshot snap;
  for (int i = 0; i < 8; i++) {
    snap.display[i] = gDDC[i].display;
    snap.seq[i] = __atomic_load_n(&gDDC[i].seq, __ATOMIC_ACQUIRE);
    snap.max[i] = __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE);
  }
  return snap;
}

static BOOL snapshotReady(const DDCSnapshot *snap, uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (snap->display[i] == display && snap->max[i] > 0) {
      return YES;
    }
  }
  return NO;
}

// Main thread. A probe result is older than any confirmation or seq bump
// that happened after the snapshot, and must not be published over it.
static BOOL ddcMovedSince(const DDCSnapshot *snap, uint32_t display) {
  // Confirmed since the probe was sent. A channel that was already ready is
  // being revalidated, and only a seq bump makes its reads stale.
  if (ddcReady(display) && !snapshotReady(snap, display)) {
    return YES;
  }
  for (int i = 0; i < 8; i++) {
    if (snap->display[i] != display) {
      continue;
    }
    if (gDDC[i].display != display ||
        __atomic_load_n(&gDDC[i].seq, __ATOMIC_ACQUIRE) != snap->seq[i]) {
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
static void applyDeferredBrightness(void);
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

static DDCSlot *ddcSlot(uint32_t display);
static long ddcFloorPercent(uint32_t display);
static int ddcLampValue(DDCSlot *slot, long percent, long floor, int scale);
static void combinedLevels(long percent, long floor, long *hardware, long *software);
static BOOL ddcNear(int got, int want, int scale);

static BOOL setDisplayBrightness(uint32_t display, long percent);

static double secondsSince(CFAbsoluteTime at) {
  return at == 0 ? -1 : CFAbsoluteTimeGetCurrent() - at;
}

// Main thread. A probe re-read a channel that was already confirmed (after
// wake, replug or a screen change). The service is always the fresh one, so
// a dead IOAVService from before the change is dropped. A failed read keeps
// the confirmed scale: the first write that fails demotes it (ddcLanded).
//
// N9: the slot is refreshed in place. It is not republished, which would
// bump seq (dropping a just-released drag's settle and save) and clear
// saveWaiting and applyWaiting. A probe result only gets here when no write
// was queued since it was sent (ddcMovedSince). Then nsRevalidateAction
// decides: keep a value the user set in the last kNSUserQuietSeconds,
// reapply the shown brightness when the monitor came back from sleep far
// off (it reset itself), and otherwise adopt what the monitor reports, so
// changes made with its own buttons stick.
static void revalidateDDC(uint32_t display, IOAVServiceRef service, int current, int max) {
  DDCSlot *slot = ddcSlot(display);
  if (slot == NULL) {
    publishDDC(display, service, current, max);
    return;
  }
  if (service != NULL) {
    if (slot->service != service) {
      if (slot->service != NULL) {
        CFRelease(slot->service);
      }
      slot->service = service;
    } else {
      CFRelease(service);
    }
  }
  if (max <= 0) {
    if (service == NULL) {
      return;
    }
    slot->posted = -1;
    return;
  }
  slot->current = current;
  slot->posted = current;
  slot->retries = 0;
  __atomic_store_n(&slot->max, max, __ATOMIC_RELEASE);
  if (slot->combined < 0 || slot->combined > 100 || slot->applyWaiting || slot->saveWaiting) {
    return;
  }
  long floor = ddcFloorPercent(display);
  long hardware = 0;
  long software = 100;
  combinedLevels(slot->combined, floor, &hardware, &software);
  int target = ddcLampValue(slot, hardware, floor, max);
  switch (nsRevalidateAction(current, target, max, secondsSince(slot->changedAt),
                             secondsSince(gWokeAt))) {
    case kNSRevalidateKeep:
      break;
    case kNSRevalidateReapply:
      putDisplayPercent(&gDeferredBrightness, display, slot->combined);
      break;
    case kNSRevalidateAdopt: {
      long adopted = nsLampToCombined(nsDDCRawPercent(current, max), floor < 0 ? 0 : floor);
      if (adopted != slot->combined) {
        // Saved, so a relaunch restores the monitor's value too.
        BrightnessSaving was = gBrightnessSaving;
        gBrightnessSaving = kSaveNow;
        setDisplayBrightness(display, adopted);
        gBrightnessSaving = was;
      }
      break;
    }
  }
}

static void probeDDC(void) {
  if (gDDCBusy) {
    gDDCAgain = YES;
    return;
  }
  if (!gDDCRevalidate && !ddcNeedsProbe() && gDDCLast != 0 &&
      CFAbsoluteTimeGetCurrent() - gDDCLast < 3) {
    return;
  }
  BOOL revalidate = gDDCRevalidate;
  gDDCRevalidate = NO;
  gDDCBusy = YES;
  gDDCLast = CFAbsoluteTimeGetCurrent();
  DDCSnapshot seen = ddcSnapshot();
  // On the DDC queue so probe reads can't overlap a lamp write.
  dispatch_async(ddcQueue(), ^{
    uint32_t ids[16];
    int count = orderedDisplays(ids, 16);
    uint32_t targets[8];
    DDCTarget wanted[8];
    int pending = 0;
    for (int i = 0; i < count && pending < 8; i++) {
      if (CGDisplayIsBuiltin(ids[i]) || (!revalidate && snapshotReady(&seen, ids[i]))) {
        continue;
      }
      DDCTarget *t = &wanted[pending];
      memset(t, 0, sizeof(*t));
      t->vendor = CGDisplayVendorNumber(ids[i]);
      t->model = CGDisplayModelNumber(ids[i]);
      t->serial = CGDisplaySerialNumber(ids[i]);
      for (int j = 0; j < count; j++) {
        if (CGDisplayIsBuiltin(ids[j]) || CGDisplayVendorNumber(ids[j]) != t->vendor ||
            CGDisplayModelNumber(ids[j]) != t->model) {
          continue;
        }
        t->twins++;
        if (j != i && t->serial != 0 && CGDisplaySerialNumber(ids[j]) == t->serial) {
          t->serialShared = YES;
        }
      }
      displayPort(ids[i], t->vendor, t->model, t->port, sizeof(t->port));
      targets[pending] = ids[i];
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
      IOAVServiceRef service = serviceMatching(&wanted[i]);
      int current = 0;
      int max = 0;
      BOOL ok = NO;
      if (service != NULL) {
        for (int attempt = 0; attempt < 4 && !ok; attempt++) {
          if (attempt > 0) {
            usleep(kDDCBetweenReads);
          }
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
        // A write confirmed or moved this channel while the probe was out, so
        // these reads are stale. Publishing them would reset current and
        // posted and drop queued writes. The result owns its service.
        if (ddcMovedSince(&seen, results[i].display)) {
          if (results[i].service != NULL) {
            CFRelease(results[i].service);
          }
          // A failed write left it unconfirmed: read it again now rather
          // than at the next menu open.
          if (ddcUnconfirmed(results[i].display)) {
            gDDCAgain = YES;
            gDDCLast = 0;
          }
          continue;
        }
        if (results[i].service == NULL && ddcHasService(results[i].display)) {
          continue;
        }
        if (snapshotReady(&seen, results[i].display)) {
          revalidateDDC(results[i].display, results[i].service, results[i].current,
                        results[i].max);
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
      applyDeferredBrightness();
      applyPendingBrightnessKeys();
      refreshMenu();
      refreshKeyDisplays();
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

static int ddcValue(long percent, int scale) { return nsDDCValue(percent, scale); }

static BOOL ddcNear(int got, int want, int scale) { return nsDDCNear(got, want, scale); }

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
  gDDCWroteAt = ddcNow();
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

static long ddcRawPercent(int raw, int scale) { return nsDDCRawPercent(raw, scale); }

static void ddcNoteMove(DDCSlot *slot, int before, int wanted, int landed, int scale,
                        long percent, BOOL stable) {
  slot->floorRaw = nsDDCLearnFloor(slot->floorRaw, before, wanted, landed, scale, percent, stable);
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

static long lampToCombined(long lamp, long floor) { return nsLampToCombined(lamp, floor); }

static void combinedLevels(long percent, long floor, long *hardware, long *software) {
  nsCombinedLevels(percent, floor, hardware, software);
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

// The floor came from a raw readback. Reuse that raw value so a round trip
// through percent can't miss it by one and force a write that changes nothing.
static int ddcLampValue(DDCSlot *slot, long percent, long floor, int scale) {
  if (floor > 0 && percent == floor && slot->floorRaw > 0 && slot->floorRaw <= scale) {
    return slot->floorRaw;
  }
  return ddcValue(percent, scale);
}

// Worker only. Reads back what the monitor applied and, when it reports a
// different scale than the write assumed, makes the one corrective write.
// A reading that is off target is read again after a pause: slow monitors
// report the old value for a while, and only a reading two reads agree on
// (stable) may teach the slot a floor.
static void ddcConfirm(DDCJob *job) {
  int current = 0;
  int max = 0;
  job->read = NO;
  job->stable = NO;
  if (!ddcReadOnce(job->service, &current, &max) || max <= 0) {
    return;
  }
  int wanted = ddcValue(job->percent, max);
  if (wanted != job->value && ddcNear(current, job->value, max) &&
      ddcWriteOnce(job->service, wanted)) {
    job->value = wanted;
    job->scale = max;
    int corrected = 0;
    int correctedMax = 0;
    if (!ddcReadOnce(job->service, &corrected, &correctedMax) || correctedMax <= 0) {
      return;
    }
    current = corrected;
    max = correctedMax;
  }
  BOOL stable = ddcNear(current, ddcValue(job->percent, max), max);
  if (!stable) {
    usleep(kDDCRecheck);
    int again = 0;
    int againMax = 0;
    if (ddcReadOnce(job->service, &again, &againMax) && againMax == max) {
      stable = again == current;
      current = again;
    }
  }
  job->read = YES;
  job->stable = stable;
  job->landed = current;
  job->max = max;
}

// Main thread. Folds a finished job into the slot and returns the lamp
// percent that landed. An unreadable monitor keeps the written value and
// latches the assumed scale, as before.
static long ddcSettle(DDCSlot *slot, const DDCJob *job) {
  slot->settled = job->seq;
  if (!job->read) {
    ddcCommit(slot, job->value, job->scale);
    slot->posted = job->value;
    return job->percent;
  }
  int before = slot->current;
  ddcCommit(slot, job->landed, job->max);
  ddcNoteMove(slot, before, ddcValue(job->percent, job->max), job->landed, job->max,
              job->percent, job->stable);
  slot->posted = job->landed;
  return ddcRawPercent(job->landed, job->max);
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

// Displays dimmed in software, by percent. The dim is the display's gamma
// table scaled down, not a window: a full-screen window got picked by
// Cmd-Shift-4's window mode and showed up in screenshots.
static NSMutableDictionary<NSNumber *, NSNumber *> *gShades = nil;
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
  if (percent >= 100) {
    if (gShades[key] != nil) {
      restoreGamma(display);
      [gShades removeObjectForKey:key];
    }
    [gSoftwareBrightness removeObjectForKey:key];
    liftBrightnessHUD();
    return;
  }
  if (percent < 0) {
    percent = 0;
  }
  if (screenForDisplay(display) == nil || !setGammaLevel(display, (float)percent / 100.0f)) {
    return;
  }
  gShades[key] = @(percent);
  gSoftwareBrightness[key] = @((float)percent / 100.0f);
  liftBrightnessHUD();
}

static BOOL shadeLogical(uint32_t display, float *level) {
  if (gShades[@(display)] == nil) {
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

static BOOL ddcPost(uint32_t display, DDCSlot *slot, long percent, long floor);
static void probeDDC(void);

// Main thread. Finishes a change with the saving mode it was made with,
// after the fact (an unconfirmed channel's write landing). A release that
// waited on the lamp saves now that it landed.
static BOOL finishBrightnessAs(uint32_t display, long percent, int saving) {
  BrightnessSaving was = gBrightnessSaving;
  gBrightnessSaving = saving == kSaveHeld ? kSaveHeld : kSaveNow;
  BOOL ok = finishBrightness(display, percent);
  gBrightnessSaving = was;
  return ok;
}

// Main thread. An unconfirmed channel refused the write: the shade does all
// of the dimming, never below kSoftwareDimFloor.
static BOOL shadeInstead(uint32_t display, long percent, int saving) {
  if (screenForDisplay(display) == nil) {
    return NO;
  }
  restoreGamma(display);
  if (percent < kSoftwareDimFloor) {
    percent = kSoftwareDimFloor;
  }
  applyDim(display, percent);
  return finishBrightnessAs(display, percent, saving);
}

static void forgetLandedSave(uint32_t display) {
  DDCSlot *slot = ddcSlot(display);
  if (slot != NULL) {
    slot->saveWaiting = NO;
  }
}

static void saveLandedBrightness(uint32_t display, DDCSlot *slot) {
  if (!slot->saveWaiting) {
    return;
  }
  slot->saveWaiting = NO;
  if (!noteBrightness(display, slot->savePercent)) {
    notifyPlain(@"Could not save brightness");
  }
}

// Main thread. A drag released on a live DDC channel. The shade and number
// already moved; the save waits for the lamp write, and a failed write leaves
// the file at its value from before the drag.
static void saveWhenLanded(uint32_t display, DDCSlot *slot, long percent) {
  noteCursorBrightness(display, percent);
  if (gSoftwareBrightness == nil) {
    gSoftwareBrightness = [NSMutableDictionary dictionary];
  }
  gSoftwareBrightness[@(display)] = @(percent / 100.0);
  dropDisplayPercent(&gHeldBrightness, display);
  slot->saveWaiting = YES;
  slot->savePercent = percent;
  // Nothing in flight: the newest target already landed.
  if (slot->posted >= 0 && slot->settled == __atomic_load_n(&slot->seq, __ATOMIC_ACQUIRE)) {
    saveLandedBrightness(display, slot);
  }
}

// Main thread. A live write's readback came in. Only the newest target's
// result counts; anything older was superseded and its successor will settle.
static void ddcLanded(DDCJob job) {
  DDCSlot *slot = ddcSlot(job.display);
  if (slot == NULL || slot->service != job.service ||
      __atomic_load_n(&slot->seq, __ATOMIC_ACQUIRE) != job.seq) {
    return;
  }
  if (!job.wrote) {
    // Unknown lamp state: the next move must write rather than skip.
    slot->posted = -1;
    slot->settled = job.seq;
    // The lamp refused a released drag. Keep the saved value.
    slot->saveWaiting = NO;
    BOOL shaded = NO;
    if (slot->applyWaiting) {
      slot->applyWaiting = NO;
      slot->combined = -1;
      shaded = shadeInstead(job.display, slot->applyPercent, slot->applySaving);
    }
    // Finding 4: a confirmed channel that stops taking writes (sleep, a
    // replug that kept the display ID, a retrained link) is demoted and
    // probed again instead of being written to forever.
    if (__atomic_load_n(&slot->max, __ATOMIC_ACQUIRE) > 0) {
      __atomic_store_n(&slot->max, 0, __ATOMIC_RELEASE);
      gDDCRevalidate = YES;
      gDDCLast = 0;
      probeDDC();
    }
    refreshKeyDisplays();
    ddcFireWaiters(job.display, shaded);
    return;
  }
  long floor = slot->postFloor;
  BOOL applying = slot->applyWaiting;
  slot->applyWaiting = NO;
  ddcSettle(slot, &job);
  saveLandedBrightness(job.display, slot);
  BOOL retrying = NO;
  if (slot->combined >= 0 && slot->combined <= 100) {
    long learned = ddcFloorPercent(job.display);
    long hardware = 0;
    long software = 100;
    combinedLevels(slot->combined, learned, &hardware, &software);
    int scale = ddcScale(__atomic_load_n(&slot->max, __ATOMIC_ACQUIRE));
    int target = ddcLampValue(slot, hardware, learned, scale);
    // A newly learned floor moves the split, so the shade follows it. Without
    // one, a lamp well off target means the write didn't take.
    BOOL off = learned != floor ? target != slot->current
                                : !ddcNear(slot->current, target, scale);
    if (learned != floor || applying) {
      slot->postFloor = learned;
      if (applying) {
        restoreGamma(job.display);
      }
      applyDim(job.display, software);
    }
    if (off && slot->retries < 2) {
      slot->retries++;
      retrying = ddcPost(job.display, slot, hardware, learned);
    }
  }
  if (applying) {
    finishBrightnessAs(job.display, slot->applyPercent, slot->applySaving);
  }
  if (!retrying) {
    ddcFireWaiters(job.display, YES);
  }
}

static void ddcDeliver(DDCJob job) {
  dispatch_async(dispatch_get_main_queue(), ^{
    ddcLanded(job);
    CFRelease(job.service);
  });
}

static const int64_t kDDCSettleDelay = (int64_t)(150 * NSEC_PER_MSEC);

// Main thread. Hands the newest lamp target to the worker and returns at once.
// The worker drops any target that was replaced before it ran, writes the
// rest, and reads back once the value has been idle for kDDCSettleDelay.
static BOOL ddcPost(uint32_t display, DDCSlot *slot, long percent, long floor) {
  int scale = ddcScale(__atomic_load_n(&slot->max, __ATOMIC_ACQUIRE));
  int value = ddcLampValue(slot, percent, floor, scale);
  // Already there or already queued, e.g. a move inside the shade range.
  if (value == slot->posted) {
    return NO;
  }
  slot->posted = value;
  unsigned *latest = &slot->seq;
  DDCJob job = {0};
  job.display = display;
  job.service = CFRetain(slot->service);
  job.seq = __atomic_add_fetch(latest, 1, __ATOMIC_ACQ_REL);
  job.percent = percent;
  job.scale = scale;
  job.value = value;
  dispatch_async(ddcQueue(), ^{
    DDCJob work = job;
    if (__atomic_load_n(latest, __ATOMIC_ACQUIRE) != work.seq) {
      CFRelease(work.service);
      return;
    }
    work.wrote = ddcWriteOnce(work.service, work.value);
    if (!work.wrote) {
      ddcDeliver(work);
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kDDCSettleDelay), ddcQueue(), ^{
      DDCJob done = work;
      if (__atomic_load_n(latest, __ATOMIC_ACQUIRE) != done.seq) {
        CFRelease(done.service);
        return;
      }
      ddcConfirm(&done);
      ddcDeliver(done);
    });
  });
  return YES;
}

// Brightness asked for on an unconfirmed channel while a probe holds the DDC
// queue. Writing it then would park the main thread, and the brightness-key
// tap, behind the probe, so the newest value per display waits here and is
// applied when the probe lands. gDeferredBrightness is declared above
// clearDDCSlot.

// Finding 1, patch review N6. Online displays other than display that are
// trusted to still show a picture (nsCountsAsLit): the built-in panel, or a
// display whose brightness is read from the display itself. A display known
// only through the software shade (a dummy plug, a virtual or DisplayLink
// display, a monitor without working DDC) doesn't count.
static BOOL hardwareBrightness(uint32_t display) {
  float level = 0;
  return ddcReady(display) || DisplayServicesCanChangeBrightness(display) ||
         readCoreBrightness(display, &level);
}

static int litDisplaysBesides(uint32_t display) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  NSOtherDisplay others[16];
  int n = 0;
  for (int i = 0; i < count; i++) {
    uint32_t other = ids[i];
    if (other == display) {
      continue;
    }
    BOOL builtin = CGDisplayIsBuiltin(other) != 0;
    others[n++] = (NSOtherDisplay){
        .builtin = builtin,
        .hardware = !builtin && hardwareBrightness(other),
        .asleep = CGDisplayIsAsleep(other) != 0,
        .mirrored = CGDisplayMirrorsDisplay(other) == display ||
                    CGDisplayMirrorsDisplay(display) == other,
        .percent = readPercent(other),
    };
  }
  return nsLitDisplays(others, n);
}

// The percent display may be set to. Black on an external display only while
// another display stays lit; otherwise the dimmest visible level.
static long safeBrightness(uint32_t display, long percent) {
  if (percent > 0) {
    return percent > 100 ? 100 : percent;
  }
  BOOL builtin = CGDisplayIsBuiltin(display) != 0;
  return nsSafeBrightness(percent, builtin, builtin ? 0 : litDisplaysBesides(display));
}

// Main thread. Finding 1 failsafe, after displays come or go and after
// wake: if every display is black (the lit one was unplugged or its lid
// closed), the first black external display comes back at
// kNSRestoreMinimum.
static BOOL setDisplayBrightness(uint32_t display, long percent);

static void keepADisplayLit(void) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  for (int i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(ids[i]) || readPercent(ids[i]) != 0 ||
        litDisplaysBesides(ids[i]) > 0) {
      continue;
    }
    BrightnessSaving was = gBrightnessSaving;
    gBrightnessSaving = kSaveNow;
    setDisplayBrightness(ids[i], kNSRestoreMinimum);
    gBrightnessSaving = was;
    return;
  }
}

// Sets a display's brightness. NO means it failed now and done is not
// called. YES means it was applied or is on its way; done, when given, is
// called once on the main thread when the lamp write lands (YES) or fails
// (NO), right away for anything that isn't a DDC lamp. Nothing here waits
// on the monitor (finding 5).
static BOOL setDisplayBrightnessThen(uint32_t display, long percent, BrightnessDone done) {
  if (percent < 0) {
    percent = 0;
  }
  if (percent > 100) {
    percent = 100;
  }
  percent = safeBrightness(display, percent);
  DDCSlot *changed = ddcSlot(display);
  if (changed != NULL) {
    changed->changedAt = CFAbsoluteTimeGetCurrent();
  }
  float level = (float)percent / 100.0f;
  BOOL ok = NO;
  if (DisplayServicesCanChangeBrightness(display)) {
    if (DisplayServicesSetBrightness(display, level) != 0) {
      return NO;
    }
    restoreGamma(display);
    applyDim(display, 100);
    ok = finishBrightness(display, percent);
    if (ok && done != nil) {
      done(YES);
    }
    return ok;
  }
  float current = 0;
  if (readCoreBrightness(display, &current)) {
    NightshiftBrightnessClient *client = brightnessClient();
    if (client != nil && [client setProperty:@(level)
                                     withKey:@"DisplayServicesBrightness"
                                  andDisplay:display]) {
      restoreGamma(display);
      applyDim(display, 100);
      ok = finishBrightness(display, percent);
      if (ok && done != nil) {
        done(YES);
      }
      return ok;
    }
  }
  // Report the value now so the next key step builds on it. The CLI waits
  // for its own write instead, and an older deferred value must not land
  // after it.
  if (done != nil) {
    dropDisplayPercent(&gDeferredBrightness, display);
  } else if (gDDCBusy && ddcUnconfirmed(display) && putDisplayPercent(&gDeferredBrightness, display, percent)) {
    if (gSoftwareBrightness == nil) {
      gSoftwareBrightness = [NSMutableDictionary dictionary];
    }
    gSoftwareBrightness[@(display)] = @((float)percent / 100.0f);
    return YES;
  }
  long floor = ddcFloorPercent(display);
  long hardware = percent;
  long software = 100;
  combinedLevels(percent, floor, &hardware, &software);
  DDCSlot *slot = ddcSlot(display);
  // A confirmed channel is optimistic: shade, number and save happen now and
  // the worker brings the lamp along.
  if (slot != NULL && __atomic_load_n(&slot->max, __ATOMIC_ACQUIRE) > 0) {
    slot->retries = 0;
    slot->postFloor = floor;
    slot->applyWaiting = NO;
    ddcRememberCombined(display, percent);
    BOOL posted = ddcPost(display, slot, hardware, floor);
    restoreGamma(display);
    applyDim(display, software);
    if (gBrightnessSaving == kSaveWhenLanded) {
      saveWhenLanded(display, slot, percent);
      ok = YES;
    } else {
      ok = finishBrightness(display, percent);
    }
    if (ok && done != nil) {
      if (posted || slot->settled != __atomic_load_n(&slot->seq, __ATOMIC_ACQUIRE)) {
        ddcAddWaiter(display, done);
      } else {
        done(YES);
      }
    }
    return ok;
  }
  // An unconfirmed channel writes in the background too. Its number shows
  // the new value now; the shade and the save wait for the write
  // (ddcLanded), and a write that fails falls back to the shade there.
  if (slot != NULL) {
    slot->retries = 0;
    slot->postFloor = floor;
    slot->saveWaiting = NO;
    ddcRememberCombined(display, percent);
    slot->applyWaiting = YES;
    slot->applyPercent = percent;
    slot->applySaving = gBrightnessSaving;
    slot->posted = -1;
    ddcPost(display, slot, hardware, floor);
    if (done != nil) {
      ddcAddWaiter(display, done);
    }
    return YES;
  }
  if (ddcFailed(display) && screenForDisplay(display) != nil) {
    restoreGamma(display);
    percent = softwareDimPercent(display, percent);
    applyDim(display, percent);
    ok = finishBrightness(display, percent);
  } else if (screenForDisplay(display) != nil) {
    return NO;
  } else {
    // No window can cover this display; dim its gamma, never to black.
    float gammaLevel = percent > 0 && percent < kNSShadeFloor ? kNSShadeFloor / 100.0f : level;
    if (!setGammaLevel(display, gammaLevel)) {
      return NO;
    }
    ok = finishBrightness(display, percent);
  }
  if (ok && done != nil) {
    done(YES);
  }
  return ok;
}

static BOOL setDisplayBrightness(uint32_t display, long percent) {
  return setDisplayBrightnessThen(display, percent, nil);
}

// Main thread, once a probe has landed and gDDCBusy is clear, so nothing
// defers again while this runs.
static void applyDeferredBrightness(void) {
  DisplayPercents deferred = gDeferredBrightness;
  gDeferredBrightness.count = 0;
  for (int i = 0; i < deferred.count; i++) {
    setDisplayBrightness(deferred.display[i], deferred.percent[i]);
  }
}

// Main thread. One tick of a slider or HUD drag: applied, held in memory,
// not saved.
static void holdBrightnessTick(uint32_t display, long percent) {
  gBrightnessSaving = kSaveHeld;
  setDisplayBrightness(display, percent);
  gBrightnessSaving = kSaveNow;
}

// Main thread. A drag ended at percent, on release or when the menu closed
// under it. This is its one save. A failed set saves nothing, so the file
// keeps the value from before the drag.
static BOOL endBrightnessDrag(uint32_t display, long percent) {
  gBrightnessSaving = kSaveWhenLanded;
  BOOL ok = setDisplayBrightness(display, percent);
  gBrightnessSaving = kSaveNow;
  dropDisplayPercent(&gHeldBrightness, display);
  return ok;
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
    [gShades removeObjectForKey:key];
    [gSoftwareBrightness removeObjectForKey:key];
  }
  liftBrightnessHUD();
  noteCursorDisplaysOffline();
  keepADisplayLit();
}

// A display reconfiguration can reset gamma tables, so the dims go back on.
static void refitDimWindows(void) {
  for (NSNumber *key in gShades.allKeys) {
    setGammaLevel(key.unsignedIntValue, gShades[key].floatValue / 100.0f);
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
    long percent = lround(saved.doubleValue * 100.0);
    NSString *savedKey = displayBrightnessKey(ids[i]);
    BOOL legacyLamp = gCombinedBrightness == nil ||
                      ![gCombinedBrightness containsObject:savedKey];
    // An unmarked line from an old file is a lamp percent only if the lamp
    // takes it. Any DDC channel tries the one-time scale change, even one
    // whose first readback failed. A shade has no channel and keeps its value.
    long legacy = percent;
    BOOL converting = legacyLamp && ddcHasService(ids[i]);
    if (converting) {
      percent = lampToCombined(percent, 0);
    }
    // Finding 1: black and near-black don't survive a relaunch, so a login
    // item can't start the session on a screen the user can't see.
    percent = nsRestoredBrightness(percent);
    legacy = nsRestoredBrightness(legacy);
    gSoftwareBrightness[@(ids[i])] = @(percent / 100.0);
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
    // If the write falls back to the shade, the line was a shade percent
    // all along. Put it back once that is known. Either save marks the line,
    // so no later launch converts it again. This runs only once a probe has
    // landed, with gDDCBusy clear, so the set writes instead of deferring.
    uint32_t display = ids[i];
    BrightnessDone check = nil;
    if (converting && percent != legacy) {
      check = ^(BOOL landed) {
        if (!landed && !ddcReady(display)) {
          setDisplayBrightness(display, legacy);
        }
      };
    }
    if (setDisplayBrightnessThen(display, percent, check)) {
      markDisplayRestored(display);
    }
  }
}

static BOOL loginItemOn(void) {
  return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}

static const CGFloat kBrightnessHUDWidth = 312;
static const CGFloat kBrightnessHUDHeight = 80;

// Text drawn on an accent fill: white, or near-black when the user's accent
// is light (yellow, light graphite) so it stays readable. Call while drawing,
// so the accent resolves for the view's appearance.
static NSColor *textOnAccent(void) {
  NSColor *accent = [NSColor.controlAccentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (accent == nil) {
    return NSColor.whiteColor;
  }
  CGFloat r = 0;
  CGFloat g = 0;
  CGFloat b = 0;
  CGFloat a = 0;
  [accent getRed:&r green:&g blue:&b alpha:&a];
  CGFloat luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return luma > 0.7 ? [NSColor colorWithWhite:0 alpha:0.85] : NSColor.whiteColor;
}

// Redraws a slider so its accent fill (AccentSliderCell) picks up the
// current accent color.
static void tintSlider(NSSlider *slider) {
  slider.needsDisplay = YES;
}

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
  // The empty part of the bar, under the fill, as in the menu's sliders.
  NSRect empty = NSMakeRect(track.origin.x, sliderY - 2.5, track.size.width, 5);
  [[label colorWithAlphaComponent:0.25] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:empty xRadius:2.5 yRadius:2.5] fill];
  CGFloat fillWidth = fillX - track.origin.x;
  if (fillWidth < knobSize / 2.0) {
    fillWidth = knobSize / 2.0;
  }
  NSRect fill = NSMakeRect(track.origin.x, sliderY - 2.5, fillWidth, 5);
  [NSColor.controlAccentColor setFill];
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
static uint32_t gBrightnessScrubDisplay = 0;
static long gBrightnessScrubPending = -1;
static uint32_t gBrightnessAnchor = 0;

static void liftBrightnessHUD(void) {
  if (gBrightnessPanel == nil) {
    return;
  }
  gBrightnessPanel.level = NSStatusWindowLevel + 2;
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
      gBrightnessScrubDisplay = gBrightnessDisplay;
      gBrightnessScrubPending = -1;
      gBrightnessHUDGeneration++;
      if (gBrightnessPanel != nil) {
        gBrightnessPanel.alphaValue = 1;
      }
      [gBrightnessHide invalidate];
      gBrightnessHide = nil;
    };
    // The scrub loop runs on the main thread. The built-in and a confirmed
    // DDC external are live because the lamp write goes to the DDC worker,
    // which keeps only the newest value. Ticks are held, not saved; release
    // sets the last value again (a no-op if queued) and saves it once.
    // Any other external still sets once on release, since its write blocks.
    gBrightnessMeter.onScrub = ^(long value) {
      uint32_t display = gBrightnessScrubDisplay;
      if (display == 0) {
        return;
      }
      gBrightnessScrubPending = value;
      if (!CGDisplayIsBuiltin(display) && !ddcReady(display)) {
        return;
      }
      holdBrightnessTick(display, value);
      refreshMenu();
    };
    gBrightnessMeter.onScrubEnd = ^{
      uint32_t display = gBrightnessScrubDisplay;
      long pending = gBrightnessScrubPending;
      gBrightnessScrubDisplay = 0;
      gBrightnessScrubPending = -1;
      if (display != 0 && pending >= 0) {
        endBrightnessDrag(display, pending);
        refreshMenu();
      }
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

// Set by a handler that keeps the connection to answer it later.
static BOOL gKeepConnection = NO;
// How long a CLI brightness reply waits for the lamp. Below main.m's
// kBrightnessTimeout, so the CLI hears an answer.
static const int64_t kBrightnessReplyWait = (int64_t)(8 * NSEC_PER_SEC);

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
        buf[11 + consumed] != '\0' || percent < 0 || percent > 100 || !knownDisplay(display)) {
      dprintf(fd, "failed\n");
      return YES;
    }
    // Finding 5: the reply waits for the lamp write without blocking the
    // main thread. The connection is ours now and is closed by answer, at
    // the latest after kBrightnessReplyWait.
    int reply = fd;
    __block BOOL answered = NO;
    void (^answer)(BOOL) = ^(BOOL ok) {
      if (answered) {
        return;
      }
      answered = YES;
      long shown = readPercent(display);
      if (shown < 0) {
        shown = softwareDimPercent(display, percent);
      }
      if (ok) {
        showBrightnessHUD(display, shown);
        dprintf(reply, "%u %ld\n", display, shown);
      } else {
        dprintf(reply, "failed\n");
      }
      close(reply);
    };
    gKeepConnection = YES;
    if (!setDisplayBrightnessThen(display, percent, ^(BOOL ok) {
          answer(ok);
        })) {
      gKeepConnection = NO;
      answered = YES;
      dprintf(fd, "failed\n");
      return YES;
    }
    // Still in flight: report the value it is heading for.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kBrightnessReplyWait),
                   dispatch_get_main_queue(), ^{
                     answer(YES);
                   });
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
  return NSMakeSize(272, row + 32);
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

- (NSColor *)digitColor:(BOOL)placeholder selected:(BOOL)selected {
  NSColor *color = selected ? textOnAccent() : NSColor.labelColor;
  if (placeholder) {
    return [color colorWithAlphaComponent:selected ? 0.55 : 0.35];
  }
  return color;
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
                       ? NSColor.controlAccentColor
                       : [NSColor.quaternaryLabelColor colorWithAlphaComponent:0.45];
  [color setFill];
  [path fill];
}

- (void)drawPeriod:(NSString *)title rect:(NSRect)rect selected:(BOOL)selected {
  [self fillRound:rect radius:5 selected:selected];
  NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  NSColor *color = selected ? textOnAccent() : NSColor.secondaryLabelColor;
  [self drawText:title inRect:rect color:color font:font];
}

- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  [self updateGeometry];
  NSFont *font = [self digitFont];
  BOOL hourSelected = self.enabled && self.field == 0;
  BOOL minuteSelected = self.enabled && self.field == 1;
  if (hourSelected) {
    [self fillRound:_hourRect radius:8 selected:YES];
  }
  if (minuteSelected) {
    [self fillRound:_minuteRect radius:8 selected:YES];
  }
  [self drawText:_hourString
          inRect:_hourRect
           color:[self digitColor:_hourPlaceholder selected:hourSelected]
            font:font];
  [self drawText:@":" inRect:_colonRect color:NSColor.secondaryLabelColor font:font];
  [self drawText:_minuteString
          inRect:_minuteRect
           color:[self digitColor:_minutePlaceholder selected:minuteSelected]
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
    // Green stays: it reports success, not a selection.
    title = @"Saved";
    fill = NSColor.systemGreenColor;
    text = NSColor.whiteColor;
  } else if (pending) {
    fill = NSColor.controlAccentColor;
    text = textOnAccent();
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

// Draws the bar like the stock Sound menu slider: a rounded grey track with
// the accent filled from the minimum end to the knob's center. AppKit leaves
// the fill out in menus (inactive windows), and trackFillColor and
// tintProminence don't change that, so the bar is drawn here. The knob is
// still AppKit's.
@interface AccentSliderCell : NSSliderCell
@end

@implementation AccentSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
  if (self.numberOfTickMarks > 0 || self.isVertical || self.sliderType != NSSliderTypeLinear) {
    [super drawBarInside:rect flipped:flipped];
    return;
  }
  // The stock macOS 26/27 bar is 6 pt thick (measured from the Sound menu).
  // Its length and center line come from AppKit's bar rect.
  CGFloat thickness = MIN(6, NSHeight(self.controlView.bounds));
  NSRect track = NSMakeRect(NSMinX(rect), NSMidY(rect) - thickness / 2.0, NSWidth(rect), thickness);
  CGFloat radius = thickness / 2.0;
  NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track
                                                            xRadius:radius
                                                            yRadius:radius];
  [NSColor.quaternaryLabelColor setFill];
  [trackPath fill];

  NSRect knob = [self knobRectFlipped:flipped];
  CGFloat end = MAX(NSMinX(track), MIN(NSMidX(knob), NSMaxX(track)));
  NSRect filled = track;
  filled.size.width = end - NSMinX(track);
  if (filled.size.width > 0) {
    NSColor *fill = self.enabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor;
    [NSGraphicsContext saveGraphicsState];
    [trackPath addClip];
    [fill setFill];
    [NSBezierPath fillRect:filled];
    [NSGraphicsContext restoreGraphicsState];
  }

  // A faint light rim, as on the stock bar.
  NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(track, 0.5, 0.5)
                                                      xRadius:radius - 0.5
                                                      yRadius:radius - 0.5];
  rim.lineWidth = 1;
  [[NSColor.whiteColor colorWithAlphaComponent:0.14] setStroke];
  [rim stroke];
}
@end

@interface ReleaseSlider : NSSlider
@end

@implementation ReleaseSlider
+ (Class)cellClass {
  return [AccentSliderCell class];
}

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

// Status menu layout, modelled on the stock Sound menu.
static const CGFloat kMenuWidth = 300;
static const CGFloat kMenuMargin = 14;
static const CGFloat kMenuContentWidth = 272;  // kMenuWidth - 2 * kMenuMargin

// Which menu sections are collapsed, one name per line, kept in the support
// folder next to max, full and brightness.
static NSString *sectionsPath(void) {
  return [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"]
      stringByAppendingPathComponent:@"sections"];
}

static NSMutableSet<NSString *> *readCollapsedSections(void) {
  NSString *text = [NSString stringWithContentsOfFile:sectionsPath()
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    NSString *name =
        [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length > 0) {
      [names addObject:name];
    }
  }
  return names;
}

static void writeCollapsedSections(NSSet<NSString *> *names) {
  NSArray<NSString *> *sorted = [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
  NSString *text = sorted.count == 0
                       ? @""
                       : [[sorted componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
  NSString *path = sectionsPath();
  if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
    fprintf(stderr, "failed to save menu sections\n");
    return;
  }
  chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
}

static BOOL menuMotionAllowed(void) {
  return !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

// A section title that opens and closes on click, with a chevron that turns
// from right to down. Clicks come through a gesture recognizer, as on the old
// Full at row, so the menu stays open.
// A capsule label: the display status pill and the Pro badge.
@interface PillView : NSView
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSColor *color;
@property(nonatomic) BOOL solid;
- (instancetype)initWithText:(NSString *)text color:(NSColor *)color solid:(BOOL)solid;
- (void)setText:(NSString *)text color:(NSColor *)color;
@end

@interface SectionHeader : NSView
@property(nonatomic, strong) NSTextField *title;
@property(nonatomic, strong) NSImageView *chevron;
// Set it through setCollapsed:animated: so the chevron follows.
@property(nonatomic) BOOL collapsed;
@property(nonatomic, copy) void (^toggled)(SectionHeader *header);
- (instancetype)initWithTitle:(NSTextField *)title
                    accessory:(NSView *)accessory
               chevronLeading:(BOOL)leading;
- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated;
@end

@implementation SectionHeader

- (instancetype)initWithTitle:(NSTextField *)title
                    accessory:(NSView *)accessory
               chevronLeading:(BOOL)leading {
  self = [super initWithFrame:NSZeroRect];
  if (self == nil) {
    return nil;
  }
  self.title = title;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  // The chevron sits frame-based in a fixed box so Auto Layout never fights
  // its rotation.
  NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
  box.translatesAutoresizingMaskIntoConstraints = NO;
  [box.widthAnchor constraintEqualToConstant:12].active = YES;
  [box.heightAnchor constraintEqualToConstant:12].active = YES;
  NSImage *image = [NSImage imageWithSystemSymbolName:@"chevron.right"
                             accessibilityDescription:nil];
  NSImageSymbolConfiguration *config =
      [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold];
  image = [image imageWithSymbolConfiguration:config];
  image.template = YES;
  NSImageView *chevron = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 12, 12)];
  chevron.image = image;
  chevron.imageScaling = NSImageScaleProportionallyDown;
  chevron.contentTintColor = NSColor.secondaryLabelColor;
  [box addSubview:chevron];
  self.chevron = chevron;

  NSMutableArray<NSView *> *views = [NSMutableArray array];
  if (leading) {
    [views addObject:box];
  }
  [views addObject:title];
  if (accessory != nil) {
    [views addObject:accessory];
  }
  NSStackView *row = [NSStackView stackViewWithViews:views];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 6;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  if (accessory != nil) {
    [row setCustomSpacing:8 afterView:title];
  }
  [title setContentHuggingPriority:NSLayoutPriorityDefaultLow
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [row.topAnchor constraintEqualToAnchor:self.topAnchor],
    [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [self.widthAnchor constraintEqualToConstant:kMenuContentWidth],
  ]];
  if (leading) {
    [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor].active = YES;
  } else {
    // Trailing chevron, so titles line up on the left and the chevron lines
    // up with the percent labels on the right.
    [self addSubview:box];
    [NSLayoutConstraint activateConstraints:@[
      [row.trailingAnchor constraintLessThanOrEqualToAnchor:box.leadingAnchor constant:-6],
      [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [box.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
  }
  NSClickGestureRecognizer *click =
      [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(clicked:)];
  [self addGestureRecognizer:click];
  [self setCollapsed:NO animated:NO];
  return self;
}

- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated {
  self.collapsed = collapsed;
  CGFloat angle = collapsed ? 0 : -90;
  NSImageView *chevron = self.chevron;
  if (animated && menuMotionAllowed()) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.2;
      chevron.animator.frameCenterRotation = angle;
    }];
  } else {
    chevron.frameCenterRotation = angle;
  }
}

- (void)toggle {
  if (self.hidden) {
    return;
  }
  [self setCollapsed:!self.collapsed animated:YES];
  if (self.toggled != nil) {
    self.toggled(self);
  }
  NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}

- (void)clicked:(id)sender {
  (void)sender;
  [self toggle];
}

- (BOOL)isAccessibilityElement {
  return YES;
}

- (NSAccessibilityRole)accessibilityRole {
  return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
  return [NSString stringWithFormat:@"%@, %@", self.title.stringValue,
                                    self.collapsed ? @"collapsed" : @"expanded"];
}

- (BOOL)isAccessibilityExpanded {
  return !self.collapsed;
}

- (BOOL)accessibilityPerformPress {
  [self toggle];
  return YES;
}
@end

// Thin divider between menu sections, like the stock Battery menu's: one
// faint point, inset to the content margins.
@interface MenuHairline : NSView
@end

@implementation MenuHairline
- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    // separatorColor reads as a dark rule inside a menu. Match the faint,
    // slightly lighter line in the stock Battery menu instead.
    BOOL dark = [self.effectiveAppearance
                    bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                         NSAppearanceNameDarkAqua ]] ==
                NSAppearanceNameDarkAqua;
    NSColor *color = dark ? [NSColor colorWithWhite:1 alpha:0.1]
                          : [NSColor colorWithWhite:0 alpha:0.1];
    self.layer.backgroundColor = color.CGColor;
  }];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}
@end

static NSView *menuHairline(void) {
  MenuHairline *line = [[MenuHairline alloc] initWithFrame:NSZeroRect];
  line.wantsLayer = YES;
  line.translatesAutoresizingMaskIntoConstraints = NO;
  [line.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
  [line.heightAnchor constraintEqualToConstant:1].active = YES;
  return line;
}

static NSStackView *menuSection(NSArray<NSView *> *views, CGFloat spacing) {
  NSStackView *stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = spacing;
  stack.detachesHiddenViews = YES;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  return stack;
}

@interface StatusPanel : NSViewController
@property(nonatomic, strong) NSSlider *nowSlider;
@property(nonatomic, strong) NSSlider *maxSlider;
@property(nonatomic, strong) NSTextField *nowValue;
@property(nonatomic, strong) NSTextField *maxValue;
@property(nonatomic) long savedMax;
@property(nonatomic, strong) RampClock *rampClock;
@property(nonatomic, strong) NSStackView *maxRow;
@property(nonatomic, strong) NSTextField *maxName;
// On the Ramp title when the ramp isn't licensed; clicking it opens Pro.
@property(nonatomic, strong) PillView *rampPro;
@property(nonatomic, strong) SectionHeader *fullRow;
@property(nonatomic, strong) NSTextField *fullTime;
@property(nonatomic) BOOL fullCollapsed;
// Called after any section opens or closes, so the menu can resize.
@property(nonatomic, copy) void (^sectionToggled)(void);
@property(nonatomic, strong) SectionHeader *brightHeader;
@property(nonatomic, strong) NSStackView *brightBody;
@property(nonatomic, strong) NSView *brightSection;
@property(nonatomic, strong) NSView *brightDivider;
@property(nonatomic, strong) SectionHeader *appearanceHeader;
@property(nonatomic, strong) NSStackView *appearanceBody;
@property(nonatomic, strong) NSMutableSet<NSString *> *collapsedSections;
@property(nonatomic, strong) NSView *clockWell;
@property(nonatomic, strong) NSTextField *payLabel;
@property(nonatomic, strong) NSButton *payButton;
@property(nonatomic, strong) NSSegmentedControl *scheduleControl;
@property(nonatomic, strong) NSButton *darkSwitch;
@property(nonatomic, strong) NSButton *toneSwitch;
@property(nonatomic, strong) NSStackView *brightRows;
@property(nonatomic, strong) NSTextField *ddcNote;
@property(nonatomic, strong) NSButton *keyButton;
@property(nonatomic, strong) NSMutableArray<DisplayRow *> *displayRows;
@property(nonatomic) uint32_t trackingDisplay;
- (void)syncSliders;
- (void)syncClock;
- (void)syncDisplay;
- (void)applyAccent;
- (void)applyRampAccess;
- (void)previewMax:(long)value;
- (void)previewNow:(long)value;
- (int)clockMinute;
@end

static BOOL gSettingsKeepsOpenForOtherApp = NO;

static void openBrightnessKeyAccess(void) {
  for (NSWindow *window in NSApp.windows) {
    if (window.isVisible && [window.identifier isEqualToString:@"NightshiftSettings"]) {
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
  [button.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
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
  [row.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
  [row.heightAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
  return row;
}

// Section title, like "Sound" in the stock Sound menu.
- (NSTextField *)sectionLabel:(NSString *)title {
  NSTextField *label = [NSTextField labelWithString:title];
  label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
  label.textColor = NSColor.labelColor;
  return label;
}

// Secondary heading inside a section, like "Output" in the Sound menu.
- (NSTextField *)subsectionLabel:(NSString *)title {
  NSTextField *label = [NSTextField labelWithString:title];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
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
  tintSlider(self.nowSlider);
  tintSlider(self.maxSlider);
  self.nowSlider.accessibilityLabel = @"Current";
  self.maxSlider.accessibilityLabel = @"Max";
  self.nowValue = [self valueLabel];
  self.maxValue = [self valueLabel];

  self.rampClock = [[RampClock alloc] initWithFrame:NSZeroRect];
  self.rampClock.accessibilityLabel = @"Full at";

  __weak StatusPanel *panel = self;
  NSTextField *fullTitle = [self subsectionLabel:@"Full at"];
  NSTextField *fullTime = [NSTextField labelWithString:@""];
  fullTime.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                   weight:NSFontWeightRegular];
  fullTime.textColor = NSColor.secondaryLabelColor;
  [fullTime setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.fullTime = fullTime;
  SectionHeader *fullRow = [[SectionHeader alloc] initWithTitle:fullTitle
                                                       accessory:fullTime
                                                  chevronLeading:YES];
  fullRow.toggled = ^(SectionHeader *header) {
    [panel sectionHeaderToggled:header];
  };
  self.fullRow = fullRow;
  NSTextField *pay = [NSTextField wrappingLabelWithString:@""];
  pay.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  pay.textColor = NSColor.secondaryLabelColor;
  pay.preferredMaxLayoutWidth = kMenuContentWidth;
  pay.hidden = YES;
  self.payLabel = pay;
  NSButton *buy = [NSButton buttonWithTitle:@"Renew the ramp"
                                     target:nil
                                     action:NULL];
  buy.bezelStyle = NSBezelStyleRounded;
  buy.hidden = YES;
  self.payButton = buy;

  self.rampClock.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *clockWell = [[NSView alloc] initWithFrame:NSZeroRect];
  self.clockWell = clockWell;
  [clockWell.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
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
  NSTextField *maxName = nil;
  NSStackView *maxRow = [self sliderRowTitled:@"Max"
                                       slider:self.maxSlider
                                        value:self.maxValue
                                    nameWidth:62
                                         name:&maxName];
  self.maxRow = maxRow;
  self.maxName = maxName;

  NSSegmentedControl *schedule = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"Off", @"Custom", @"Sunset to Sunrise" ]
                    trackingMode:NSSegmentSwitchTrackingSelectOne
                          target:nil
                          action:NULL];
  schedule.segmentDistribution = NSSegmentDistributionFillProportionally;
  schedule.controlSize = NSControlSizeSmall;
  schedule.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  schedule.accessibilityLabel = @"Night Shift schedule";
  schedule.selectedSegmentBezelColor = NSColor.controlAccentColor;
  [schedule.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
  self.scheduleControl = schedule;

  self.darkSwitch = [self appearanceButton];
  self.toneSwitch = [self appearanceButton];
  NSStackView *brightRows = [[NSStackView alloc] initWithFrame:NSZeroRect];
  brightRows.orientation = NSUserInterfaceLayoutOrientationVertical;
  brightRows.alignment = NSLayoutAttributeLeading;
  brightRows.spacing = 12;
  [brightRows.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
  self.brightRows = brightRows;
  self.displayRows = [NSMutableArray array];
  NSTextField *ddcNote = [NSTextField
      wrappingLabelWithString:@"Turn on DDC/CI in the monitor menu to change the backlight."];
  ddcNote.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  ddcNote.textColor = NSColor.secondaryLabelColor;
  ddcNote.preferredMaxLayoutWidth = kMenuContentWidth;
  [ddcNote.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
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

  // Spacing: 10 between rows and under each title, 12 above and below each
  // divider, 14 side margins, as in the stock Sound menu.
  NSTextField *nightTitle = [self sectionLabel:@"Night Shift Intensity"];
  NSStackView *nightSection = menuSection(@[ nightTitle, nowRow, schedule ], 10);
  [nightSection setCustomSpacing:14 afterView:nowRow];

  // Max and Full at are the Pro ramp, so they share one section with one
  // PRO badge. Without Pro they show grayed out and the badge opens Pro.
  PillView *rampPro = [[PillView alloc] initWithText:@"PRO"
                                              color:NSColor.controlAccentColor
                                              solid:YES];
  rampPro.toolTip = @"Unlock the ramp with Pro";
  rampPro.hidden = YES;
  [rampPro addGestureRecognizer:[[NSClickGestureRecognizer alloc]
                                    initWithTarget:self
                                            action:@selector(rampProClicked:)]];
  self.rampPro = rampPro;
  NSStackView *rampTitle =
      [NSStackView stackViewWithViews:@[ [self sectionLabel:@"Ramp"], rampPro ]];
  rampTitle.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  rampTitle.alignment = NSLayoutAttributeCenterY;
  rampTitle.spacing = 8;
  NSStackView *rampSection =
      menuSection(@[ rampTitle, pay, maxRow, buy, fullRow, clockWell ], 10);
  [rampSection setCustomSpacing:14 afterView:maxRow];
  [rampSection setCustomSpacing:14 afterView:buy];
  [rampSection setCustomSpacing:6 afterView:fullRow];

  self.collapsedSections = readCollapsedSections();
  SectionHeader *brightHeader =
      [[SectionHeader alloc] initWithTitle:[self sectionLabel:@"Brightness"]
                                 accessory:nil
                            chevronLeading:NO];
  brightHeader.toggled = ^(SectionHeader *header) {
    [panel sectionHeaderToggled:header];
  };
  self.brightHeader = brightHeader;
  NSStackView *brightBody = menuSection(@[ brightRows, ddcNote, keyButton ], 10);
  self.brightBody = brightBody;
  NSStackView *brightSection = menuSection(@[ brightHeader, brightBody ], 10);
  self.brightSection = brightSection;

  SectionHeader *appearanceHeader =
      [[SectionHeader alloc] initWithTitle:[self sectionLabel:@"Appearance"]
                                 accessory:nil
                            chevronLeading:NO];
  appearanceHeader.toggled = ^(SectionHeader *header) {
    [panel sectionHeaderToggled:header];
  };
  self.appearanceHeader = appearanceHeader;
  NSStackView *appearanceBody = menuSection(@[ self.darkSwitch, self.toneSwitch ], 8);
  self.appearanceBody = appearanceBody;
  NSStackView *appearanceSection = menuSection(@[ appearanceHeader, appearanceBody ], 10);

  BOOL brightClosed = [self.collapsedSections containsObject:@"brightness"];
  BOOL appearanceClosed = [self.collapsedSections containsObject:@"appearance"];
  [brightHeader setCollapsed:brightClosed animated:NO];
  brightBody.hidden = brightClosed;
  [appearanceHeader setCollapsed:appearanceClosed animated:NO];
  appearanceBody.hidden = appearanceClosed;

  NSView *brightDivider = menuHairline();
  self.brightDivider = brightDivider;
  NSStackView *stack = [NSStackView stackViewWithViews:@[
    nightSection, menuHairline(), rampSection, brightDivider, brightSection, menuHairline(),
    appearanceSection
  ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 12;
  stack.edgeInsets = NSEdgeInsetsMake(12, kMenuMargin, 8, kMenuMargin);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  stack.detachesHiddenViews = YES;

  NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kMenuWidth, 280)];
  [root addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [root.widthAnchor constraintEqualToConstant:kMenuWidth],
  ]];
  self.view = root;
}

// The accent or highlight color changed in System Settings. Dynamic colors
// resolve again at draw time, so re-set them and redraw.
- (void)applyAccent {
  tintSlider(self.nowSlider);
  tintSlider(self.maxSlider);
  for (DisplayRow *row in self.displayRows) {
    tintSlider(row.slider);
  }
  self.scheduleControl.selectedSegmentBezelColor = NSColor.controlAccentColor;
  self.scheduleControl.needsDisplay = YES;
  self.rampClock.needsDisplay = YES;
  [self syncDisplay];
}

- (void)applyRampAccess {
  BOOL paid = rampLicensed();
  BOOL soon = rampLicenseRenewingSoon();
  NSString *until = rampLicenseUntil();
  self.rampPro.hidden = paid;
  self.maxSlider.enabled = paid;
  self.maxSlider.alphaValue = paid ? 1 : 0.4;
  self.maxName.textColor = paid ? NSColor.labelColor : NSColor.tertiaryLabelColor;
  self.maxValue.textColor = paid ? NSColor.labelColor : NSColor.tertiaryLabelColor;
  self.fullRow.title.textColor = paid ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
  self.fullTime.textColor = paid ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
  self.clockWell.hidden = self.fullCollapsed;
  [self syncClock];
  [self styleFullHeader];
  self.payLabel.hidden = until == nil;
  self.payLabel.stringValue =
      until == nil ? @"" : [NSString stringWithFormat:@"Ramp through %@", until];
  self.payButton.hidden = !(paid && soon);
}

- (void)rampProClicked:(id)sender {
  [NSApp sendAction:self.payButton.action to:self.payButton.target from:self.payButton];
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
    tintSlider(slider);
    slider.enabled = readable && writable;
    slider.tag = (NSInteger)ids[i];
    NSString *title = displayTitle(ids[i]);
    slider.accessibilityLabel = title;
    NSTextField *value = [self valueLabel];
    NSTextField *name = [NSTextField labelWithString:title];
    name.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.maximumNumberOfLines = 1;
    [name.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
    NSStackView *controls = [NSStackView stackViewWithViews:@[ slider, value ]];
    controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controls.spacing = 8;
    [controls setCustomSpacing:4 afterView:slider];
    controls.alignment = NSLayoutAttributeCenterY;
    [controls.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
    [controls.heightAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[ name, controls ]];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 4;
    [row.widthAnchor constraintEqualToConstant:kMenuContentWidth].active = YES;
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
  self.brightSection.hidden = count == 0;
  self.brightDivider.hidden = count == 0;
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
  if (self.fullRow.collapsed != self.fullCollapsed) {
    [self.fullRow setCollapsed:self.fullCollapsed animated:NO];
  }
}

- (void)revealBody:(NSView *)body {
  body.hidden = NO;
  if (!menuMotionAllowed()) {
    body.alphaValue = 1;
    return;
  }
  body.alphaValue = 0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = 0.18;
    body.animator.alphaValue = 1;
  }];
}

- (void)sectionHeaderToggled:(SectionHeader *)header {
  if (header == self.fullRow) {
    self.fullCollapsed = header.collapsed;
    self.clockWell.hidden = self.fullCollapsed;
  } else {
    BOOL bright = header == self.brightHeader;
    NSString *name = bright ? @"brightness" : @"appearance";
    NSView *body = bright ? self.brightBody : self.appearanceBody;
    if (header.collapsed) {
      body.hidden = YES;
      [self.collapsedSections addObject:name];
    } else {
      [self revealBody:body];
      [self.collapsedSections removeObject:name];
    }
    writeCollapsedSections(self.collapsedSections);
  }
  if (self.sectionToggled != nil) {
    self.sectionToggled();
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
  BOOL on = customSchedule() && rampLicensed();
  self.rampClock.enabled = on;
  self.rampClock.alphaValue = on ? 1 : 0.4;
}

- (int)clockMinute {
  return [self.rampClock clockMinute];
}
@end

// MARK: - Settings window

// Menu bar choices, one "key value" per line in the support folder file
// menubar, next to max, full, clock and sections:
//   icon horizon
//   warmth on
static NSString *menuBarPrefsPath(void) {
  return [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"]
      stringByAppendingPathComponent:@"menubar"];
}

static NSMutableDictionary<NSString *, NSString *> *gMenuBarPrefs = nil;

static NSMutableDictionary<NSString *, NSString *> *menuBarPrefs(void) {
  if (gMenuBarPrefs != nil) {
    return gMenuBarPrefs;
  }
  gMenuBarPrefs = [NSMutableDictionary dictionary];
  NSString *text = [NSString stringWithContentsOfFile:menuBarPrefsPath()
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  NSCharacterSet *blank = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:blank];
    NSRange space = [trimmed rangeOfString:@" "];
    if (space.location == NSNotFound || space.location == 0) {
      continue;
    }
    NSString *key = [trimmed substringToIndex:space.location];
    NSString *value =
        [[trimmed substringFromIndex:space.location + 1] stringByTrimmingCharactersInSet:blank];
    if (value.length > 0) {
      gMenuBarPrefs[key] = value;
    }
  }
  return gMenuBarPrefs;
}

static BOOL setMenuBarPref(NSString *key, NSString *value) {
  NSMutableDictionary<NSString *, NSString *> *prefs = menuBarPrefs();
  NSString *old = prefs[key];
  prefs[key] = value;
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [prefs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@ %@\n", name, prefs[name]];
  }
  NSString *path = menuBarPrefsPath();
  if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
    if (old != nil) {
      prefs[key] = old;
    } else {
      [prefs removeObjectForKey:key];
    }
    fprintf(stderr, "failed to save menu bar settings\n");
    return NO;
  }
  chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
  return YES;
}

static BOOL menuBarShowsWarmth(void) {
  return [menuBarPrefs()[@"warmth"] isEqualToString:@"on"];
}

static BOOL appearanceIsDark(NSAppearance *appearance) {
  NSAppearanceName match = [appearance
      bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  return [match isEqualToString:NSAppearanceNameDarkAqua];
}

// One icon the user can pick in Settings › General.
//
// Art drops in as bundle resources in Contents/Resources (phase 2):
//   icon-<ident>.pdf (or .png)        the app icon tile, the full art with its
//                                     transparent margin
//   icon-<ident>-glyph.pdf (or .png)  the menu bar template glyph, black on
//                                     clear, 1 unit = 1 pt
// The design files are SVG (settings-mock/icons/<name>.svg and
// <name>-glyph.svg); convert them on the Mac before bundling, for example
// `rsvg-convert -f pdf -o icon-lamp-glyph.pdf lamp-glyph.svg`, and copy them
// into Nightshift.app/Contents/Resources from the Makefile.
// A choice with menuSymbol set shows that SF Symbol in the menu bar instead of
// a bundled glyph: Horizon and Mono use sun.horizon, Thermometer uses
// thermometer.medium. SF Symbols are fine in UI but not in app icons, so the
// tile drawn here without bundled art is only a placeholder.
@interface IconChoice : NSObject
@property(nonatomic, copy) NSString *ident;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *menuSymbol;
@property(nonatomic, copy) NSArray<NSColor *> *placeholderColors;
+ (NSArray<IconChoice *> *)all;
+ (IconChoice *)standard;
+ (IconChoice *)current;
- (NSImage *)tileImageOfSize:(CGFloat)size;
- (NSImage *)menuImage;
@end

@implementation IconChoice
+ (IconChoice *)choice:(NSString *)ident
                  name:(NSString *)name
                symbol:(NSString *)symbol
                colors:(NSArray<NSColor *> *)colors {
  IconChoice *choice = [[IconChoice alloc] init];
  choice.ident = ident;
  choice.name = name;
  choice.menuSymbol = symbol;
  choice.placeholderColors = colors;
  return choice;
}

+ (NSArray<IconChoice *> *)all {
  static NSArray<IconChoice *> *choices = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSColor *indigo = [NSColor colorWithSRGBRed:0.16 green:0.17 blue:0.42 alpha:1];
    NSColor *violet = [NSColor colorWithSRGBRed:0.49 green:0.25 blue:0.53 alpha:1];
    NSColor *amber = [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.34 alpha:1];
    // Phase 1 offers Horizon only. Phase 2 adds, in this order, once their
    // resources are bundled: Mono (symbol sun.horizon), Thermometer (symbol
    // thermometer.medium), Dusk Moon, Warm Dial and Lamp (bundled glyphs,
    // symbol nil).
    choices = @[
      [IconChoice choice:@"horizon"
                    name:@"Horizon"
                  symbol:@"sun.horizon"
                  colors:@[ indigo, violet, amber ]],
    ];
  });
  return choices;
}

+ (IconChoice *)standard {
  return [IconChoice all].firstObject;
}

+ (IconChoice *)current {
  NSString *saved = menuBarPrefs()[@"icon"];
  for (IconChoice *choice in [IconChoice all]) {
    if ([choice.ident isEqualToString:saved]) {
      return choice;
    }
  }
  return [IconChoice standard];
}

+ (NSImage *)bundled:(NSString *)name {
  for (NSString *type in @[ @"pdf", @"png" ]) {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:type];
    NSImage *image = path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
    if (image != nil) {
      return image;
    }
  }
  return nil;
}

- (NSImage *)tileImageOfSize:(CGFloat)size {
  NSImage *art = [IconChoice bundled:[@"icon-" stringByAppendingString:self.ident]];
  if (art != nil) {
    art = [art copy];
    art.size = NSMakeSize(size, size);
    return art;
  }
  NSArray<NSColor *> *colors = self.placeholderColors;
  NSString *symbolName = self.menuSymbol;
  return [NSImage imageWithSize:NSMakeSize(size, size)
                        flipped:NO
                 drawingHandler:^BOOL(NSRect rect) {
                   // The art files keep about a tenth of margin, so the
                   // placeholder does too.
                   NSRect tileRect = NSInsetRect(rect, NSWidth(rect) * 0.1, NSWidth(rect) * 0.1);
                   CGFloat radius = NSWidth(tileRect) * 0.225;
                   NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:tileRect
                                                                        xRadius:radius
                                                                        yRadius:radius];
                   NSGradient *gradient = [[NSGradient alloc] initWithColors:colors];
                   [gradient drawInBezierPath:tile angle:-90];
                   if (symbolName == nil) {
                     return YES;
                   }
                   NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration
                       configurationWithPointSize:NSWidth(tileRect) * 0.36
                                           weight:NSFontWeightSemibold]
                       configurationByApplyingConfiguration:
                           [NSImageSymbolConfiguration
                               configurationWithPaletteColors:@[ NSColor.whiteColor ]]];
                   NSImage *symbol = [[NSImage imageWithSystemSymbolName:symbolName
                                                 accessibilityDescription:nil]
                       imageWithSymbolConfiguration:config];
                   if (symbol == nil) {
                     return YES;
                   }
                   NSSize s = symbol.size;
                   NSRect target = NSMakeRect(NSMidX(tileRect) - s.width / 2,
                                              NSMidY(tileRect) - s.height / 2, s.width, s.height);
                   [symbol drawInRect:target
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1];
                   return YES;
                 }];
}

- (NSImage *)menuImage {
  NSImage *image = nil;
  if (self.menuSymbol != nil) {
    NSImageSymbolConfiguration *symbol =
        [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular];
    image = [[NSImage imageWithSystemSymbolName:self.menuSymbol
                       accessibilityDescription:@"Nightshift"]
        imageWithSymbolConfiguration:symbol];
  } else {
    image = [IconChoice bundled:[NSString stringWithFormat:@"icon-%@-glyph", self.ident]];
    image.accessibilityDescription = @"Nightshift";
  }
  image.template = YES;
  return image;
}
@end

// Settings layout, modelled on System Settings.
static const CGFloat kSettingsWidth = 720;
static const CGFloat kSettingsHeight = 540;
static const CGFloat kSettingsSidebarWidth = 200;
static const CGFloat kFormWidth = 480;  // content pane 520 less 20 a side
static const CGFloat kFormInset = 10;        // row content inset, left and right
static const CGFloat kRowInsetV = 10;        // row content inset, top and bottom
static const CGFloat kRowMinHeight = 44;     // a one-line row; two-line rows grow
static const CGFloat kRowGap = 12;           // text to control in a row
static const CGFloat kSectionGap = 20;       // above each section
static const CGFloat kSectionHeaderGap = 8;  // section title to its box
static const CGFloat kSectionFooterGap = 6;  // box to its footer
static const CGFloat kSidebarSearchTop = 52; // window top to the search field
static const CGFloat kSidebarListGap = 16;   // search field to the first row
static const CGFloat kSidebarRowHeight = 28; // plus 4 spacing: a 32 pt pitch
static const CGFloat kSidebarIconSize = 20;

enum {
  kPaneGeneral = 0,
  kPaneNightShift,
  kPaneDisplays,
  kPaneLicense,
  kPaneAbout,
  kPaneCount,
};

static NSString *const kSettingsWindowID = @"NightshiftSettings";

// The rounded inset box behind a group of rows.
@interface FormGroupView : NSView
@end

@implementation FormGroupView
- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  BOOL dark = appearanceIsDark(self.effectiveAppearance);
  CGFloat scale = self.window != nil ? self.window.backingScaleFactor : 2;
  self.layer.cornerRadius = 10;
  self.layer.borderWidth = 1.0 / MAX(scale, 1);
  self.layer.backgroundColor =
      (dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:0 alpha:0.035])
          .CGColor;
  self.layer.borderColor =
      (dark ? [NSColor colorWithWhite:1 alpha:0.08] : [NSColor colorWithWhite:0 alpha:0.07])
          .CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}
@end

@implementation PillView
- (instancetype)initWithText:(NSString *)text color:(NSColor *)color solid:(BOOL)solid {
  self = [super initWithFrame:NSZeroRect];
  if (self == nil) {
    return nil;
  }
  self.wantsLayer = YES;
  self.solid = solid;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  self.label = [NSTextField labelWithString:text];
  self.label.font = [NSFont systemFontOfSize:solid ? 9.5 : 11 weight:NSFontWeightBold];
  self.label.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:self.label];
  CGFloat pad = solid ? 5 : 8;
  [NSLayoutConstraint activateConstraints:@[
    [self.label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:pad],
    [self.label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-pad],
    [self.label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [self.heightAnchor constraintEqualToConstant:solid ? 15 : 20],
  ]];
  [self setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self setText:text color:color];
  return self;
}

- (void)setText:(NSString *)text color:(NSColor *)color {
  self.label.stringValue = text;
  self.color = color;
  self.label.textColor = self.solid ? NSColor.whiteColor : color;
  self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    NSColor *fill = self.solid ? self.color : [self.color colorWithAlphaComponent:0.16];
    self.layer.backgroundColor = fill.CGColor;
  }];
  self.layer.cornerRadius = NSHeight(self.bounds) / 2;
}

- (void)layout {
  [super layout];
  self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}
@end

// A small status dot, as in "● Allowed".
@interface DotView : NSView
@property(nonatomic, strong) NSColor *color;
@end

@implementation DotView
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [(self.color != nil ? self.color : NSColor.secondaryLabelColor) setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 0.5, 0.5)] fill];
}
@end

// A row in a group: title and optional caption on the left, control on the
// right.
@interface FormRow : NSView
@property(nonatomic, strong) NSTextField *titleField;
@property(nonatomic, strong) NSTextField *captionField;
@end

@implementation FormRow
@end

// A wrapping caption that wraps at the width it is laid out at, so it never
// clips when its row's control turns out wider or narrower than estimated.
@interface FormCaption : NSTextField
@end

@implementation FormCaption
- (void)layout {
  [super layout];
  CGFloat width = NSWidth(self.bounds);
  if (width > 1 && fabs(self.preferredMaxLayoutWidth - width) > 0.5) {
    self.preferredMaxLayoutWidth = width;
    [self invalidateIntrinsicContentSize];
  }
}
@end

// One choice in the icon picker: the tile, its name under it, and an accent
// ring around the chosen one.
@interface IconTile : NSView
@property(nonatomic, strong) IconChoice *choice;
@property(nonatomic, strong) NSImageView *imageView;
@property(nonatomic, strong) NSTextField *nameField;
@property(nonatomic) BOOL selected;
@property(nonatomic, copy) void (^picked)(IconTile *tile);
- (instancetype)initWithChoice:(IconChoice *)choice;
@end

// The image includes the art's margin; the visible tile is 80% of it.
static const CGFloat kIconTileImage = 60;

@implementation IconTile
- (instancetype)initWithChoice:(IconChoice *)choice {
  self = [super initWithFrame:NSZeroRect];
  if (self == nil) {
    return nil;
  }
  self.choice = choice;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  self.imageView = [NSImageView imageViewWithImage:[choice tileImageOfSize:kIconTileImage]];
  self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
  self.nameField = [NSTextField labelWithString:choice.name];
  self.nameField.font = [NSFont systemFontOfSize:11];
  self.nameField.alignment = NSTextAlignmentCenter;
  self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:self.imageView];
  [self addSubview:self.nameField];
  [NSLayoutConstraint activateConstraints:@[
    [self.widthAnchor constraintEqualToConstant:72],
    [self.imageView.topAnchor constraintEqualToAnchor:self.topAnchor],
    [self.imageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [self.imageView.widthAnchor constraintEqualToConstant:kIconTileImage],
    [self.imageView.heightAnchor constraintEqualToConstant:kIconTileImage],
    [self.nameField.topAnchor constraintEqualToAnchor:self.imageView.bottomAnchor constant:1],
    [self.nameField.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [self.nameField.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor],
    [self.nameField.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];
  return self;
}

- (void)setSelected:(BOOL)selected {
  _selected = selected;
  self.nameField.font =
      [NSFont systemFontOfSize:11 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
  self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  if (!self.selected) {
    return;
  }
  NSRect frame = self.imageView.frame;
  NSRect tile = NSInsetRect(frame, NSWidth(frame) * 0.1, NSWidth(frame) * 0.1);
  NSRect ring = NSInsetRect(tile, -3.5, -3.5);
  CGFloat radius = NSWidth(tile) * 0.225 + 3.5;
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:ring xRadius:radius yRadius:radius];
  path.lineWidth = 3;
  [NSColor.controlAccentColor setStroke];
  [path stroke];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  (void)event;
  if (self.picked != nil) {
    self.picked(self);
  }
}

- (BOOL)isAccessibilityElement {
  return YES;
}

- (NSAccessibilityRole)accessibilityRole {
  return NSAccessibilityRadioButtonRole;
}

- (NSString *)accessibilityLabel {
  return self.choice.name;
}

- (id)accessibilityValue {
  return @(self.selected ? 1 : 0);
}

- (BOOL)accessibilityPerformPress {
  if (self.picked != nil) {
    self.picked(self);
  }
  return YES;
}
@end

@interface SettingsFlippedView : NSView
@end

@implementation SettingsFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

@interface SettingsPanel
    : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *sidebarTable;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSArray<NSNumber *> *visiblePanes;
@property(nonatomic, strong) NSMutableArray<NSView *> *pages;
@property(nonatomic, strong) NSMutableArray<NSMutableArray<NSString *> *> *paneWords;
@property(nonatomic) NSInteger buildingPane;
@property(nonatomic) BOOL selectingRow;
// General
@property(nonatomic, strong) NSSwitch *loginSwitch;
@property(nonatomic, strong) NSSwitch *cycleSwitch;
@property(nonatomic, strong) NSSwitch *warmthSwitch;
@property(nonatomic, strong) NSMutableArray<IconTile *> *iconTiles;
@property(nonatomic, copy) void (^iconPicked)(IconChoice *choice);
// Night Shift
@property(nonatomic, strong) NSPopUpButton *schedulePopup;
@property(nonatomic, strong) NSTextField *timesLabel;
@property(nonatomic, strong) NSSlider *maxSlider;
@property(nonatomic, strong) NSTextField *maxValue;
@property(nonatomic, strong) FormRow *maxRow;
@property(nonatomic, strong) NSDatePicker *fullAtPicker;
@property(nonatomic, strong) FormRow *fullAtRow;
@property(nonatomic, strong) NSButton *unlockButton;
@property(nonatomic) BOOL editingFullAt;
// Displays
@property(nonatomic, strong) NSStackView *displaysStack;
@property(nonatomic, strong) NSMutableArray<NSView *> *displaySections;
@property(nonatomic, strong) NSMutableArray<DisplayRow *> *displayRows;
@property(nonatomic, copy) NSString *displaySignature;
@property(nonatomic) uint32_t trackingDisplay;
@property(nonatomic, weak) id brightnessTarget;
@property(nonatomic) SEL brightnessAction;
@property(nonatomic, strong) DotView *keysDot;
@property(nonatomic, strong) NSTextField *keysStatus;
@property(nonatomic, strong) NSButton *keysButton;
// License
@property(nonatomic, strong) DotView *licenseDot;
@property(nonatomic, strong) NSTextField *licenseStatus;
@property(nonatomic, strong) NSView *buySection;
@property(nonatomic, strong) NSButton *buyButton;
@property(nonatomic, strong) NSTextField *installIDLabel;
@property(nonatomic, strong) NSButton *installIDCopyButton;
@property(nonatomic) BOOL paid;
@property(nonatomic) BOOL soon;
@property(nonatomic, copy) NSString *until;
@property(nonatomic) BOOL buying;
// Window
@property(nonatomic, copy) void (^becameKey)(void);
@property(nonatomic, copy) void (^needsSync)(void);
@property(nonatomic, strong) NSTimer *syncTimer;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL stayOpen;
@property(nonatomic, strong) id outsideMonitor;
@property(nonatomic, strong) id localOutsideMonitor;
- (void)showPage:(NSInteger)index;
- (void)syncPaid:(BOOL)paid soon:(BOOL)soon until:(NSString *)until buying:(BOOL)buying;
- (void)paintSidebar;
- (void)showMaxValue:(long)value;
- (void)showBrightness:(long)percent forDisplay:(uint32_t)display;
- (int)fullAtMinute;
@end

// The top menu bar while Settings is open. There is deliberately no Quit
// here: quitting the daemon would drop brightness and warmth.
static void installSettingsMenu(void) {
  if (NSApp.mainMenu != nil) {
    return;
  }
  NSMenu *bar = [[NSMenu alloc] init];

  NSMenuItem *appItem = [[NSMenuItem alloc] init];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Nightshift"];
  [appMenu addItemWithTitle:@"Close Nightshift Settings"
                     action:@selector(performClose:)
              keyEquivalent:@""];
  appItem.submenu = appMenu;
  [bar addItem:appItem];

  NSMenuItem *editItem = [[NSMenuItem alloc] init];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  NSMenuItem *redo = [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
  redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = edit;
  [bar addItem:editItem];

  NSMenuItem *windowItem = [[NSMenuItem alloc] init];
  NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
  [window addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
  [window addItemWithTitle:@"Minimize"
                    action:@selector(performMiniaturize:)
             keyEquivalent:@"m"];
  windowItem.submenu = window;
  [bar addItem:windowItem];
  NSApp.windowsMenu = window;

  NSApp.mainMenu = bar;
}

// Stack views and some controls (date pickers) stretch by default; a row's
// control group hugs its controls so it sits flush right, and never clips
// them: the caption beside it wraps instead.
static void hugControls(NSView *view) {
  if ([view isKindOfClass:[NSStackView class]]) {
    NSStackView *stack = (NSStackView *)view;
    // Across a vertical stack, required hugging would pull every view to the
    // same width, so there it only has to beat the text column beside it.
    BOOL across = stack.orientation == NSUserInterfaceLayoutOrientationVertical;
    [stack setHuggingPriority:across ? NSLayoutPriorityDefaultHigh - 1 : NSLayoutPriorityRequired
               forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *part in stack.arrangedSubviews) {
      hugControls(part);
    }
  } else if (view != nil) {
    [view setContentHuggingPriority:NSLayoutPriorityRequired
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [view setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  }
}

@implementation SettingsPanel

// MARK: Form helpers

// Words the sidebar search matches for the pane being built.
- (void)addWords:(NSString *)text {
  if (text.length > 0 && self.buildingPane >= 0 && self.buildingPane < kPaneCount) {
    [self.paneWords[(NSUInteger)self.buildingPane] addObject:text];
  }
}

- (NSTextField *)captionLabel:(NSString *)text width:(CGFloat)width {
  NSTextField *label = [FormCaption wrappingLabelWithString:text];
  label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  label.textColor = NSColor.secondaryLabelColor;
  label.preferredMaxLayoutWidth = width;
  label.selectable = NO;
  // Give way to the control; the caption rewraps at whatever width is left.
  [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  return label;
}

// A row: title and optional caption on the left, the control on the right.
// Pass caption @"" for a caption that is filled in later.
- (FormRow *)row:(NSString *)title caption:(NSString *)caption control:(NSView *)control {
  return [self row:title caption:caption control:control below:NO];
}

// With below, the control gets its own line under the title and caption, for
// controls too wide to sit beside a caption.
- (FormRow *)row:(NSString *)title
         caption:(NSString *)caption
         control:(NSView *)control
           below:(BOOL)below {
  [self addWords:title];
  [self addWords:caption];
  FormRow *row = [[FormRow alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  hugControls(control);
  CGFloat controlWidth = control == nil || below ? 0 : control.fittingSize.width + kRowGap;
  NSMutableArray<NSView *> *texts = [NSMutableArray array];
  if (title.length > 0) {
    row.titleField = [NSTextField labelWithString:title];
    row.titleField.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    row.titleField.textColor = NSColor.labelColor;
    row.titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    [row.titleField
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [texts addObject:row.titleField];
  }
  if (caption != nil) {
    row.captionField =
        [self captionLabel:caption width:kFormWidth - 2 * kFormInset - controlWidth];
    [texts addObject:row.captionField];
  }
  NSStackView *text = [NSStackView stackViewWithViews:texts];
  text.orientation = NSUserInterfaceLayoutOrientationVertical;
  text.alignment = NSLayoutAttributeLeading;
  text.spacing = 2;
  text.detachesHiddenViews = YES;
  [text setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  if (row.captionField != nil) {
    // The caption spans the text column, which takes whatever the control
    // leaves, and wraps at that width (see FormCaption).
    [row.captionField.widthAnchor constraintEqualToAnchor:text.widthAnchor].active = YES;
  }
  if (below) {
    [text.widthAnchor constraintEqualToConstant:kFormWidth - 2 * kFormInset].active = YES;
  }
  NSMutableArray<NSView *> *parts = [NSMutableArray arrayWithObject:text];
  if (control != nil) {
    [control setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [control setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    if ([control isKindOfClass:[NSControl class]] && title.length > 0 &&
        control.accessibilityLabel.length == 0) {
      control.accessibilityLabel = title;
    }
    [parts addObject:control];
  }
  NSStackView *line = [NSStackView stackViewWithViews:parts];
  line.orientation = below ? NSUserInterfaceLayoutOrientationVertical
                           : NSUserInterfaceLayoutOrientationHorizontal;
  line.alignment = below ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
  line.spacing = below ? 8 : kRowGap;
  line.distribution = NSStackViewDistributionFill;
  line.edgeInsets = NSEdgeInsetsMake(kRowInsetV, kFormInset, kRowInsetV, kFormInset);
  line.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:line];
  [NSLayoutConstraint activateConstraints:@[
    [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [line.topAnchor constraintEqualToAnchor:row.topAnchor],
    [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    [row.widthAnchor constraintEqualToConstant:kFormWidth],
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:kRowMinHeight],
  ]];
  if (below && control != nil) {
    [control.widthAnchor constraintLessThanOrEqualToConstant:kFormWidth - 2 * kFormInset]
        .active = YES;
  }
  return row;
}

// The hairline between rows, inset to the row text, one device pixel.
- (NSView *)hairline {
  MenuHairline *line = [[MenuHairline alloc] initWithFrame:NSZeroRect];
  line.wantsLayer = YES;
  line.translatesAutoresizingMaskIntoConstraints = NO;
  CGFloat scale = NSScreen.mainScreen != nil ? NSScreen.mainScreen.backingScaleFactor : 2;
  [line.widthAnchor constraintEqualToConstant:kFormWidth - 2 * kFormInset].active = YES;
  [line.heightAnchor constraintEqualToConstant:1.0 / MAX(scale, 1)].active = YES;
  return line;
}

- (NSView *)groupWithViews:(NSArray<NSView *> *)views {
  NSMutableArray<NSView *> *parts = [NSMutableArray array];
  for (NSView *view in views) {
    if (parts.count > 0) {
      [parts addObject:[self hairline]];
    }
    [parts addObject:view];
  }
  NSStackView *stack = [NSStackView stackViewWithViews:parts];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeCenterX;
  stack.spacing = 0;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  FormGroupView *group = [[FormGroupView alloc] initWithFrame:NSZeroRect];
  group.wantsLayer = YES;
  group.translatesAutoresizingMaskIntoConstraints = NO;
  [group addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:group.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:group.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:group.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:group.bottomAnchor],
    [group.widthAnchor constraintEqualToConstant:kFormWidth],
  ]];
  return group;
}

// A section: a semibold header, the rounded group, an optional footer.
- (NSView *)section:(NSString *)header
          accessory:(NSView *)accessory
               rows:(NSArray<NSView *> *)rows
             footer:(NSString *)footer {
  NSMutableArray<NSView *> *parts = [NSMutableArray array];
  if (header.length > 0) {
    [self addWords:header];
    NSTextField *title = [NSTextField labelWithString:header];
    title.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    title.textColor = NSColor.labelColor;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableArray<NSView *> *headParts = [NSMutableArray arrayWithObject:title];
    if (accessory != nil) {
      [headParts addObject:accessory];
    }
    NSStackView *head = [NSStackView stackViewWithViews:headParts];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    head.spacing = 6;
    head.edgeInsets = NSEdgeInsetsMake(0, kFormInset, 0, 0);
    [parts addObject:head];
  }
  NSView *group = [self groupWithViews:rows];
  [parts addObject:group];
  if (footer.length > 0) {
    [self addWords:footer];
    NSTextField *foot = [self captionLabel:footer width:kFormWidth - 2 * kFormInset];
    NSStackView *footBox = [NSStackView stackViewWithViews:@[ foot ]];
    footBox.edgeInsets = NSEdgeInsetsMake(0, kFormInset, 0, kFormInset);
    [parts addObject:footBox];
  }
  NSStackView *stack = [NSStackView stackViewWithViews:parts];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = kSectionFooterGap;
  if (header.length > 0) {
    [stack setCustomSpacing:kSectionHeaderGap afterView:parts.firstObject];
  }
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  return stack;
}

// A scrolling page of sections, kSectionGap apart. The scroll view's automatic
// content insets keep the first section clear of the toolbar.
- (NSScrollView *)pageWithSections:(NSArray<NSView *> *)sections stack:(NSStackView **)stackOut {
  NSStackView *stack = [NSStackView stackViewWithViews:sections];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeCenterX;
  stack.spacing = kSectionGap;
  stack.detachesHiddenViews = YES;
  stack.edgeInsets = NSEdgeInsetsMake(kSectionGap - 6, 20, 20, 20);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  SettingsFlippedView *document = [[SettingsFlippedView alloc] initWithFrame:NSZeroRect];
  document.translatesAutoresizingMaskIntoConstraints = NO;
  [document addSubview:stack];
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.drawsBackground = NO;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = document;
  NSClipView *clip = scroll.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
    [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
  ]];
  if (stackOut != NULL) {
    *stackOut = stack;
  }
  return scroll;
}

- (NSStackView *)hstack:(NSArray<NSView *> *)views spacing:(CGFloat)spacing {
  NSStackView *stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.alignment = NSLayoutAttributeCenterY;
  stack.spacing = spacing;
  stack.detachesHiddenViews = YES;
  return stack;
}

- (NSStackView *)dot:(DotView * __strong *)dotOut label:(NSTextField * __strong *)labelOut {
  DotView *dot = [[DotView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
  dot.translatesAutoresizingMaskIntoConstraints = NO;
  [dot.widthAnchor constraintEqualToConstant:8].active = YES;
  [dot.heightAnchor constraintEqualToConstant:8].active = YES;
  NSTextField *label = [NSTextField labelWithString:@""];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  label.textColor = NSColor.secondaryLabelColor;
  *dotOut = dot;
  *labelOut = label;
  return [self hstack:@[ dot, label ] spacing:6];
}

- (NSButton *)pushButton:(NSString *)title action:(SEL)action {
  NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
  button.bezelStyle = NSBezelStyleRounded;
  return button;
}

- (NSTextField *)secondaryLabel:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  label.textColor = NSColor.secondaryLabelColor;
  return label;
}

- (NSTextField *)valueLabel {
  NSTextField *value = [NSTextField labelWithString:@"—"];
  value.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                 weight:NSFontWeightRegular];
  value.textColor = NSColor.secondaryLabelColor;
  value.alignment = NSTextAlignmentRight;
  [value.widthAnchor constraintEqualToConstant:40].active = YES;
  return value;
}

- (NSSlider *)formSlider:(CGFloat)width {
  ReleaseSlider *slider = [[ReleaseSlider alloc] initWithFrame:NSZeroRect];
  slider.minValue = 0;
  slider.maxValue = 100;
  slider.continuous = YES;
  slider.translatesAutoresizingMaskIntoConstraints = NO;
  [slider.widthAnchor constraintEqualToConstant:width].active = YES;
  tintSlider(slider);
  return slider;
}

// MARK: General

- (NSView *)iconPickerRow {
  self.iconTiles = [NSMutableArray array];
  NSMutableArray<NSView *> *tiles = [NSMutableArray array];
  __weak SettingsPanel *panel = self;
  for (IconChoice *choice in [IconChoice all]) {
    IconTile *tile = [[IconTile alloc] initWithChoice:choice];
    tile.picked = ^(IconTile *picked) {
      [panel pickIcon:picked.choice];
    };
    [self.iconTiles addObject:tile];
    [tiles addObject:tile];
    [self addWords:choice.name];
  }
  NSStackView *strip = [self hstack:tiles spacing:4];
  strip.alignment = NSLayoutAttributeTop;
  strip.edgeInsets = NSEdgeInsetsMake(kRowInsetV, kFormInset - 4, kRowInsetV, kFormInset);
  [strip setAccessibilityRole:NSAccessibilityRadioGroupRole];
  strip.accessibilityLabel = @"Icon";
  NSStackView *box = [NSStackView stackViewWithViews:@[ strip ]];
  box.orientation = NSUserInterfaceLayoutOrientationVertical;
  box.alignment = NSLayoutAttributeLeading;
  [box.widthAnchor constraintEqualToConstant:kFormWidth].active = YES;
  [self syncIconTiles];
  return box;
}

- (void)pickIcon:(IconChoice *)choice {
  if (self.iconPicked != nil) {
    self.iconPicked(choice);
  }
  [self syncIconTiles];
}

- (void)syncIconTiles {
  NSString *current = [IconChoice current].ident;
  for (IconTile *tile in self.iconTiles) {
    tile.selected = [tile.choice.ident isEqualToString:current];
  }
}

- (NSView *)generalPane {
  self.loginSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
  self.cycleSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
  self.warmthSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
  NSButton *notifications = [self pushButton:@"Open…" action:@selector(openNotifications:)];
  notifications.accessibilityLabel = @"Open Notification settings";

  NSView *startup = [self section:@"Startup"
                        accessory:nil
                             rows:@[ [self row:@"Open at login"
                                         caption:@"Nightshift starts when you log in and keeps "
                                                 @"the evening ramp running."
                                         control:self.loginSwitch] ]
                           footer:nil];
  [self addWords:@"Menu bar"];
  NSView *icon = [self section:@"Icon"
                     accessory:nil
                          rows:@[
                            [self iconPickerRow],
                            [self row:@"Show warmth next to icon"
                                caption:@"Shows the current warmth, like 64%, in the menu bar."
                                control:self.warmthSwitch],
                          ]
                        footer:@"Sets the menu bar icon. More icons are on the way."];
  NSView *clock = [self section:@"Clock"
                      accessory:nil
                           rows:@[ [self row:@"24-hour time"
                                       caption:@"Full at in the menu and in Settings uses "
                                               @"24-hour time."
                                       control:self.cycleSwitch] ]
                         footer:nil];
  NSView *alerts = [self section:@"Notifications"
                       accessory:nil
                            rows:@[ [self row:@"Notification style"
                                        caption:@"Warmth banners can stay on screen. Choose "
                                                @"Alerts for Nightshift."
                                        control:notifications] ]
                          footer:nil];
  return [self pageWithSections:@[ startup, icon, clock, alerts ] stack:NULL];
}

// MARK: Night Shift

- (NSView *)nightShiftPane {
  self.schedulePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  NSArray<NSString *> *titles = @[ @"Off", @"Custom", @"Sunset to Sunrise" ];
  NSInteger modes[3] = {0, 2, 1};
  for (NSUInteger i = 0; i < titles.count; i++) {
    [self.schedulePopup addItemWithTitle:titles[i]];
    self.schedulePopup.lastItem.tag = modes[i];
    [self addWords:titles[i]];
  }

  // Night Shift's hours can only be read here; nothing in Nightshift sets
  // them yet, so the row hands off to System Settings.
  self.timesLabel = [self secondaryLabel:@"—"];
  self.timesLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                         weight:NSFontWeightRegular];
  NSButton *change = [self pushButton:@"Change…" action:@selector(openNightShiftSettings:)];
  change.accessibilityLabel = @"Change hours in System Settings";
  FormRow *hours = [self row:@"Hours"
                     caption:@"Set in System Settings › Displays › Night Shift."
                     control:[self hstack:@[ self.timesLabel, change ] spacing:10]];

  NSView *schedule = [self section:@"Schedule"
                         accessory:nil
                              rows:@[
                                [self row:@"Schedule"
                                    caption:@"Custom runs the evening ramp between your hours."
                                    control:self.schedulePopup],
                                hours,
                              ]
                            footer:nil];

  // The slider gets its own line under the title and caption, so the
  // caption wraps across the full row instead of beside the slider.
  self.maxValue = [self valueLabel];
  NSTextField *less = [self secondaryLabel:@"Less Warm"];
  less.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  NSTextField *more = [self secondaryLabel:@"More Warm"];
  more.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  CGFloat sliderWidth = kFormWidth - 2 * kFormInset - less.fittingSize.width -
                        more.fittingSize.width - 40 - 3 * 8;
  self.maxSlider = [self formSlider:floor(sliderWidth)];
  self.maxSlider.minValue = 1;
  NSStackView *maxControl = [self hstack:@[ less, self.maxSlider, more, self.maxValue ]
                                 spacing:8];
  self.maxRow = [self row:@"Max" caption:@"" control:maxControl below:YES];
  NSView *warmth = [self section:@"Warmth" accessory:nil rows:@[ self.maxRow ] footer:nil];

  self.fullAtPicker = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
  self.fullAtPicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
  self.fullAtPicker.datePickerElements = NSDatePickerElementFlagHourMinute;
  self.fullAtPicker.datePickerMode = NSDatePickerModeSingle;
  self.fullAtPicker.bezeled = YES;
  self.fullAtPicker.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  self.fullAtPicker.timeZone = [NSTimeZone localTimeZone];
  self.unlockButton = [self pushButton:@"Unlock…" action:@selector(showLicensePane:)];
  self.fullAtRow =
      [self row:@"Full at"
          caption:@""
          control:[self hstack:@[ self.unlockButton, self.fullAtPicker ] spacing:8]];
  PillView *pro = [[PillView alloc] initWithText:@"PRO"
                                           color:NSColor.controlAccentColor
                                           solid:YES];
  [self addWords:@"Pro"];
  [self addWords:@"Ramp"];
  NSView *ramp = [self section:@"Evening Ramp"
                     accessory:pro
                          rows:@[ self.fullAtRow ]
                        footer:@"On a Custom schedule, warmth starts low and climbs to Max over "
                               @"two hours, or by Full at. After Full at, it holds at Max."];
  // PHASE 2: a Ramp length row (popup: 1, 2, 3 hours) joins Evening Ramp, and
  // a "Tonight" section with the warmth-over-time chart goes here, between
  // Evening Ramp and the end of the page.
  return [self pageWithSections:@[ schedule, warmth, ramp ] stack:NULL];
}

- (void)syncNightShift {
  BLStatus status;
  BOOL known = readStatus(gClient, &status);
  NSInteger mode = known ? status.mode : -1;
  if (mode >= 0 && self.schedulePopup.selectedTag != mode) {
    [self.schedulePopup selectItemWithTag:mode];
  }
  self.schedulePopup.enabled = known;
  BOOL custom = mode == kModeCustom;
  if (known && custom) {
    int from = status.schedule.from.hour * 60 + status.schedule.from.minute;
    int to = status.schedule.to.hour * 60 + status.schedule.to.minute;
    self.timesLabel.stringValue =
        [NSString stringWithFormat:@"%@ – %@", clockString(from), clockString(to)];
  } else if (known && mode == 1) {
    self.timesLabel.stringValue = @"Sunset – Sunrise";
  } else {
    self.timesLabel.stringValue = @"—";
  }

  BOOL paid = self.paid;
  self.maxSlider.enabled = paid;
  self.maxRow.captionField.stringValue =
      paid ? @"The warmest the ramp gets. Current warmth stays at or below it."
           : @"Max is part of Nightshift Pro.";
  long now = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  if (warmthStatus(&now, &maxv, &state, &full)) {
    if (maxv >= 1) {
      [self showMaxValue:maxv];
    } else {
      self.maxSlider.doubleValue = now >= 1 && now <= 100 ? now : 50;
      self.maxValue.stringValue = @"—";
    }
  }

  self.unlockButton.hidden = paid;
  BOOL rampOn = paid && custom;
  self.fullAtPicker.enabled = rampOn;
  if (!paid) {
    self.fullAtRow.captionField.stringValue = @"Upgrade to Pro to set when the ramp is full.";
  } else if (!custom) {
    self.fullAtRow.captionField.stringValue = @"Choose the Custom schedule to use Full at.";
  } else {
    self.fullAtRow.captionField.stringValue = @"When warmth reaches Max.";
  }
  // Leave the picker alone while it is being typed in.
  BOOL editing = self.editingFullAt ||
                 (self.window.firstResponder != nil &&
                  [self.window.firstResponder isKindOfClass:[NSView class]] &&
                  [(NSView *)self.window.firstResponder isDescendantOf:self.fullAtPicker]);
  if (!editing) {
    BOOL h24 = hourCycleIs24();
    self.fullAtPicker.locale =
        [NSLocale localeWithLocaleIdentifier:h24 ? @"en_GB" : @"en_US_POSIX"];
    int minute = gRampClock >= 0 ? gRampClock : gFullAt;
    if (minute < 0) {
      minute = minutesNow();
    }
    if (minute < 0) {
      minute = 0;
    }
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = 2001;
    parts.month = 1;
    parts.day = 1;
    parts.hour = minute / 60;
    parts.minute = minute % 60;
    NSDate *date = [self.fullAtPicker.calendar dateFromComponents:parts];
    if (date != nil && ![date isEqualToDate:self.fullAtPicker.dateValue]) {
      self.fullAtPicker.dateValue = date;
    }
  }
}

- (int)fullAtMinute {
  NSDateComponents *parts =
      [self.fullAtPicker.calendar components:NSCalendarUnitHour | NSCalendarUnitMinute
                                    fromDate:self.fullAtPicker.dateValue];
  if (parts == nil) {
    return -1;
  }
  return (int)(parts.hour * 60 + parts.minute);
}

- (void)showMaxValue:(long)value {
  if (llround(self.maxSlider.doubleValue) != value) {
    self.maxSlider.doubleValue = value;
  }
  self.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
}

- (void)showLicensePane:(id)sender {
  (void)sender;
  [self applyPage:kPaneLicense];
}

- (void)openNightShiftSettings:(id)sender {
  (void)sender;
  gSettingsKeepsOpenForOtherApp = YES;
  NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings."
                                    @"extension?nightShift"];
  if (url != nil) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

// MARK: Displays

static void displayKind(uint32_t display, NSString **text, NSColor **color) {
  float level = 0;
  if (CGDisplayIsBuiltin(display)) {
    *text = @"Built-in backlight";
    *color = NSColor.secondaryLabelColor;
  } else if (ddcReady(display)) {
    *text = @"DDC/CI connected";
    *color = NSColor.systemGreenColor;
  } else if (ddcPending(display) || ddcUnconfirmed(display)) {
    *text = @"Checking DDC/CI…";
    *color = NSColor.secondaryLabelColor;
  } else if (readCoreBrightness(display, &level)) {
    *text = @"Backlight";
    *color = NSColor.secondaryLabelColor;
  } else {
    *text = @"Dimming overlay";
    *color = NSColor.systemOrangeColor;
  }
}

static NSString *displaySignature(uint32_t *ids, int count) {
  NSMutableString *signature = [NSMutableString string];
  for (int i = 0; i < count; i++) {
    NSString *kind = nil;
    NSColor *color = nil;
    displayKind(ids[i], &kind, &color);
    [signature appendFormat:@"%u:%@:%@;", ids[i], displayTitle(ids[i]), kind];
  }
  return signature;
}

- (NSView *)displaysPane {
  self.displaySections = [NSMutableArray array];
  self.displayRows = [NSMutableArray array];
  [self addWords:@"Brightness"];
  [self addWords:@"Display"];
  [self addWords:@"DDC/CI"];

  self.keysButton = [NSButton buttonWithTitle:@"Open Accessibility Settings…"
                                       target:nil
                                       action:NULL];
  self.keysButton.bezelStyle = NSBezelStyleRounded;
  DotView *dot = nil;
  NSTextField *status = nil;
  NSStackView *keysState = [self dot:&dot label:&status];
  self.keysDot = dot;
  self.keysStatus = status;
  // The status and its button share the row, stacked at the trailing edge.
  NSStackView *keysControl = [NSStackView stackViewWithViews:@[ keysState, self.keysButton ]];
  keysControl.orientation = NSUserInterfaceLayoutOrientationVertical;
  keysControl.alignment = NSLayoutAttributeTrailing;
  keysControl.spacing = 6;
  FormRow *keysRow = [self row:@"Brightness Keys"
                       caption:@"The brightness keys change the display under the pointer. "
                               @"They need Accessibility access."
                       control:keysControl];
  NSView *keys = [self section:@"Keyboard"
                     accessory:nil
                          rows:@[ keysRow ]
                        footer:@"The lower half of the range dims the picture after the "
                               @"backlight is as low as it will go. Turn on DDC/CI in the "
                               @"monitor's menu to change an external display's backlight."];
  NSStackView *stack = nil;
  NSScrollView *page = [self pageWithSections:@[ keys ] stack:&stack];
  self.displaysStack = stack;
  return page;
}

- (void)rebuildDisplays:(uint32_t *)ids count:(int)count {
  for (NSView *section in self.displaySections) {
    [self.displaysStack removeArrangedSubview:section];
    [section removeFromSuperview];
  }
  [self.displaySections removeAllObjects];
  [self.displayRows removeAllObjects];
  NSInteger saved = self.buildingPane;
  self.buildingPane = kPaneDisplays;
  for (int i = 0; i < count; i++) {
    NSString *name = displayTitle(ids[i]);
    NSString *kind = nil;
    NSColor *color = nil;
    displayKind(ids[i], &kind, &color);
    PillView *pill = [[PillView alloc] initWithText:kind color:color solid:NO];
    FormRow *control = [self row:@"Control" caption:nil control:pill];

    NSSlider *slider = [self formSlider:200];
    slider.tag = (NSInteger)ids[i];
    slider.target = self.brightnessTarget;
    slider.action = self.brightnessAction;
    NSTextField *value = [self valueLabel];
    FormRow *brightness = [self row:@"Brightness"
                            caption:nil
                            control:[self hstack:@[ slider, value ] spacing:8]];
    slider.accessibilityLabel = [NSString stringWithFormat:@"%@ brightness", name];
    // PHASE 2: Lowest brightness (a floor for the keys and the ramp) and a
    // DDC/CI Test button join this group.
    NSView *section = [self section:name
                          accessory:nil
                               rows:@[ control, brightness ]
                             footer:nil];
    DisplayRow *row = [[DisplayRow alloc] init];
    row.display = ids[i];
    row.slider = slider;
    row.valueLabel = value;
    [self.displayRows addObject:row];
    [self.displaySections addObject:section];
    [self.displaysStack insertArrangedSubview:section atIndex:(NSUInteger)i];
  }
  self.buildingPane = saved;
}

- (void)syncDisplays {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  NSString *signature = displaySignature(ids, count);
  if (self.trackingDisplay == 0 && ![signature isEqualToString:self.displaySignature]) {
    self.displaySignature = signature;
    [self rebuildDisplays:ids count:count];
  }
  for (DisplayRow *row in self.displayRows) {
    if (row.display == self.trackingDisplay) {
      continue;
    }
    float level = 0;
    BOOL writable = NO;
    BOOL readable = readDisplayBrightness(row.display, &level, &writable);
    row.slider.enabled = readable && writable;
    if (!readable) {
      row.valueLabel.stringValue = @"—";
      continue;
    }
    long percent = MAX(0L, MIN(100L, (long)llround(level * 100.0)));
    [self showBrightness:percent forDisplay:row.display];
  }
  BOOL keys = brightnessKeysReady();
  self.keysDot.color = keys ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
  self.keysDot.needsDisplay = YES;
  self.keysStatus.stringValue = keys ? @"Allowed" : @"Not allowed";
}

- (void)showBrightness:(long)percent forDisplay:(uint32_t)display {
  for (DisplayRow *row in self.displayRows) {
    if (row.display == display) {
      if (llround(row.slider.doubleValue) != percent) {
        row.slider.doubleValue = percent;
      }
      row.valueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", percent];
      return;
    }
  }
}

- (void)screensChanged:(NSNotification *)notification {
  (void)notification;
  if (self.window.isVisible) {
    [self syncDisplays];
  }
}

// MARK: License

static NSString *licenseDay(NSString *until) {
  NSDateFormatter *parse = [[NSDateFormatter alloc] init];
  parse.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  parse.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
  parse.dateFormat = @"yyyy-MM-dd";
  NSDate *date = [parse dateFromString:until];
  if (date == nil) {
    return until;
  }
  NSDateFormatter *show = [[NSDateFormatter alloc] init];
  show.timeZone = parse.timeZone;
  show.dateStyle = NSDateFormatterMediumStyle;
  show.timeStyle = NSDateFormatterNoStyle;
  return [show stringFromDate:date];
}

- (NSView *)licensePane {
  NSImageView *icon =
      [NSImageView imageViewWithImage:[[IconChoice standard] tileImageOfSize:64]];
  NSTextField *name = [NSTextField labelWithString:@"Nightshift Pro"];
  name.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  DotView *dot = nil;
  NSTextField *status = nil;
  NSStackView *state = [self dot:&dot label:&status];
  self.licenseDot = dot;
  self.licenseStatus = status;
  NSStackView *titles = [NSStackView stackViewWithViews:@[ name, state ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical;
  titles.alignment = NSLayoutAttributeLeading;
  titles.spacing = 4;
  NSStackView *hero = [self hstack:@[ icon, titles ] spacing:12];
  hero.edgeInsets = NSEdgeInsetsMake(12, kFormInset, 12, kFormInset);
  [hero.widthAnchor constraintEqualToConstant:kFormWidth].active = YES;
  NSTextField *about =
      [self captionLabel:@"Pro unlocks the evening ramp, Max and Full at. Warmth, brightness, "
                         @"Dark mode, and True Tone stay free."
                   width:kFormWidth - 2 * kFormInset];
  NSStackView *aboutBox = [NSStackView stackViewWithViews:@[ about ]];
  aboutBox.edgeInsets = NSEdgeInsetsMake(0, kFormInset, 12, kFormInset);
  [self addWords:@"Nightshift Pro"];
  [self addWords:about.stringValue];
  NSStackView *heroBox = [NSStackView stackViewWithViews:@[ hero, aboutBox ]];
  heroBox.orientation = NSUserInterfaceLayoutOrientationVertical;
  heroBox.alignment = NSLayoutAttributeLeading;
  heroBox.spacing = 0;
  NSView *summary = [self section:nil accessory:nil rows:@[ heroBox ] footer:nil];

  self.buyButton = [NSButton buttonWithTitle:@"Unlock the ramp" target:nil action:NULL];
  self.buyButton.bezelStyle = NSBezelStyleRounded;
  self.buyButton.keyEquivalent = @"";
  self.buySection = [self section:@"Purchase"
                        accessory:nil
                             rows:@[ [self row:@"Nightshift Pro"
                                         caption:@"Opens checkout in your browser. Nightshift "
                                                 @"picks up the license when you finish."
                                         control:self.buyButton] ]
                           footer:nil];
  // TODO: Manage Subscription. The billing portal only comes back from
  // /checkout as a 409 when no license is saved here (rampBeginPurchase sets
  // portal), so there is no way to open it for an active license yet. Add a
  // row here once the server has a portal endpoint for a saved license.

  self.installIDLabel = [NSTextField labelWithString:rampInstallID() ?: @"—"];
  self.installIDLabel.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize
                                                         weight:NSFontWeightRegular];
  self.installIDLabel.textColor = NSColor.secondaryLabelColor;
  self.installIDLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  self.installIDLabel.selectable = YES;
  [self.installIDLabel.widthAnchor constraintLessThanOrEqualToConstant:230].active = YES;
  [self.installIDLabel
      setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSImage *copyImage = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                 accessibilityDescription:@"Copy Install ID"];
  self.installIDCopyButton = [NSButton buttonWithImage:copyImage
                                       target:self
                                       action:@selector(copyInstallID:)];
  self.installIDCopyButton.bezelStyle = NSBezelStyleRounded;
  self.installIDCopyButton.toolTip = @"Copy";
  NSView *mac = [self section:@"This Mac"
                    accessory:nil
                         rows:@[ [self row:@"Install ID"
                                     caption:@"Support may ask for this."
                                     control:[self hstack:@[ self.installIDLabel, self.installIDCopyButton ]
                                                  spacing:6]] ]
                       footer:nil];
  return [self pageWithSections:@[ summary, self.buySection, mac ] stack:NULL];
}

- (void)syncLicense {
  NSString *text = nil;
  NSColor *color = nil;
  if (self.buying) {
    text = @"Waiting for checkout…";
    color = NSColor.systemOrangeColor;
  } else if (self.paid && self.until != nil && self.soon) {
    text = [NSString stringWithFormat:@"Ends %@", licenseDay(self.until)];
    color = NSColor.systemOrangeColor;
  } else if (self.paid && self.until != nil) {
    text = [NSString stringWithFormat:@"Active through %@", licenseDay(self.until)];
    color = NSColor.systemGreenColor;
  } else if (self.paid) {
    text = @"Active";
    color = NSColor.systemGreenColor;
  } else {
    text = @"Not active";
    color = NSColor.secondaryLabelColor;
  }
  self.licenseStatus.stringValue = text;
  self.licenseDot.color = color;
  self.licenseDot.needsDisplay = YES;
  self.buySection.hidden = self.paid && !self.soon;
  self.buyButton.title = self.soon ? @"Renew…" : @"Buy…";
  self.buyButton.enabled = !self.buying;
  NSString *installID = rampInstallID();
  if (installID.length > 0 && ![installID isEqualToString:self.installIDLabel.stringValue]) {
    self.installIDLabel.stringValue = installID;
  }
  self.installIDCopyButton.enabled = installID.length > 0;
}

- (void)copyInstallID:(id)sender {
  (void)sender;
  NSString *installID = rampInstallID();
  if (installID.length == 0) {
    return;
  }
  NSPasteboard *board = NSPasteboard.generalPasteboard;
  [board clearContents];
  [board setString:installID forType:NSPasteboardTypeString];
  NSButton *button = self.installIDCopyButton;
  button.image = [NSImage imageWithSystemSymbolName:@"checkmark"
                           accessibilityDescription:@"Copied"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   button.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                            accessibilityDescription:@"Copy Install ID"];
                 });
}

// MARK: About

- (NSView *)aboutPane {
  NSImageView *icon =
      [NSImageView imageViewWithImage:[[IconChoice standard] tileImageOfSize:96]];
  NSTextField *name = [NSTextField labelWithString:@"Nightshift"];
  name.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  NSString *version = info[@"CFBundleShortVersionString"];
  NSString *build = info[@"CFBundleVersion"];
  NSString *versionText = version == nil ? @"Development build"
                          : build == nil ? [NSString stringWithFormat:@"Version %@", version]
                                         : [NSString stringWithFormat:@"Version %@ (%@)",
                                                                      version, build];
  NSTextField *versionLabel = [self secondaryLabel:versionText];
  versionLabel.selectable = YES;
  NSStackView *hero = [NSStackView stackViewWithViews:@[ icon, name, versionLabel ]];
  hero.orientation = NSUserInterfaceLayoutOrientationVertical;
  hero.alignment = NSLayoutAttributeCenterX;
  hero.spacing = 4;
  [hero setCustomSpacing:8 afterView:icon];
  hero.edgeInsets = NSEdgeInsetsMake(10, 0, 4, 0);
  [hero.widthAnchor constraintEqualToConstant:kFormWidth].active = YES;
  [self addWords:@"Version"];

  NSButton *github = [self pushButton:@"GitHub" action:@selector(openLink:)];
  github.identifier = @"https://github.com/freechie/nightshift";
  NSButton *issues = [self pushButton:@"Report an Issue…" action:@selector(openLink:)];
  issues.identifier = @"https://github.com/freechie/nightshift/issues";
  // TODO: a Privacy link once a privacy page exists. No Acknowledgements row:
  // Nightshift ships no third-party code.
  NSView *links = [self section:@"Links"
                      accessory:nil
                           rows:@[
                             [self row:@"Source code" caption:nil control:github],
                             [self row:@"Feedback" caption:nil control:issues],
                           ]
                         footer:nil];
  NSView *legal = [self section:@"License"
                      accessory:nil
                           rows:@[ [self row:@"Copyright 2026 John."
                                        caption:@"Licensed under the Apache License 2.0."
                                        control:nil] ]
                         footer:nil];
  // No Check for Updates: Nightshift has no updater. Add it here with one.
  return [self pageWithSections:@[ hero, links, legal ] stack:NULL];
}

- (void)openLink:(NSButton *)sender {
  NSURL *url = [NSURL URLWithString:sender.identifier];
  if (url != nil) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

// MARK: Window

static NSString *paneTitle(NSInteger pane) {
  switch (pane) {
    case kPaneGeneral: return @"General";
    case kPaneNightShift: return @"Night Shift";
    case kPaneDisplays: return @"Displays";
    case kPaneLicense: return @"License";
    case kPaneAbout: return @"About";
    default: return @"";
  }
}

static NSString *paneSymbol(NSInteger pane) {
  switch (pane) {
    case kPaneGeneral: return @"gearshape.fill";
    case kPaneNightShift: return @"sun.horizon.fill";
    case kPaneDisplays: return @"display";
    case kPaneLicense: return @"checkmark.seal.fill";
    case kPaneAbout: return @"info.circle.fill";
    default: return @"questionmark";
  }
}

static NSColor *paneColor(NSInteger pane) {
  switch (pane) {
    case kPaneGeneral: return NSColor.systemGrayColor;
    case kPaneNightShift: return NSColor.systemOrangeColor;
    case kPaneDisplays: return NSColor.systemBlueColor;
    case kPaneLicense: return NSColor.systemGreenColor;
    case kPaneAbout: return NSColor.systemGrayColor;
    default: return NSColor.systemGrayColor;
  }
}

// A System Settings sidebar tile: a white symbol on a colored rounded square.
static NSImage *sidebarTile(NSInteger pane, CGFloat size) {
  NSString *symbolName = paneSymbol(pane);
  NSColor *color = paneColor(pane);
  return [NSImage imageWithSize:NSMakeSize(size, size)
                        flipped:NO
                 drawingHandler:^BOOL(NSRect rect) {
                   NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:rect
                                                                        xRadius:size * 0.225
                                                                        yRadius:size * 0.225];
                   [[color blendedColorWithFraction:0.18 ofColor:NSColor.whiteColor] setFill];
                   [tile fill];
                   NSGradient *shade = [[NSGradient alloc]
                       initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.0]
                                 endingColor:[NSColor colorWithWhite:0 alpha:0.12]];
                   [shade drawInBezierPath:tile angle:-90];
                   NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration
                       configurationWithPointSize:size * 0.55
                                           weight:NSFontWeightMedium]
                       configurationByApplyingConfiguration:
                           [NSImageSymbolConfiguration
                               configurationWithPaletteColors:@[ NSColor.whiteColor ]]];
                   NSImage *symbol = [[NSImage imageWithSystemSymbolName:symbolName
                                                 accessibilityDescription:nil]
                       imageWithSymbolConfiguration:config];
                   if (symbol != nil) {
                     NSSize s = symbol.size;
                     CGFloat fit = MIN(1, size * 0.68 / MAX(s.width, s.height));
                     s = NSMakeSize(s.width * fit, s.height * fit);
                     [symbol drawInRect:NSMakeRect(NSMidX(rect) - s.width / 2,
                                                   NSMidY(rect) - s.height / 2, s.width,
                                                   s.height)
                               fromRect:NSZeroRect
                              operation:NSCompositingOperationSourceOver
                               fraction:1];
                   }
                   return YES;
                 }];
}

- (instancetype)init {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  self.pages = [NSMutableArray array];
  self.paneWords = [NSMutableArray array];
  for (NSInteger pane = 0; pane < kPaneCount; pane++) {
    [self.paneWords addObject:[NSMutableArray arrayWithObject:paneTitle(pane)]];
  }
  self.visiblePanes = @[ @(kPaneGeneral), @(kPaneNightShift), @(kPaneDisplays), @(kPaneLicense),
                         @(kPaneAbout) ];
  self.page = -1;

  // Shortcuts has no pane: there are no shortcuts to set yet, and an empty
  // "coming soon" page reads as unfinished. Add kPaneShortcuts with the feature.
  for (NSInteger pane = 0; pane < kPaneCount; pane++) {
    self.buildingPane = pane;
    NSView *page = nil;
    switch (pane) {
      case kPaneGeneral: page = [self generalPane]; break;
      case kPaneNightShift: page = [self nightShiftPane]; break;
      case kPaneDisplays: page = [self displaysPane]; break;
      case kPaneLicense: page = [self licensePane]; break;
      default: page = [self aboutPane]; break;
    }
    [self.pages addObject:page];
  }
  self.buildingPane = -1;

  // Content: every page stacked in one view, one shown at a time.
  NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
  for (NSView *page in self.pages) {
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
      [page.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
      [page.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
      [page.topAnchor constraintEqualToAnchor:content.topAnchor],
      [page.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
  }
  NSViewController *contentController = [[NSViewController alloc] init];
  contentController.view = content;

  // Sidebar: search field over a source list.
  self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  self.searchField.placeholderString = @"Search";
  self.searchField.sendsSearchStringImmediately = YES;
  self.searchField.target = self;
  self.searchField.action = @selector(searchChanged:);
  self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
  self.sidebarTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"pane"];
  [self.sidebarTable addTableColumn:column];
  self.sidebarTable.headerView = nil;
  self.sidebarTable.style = NSTableViewStyleSourceList;
  self.sidebarTable.rowHeight = kSidebarRowHeight;
  self.sidebarTable.intercellSpacing = NSMakeSize(0, 32 - kSidebarRowHeight);
  self.sidebarTable.backgroundColor = NSColor.clearColor;
  self.sidebarTable.allowsEmptySelection = YES;
  self.sidebarTable.dataSource = self;
  self.sidebarTable.delegate = self;
  self.sidebarTable.accessibilityLabel = @"Settings sections";
  NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  tableScroll.documentView = self.sidebarTable;
  tableScroll.drawsBackground = NO;
  tableScroll.hasVerticalScroller = YES;
  tableScroll.autohidesScrollers = YES;
  tableScroll.automaticallyAdjustsContentInsets = NO;
  tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *sidebar = [[NSView alloc] initWithFrame:NSZeroRect];
  [sidebar addSubview:self.searchField];
  [sidebar addSubview:tableScroll];
  [NSLayoutConstraint activateConstraints:@[
    // Measured from the window top, not the safe area, so the field sits
    // clear of the traffic lights the way System Settings' does.
    [self.searchField.topAnchor constraintEqualToAnchor:sidebar.topAnchor
                                               constant:kSidebarSearchTop],
    [self.searchField.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:10],
    [self.searchField.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor
                                                    constant:-10],
    [tableScroll.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor
                                          constant:kSidebarListGap],
    [tableScroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
    [tableScroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    [tableScroll.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor],
  ]];
  NSViewController *sidebarController = [[NSViewController alloc] init];
  sidebarController.view = sidebar;

  NSSplitViewController *split = [[NSSplitViewController alloc] init];
  NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarController];
  sidebarItem.minimumThickness = kSettingsSidebarWidth;
  sidebarItem.maximumThickness = kSettingsSidebarWidth;
  sidebarItem.canCollapse = NO;
  NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:contentController];
  [split addSplitViewItem:sidebarItem];
  [split addSplitViewItem:contentItem];

  self.window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, kSettingsWidth, kSettingsHeight)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.contentViewController = split;
  [self.window setContentSize:NSMakeSize(kSettingsWidth, kSettingsHeight)];
  self.window.contentMinSize = NSMakeSize(kSettingsWidth, kSettingsHeight);
  self.window.contentMaxSize = NSMakeSize(kSettingsWidth, kSettingsHeight);
  self.window.identifier = kSettingsWindowID;
  self.window.title = @"Nightshift Settings";
  self.window.titlebarAppearsTransparent = NO;
  self.window.toolbarStyle = NSWindowToolbarStyleUnified;
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"NightshiftSettingsToolbar"];
  toolbar.delegate = self;
  toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  toolbar.allowsUserCustomization = NO;
  self.window.toolbar = toolbar;
  self.window.releasedWhenClosed = NO;
  self.window.hidesOnDeactivate = NO;
  self.window.canHide = NO;
  self.window.delegate = self;
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(appResigned:)
             name:NSApplicationDidResignActiveNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(screensChanged:)
             name:NSApplicationDidChangeScreenParametersNotification
           object:nil];
  [self.sidebarTable reloadData];
  [self.window center];
  [self applyPage:kPaneGeneral];
  return self;
}

// The toolbar only carries the sidebar separator, so the pane title sits over
// the content as in System Settings.
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
  (void)toolbar;
  return @[ NSToolbarSidebarTrackingSeparatorItemIdentifier ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
  (void)toolbar;
  return @[ NSToolbarSidebarTrackingSeparatorItemIdentifier ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
        itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
  (void)toolbar;
  (void)identifier;
  (void)flag;
  return nil;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return (NSInteger)self.visiblePanes.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
  (void)tableColumn;
  NSInteger pane = self.visiblePanes[(NSUInteger)row].integerValue;
  NSTableCellView *cell = [tableView makeViewWithIdentifier:@"paneCell" owner:self];
  if (cell == nil) {
    cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
    cell.identifier = @"paneCell";
    NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *text = [NSTextField labelWithString:@""];
    text.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    text.lineBreakMode = NSLineBreakByTruncatingTail;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:image];
    [cell addSubview:text];
    cell.imageView = image;
    cell.textField = text;
    [NSLayoutConstraint activateConstraints:@[
      [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
      [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      [image.widthAnchor constraintEqualToConstant:kSidebarIconSize],
      [image.heightAnchor constraintEqualToConstant:kSidebarIconSize],
      [text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:8],
      [text.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
      [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
  }
  cell.imageView.image = sidebarTile(pane, kSidebarIconSize);
  cell.textField.stringValue = paneTitle(pane);
  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  (void)notification;
  if (self.selectingRow) {
    return;
  }
  NSInteger row = self.sidebarTable.selectedRow;
  if (row >= 0 && row < (NSInteger)self.visiblePanes.count) {
    [self applyPage:self.visiblePanes[(NSUInteger)row].integerValue];
  }
}

- (void)searchChanged:(NSSearchField *)field {
  NSString *query = [field.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSMutableArray<NSNumber *> *panes = [NSMutableArray array];
  for (NSInteger pane = 0; pane < kPaneCount; pane++) {
    BOOL match = query.length == 0;
    for (NSString *words in self.paneWords[(NSUInteger)pane]) {
      if (match) {
        break;
      }
      match = [words rangeOfString:query
                           options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch]
                  .location != NSNotFound;
    }
    if (match) {
      [panes addObject:@(pane)];
    }
  }
  self.visiblePanes = panes;
  [self.sidebarTable reloadData];
  if (panes.count > 0 && ![panes containsObject:@(self.page)]) {
    [self applyPage:panes.firstObject.integerValue];
  } else {
    [self selectPageRow];
  }
}

- (void)selectPageRow {
  NSUInteger row = [self.visiblePanes indexOfObject:@(self.page)];
  self.selectingRow = YES;
  if (row == NSNotFound) {
    [self.sidebarTable deselectAll:nil];
  } else {
    [self.sidebarTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                   byExtendingSelection:NO];
  }
  self.selectingRow = NO;
}

- (void)applyPage:(NSInteger)index {
  if (index < 0 || index >= kPaneCount) {
    index = kPaneGeneral;
  }
  self.page = index;
  for (NSUInteger i = 0; i < self.pages.count; i++) {
    self.pages[i].hidden = (NSInteger)i != index;
  }
  self.window.title = paneTitle(index);
  [self selectPageRow];
}

- (void)paintSidebar {
  [self.sidebarTable reloadData];
  [self selectPageRow];
  tintSlider(self.maxSlider);
  for (DisplayRow *row in self.displayRows) {
    tintSlider(row.slider);
  }
  for (IconTile *tile in self.iconTiles) {
    tile.needsDisplay = YES;
  }
}

- (void)showPage:(NSInteger)index {
  [self applyPage:index];
  self.stayOpen = YES;
  // A regular app while Settings is open, so it gets a Dock icon and a
  // Cmd-Tab entry and stays put when you click into another app.
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  installSettingsMenu();
  [NSApp activate];
  [self.window makeKeyAndOrderFront:nil];
  if (self.syncTimer == nil) {
    __weak SettingsPanel *panel = self;
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:2
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
                                                         (void)timer;
                                                         SettingsPanel *strong = panel;
                                                         if (strong.needsSync != nil &&
                                                             strong.window.isVisible) {
                                                           strong.needsSync();
                                                         }
                                                       }];
  }
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
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  self.stayOpen = NO;
  gSettingsKeepsOpenForOtherApp = NO;
  [self stopOutsideClicks];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [self.syncTimer invalidate];
  self.syncTimer = nil;
}

- (void)syncPaid:(BOOL)paid
            soon:(BOOL)soon
           until:(NSString *)until
         buying:(BOOL)buying {
  self.paid = paid;
  self.soon = soon;
  self.until = until;
  self.buying = buying;
  self.loginSwitch.state = loginItemOn() ? NSControlStateValueOn : NSControlStateValueOff;
  self.cycleSwitch.state = hourCycleIs24() ? NSControlStateValueOn : NSControlStateValueOff;
  self.warmthSwitch.state =
      menuBarShowsWarmth() ? NSControlStateValueOn : NSControlStateValueOff;
  [self syncIconTiles];
  [self syncNightShift];
  [self syncDisplays];
  [self syncLicense];
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
@property(nonatomic) NSTimeInterval brightReleaseTime;
@property(nonatomic) BOOL buying;
@property(nonatomic) long pendingMax;
@property(nonatomic, strong) id clockKeyMonitor;
@property(nonatomic, strong) SettingsPanel *settings;
@property(nonatomic) NSTimeInterval settingsReleaseTime;
@property(nonatomic) BOOL settingsMaxTracking;
@property(nonatomic, copy) NSString *statusIconID;
- (void)refresh;
- (void)syncLoginItem;
- (void)syncStatusItem;
@end

@implementation MenuBar
- (instancetype)init {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  self.item = [[NSStatusBar systemStatusBar]
      statusItemWithLength:NSVariableStatusItemLength];
  self.item.autosaveName = @"nightshift";
  self.item.button.toolTip = @"Nightshift";
  self.item.button.imagePosition = NSImageLeading;
  [self syncStatusItem];

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
  [[NSNotificationCenter defaultCenter]
      addObserverForName:NSSystemColorsDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                (void)note;
                MenuBar *strong = menu;
                if (strong == nil) {
                  return;
                }
                [strong.panel applyAccent];
                if (strong.settings.window != nil) {
                  [strong.settings paintSidebar];
                }
                gBrightnessMeter.needsDisplay = YES;
              }];
  self.panel.sectionToggled = ^{
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
  [self.menu addItem:[NSMenuItem separatorItem]];
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
  if (fit.width < kMenuWidth - 16) {
    fit.width = kMenuWidth;
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
        [self brightReleaseHandled];
        endBrightnessDrag(row.display, (long)llround(row.slider.doubleValue));
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
  [self syncStatusItem];
  [self sizeMenuView];
}

// The menu bar icon, and the warmth next to it when General asks for it.
- (void)syncStatusItem {
  NSStatusBarButton *button = self.item.button;
  if (button == nil) {
    return;
  }
  NSImage *image = [[IconChoice current] menuImage];
  if (image == nil) {
    image = [[IconChoice standard] menuImage];
  }
  NSString *ident = [IconChoice current].ident;
  if (![ident isEqualToString:self.statusIconID] || button.image == nil) {
    self.statusIconID = ident;
    button.image = image;
  }
  NSString *title = @"";
  if (menuBarShowsWarmth()) {
    long now = 0;
    long maxv = 0;
    const char *state = NULL;
    int full = -1;
    if (warmthStatus(&now, &maxv, &state, &full)) {
      title = strcmp(state, "off") == 0 ? @"Off" : [NSString stringWithFormat:@"%ld%%", now];
    }
  } else if (image == nil) {
    title = @"NS";
  }
  if (![button.title isEqualToString:title]) {
    if (title.length == 0) {
      button.title = @"";
    } else {
      button.attributedTitle = [[NSAttributedString alloc]
          initWithString:title
              attributes:@{
                NSFontAttributeName : [NSFont
                    monospacedDigitSystemFontOfSize:[NSFont systemFontSizeForControlSize:
                                                                NSControlSizeRegular]
                                             weight:NSFontWeightRegular],
              }];
    }
  }
  button.imagePosition = title.length == 0 ? NSImageOnly : NSImageLeading;
}

- (SettingsPanel *)makeSettings {
  if (self.settings == nil) {
    SettingsPanel *settings = [[SettingsPanel alloc] init];
    self.settings = settings;
    // Display groups are built on the first sync, after this.
    settings.brightnessTarget = self;
    settings.brightnessAction = @selector(settingsBrightMoved:);
    settings.loginSwitch.target = self;
    settings.loginSwitch.action = @selector(toggleLogin:);
    settings.cycleSwitch.target = self;
    settings.cycleSwitch.action = @selector(toggleCycle:);
    settings.warmthSwitch.target = self;
    settings.warmthSwitch.action = @selector(settingsWarmthToggled:);
    settings.keysButton.target = self;
    settings.keysButton.action = @selector(allowKeys:);
    settings.buyButton.target = self;
    settings.buyButton.action = @selector(buyRamp:);
    settings.schedulePopup.target = self;
    settings.schedulePopup.action = @selector(settingsScheduleChanged:);
    settings.maxSlider.target = self;
    settings.maxSlider.action = @selector(settingsMaxMoved:);
    settings.fullAtPicker.target = self;
    settings.fullAtPicker.action = @selector(settingsFullAtChanged:);
    __weak MenuBar *menu = self;
    settings.becameKey = ^{
      probeDDC();
      [menu syncLoginItem];
    };
    settings.needsSync = ^{
      MenuBar *strong = menu;
      if (strong != nil && !strong.settingsMaxTracking && strong.settings.trackingDisplay == 0) {
        [strong syncLoginItem];
      }
    };
    settings.iconPicked = ^(IconChoice *choice) {
      MenuBar *strong = menu;
      if (strong == nil || [choice.ident isEqualToString:[IconChoice current].ident]) {
        return;
      }
      setMenuBarPref(@"icon", choice.ident);
      [strong syncStatusItem];
      [strong syncLoginItem];
    };
  }
  return self.settings;
}

- (void)syncLoginItem {
  if (self.settings == nil || !self.settings.window.isVisible) {
    return;
  }
  [self.settings syncPaid:rampLicensed()
                     soon:rampLicenseRenewingSoon()
                    until:rampLicenseUntil()
                  buying:self.buying];
}

- (void)showSettings:(id)sender {
  (void)sender;
  [[self makeSettings] showPage:kPaneGeneral];
  [self syncLoginItem];
}

- (void)showPro:(id)sender {
  (void)sender;
  [[self makeSettings] showPage:kPaneLicense];
  [self syncLoginItem];
}

- (void)settingsWarmthToggled:(NSSwitch *)sender {
  BOOL on = sender.state == NSControlStateValueOn;
  if (!setMenuBarPref(@"warmth", on ? @"on" : @"off")) {
    sender.state = on ? NSControlStateValueOff : NSControlStateValueOn;
  }
  [self syncStatusItem];
}

- (void)settingsScheduleChanged:(NSPopUpButton *)popup {
  NSInteger mode = popup.selectedTag;
  if (mode == 0 || mode == 1 || mode == 2) {
    setBlueLightMode((int)mode);
  }
  [self refresh];
  [self syncLoginItem];
}

// Max in Settings follows the menu's Max: the value shows while dragging and
// is committed once, on release.
- (void)settingsMaxMoved:(NSSlider *)slider {
  if (!rampLicensed()) {
    [self syncLoginItem];
    return;
  }
  long value = (long)llround(slider.doubleValue);
  [self.settings showMaxValue:value];
  if (!sliderSettled()) {
    self.settingsMaxTracking = YES;
    return;
  }
  if ([self settingsReleaseHandled]) {
    return;
  }
  self.settingsMaxTracking = NO;
  long live = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  BOOL known = warmthStatus(&live, &maxv, &state, &full);
  [self.panel syncSliders];
  [self finishMax:value known:known live:live];
  [self syncLoginItem];
}

- (void)settingsFullAtChanged:(NSDatePicker *)picker {
  (void)picker;
  self.settings.editingFullAt = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(commitSettingsFullAt)
                                             object:nil];
  [self performSelector:@selector(commitSettingsFullAt) withObject:nil afterDelay:0.8];
}

- (void)commitSettingsFullAt {
  self.settings.editingFullAt = NO;
  if (!rampLicensed() || !customSchedule()) {
    [self syncLoginItem];
    return;
  }
  int minute = [self.settings fullAtMinute];
  if (minute >= 0 && minute != gRampClock && !setRampClock(minute)) {
    notifyPlain(@"Could not set Full at");
  }
  [self refresh];
  [self syncLoginItem];
}

// Like brightReleaseHandled, for the Settings sliders, which live outside
// the menu and so always settle on mouse-up.
- (BOOL)settingsReleaseHandled {
  NSEvent *event = NSApp.currentEvent;
  if (event == nil || event.type != NSEventTypeLeftMouseUp) {
    return NO;
  }
  if (event.timestamp == self.settingsReleaseTime) {
    return YES;
  }
  self.settingsReleaseTime = event.timestamp;
  return NO;
}

// Brightness from Settings: the same paths as the menu. The built-in and a
// confirmed DDC display follow the knob; every display saves once on release.
- (void)settingsBrightMoved:(NSSlider *)slider {
  uint32_t display = (uint32_t)slider.tag;
  BOOL settled = sliderSettled();
  if (settled && [self settingsReleaseHandled]) {
    return;
  }
  long value = softwareDimPercent(display, (long)llround(slider.doubleValue));
  [self.settings showBrightness:value forDisplay:display];
  if (!settled) {
    self.settings.trackingDisplay = display;
    if (CGDisplayIsBuiltin(display) || ddcReady(display)) {
      holdBrightnessTick(display, value);
    }
    return;
  }
  self.settings.trackingDisplay = 0;
  if (!endBrightnessDrag(display, value)) {
    [self syncLoginItem];
    return;
  }
  long shown = readPercent(display);
  if (shown >= 0) {
    [self.settings showBrightness:shown forDisplay:display];
  }
  [self refresh];
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
          notifyPlain(body);
        }
        [self refresh];
      });
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      // Review finding 2: Stripe Checkout or the billing portal only, opened
      // as the very NSURL that was checked.
      NSURL *page = rampPurchasePage(url);
      BOOL opened = page != nil && [[NSWorkspace sharedWorkspace] openURL:page];
      if (!opened) {
        self.buying = NO;
        notifyPlain(@"could not open checkout");
        [self refresh];
        return;
      }
      if (portal) {
        self.buying = NO;
        if (out != nil) {
          notifyPlain(out);
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
                notifyPlain(body);
              }
              [self refresh];
            });
            return;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          self.buying = NO;
          notifyPlain(@"Checkout did not finish");
          [self refresh];
        });
      });
    });
  });
}

// A mouse-up that already ended a brightness drag. NSSlider may send its own
// action for the mouse-up, and ReleaseSlider sends another after tracking.
// Both look settled, so without this a release sets and saves twice, the
// second time with the readback brightMoved put on the slider.
- (BOOL)brightReleaseHandled {
  NSEvent *event = NSApp.currentEvent;
  if (event == nil || event.type != NSEventTypeLeftMouseUp) {
    return NO;
  }
  if (event.timestamp == self.brightReleaseTime) {
    return YES;
  }
  self.brightReleaseTime = event.timestamp;
  return NO;
}

- (void)brightMoved:(NSSlider *)slider {
  uint32_t display = (uint32_t)slider.tag;
  if ((sliderSettled() || !self.menuOpen) && [self brightReleaseHandled]) {
    return;
  }
  long value = softwareDimPercent(display, (long)llround(slider.doubleValue));
  slider.doubleValue = value;
  for (DisplayRow *row in self.panel.displayRows) {
    if (row.display == display) {
      row.valueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", value];
      break;
    }
  }
  // The built-in (a ~10ms DisplayServices call) and a confirmed DDC external
  // (handed to the DDC worker, which keeps only the newest value) follow the
  // knob live. Others still set once on release (ReleaseSlider sends that
  // action after mouse-up). Ticks are held; the release saves once. Once
  // the menu has closed, menuDidClose has ended the drag, so a late action
  // ends it too rather than holding a value nothing would save.
  if (!sliderSettled() && self.menuOpen) {
    self.panel.trackingDisplay = display;
    if (CGDisplayIsBuiltin(display) || ddcReady(display)) {
      holdBrightnessTick(display, value);
    }
    return;
  }
  self.panel.trackingDisplay = 0;
  if (!endBrightnessDrag(display, value)) {
    [self refresh];
    return;
  }
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
    notifyPlain(@"Allow Nightshift in Login Items");
  }
  [self syncLoginItem];
  [self refresh];
}

- (void)quitApp:(id)sender {
  teardownDaemon();
  [NSApp terminate:sender];
}

- (void)toggleCycle:(id)sender {
  (void)sender;
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
  [gMenu syncStatusItem];
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
          notifyPlain(err);
        }
      }
    }
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  teardownDaemon();
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
// Monitor clients only watch HID events; they can't filter or take them.
static const int kIOHIDEventSystemClientTypeMonitor = 1;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator,
                                                                      int type,
                                                                      CFDictionaryRef attributes);
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
static uint32_t gBlackCursorDisplays[8];
static int gBlackCursorCount = 0;
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

static BOOL blackCursorHas(uint32_t display) {
  for (int i = 0; i < gBlackCursorCount; i++) {
    if (gBlackCursorDisplays[i] == display) {
      return YES;
    }
  }
  return NO;
}

static void blackCursorAdd(uint32_t display) {
  if (display == 0 || blackCursorHas(display) || gBlackCursorCount >= 8) {
    return;
  }
  gBlackCursorDisplays[gBlackCursorCount++] = display;
}

static void blackCursorRemove(uint32_t display) {
  for (int i = 0; i < gBlackCursorCount; i++) {
    if (gBlackCursorDisplays[i] != display) {
      continue;
    }
    gBlackCursorCount--;
    gBlackCursorDisplays[i] = gBlackCursorDisplays[gBlackCursorCount];
    gBlackCursorDisplays[gBlackCursorCount] = 0;
    return;
  }
}

static BOOL displayIsBlack(uint32_t display) {
  return blackCursorHas(display) && !CGDisplayIsBuiltin(display) && readPercent(display) == 0;
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
  if (gBlackCursorCount == 0 && gCursorHiddenDisplay == 0) {
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
  if (gBlackCursorCount != 0 || gCursorHiddenDisplay != 0) {
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
    blackCursorAdd(display);
    watchCursor();
    cancelCursorHide();
    if (displayUnderPointer() == display) {
      hideCursorOn(display);
    }
    return;
  }
  blackCursorRemove(display);
  if (gCursorHiddenDisplay == display) {
    cancelCursorHide();
    showHiddenCursor();
  }
}

static BOOL cursorDisplayOnline(uint32_t display) {
  for (NSScreen *screen in NSScreen.screens) {
    if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) {
      return YES;
    }
  }
  return NO;
}

static void noteCursorDisplaysOffline(void) {
  if (gBlackCursorCount == 0 && gCursorHiddenDisplay == 0) {
    return;
  }
  for (int i = gBlackCursorCount - 1; i >= 0; i--) {
    uint32_t display = gBlackCursorDisplays[i];
    if (cursorDisplayOnline(display)) {
      continue;
    }
    blackCursorRemove(display);
    if (gCursorHiddenDisplay == display) {
      cancelCursorHide();
      showHiddenCursor();
    }
  }
  if (gCursorHiddenDisplay != 0 && !cursorDisplayOnline(gCursorHiddenDisplay)) {
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
  return nsSteppedPercent(percent, direction, stops);
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
  refreshKeyDisplays();
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
    bool down = false;
    int direction = nsMediaBrightnessKey((long)key.data1, &down);
    return down ? direction : 0;
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

// Finding 5: the key tap is an active filter on every key-down in the
// session, so it runs on its own thread and never waits on the main one.
// Whether to swallow a brightness key is decided from this copy of the
// displays the main thread can step (readPercent works, or a DDC probe is
// pending), refreshed on main by refreshKeyDisplays.
static pthread_mutex_t gKeyLock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gKeyDisplays[16];
static int gKeyDisplayCount = 0;
static CFRunLoopRef gTapRunLoop = NULL;

static void refreshKeyDisplays(void) {
  uint32_t ids[16];
  int count = orderedDisplays(ids, 16);
  uint32_t handled[16];
  int kept = 0;
  for (int i = 0; i < count; i++) {
    if (readPercent(ids[i]) >= 0 || ddcPending(ids[i])) {
      handled[kept++] = ids[i];
    }
  }
  pthread_mutex_lock(&gKeyLock);
  memcpy(gKeyDisplays, handled, sizeof(handled[0]) * (size_t)kept);
  gKeyDisplayCount = kept;
  pthread_mutex_unlock(&gKeyLock);
}

// Main thread. N5: a display whose step just failed stays out of the list
// until the next refresh finds it working.
static void dropKeyDisplay(uint32_t display) {
  pthread_mutex_lock(&gKeyLock);
  for (int i = 0; i < gKeyDisplayCount; i++) {
    if (gKeyDisplays[i] == display) {
      gKeyDisplays[i] = gKeyDisplays[--gKeyDisplayCount];
      break;
    }
  }
  pthread_mutex_unlock(&gKeyLock);
}

// Marks a key the tap swallowed and then handed back, so the taps let it
// through the second time.
static const int64_t kKeyReposted = 0x4e53686b;  // "NShk"

// Tap thread: a brightness press the taps swallowed, so its release is
// swallowed too. Cleared on main whenever the taps are (re-)created.
static BOOL gSwallowedPress[2];
// Set by the tap thread when a disabled notice is queued for main.
static atomic_bool gTapDisabledPending;
static void handleTapsDisabled(void);

// Tap thread. Whether the display under the event is one the main thread
// can step; display is set to it either way.
static BOOL keyDisplayHandled(CGEventRef event, uint32_t *displayOut) {
  CGDirectDisplayID display = 0;
  uint32_t found = 0;
  *displayOut = 0;
  if (CGGetDisplaysWithPoint(CGEventGetLocation(event), 1, &display, &found) != kCGErrorSuccess ||
      found == 0) {
    return NO;
  }
  *displayOut = display;
  BOOL handled = NO;
  pthread_mutex_lock(&gKeyLock);
  for (int i = 0; i < gKeyDisplayCount; i++) {
    if (gKeyDisplays[i] == display) {
      handled = YES;
      break;
    }
  }
  pthread_mutex_unlock(&gKeyLock);
  return handled;
}

// Main thread. Steps for a key the tap swallowed. When the step fails (a
// stale list, a write error, a slot just demoted) the display is dropped
// from the list and the key goes back to macOS, as if never tapped.
static void deliverTappedKey(int direction, uint32_t display, CGEventRef copy) {
  if (!deliverBrightness(direction)) {
    refreshKeyDisplays();
    dropKeyDisplay(display);
    if (copy != NULL) {
      CGEventSetIntegerValueField(copy, kCGEventSourceUserData, kKeyReposted);
      CGEventPost(kCGHIDEventTap, copy);
    }
  }
  if (copy != NULL) {
    CFRelease(copy);
  }
}

// Tap thread. Only system-defined (media) events reach the tap; plain
// key-downs 144/145 come in as hotkeys instead.
static int tapDirection(CGEventType type, CGEventRef event) {
  if (type != (CGEventType)NSEventTypeSystemDefined) {
    return 0;
  }
  NSEvent *key = [NSEvent eventWithCGEvent:event];
  return key == nil ? 0 : brightnessDirection(key);
}

static CGEventRef brightnessKey(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *user) {
  (void)proxy;
  (void)user;
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    // Never re-enabled here: when Accessibility is revoked, macOS disables
    // the taps and an immediate re-enable loops with it. The main thread
    // decides, once for all taps, with backoff.
    if (!atomic_exchange(&gTapDisabledPending, true)) {
      dispatch_async(dispatch_get_main_queue(), ^{
        handleTapsDisabled();
      });
    }
    return event;
  }
  @autoreleasepool {
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kKeyReposted) {
      return event;
    }
    // A brightness key whose press was swallowed has its release swallowed
    // too, so nothing downstream sees a release without a press. Every
    // other key, volume and mute included, goes back untouched.
    if (type == (CGEventType)NSEventTypeSystemDefined) {
      NSEvent *key = [NSEvent eventWithCGEvent:event];
      bool down = false;
      int brightness = key.subtype == 8 ? nsMediaBrightnessKey((long)key.data1, &down) : 0;
      if (brightness != 0 && !down) {
        BOOL *pressed = &gSwallowedPress[brightness > 0];
        BOOL swallow = *pressed;
        *pressed = NO;
        return swallow ? NULL : event;
      }
    }
    int direction = tapDirection(type, event);
    uint32_t display = 0;
    if (direction == 0 || !keyDisplayHandled(event, &display)) {
      return event;
    }
    gSwallowedPress[direction > 0] = YES;
    // Guards against a press delivered twice; only the first one steps.
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last >= 0.02) {
      last = now;
      // N5: swallowed on the strength of the cached list, so keep a copy to
      // hand back to macOS if the step fails.
      CGEventRef copy = CGEventCreateCopy(event);
      dispatch_async(dispatch_get_main_queue(), ^{
        deliverTappedKey(direction, display, copy);
      });
    }
    return NULL;
  }
}

// The run loop the key taps run on, started once.
static CFRunLoopRef tapRunLoop(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
      gTapRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
      // Keeps CFRunLoopRun from returning before the first tap is added.
      CFRunLoopTimerRef keep = CFRunLoopTimerCreateWithHandler(
          kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
          ^(CFRunLoopTimerRef timer) {
            (void)timer;
          });
      CFRunLoopAddTimer(gTapRunLoop, keep, kCFRunLoopCommonModes);
      CFRelease(keep);
      dispatch_semaphore_signal(ready);
      while (YES) {
        CFRunLoopRun();
      }
    }];
    thread.name = @"nightshift.keys";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
  });
  return gTapRunLoop;
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
  IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(
      kCFAllocatorDefault, kIOHIDEventSystemClientTypeMonitor, NULL);
  if (client == NULL) {
    return;
  }
  IOHIDEventSystemClientRegisterEventCallback(client, hidBrightness, NULL, NULL);
  IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(),
                                            kCFRunLoopCommonModes);
}

static void startBrightnessKeys(void);

// Main thread. Disables, invalidates and releases the key taps; their run
// loop sources go with the invalidated ports.
static void removeBrightnessTaps(void) {
  for (int i = 0; i < gBrightnessTapCount; i++) {
    if (gBrightnessTaps[i] != NULL) {
      CGEventTapEnable(gBrightnessTaps[i], false);
      CFMachPortInvalidate(gBrightnessTaps[i]);
      CFRelease(gBrightnessTaps[i]);
      gBrightnessTaps[i] = NULL;
    }
  }
  gBrightnessTapCount = 0;
}

// Main thread. At most one pending retry of startBrightnessKeys.
static BOOL gTapRetryScheduled = NO;
static void scheduleTapRetry(double delay) {
  if (gTapRetryScheduled) {
    return;
  }
  gTapRetryScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   gTapRetryScheduled = NO;
                   startBrightnessKeys();
                 });
}

// Main thread. Drops the taps so installBrightnessTap can re-create them,
// and lets the permission poll do that once Accessibility is back.
static void dropTapsAndRetry(void) {
  removeBrightnessTaps();
  atomic_store(&gTapDisabledPending, false);
  if (gMenu != nil) {
    [gMenu refresh];
  }
  gTapTries = 0;
  scheduleTapRetry(nsTapRetryDelay(0));
}

// Main thread, once per burst of disabled notices.
static void handleTapsDisabled(void) {
  static CFAbsoluteTime windowStart = 0;
  static int recent = 0;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now - windowStart > 60) {
    windowStart = now;
    recent = 0;
  }
  recent++;
  double delay = nsTapRecoveryDelay(AXIsProcessTrusted(), recent);
  if (delay < 0) {
    dropTapsAndRetry();
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!AXIsProcessTrusted()) {
                     // Revoked during the wait: disabled taps left in place
                     // would block installBrightnessTap for good.
                     dropTapsAndRetry();
                     return;
                   }
                   for (int i = 0; i < gBrightnessTapCount; i++) {
                     CGEventTapEnable(gBrightnessTaps[i], true);
                   }
                   atomic_store(&gTapDisabledPending, false);
                 });
}

static BOOL installBrightnessTap(void) {
  if (gBrightnessTapCount > 0) {
    return YES;
  }
  gSwallowedPress[0] = gSwallowedPress[1] = NO;
  // System-defined events only. A key-down bit here would make every tap
  // an active filter on everything typed, passwords included.
  CGEventMask mask = CGEventMaskBit(NSEventTypeSystemDefined);
  // One Session tap. An active Annotated Session tap breaks the volume and
  // mute keys even when it hands their events back untouched, and the HID
  // tap adds nothing the Session tap misses (measured Oct 14, 2026).
  CGEventTapLocation places[1] = {kCGSessionEventTap};
  refreshKeyDisplays();
  CFRunLoopRef loop = tapRunLoop();
  for (int i = 0; i < 1; i++) {
    CFMachPortRef tap = CGEventTapCreate(places[i], kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault, mask, brightnessKey,
                                         NULL);
    if (tap == NULL) {
      continue;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    gBrightnessTaps[gBrightnessTapCount++] = tap;
    CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(tap, true);
  }
  CFRunLoopWakeUp(loop);
  return gBrightnessTapCount > 0;
}

// Main thread. Key codes 144/145 (brightness on keyboards that send them as
// plain keys) as hotkeys, so macOS reports only these two to Nightshift.
static OSStatus brightnessHotKey(EventHandlerCallRef next, EventRef event, void *user) {
  (void)next;
  (void)user;
  EventHotKeyID hotKey;
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                        sizeof(hotKey), NULL, &hotKey) != noErr) {
    return eventNotHandledErr;
  }
  deliverBrightness(hotKey.id == 1 ? 1 : -1);
  return noErr;
}

static void registerBrightnessHotKeys(void) {
  EventTypeSpec pressed = {kEventClassKeyboard, kEventHotKeyPressed};
  InstallApplicationEventHandler(brightnessHotKey, 1, &pressed, NULL, NULL);
  const UInt32 codes[2] = {144, 145};
  for (UInt32 i = 0; i < 2; i++) {
    EventHotKeyRef ref = NULL;
    EventHotKeyID hotKey = {'NShk', i + 1};
    if (RegisterEventHotKey(codes[i], 0, hotKey, GetApplicationEventTarget(), 0, &ref) != noErr) {
      NSLog(@"nightshift: brightness hotkey %u not registered", (unsigned)codes[i]);
    }
  }
}

static void startBrightnessKeys(void) {
  if (!gHIDWatching) {
    gHIDWatching = YES;
    watchHIDBrightness();
    registerBrightnessHotKeys();
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
    notifyPlain(@"Allow Nightshift in Accessibility to use the brightness keys");
  }
  // Never gives up: 2 s for about a minute, then every 30 s.
  double retry = nsTapRetryDelay(gTapTries);
  if (gTapTries < 30) {
    gTapTries++;
  }
  scheduleTapRetry(retry);
}

// Main thread. Re-reads every DDC channel, the confirmed ones included, as
// soon as the queue is free.
static void ddcRevalidate(void) {
  gDDCRevalidate = YES;
  gDDCLast = 0;
  probeDDC();
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
                // Finding 4: drop slots for displays that left now, even
                // when the probe below is throttled or busy, and re-read
                // the ones that stayed, since a quick replug can keep the
                // display ID with a new service behind it.
                forgetOfflineDisplays();
                ddcRevalidate();
                refreshKeyDisplays();
              }];
  NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
  for (NSNotificationName name in @[ NSWorkspaceDidWakeNotification,
                                     NSWorkspaceScreensDidWakeNotification ]) {
    [workspace addObserverForName:name
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
                         (void)note;
                         gWokeAt = CFAbsoluteTimeGetCurrent();
                         // Finding 4: monitors may have power-cycled.
                         forgetOfflineDisplays();
                         ddcRevalidate();
                         refreshKeyDisplays();
                       }];
  }
  gMenu = [[MenuBar alloc] init];
  startBrightnessKeys();
  [gMenu refresh];
}

static char gSockPath[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void teardownDaemon(void) {
  static BOOL done = NO;
  if (done) {
    return;
  }
  done = YES;
  // A drag, or a release still waiting on its lamp write: the display shows
  // these values, so keep them rather than restore the old ones next launch.
  // Quit can't wait for the readback, so a pending release counts as landed.
  for (int i = 0; i < gHeldBrightness.count; i++) {
    noteBrightness(gHeldBrightness.display[i], gHeldBrightness.percent[i]);
  }
  gHeldBrightness.count = 0;
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display != 0 && gDDC[i].saveWaiting) {
      gDDC[i].saveWaiting = NO;
      noteBrightness(gDDC[i].display, gDDC[i].savePercent);
    }
    if (gDDC[i].display != 0 && gDDC[i].applyWaiting) {
      gDDC[i].applyWaiting = NO;
      noteBrightness(gDDC[i].display, gDDC[i].applyPercent);
    }
  }
  if (gShades != nil) {
    for (NSNumber *key in gShades.allKeys) {
      restoreGamma(key.unsignedIntValue);
      [gShades removeObjectForKey:key];
    }
  }
  gBlackCursorCount = 0;
  cancelCursorHide();
  showHiddenCursor();
  if (gSockPath[0] != '\0') {
    unlink(gSockPath);
    gSockPath[0] = '\0';
  }
  // Let a queued lamp write finish instead of exiting mid-transaction. A
  // probe can run long, so wait only a moment.
  dispatch_semaphore_t drained = dispatch_semaphore_create(0);
  dispatch_async(ddcQueue(), ^{
    dispatch_semaphore_signal(drained);
  });
  dispatch_semaphore_wait(drained,
                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)));
}

// Finding 12: SIGINT and SIGTERM (logout, launchctl, kill) run the same
// teardown as Quit, so held and pending brightness is saved and the shades
// and cursor are put back. Handled on the main queue through dispatch
// sources, not in a signal handler, so teardown may use Cocoa.
static dispatch_source_t gSignalSources[2];

static void watchStopSignals(void) {
  int signals[2] = {SIGINT, SIGTERM};
  for (int i = 0; i < 2; i++) {
    signal(signals[i], SIG_IGN);
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signals[i], 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
      teardownDaemon();
      exit(0);
    });
    dispatch_resume(source);
    gSignalSources[i] = source;
  }
}

// Finding 13: one daemon per user. The lock is taken before the socket is
// touched and held until exit (the kernel drops it if the process dies), so
// two daemons started together can't both unlink and bind the socket.
static int gInstanceLock = -1;

static BOOL holdInstanceLock(NSString *dir) {
  NSString *path = [dir stringByAppendingPathComponent:@"nightshiftd.lock"];
  int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR);
  if (fd < 0) {
    return NO;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return NO;
  }
  gInstanceLock = fd;
  return YES;
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
      sendBanner(pending, !gPendingPlain);
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
    if (!holdInstanceLock(dir)) {
      fprintf(stderr, "Night Shift is already running\n");
      return 1;
    }
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
    watchStopSignals();

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_main_queue());
    dispatch_source_set_timer(gTimer, dispatch_walltime(NULL, 0),
                              60 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gTimer, ^{
      rampTick();
      refreshMenu();
      refreshKeyDisplays();
    });
    dispatch_resume(gTimer);

    // Finding 5: accept and read off the main thread, so a client that
    // connects and stalls can't freeze the menu or the brightness keys.
    // Only the parsed line is handled on main. Connections are read one at
    // a time on this one serial queue: a stalled client holds it for at most
    // the 2 s read timeout, and waiting clients stay in the listen backlog
    // instead of each taking a thread.
    dispatch_queue_t socketQueue = dispatch_queue_create("nightshift.socket", DISPATCH_QUEUE_SERIAL);
    gListener = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)server, 0, socketQueue);
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
      int noSigPipe = 1;
      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
      struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
      setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
      char buf[128];
      if (!readMessage(connection, buf, sizeof(buf))) {
        dprintf(connection, "failed\n");
        close(connection);
        return;
      }
      char *line = strdup(buf);
      if (line == NULL) {
        close(connection);
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        gKeepConnection = NO;
        handleLine(line, connection);
        BOOL keep = gKeepConnection;
        gKeepConnection = NO;
        free(line);
        refreshMenu();
        if (gMenu != nil) {
          [gMenu syncLoginItem];
        }
        if (!keep) {
          close(connection);
        }
      });
    });
    dispatch_resume(gListener);
    installMenu();
    [NSApp run];
  }
  return 0;
}
