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
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#include <stdatomic.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSShortcut warmthShortcut(unsigned hotKeyID);
static NSShortcutState warmthKeyState(unsigned hotKeyID);
static void retryWarmthKeys(void);
static void pauseWarmthKeys(void);
static void resumeWarmthKeys(void);
static void startMenuWarmthKeys(void);
static void stopMenuWarmthKeys(void);
// How setWarmthShortcut went. Anything but saved leaves the old shortcut
// saved and in use.
typedef enum {
  kWarmthSetSaved = 0,
  kWarmthSetOtherKey,  // the other warmth key has it
  kWarmthSetSystem,    // a macOS shortcut
  kWarmthSetApp,       // another app's hotkey
  kWarmthSetFailed,    // any other registration error
  kWarmthSetNotSaved,  // the shortcuts file was not written
} WarmthSetResult;
static WarmthSetResult setWarmthShortcut(unsigned hotKeyID, NSShortcut shortcut);
static bool warmthShortcutUsable(const NSShortcut *shortcut, void *context);
static BOOL resetWarmthShortcuts(void);
static void teardownDaemon(void);
static void startWarmthKeys(void);
void notifyPlain(NSString *body);
BOOL selectorMatches(id object, SEL sel, const char *expected);
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
  return nsReadSavedNumber(gMaxPath.fileSystemRepresentation, 1, 100, value);
}

static BOOL writeMax(long value) {
  return nsWriteSavedNumber(gMaxPath.fileSystemRepresentation, value);
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
  long saved = 0;
  if (!nsReadSavedNumber(gRampPath.fileSystemRepresentation, 0, 1439, &saved)) {
    return NO;
  }
  *minute = (int)saved;
  return YES;
}

static BOOL rememberRampClock(int minute) {
  if (minute < 0 || minute >= 1440) {
    return NO;
  }
  if (!nsWriteSavedNumber(gRampPath.fileSystemRepresentation, minute)) {
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
  }
  // Replacing a delivered request with the same id only updates it in
  // Notification Center, with no banner. Remove it so the new one shows.
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center removeDeliveredNotificationsWithIdentifiers:@[ @"ramp" ]];
  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:@"ramp"
                                           content:content
                                           trigger:nil];
  [center
      addNotificationRequest:request
       withCompletionHandler:^(NSError *error) {
         if (error != nil) {
           fprintf(stderr, "notification failed: %s\n",
                   error.localizedDescription.UTF8String);
         }
       }];
}

// While the warmth keys are saving a value, banners wait here and only the
// last one is posted, once the keys have been let go for a moment.
static BOOL gBannerHoldoff = NO;
static NSString *gHeldBanner = nil;
static BOOL gHeldBannerControls = NO;

static void postBanner(NSString *body, BOOL controls) {
  if (gBannerHoldoff) {
    gHeldBanner = body;
    gHeldBannerControls = controls;
    return;
  }
  // A banner shown now replaces any warmth key banner still waiting, so an
  // older value never lands on top of a newer one.
  gHeldBanner = nil;
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
void notifyPlain(NSString *body) { postBanner(body, NO); }

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

void refreshMenu(void);
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
  // Unknown lines, the removed brightness, ddc and keys commands included,
  // get the same clean reply as a bad value.
  if (nsDaemonCommand(buf) == kNSCommandUnknown) {
    dprintf(fd, "failed\n");
    return;
  }
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

BOOL selectorMatches(id object, SEL sel, const char *expected) {
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

static BOOL loginItemOn(void) {
  return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}


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

void refreshMenu(void);

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

// Status menu layout, modelled on the stock Sound menu.
static const CGFloat kMenuWidth = 300;
static const CGFloat kMenuMargin = 14;
static const CGFloat kMenuContentWidth = 272;  // kMenuWidth - 2 * kMenuMargin

// Which menu sections are collapsed, one name per line, kept in the support
// folder next to max and full. A name for a section that no longer exists
// (the old "brightness") is dropped here and so gone after the next save.
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
    if (name.length > 0 && nsSectionKept(name.UTF8String)) {
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

// The Pro badge sits in the Ramp header and has its own click. That click
// opens Pro; the title and the chevron still collapse the section.
- (BOOL)clickHandledBySubview:(id)sender {
  if (![sender isKindOfClass:[NSClickGestureRecognizer class]] || self.superview == nil) {
    return NO;
  }
  NSClickGestureRecognizer *click = sender;
  NSPoint local = [click locationInView:self];
  NSView *hit = [self hitTest:[self convertPoint:local toView:self.superview]];
  for (NSView *view = hit; view != nil && view != self; view = view.superview) {
    for (NSGestureRecognizer *recognizer in view.gestureRecognizers) {
      if (recognizer != click && [recognizer isKindOfClass:[NSClickGestureRecognizer class]]) {
        return YES;
      }
    }
  }
  return NO;
}

- (void)clicked:(id)sender {
  if ([self clickHandledBySubview:sender]) {
    return;
  }
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
@property(nonatomic, strong) SectionHeader *rampHeader;
@property(nonatomic, strong) NSStackView *rampBody;
@property(nonatomic, strong) SectionHeader *fullRow;
@property(nonatomic, strong) NSTextField *fullTime;
@property(nonatomic) BOOL fullCollapsed;
// Called after any section opens or closes, so the menu can resize.
@property(nonatomic, copy) void (^sectionToggled)(void);
@property(nonatomic, strong) SectionHeader *appearanceHeader;
@property(nonatomic, strong) NSStackView *appearanceBody;
@property(nonatomic, strong) NSMutableSet<NSString *> *collapsedSections;
@property(nonatomic, strong) NSView *clockWell;
@property(nonatomic, strong) NSTextField *payLabel;
@property(nonatomic, strong) NSButton *payButton;
@property(nonatomic, strong) NSSegmentedControl *scheduleControl;
@property(nonatomic, strong) NSButton *darkSwitch;
@property(nonatomic, strong) NSButton *toneSwitch;
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

static BOOL openWorkspaceURL(NSString *text) {
  NSURL *page = rampWorkspaceURL(text);
  return page != nil && [[NSWorkspace sharedWorkspace] openURL:page];
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

  // Spacing: 10 between rows and under each title, 12 above and below each
  // divider, 14 side margins, as in the stock Sound menu.
  NSTextField *nightTitle = [self sectionLabel:@"Night Shift Intensity"];
  NSStackView *nightSection = menuSection(@[ nightTitle, nowRow, schedule ], 10);
  [nightSection setCustomSpacing:14 afterView:nowRow];

  // Max and Full at are the Pro ramp, so they share one section with one
  // PRO badge. Without Pro they show grayed out and the badge opens Pro.
  // The section collapses like Appearance. Full at keeps its
  // own disclosure while Ramp is open.
  PillView *rampPro = [[PillView alloc] initWithText:@"PRO"
                                              color:NSColor.controlAccentColor
                                              solid:YES];
  rampPro.toolTip = @"Unlock the ramp with Pro";
  rampPro.hidden = YES;
  [rampPro addGestureRecognizer:[[NSClickGestureRecognizer alloc]
                                    initWithTarget:self
                                            action:@selector(rampProClicked:)]];
  self.rampPro = rampPro;
  SectionHeader *rampHeader =
      [[SectionHeader alloc] initWithTitle:[self sectionLabel:@"Ramp"]
                                 accessory:rampPro
                            chevronLeading:NO];
  rampHeader.toggled = ^(SectionHeader *header) {
    [panel sectionHeaderToggled:header];
  };
  self.rampHeader = rampHeader;
  NSStackView *rampBody = menuSection(@[ pay, maxRow, buy, fullRow, clockWell ], 10);
  [rampBody setCustomSpacing:14 afterView:maxRow];
  [rampBody setCustomSpacing:14 afterView:buy];
  [rampBody setCustomSpacing:6 afterView:fullRow];
  self.rampBody = rampBody;
  NSStackView *rampSection = menuSection(@[ rampHeader, rampBody ], 10);

  self.collapsedSections = readCollapsedSections();
  BOOL rampClosed = [self.collapsedSections containsObject:@"ramp"];
  [rampHeader setCollapsed:rampClosed animated:NO];
  rampBody.hidden = rampClosed;

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

  BOOL appearanceClosed = [self.collapsedSections containsObject:@"appearance"];
  [appearanceHeader setCollapsed:appearanceClosed animated:NO];
  appearanceBody.hidden = appearanceClosed;

  NSStackView *stack = [NSStackView stackViewWithViews:@[
    nightSection, menuHairline(), rampSection, menuHairline(), appearanceSection
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
    NSString *name = nil;
    NSView *body = nil;
    if (header == self.rampHeader) {
      name = @"ramp";
      body = self.rampBody;
    } else if (header == self.appearanceHeader) {
      name = @"appearance";
      body = self.appearanceBody;
    }
    if (body != nil) {
      if (header.collapsed) {
        body.hidden = YES;
        [self.collapsedSections addObject:name];
      } else {
        [self revealBody:body];
        [self.collapsedSections removeObject:name];
      }
      writeCollapsedSections(self.collapsedSections);
    }
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
// Keyboard
@property(nonatomic, strong) NSArray<NSButton *> *shortcutButtons;
@property(nonatomic, strong) NSArray<DotView *> *shortcutDots;
@property(nonatomic, strong) NSArray<NSTextField *> *shortcutLabels;
@property(nonatomic) unsigned recordingID;  // 0, or the hotkey id being recorded
@property(nonatomic, copy) NSString *recordNote;
@property(nonatomic, strong) id recordMonitor;
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
- (int)fullAtMinute;
@end

// The top menu bar while Settings is open. There is deliberately no Quit
// here: quitting the daemon would drop warmth.
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
                          rows:@[ self.maxRow, self.fullAtRow ]
                        footer:@"On a Custom schedule, warmth starts low and climbs to Max over "
                               @"two hours, or by Full at. After Full at, it holds at Max."];
  // PHASE 2: a Ramp length row (popup: 1, 2, 3 hours) joins Evening Ramp, and
  // a "Tonight" section with the warmth-over-time chart goes here, between
  // Evening Ramp and the end of the page.
  return [self pageWithSections:@[ schedule, ramp ] stack:NULL];
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
  openWorkspaceURL(@"x-apple.systempreferences:com.apple.Displays-Settings."
                   @"extension?nightShift");
}

// MARK: Keyboard

- (NSView *)displaysPane {
  [self addWords:@"Keyboard"];
  [self addWords:@"Warmth keys"];
  [self addWords:@"Shortcuts"];

  NSString *titles[2] = {@"Lower Warmth", @"Raise Warmth"};
  NSString *captions[2] = {@"Steps Night Shift intensity down. Hold to keep stepping.",
                           @"Steps Night Shift intensity up. Hold to keep stepping."};
  NSMutableArray<NSView *> *rows = [NSMutableArray array];
  NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
  NSMutableArray<DotView *> *dots = [NSMutableArray array];
  NSMutableArray<NSTextField *> *labels = [NSMutableArray array];
  for (NSInteger i = 0; i < 2; i++) {
    DotView *dot = nil;
    NSTextField *label = nil;
    NSStackView *state = [self dot:&dot label:&label];
    NSButton *button = [self pushButton:@"" action:@selector(recordShortcut:)];
    button.tag = i + 1;
    [rows addObject:[self row:titles[i]
                      caption:captions[i]
                      control:[self hstack:@[ state, button ] spacing:10]]];
    [buttons addObject:button];
    [dots addObject:dot];
    [labels addObject:label];
  }
  self.shortcutButtons = buttons;
  self.shortcutDots = dots;
  self.shortcutLabels = labels;
  NSButton *reset = [self pushButton:@"Restore Defaults" action:@selector(resetShortcuts:)];
  [rows addObject:[self row:@"Defaults" caption:@"⌃⌥⌘− and ⌃⌥⌘=." control:reset]];
  NSView *keys = [self section:@"Keyboard"
                     accessory:nil
                          rows:rows
                        footer:@"Click a shortcut, then press the new keys. Esc cancels."];
  return [self pageWithSections:@[ keys ] stack:NULL];
}

- (void)syncDisplays {
  retryWarmthKeys();
  for (NSUInteger i = 0; i < self.shortcutButtons.count; i++) {
    unsigned hotKeyID = (unsigned)i + 1;
    BOOL recording = self.recordingID == hotKeyID;
    NSShortcut shortcut = warmthShortcut(hotKeyID);
    NSShortcutState state = warmthKeyState(hotKeyID);
    self.shortcutButtons[i].title =
        recording ? @"Type Shortcut…" : [NSString stringWithUTF8String:shortcut.name];
    DotView *dot = self.shortcutDots[i];
    if (recording) {
      dot.color = NSColor.controlAccentColor;
      self.shortcutLabels[i].stringValue = self.recordNote ?: @"Recording";
    } else {
      dot.color = state == kNSShortcutReady ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
      self.shortcutLabels[i].stringValue = [NSString stringWithUTF8String:nsShortcutStateLabel(state)];
    }
    dot.needsDisplay = YES;
  }
}

- (void)recordShortcut:(NSButton *)sender {
  unsigned hotKeyID = (unsigned)sender.tag;
  if (self.recordingID == hotKeyID) {
    [self stopRecording];
    return;
  }
  [self stopRecording];
  self.recordingID = hotKeyID;
  self.recordNote = nil;
  pauseWarmthKeys();
  __weak SettingsPanel *weakSelf = self;
  self.recordMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *event) {
                                     SettingsPanel *panel = weakSelf;
                                     if (panel == nil || panel.recordingID == 0) {
                                       return event;
                                     }
                                     return [panel recordKey:event] ? nil : event;
                                   }];
  [self syncDisplays];
}

// YES when the key press was used for recording. ⌘W and ⌘Q stop recording
// and go on to the app as usual. Any other refused key says why and, when
// one passes, which shortcut to try; recording goes on.
- (BOOL)recordKey:(NSEvent *)event {
  if (event.isARepeat) {
    return YES;
  }
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  unsigned modifiers = 0;
  if (flags & NSEventModifierFlagCommand) {
    modifiers |= cmdKey;
  }
  if (flags & NSEventModifierFlagShift) {
    modifiers |= shiftKey;
  }
  if (flags & NSEventModifierFlagOption) {
    modifiers |= optionKey;
  }
  if (flags & NSEventModifierFlagControl) {
    modifiers |= controlKey;
  }
  if (event.keyCode == kVK_Escape && modifiers == 0) {
    [self stopRecording];
    return YES;
  }
  if (modifiers == cmdKey && (event.keyCode == kVK_ANSI_W || event.keyCode == kVK_ANSI_Q)) {
    [self stopRecording];
    return NO;
  }
  unsigned keyCode = event.keyCode;
  NSString *key = event.charactersIgnoringModifiers.uppercaseString;
  const char *typed = key.UTF8String;
  if (!nsShortcutAllowed(keyCode, modifiers)) {
    char pressed[40];
    BOOL named = nsShortcutName(keyCode, modifiers, typed, pressed, sizeof pressed);
    BOOL loneCommand = (modifiers & (cmdKey | optionKey | controlKey)) == cmdKey;
    [self refuse:loneCommand && named ? kNSRefusalOtherApps : kNSRefusalModifiers
         pressed:named ? pressed : NULL
         keyCode:keyCode
       modifiers:modifiers
             key:typed];
    return YES;
  }
  NSShortcut shortcut;
  if (!nsShortcutMake(keyCode, modifiers, typed, &shortcut)) {
    [self refuse:kNSRefusalKey pressed:NULL keyCode:keyCode modifiers:modifiers key:typed];
    return YES;
  }
  NSShortcutRefusal why = kNSRefusalKey;
  switch (setWarmthShortcut(self.recordingID, shortcut)) {
    case kWarmthSetSaved:
      [self stopRecording];
      return YES;
    case kWarmthSetOtherKey: why = kNSRefusalOtherKey; break;
    case kWarmthSetSystem: why = kNSRefusalSystem; break;
    case kWarmthSetApp: why = kNSRefusalApp; break;
    case kWarmthSetFailed: why = kNSRefusalKey; break;
    case kWarmthSetNotSaved: why = kNSRefusalSave; break;
  }
  [self refuse:why pressed:shortcut.name keyCode:keyCode modifiers:modifiers key:typed];
  return YES;
}

// Says why a recorded key was refused, in place of the status, and goes on
// recording. A "Try" suggestion is offered only when it passes the same
// checks a recorded key does: the rule, the other key, macOS shortcuts and
// a trial registration.
- (void)refuse:(NSShortcutRefusal)why
       pressed:(const char *)pressed
       keyCode:(unsigned)keyCode
     modifiers:(unsigned)modifiers
           key:(const char *)key {
  NSShortcut suggestion;
  BOOL suggest = NO;
  if (why == kNSRefusalOtherApps || why == kNSRefusalModifiers || why == kNSRefusalSystem ||
      why == kNSRefusalApp) {
    NSShortcut other = warmthShortcut(self.recordingID == 1 ? 2 : 1);
    suggest = nsShortcutSuggest(keyCode, modifiers, key, &other, warmthShortcutUsable, NULL,
                                &suggestion);
  }
  char note[160];
  nsShortcutRefusal(why, pressed, suggest ? suggestion.name : NULL, note, sizeof note);
  self.recordNote = [NSString stringWithUTF8String:note];
  [self syncDisplays];
}

- (void)stopRecording {
  if (self.recordMonitor != nil) {
    [NSEvent removeMonitor:self.recordMonitor];
    self.recordMonitor = nil;
  }
  BOOL wasRecording = self.recordingID != 0;
  self.recordingID = 0;
  self.recordNote = nil;
  if (wasRecording) {
    resumeWarmthKeys();
    [self syncDisplays];
  }
}

- (void)resetShortcuts:(id)sender {
  (void)sender;
  [self stopRecording];
  if (!resetWarmthShortcuts()) {
    notifyPlain(@"Couldn't save the default warmth shortcuts.");
  }
  [self syncDisplays];
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
      [self captionLabel:@"Pro unlocks the evening ramp, Max and Full at. Warmth, Dark mode, "
                         @"and True Tone stay free."
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
  openWorkspaceURL(sender.identifier);
}

// MARK: Window

static NSString *paneTitle(NSInteger pane) {
  switch (pane) {
    case kPaneGeneral: return @"General";
    case kPaneNightShift: return @"Night Shift";
    case kPaneDisplays: return @"Keyboard";
    case kPaneLicense: return @"License";
    case kPaneAbout: return @"About";
    default: return @"";
  }
}

static NSString *paneSymbol(NSInteger pane) {
  switch (pane) {
    case kPaneGeneral: return @"gearshape.fill";
    case kPaneNightShift: return @"sun.horizon.fill";
    case kPaneDisplays: return @"keyboard";
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
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.contentViewController = split;
  [self.window setContentSize:NSMakeSize(kSettingsWidth, kSettingsHeight)];
  self.window.contentMinSize = NSMakeSize(kSettingsWidth, kSettingsHeight);
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
  [self stopRecording];
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
  [self stopRecording];
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  self.stayOpen = NO;
  gSettingsKeepsOpenForOtherApp = NO;
  [self stopRecording];
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
  openWorkspaceURL(@"x-apple.systempreferences:com.apple.Notifications-Settings.extension");
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
@property(nonatomic) NSTimeInterval settingsReleaseTime;
@property(nonatomic) BOOL settingsMaxTracking;
@property(nonatomic, copy) NSString *statusIconID;
// A held warmth hotkey's unsaved step, shown in the menu bar until release.
@property(nonatomic) BOOL holdTitleActive;
@property(nonatomic) long holdTitlePercent;
- (void)refresh;
- (void)syncLoginItem;
- (void)syncStatusItem;
// The Current slider. preview is a drag tick (shown, not saved). commit is
// the mouse-up: one applyWarmth, the same path nowMoved uses on release.
- (void)previewCurrentIntensity:(long)value;
- (void)commitCurrentIntensity:(long)value;
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
  retryWarmthKeys();
  [self refresh];
  [self armClockKeys];
  startMenuWarmthKeys();
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
  stopMenuWarmthKeys();
  self.menuOpen = NO;
  [self disarmClockKeys];
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
    if (self.holdTitleActive) {
      title = [NSString stringWithFormat:@"%ld%%", self.holdTitlePercent];
    } else if (warmthStatus(&now, &maxv, &state, &full)) {
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
    settings.loginSwitch.target = self;
    settings.loginSwitch.action = @selector(toggleLogin:);
    settings.cycleSwitch.target = self;
    settings.cycleSwitch.action = @selector(toggleCycle:);
    settings.warmthSwitch.target = self;
    settings.warmthSwitch.action = @selector(settingsWarmthToggled:);
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
      [menu syncLoginItem];
    };
    settings.needsSync = ^{
      MenuBar *strong = menu;
      if (strong != nil && !strong.settingsMaxTracking) {
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

// A mouse-up that already ended a Settings slider drag. NSSlider may send its
// own action for the mouse-up, and ReleaseSlider sends another after
// tracking; both look settled. The Settings sliders live outside the menu
// and so always settle on mouse-up.
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

- (void)previewCurrentIntensity:(long)value {
  if (value < 0) {
    value = 0;
  }
  if (value > 100) {
    value = 100;
  }
  if (self.panel != nil) {
    self.panel.nowSlider.doubleValue = value;
    self.panel.nowValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
    long saved = self.panel.savedMax;
    if ([self holdingFull] || (rampLicensed() && saved >= 1 && value > saved)) {
      [self.panel previewMax:value];
    } else if (saved >= 1) {
      [self.panel previewMax:saved];
    }
  }
  self.tracking = YES;
}

- (void)commitCurrentIntensity:(long)value {
  if (value < 0) {
    value = 0;
  }
  if (value > 100) {
    value = 100;
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

- (void)nowMoved:(NSSlider *)slider {
  long value = (long)llround(slider.doubleValue);
  if (!sliderSettled()) {
    [self previewCurrentIntensity:value];
    return;
  }
  [self commitCurrentIntensity:value];
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
      BOOL opened = page != nil && openWorkspaceURL(page.absoluteString);
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

@end

static MenuBar *gMenu = nil;

void refreshMenu(void) {
  if (gMenu == nil) {
    return;
  }
  [gMenu syncStatusItem];
  if (!gMenu.menuOpen) {
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

static BOOL gWarmthKeysStarted = NO;

// Two shortcuts, ⌃⌥⌘− and ⌃⌥⌘= unless changed in Settings, lower and
// raise Night Shift intensity. The value is the menu's Current slider. Nothing here changes display brightness.
//
// Both are Carbon RegisterEventHotKey hotkeys: no event tap, so no
// Accessibility permission, and a rebuild or re-sign cannot silently turn
// them off. A combo macOS (CopySymbolicHotKeys) or another app already owns
// is not registered: launch says which key and why with notifyPlain,
// Settings shows it per key, and the other key still works. Menu open and
// Settings try failed keys again, so a freed combo works without a relaunch.
//
// Carbon reports the chord once on press and once on release, with no
// repeat. The hold repeats on the main queue and only previews, the way
// the Current slider moves before mouse-up. Release calls
// commitCurrentIntensity, which is that slider's save.
_Static_assert(kNSHotKeyCommand == cmdKey, "Carbon cmdKey");
_Static_assert(kNSHotKeyOption == optionKey, "Carbon optionKey");
_Static_assert(kNSHotKeyShift == shiftKey, "Carbon shiftKey");
_Static_assert(kNSHotKeyControl == controlKey, "Carbon controlKey");
_Static_assert(kNSKeyCodeMinus == kVK_ANSI_Minus, "kVK_ANSI_Minus");
_Static_assert(kNSKeyCodeEqual == kVK_ANSI_Equal, "kVK_ANSI_Equal");
static EventHotKeyRef gCommandHotKeys[2];
static NSShortcut gWarmthShortcuts[2];
static NSShortcutState gWarmthKeyStates[2];
static BOOL gWarmthShortcutsLoaded = NO;
static BOOL gWarmthKeysPaused = NO;
static EventHandlerRef gCommandHotKeyHandler = NULL;
// While the menu is open its tracking holds the Carbon hotkey events until
// it closes, so the menu reads the keys on a timer and feeds the same
// press and release path. Times are GetCurrentEventTime's, so they compare
// with GetEventTime of the held events, which are then dropped.
static NSTimer *gMenuKeyTimer = nil;
static BOOL gMenuKeyHeld[2];
static EventTime gMenuKeysOpenedAt = -1;
static EventTime gMenuKeysClosedAt = -1;
static int gCommandHoldGeneration = 0;
static int gCommandHoldDirection = 0;
static long gCommandHoldPercent = -1;
static BOOL gCommandHoldDirty = NO;
// The held key, and whether its physical state could be read when pressed.
// If it could, a repeat that finds it up ends the hold (a lost key-up).
static unsigned gCommandHoldKeyCode = 0;
static BOOL gCommandHoldKeyReadable = NO;
static int gHeldBannerGeneration = 0;
static const double kHeldBannerDelay = 0.5;

static long commandWarmthNow(void) {
  long now = 0;
  long maxv = 0;
  const char *state = NULL;
  int full = -1;
  if (!warmthStatus(&now, &maxv, &state, &full)) {
    return -1;
  }
  return nsCommandWarmthNext(now, 0);
}

static void commandWarmthClearHold(void) {
  gCommandHoldDirection = 0;
  gCommandHoldPercent = -1;
  gCommandHoldDirty = NO;
  if (gMenu != nil) {
    gMenu.tracking = NO;
    gMenu.holdTitleActive = NO;
    [gMenu syncStatusItem];
  }
}

static void commandWarmthTick(BOOL release);

// Posts the last held banner once no warmth key is down, so quick taps and
// a hold give one banner with the final value.
static void scheduleHeldBanner(void) {
  int generation = ++gHeldBannerGeneration;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeldBannerDelay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (generation != gHeldBannerGeneration || gCommandHoldDirection != 0 ||
                       gHeldBanner == nil) {
                     return;
                   }
                   NSString *body = gHeldBanner;
                   gHeldBanner = nil;
                   postBanner(body, gHeldBannerControls);
                 });
}

static BOOL commandWarmthKeyDown(unsigned keyCode) {
  return CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)keyCode);
}

// Main thread. A repeat previews the next Current value. release saves it
// once, through the slider's mouse-up path, and does not take another step.
static void commandWarmthTick(BOOL release) {
  if (release) {
    gBannerHoldoff = YES;
    if (gCommandHoldDirty && gCommandHoldPercent >= 0 && gMenu != nil) {
      [gMenu commitCurrentIntensity:gCommandHoldPercent];
    }
    // A press that changed nothing, such as raise at 100%, still says
    // where warmth is.
    if (gHeldBanner == nil) {
      long now = commandWarmthNow();
      if (now >= 0) {
        reportWarmth(now);
      }
    }
    gBannerHoldoff = NO;
    commandWarmthClearHold();
    if (gHeldBanner != nil) {
      scheduleHeldBanner();
    }
    return;
  }
  if (gCommandHoldDirection == 0) {
    return;
  }
  if (gCommandHoldPercent < 0) {
    long now = commandWarmthNow();
    if (now < 0) {
      return;
    }
    gCommandHoldPercent = now;
  }
  long next = nsCommandWarmthNext(gCommandHoldPercent, gCommandHoldDirection);
  if (next == gCommandHoldPercent) {
    return;
  }
  gCommandHoldDirty = YES;
  gCommandHoldPercent = next;
  if (gMenu != nil) {
    [gMenu previewCurrentIntensity:next];
    gMenu.holdTitlePercent = next;
    gMenu.holdTitleActive = YES;
    [gMenu syncStatusItem];
  }
}

static void scheduleCommandWarmthRepeat(int generation, BOOL first) {
  NSTimeInterval seconds = first ? NSEvent.keyRepeatDelay : NSEvent.keyRepeatInterval;
  double gap = nsCommandWarmthRepeatGap(seconds);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (generation != gCommandHoldGeneration || gCommandHoldDirection == 0) {
                     return;
                   }
                   if (gCommandHoldKeyReadable && !commandWarmthKeyDown(gCommandHoldKeyCode)) {
                     gCommandHoldGeneration++;
                     commandWarmthTick(YES);
                     return;
                   }
                   commandWarmthTick(NO);
                   scheduleCommandWarmthRepeat(generation, NO);
                 });
}

static void commandWarmthHotKeyOnMain(UInt32 kind, EventHotKeyID hotKey) {
  int direction = nsCommandWarmthDirection(hotKey.id);
  if (direction == 0) {
    return;
  }
  if (kind == kEventHotKeyReleased) {
    if (direction != gCommandHoldDirection) {
      return;
    }
    gCommandHoldGeneration++;
    commandWarmthTick(YES);
    return;
  }
  if (kind != kEventHotKeyPressed) {
    return;
  }
  if (gCommandHoldDirection == direction) {
    return;
  }
  // tracking is also set by this hold's own previews; only a slider drag,
  // with no hold, keeps the keys out.
  if (gCommandHoldDirection == 0 && gMenu != nil && gMenu.tracking) {
    return;
  }
  if (gCommandHoldDirection != 0) {
    gCommandHoldGeneration++;
    commandWarmthTick(YES);
  }
  gCommandHoldDirection = direction;
  gCommandHoldKeyCode = warmthShortcut(hotKey.id).keyCode;
  gCommandHoldKeyReadable = commandWarmthKeyDown(gCommandHoldKeyCode);
  gCommandHoldGeneration++;
  int generation = gCommandHoldGeneration;
  commandWarmthTick(NO);
  scheduleCommandWarmthRepeat(generation, YES);
}

static OSStatus commandWarmthHotKey(EventHandlerCallRef next, EventRef event, void *user) {
  (void)next;
  (void)user;
  EventHotKeyID hotKey;
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKey),
                        NULL, &hotKey) != noErr) {
    return eventNotHandledErr;
  }
  if (hotKey.signature != 'NScm') {
    return eventNotHandledErr;
  }
  if (nsHotKeyDuringMenu(GetEventTime(event), gMenuKeysOpenedAt, gMenuKeysClosedAt)) {
    return noErr;
  }
  UInt32 kind = GetEventKind(event);
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      commandWarmthHotKeyOnMain(kind, hotKey);
    });
    return noErr;
  }
  commandWarmthHotKeyOnMain(kind, hotKey);
  return noErr;
}

static NSString *shortcutsPath(void) {
  return [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"]
      stringByAppendingPathComponent:@"shortcuts"];
}

// Set by a load that found a saved shortcut this build refuses.
static NSString *gRefusedShortcutsNotice = nil;

static void ensureWarmthShortcuts(void) {
  if (gWarmthShortcutsLoaded) {
    return;
  }
  gWarmthShortcutsLoaded = YES;
  NSString *text = [NSString stringWithContentsOfFile:shortcutsPath()
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  char refused[2][40];
  nsShortcutsParseRefused(text.UTF8String, gWarmthShortcuts, refused);
  char notice[200];
  nsShortcutDroppedNotice(refused[0], gWarmthShortcuts[0].name, refused[1],
                          gWarmthShortcuts[1].name, notice, sizeof notice);
  gRefusedShortcutsNotice = notice[0] != '\0' ? [NSString stringWithUTF8String:notice] : nil;
}

static void loadWarmthShortcuts(void) {
  gWarmthShortcutsLoaded = NO;
  ensureWarmthShortcuts();
}

static BOOL saveWarmthShortcuts(void) {
  char buf[256];
  int n = nsShortcutsFormat(gWarmthShortcuts, buf, sizeof buf);
  if (n < 0 || (size_t)n >= sizeof buf) {
    return NO;
  }
  NSString *path = shortcutsPath();
  [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700}
                                                  error:NULL];
  NSString *temp = [path stringByAppendingString:@".tmp"];
  NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
  if (![[NSFileManager defaultManager] createFileAtPath:temp
                                               contents:data
                                             attributes:@{NSFilePosixPermissions : @0600}]) {
    return NO;
  }
  if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
    unlink(temp.fileSystemRepresentation);
    return NO;
  }
  return YES;
}

// A saved shortcut this build refuses (a lone ⌃K, or ⌘⇧K from an older
// build) loads as its default. Say so once with notifyPlain, then save the
// file with what is in use, so the next launch is quiet. If that save
// fails, the next launch says it again.
static void noticeRefusedShortcuts(void) {
  if (gRefusedShortcutsNotice == nil) {
    return;
  }
  NSString *notice = gRefusedShortcutsNotice;
  gRefusedShortcutsNotice = nil;
  NSLog(@"%@", notice);
  notifyPlain(notice);
  if (!saveWarmthShortcuts()) {
    NSLog(@"Couldn't save the warmth shortcuts.");
  }
}

static NSShortcut warmthShortcut(unsigned hotKeyID) {
  ensureWarmthShortcuts();
  NSShortcut none = {0, 0, "", ""};
  return hotKeyID >= 1 && hotKeyID <= 2 ? gWarmthShortcuts[hotKeyID - 1] : none;
}

static unsigned heldWarmthModifiers(void) {
  CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
  unsigned held = 0;
  if (flags & kCGEventFlagMaskCommand) {
    held |= kNSHotKeyCommand;
  }
  if (flags & kCGEventFlagMaskShift) {
    held |= kNSHotKeyShift;
  }
  if (flags & kCGEventFlagMaskAlternate) {
    held |= kNSHotKeyOption;
  }
  if (flags & kCGEventFlagMaskControl) {
    held |= kNSHotKeyControl;
  }
  return held;
}

static BOOL menuWarmthKeyHeld(unsigned i, unsigned heldModifiers) {
  NSShortcut shortcut = warmthShortcut(i + 1);
  return nsShortcutHeld(shortcut.modifiers, commandWarmthKeyDown(shortcut.keyCode), heldModifiers);
}

static void pollMenuWarmthKeys(void) {
  unsigned held = heldWarmthModifiers();
  for (unsigned i = 0; i < 2; i++) {
    BOOL down = menuWarmthKeyHeld(i, held);
    if (down == gMenuKeyHeld[i]) {
      continue;
    }
    gMenuKeyHeld[i] = down;
    if (gCommandHotKeys[i] == NULL) {
      continue;
    }
    EventHotKeyID hotKey = {'NScm', i + 1};
    commandWarmthHotKeyOnMain(down ? kEventHotKeyPressed : kEventHotKeyReleased, hotKey);
  }
}

static void startMenuWarmthKeys(void) {
  [gMenuKeyTimer invalidate];
  gMenuKeysOpenedAt = GetCurrentEventTime();
  unsigned held = heldWarmthModifiers();
  for (unsigned i = 0; i < 2; i++) {
    gMenuKeyHeld[i] = menuWarmthKeyHeld(i, held);
  }
  gMenuKeyTimer = [NSTimer timerWithTimeInterval:0.008
                                         repeats:YES
                                           block:^(NSTimer *timer) {
                                             (void)timer;
                                             pollMenuWarmthKeys();
                                           }];
  [NSRunLoop.mainRunLoop addTimer:gMenuKeyTimer forMode:NSRunLoopCommonModes];
}

static void stopMenuWarmthKeys(void) {
  [gMenuKeyTimer invalidate];
  gMenuKeyTimer = nil;
  gMenuKeysClosedAt = GetCurrentEventTime();
}

static NSShortcutState warmthKeyState(unsigned hotKeyID) {
  return hotKeyID >= 1 && hotKeyID <= 2 ? gWarmthKeyStates[hotKeyID - 1] : kNSShortcutFailed;
}

// True when an enabled macOS shortcut (Mission Control, Spotlight, input
// sources...) uses this key and modifiers. Those win over an app's hotkey
// without RegisterEventHotKey saying so.
static BOOL systemShortcutTaken(NSShortcut shortcut) {
  CFArrayRef keys = NULL;
  if (CopySymbolicHotKeys(&keys) != noErr || keys == NULL) {
    return NO;
  }
  const UInt32 mask = cmdKey | shiftKey | optionKey | controlKey;
  BOOL taken = NO;
  for (CFIndex i = 0; i < CFArrayGetCount(keys) && !taken; i++) {
    CFDictionaryRef key = CFArrayGetValueAtIndex(keys, i);
    if (key == NULL || CFGetTypeID(key) != CFDictionaryGetTypeID()) {
      continue;
    }
    CFTypeRef enabled = CFDictionaryGetValue(key, kHISymbolicHotKeyEnabled);
    CFTypeRef code = CFDictionaryGetValue(key, kHISymbolicHotKeyCode);
    CFTypeRef mods = CFDictionaryGetValue(key, kHISymbolicHotKeyModifiers);
    if (enabled == NULL || CFGetTypeID(enabled) != CFBooleanGetTypeID() ||
        !CFBooleanGetValue(enabled) || code == NULL || CFGetTypeID(code) != CFNumberGetTypeID() ||
        mods == NULL || CFGetTypeID(mods) != CFNumberGetTypeID()) {
      continue;
    }
    SInt64 keyCode = -1;
    SInt64 modifiers = 0;
    CFNumberGetValue(code, kCFNumberSInt64Type, &keyCode);
    CFNumberGetValue(mods, kCFNumberSInt64Type, &modifiers);
    taken = keyCode == (SInt64)shortcut.keyCode && ((UInt32)modifiers & mask) == shortcut.modifiers;
  }
  CFRelease(keys);
  return taken;
}

// What registering shortcut would run into now, without keeping it: a macOS
// shortcut, another app's hotkey, or nothing. The trial has its own
// signature, which the hotkey handler ignores, and is released at once.
static NSShortcutState probeShortcut(NSShortcut shortcut) {
  if (systemShortcutTaken(shortcut)) {
    return kNSShortcutTakenBySystem;
  }
  EventHotKeyID trial = {'NStr', 1};
  EventHotKeyRef ref = NULL;
  OSStatus err = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, trial,
                                     GetApplicationEventTarget(), 0, &ref);
  if (err == noErr) {
    UnregisterEventHotKey(ref);
    return kNSShortcutReady;
  }
  return err == eventHotKeyExistsErr ? kNSShortcutTakenByApp : kNSShortcutFailed;
}

static bool warmthShortcutUsable(const NSShortcut *shortcut, void *context) {
  (void)context;
  return probeShortcut(*shortcut) == kNSShortcutReady;
}

static NSShortcutState registerWarmthKey(unsigned i) {
  if (gCommandHotKeys[i] != NULL) {
    return kNSShortcutReady;
  }
  NSShortcut shortcut = gWarmthShortcuts[i];
  if (systemShortcutTaken(shortcut)) {
    return kNSShortcutTakenBySystem;
  }
  EventHotKeyID hotKey = {'NScm', i + 1};
  EventHotKeyRef ref = NULL;
  OSStatus err = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKey,
                                     GetApplicationEventTarget(), 0, &ref);
  if (err == noErr) {
    gCommandHotKeys[i] = ref;
    return kNSShortcutReady;
  }
  return err == eventHotKeyExistsErr ? kNSShortcutTakenByApp : kNSShortcutFailed;
}

// Registers whichever keys are not registered yet. With notify, a key that
// newly fails says which key and why; Settings shows the rest.
static void registerWarmthKeys(BOOL notify) {
  if (gWarmthKeysPaused) {
    return;
  }
  ensureWarmthShortcuts();
  for (unsigned i = 0; i < 2; i++) {
    NSShortcutState before = gWarmthKeyStates[i];
    NSShortcutState now = registerWarmthKey(i);
    gWarmthKeyStates[i] = now;
    if (now != kNSShortcutReady && now != before) {
      char message[160];
      nsShortcutNotice(i + 1, gWarmthShortcuts[i].name, now, message, sizeof message);
      NSLog(@"%s", message);
      if (notify) {
        notifyPlain([NSString stringWithUTF8String:message]);
      }
    }
  }
}

// Releases key i so it can be registered again, as a new shortcut.
static void dropWarmthKey(unsigned i) {
  if (gCommandHotKeys[i] != NULL) {
    UnregisterEventHotKey(gCommandHotKeys[i]);
    gCommandHotKeys[i] = NULL;
  }
  gWarmthKeyStates[i] = kNSShortcutReady;
}

static void unregisterWarmthKeys(void) {
  gCommandHoldGeneration++;
  if (gCommandHoldDirection != 0) {
    commandWarmthTick(YES);
  }
  for (unsigned i = 0; i < 2; i++) {
    if (gCommandHotKeys[i] != NULL) {
      UnregisterEventHotKey(gCommandHotKeys[i]);
      gCommandHotKeys[i] = NULL;
    }
  }
}

static void registerCommandWarmthHotKeys(void) {
  if (gCommandHotKeyHandler != NULL) {
    return;
  }
  EventTypeSpec types[2] = {
      {kEventClassKeyboard, kEventHotKeyPressed},
      {kEventClassKeyboard, kEventHotKeyReleased},
  };
  EventHandlerRef handler = NULL;
  OSStatus err = InstallApplicationEventHandler(commandWarmthHotKey, 2, types, NULL, &handler);
  if (err != noErr) {
    NSLog(@"%d", (int)err);
    return;
  }
  gCommandHotKeyHandler = handler;
  loadWarmthShortcuts();
  noticeRefusedShortcuts();
  registerWarmthKeys(YES);
}

static void unregisterCommandWarmthHotKeys(void) {
  unregisterWarmthKeys();
  if (gCommandHotKeyHandler != NULL) {
    RemoveEventHandler(gCommandHotKeyHandler);
    gCommandHotKeyHandler = NULL;
  }
}

static void retryWarmthKeys(void) {
  if (gCommandHotKeyHandler != NULL) {
    registerWarmthKeys(NO);
  }
}

// Settings records a new shortcut with both released, so pressing the
// current one records it instead of changing warmth.
static void pauseWarmthKeys(void) {
  gWarmthKeysPaused = YES;
  unregisterWarmthKeys();
}

static void resumeWarmthKeys(void) {
  gWarmthKeysPaused = NO;
  retryWarmthKeys();
}

// Checks before it saves: a shortcut the other key has, a macOS shortcut,
// or one another app holds is refused with nothing changed, so the old
// shortcut stays saved and, outside recording, registered. The new hotkey
// is registered before the old one is released, so there is no moment with
// neither. While Settings records, both are paused; the new one stays
// registered and stopRecording's resume keeps it.
static WarmthSetResult setWarmthShortcut(unsigned hotKeyID, NSShortcut shortcut) {
  if (hotKeyID < 1 || hotKeyID > 2) {
    return kWarmthSetFailed;
  }
  ensureWarmthShortcuts();
  unsigned i = hotKeyID - 1;
  if (nsShortcutSame(&shortcut, &gWarmthShortcuts[1 - i])) {
    return kWarmthSetOtherKey;
  }
  if (systemShortcutTaken(shortcut)) {
    return kWarmthSetSystem;
  }
  EventHotKeyRef ref = NULL;
  if (!(nsShortcutSame(&shortcut, &gWarmthShortcuts[i]) && gCommandHotKeys[i] != NULL)) {
    EventHotKeyID hotKey = {'NScm', hotKeyID};
    OSStatus err = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKey,
                                       GetApplicationEventTarget(), 0, &ref);
    if (err != noErr) {
      return err == eventHotKeyExistsErr ? kWarmthSetApp : kWarmthSetFailed;
    }
  }
  NSShortcut old = gWarmthShortcuts[i];
  gWarmthShortcuts[i] = shortcut;
  if (!saveWarmthShortcuts()) {
    gWarmthShortcuts[i] = old;
    if (ref != NULL) {
      UnregisterEventHotKey(ref);
    }
    return kWarmthSetNotSaved;
  }
  if (ref != NULL) {
    if (gCommandHotKeys[i] != NULL) {
      UnregisterEventHotKey(gCommandHotKeys[i]);
    }
    gCommandHotKeys[i] = ref;
  }
  gWarmthKeyStates[i] = kNSShortcutReady;
  return kWarmthSetSaved;
}

static BOOL resetWarmthShortcuts(void) {
  ensureWarmthShortcuts();
  NSShortcut old[2] = {gWarmthShortcuts[0], gWarmthShortcuts[1]};
  nsShortcutDefault(1, &gWarmthShortcuts[0]);
  nsShortcutDefault(2, &gWarmthShortcuts[1]);
  if (!saveWarmthShortcuts()) {
    gWarmthShortcuts[0] = old[0];
    gWarmthShortcuts[1] = old[1];
    return NO;
  }
  dropWarmthKey(0);
  dropWarmthKey(1);
  retryWarmthKeys();
  return YES;
}

static void startWarmthKeys(void) {
  if (gWarmthKeysStarted) {
    return;
  }
  gWarmthKeysStarted = YES;
  registerCommandWarmthHotKeys();
  if (gMenu != nil) {
    [gMenu refresh];
  }
}

static void installMenu(void) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  gAppDelegate = [[AppDelegate alloc] init];
  NSApp.delegate = gAppDelegate;
  gMenu = [[MenuBar alloc] init];
  startWarmthKeys();
  [gMenu refresh];
}

static char gSockPath[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void teardownDaemon(void) {
  static BOOL done = NO;
  if (done) {
    return;
  }
  done = YES;
  unregisterCommandWarmthHotKeys();
  if (gSockPath[0] != '\0') {
    unlink(gSockPath);
    gSockPath[0] = '\0';
  }
}

// Finding 12: SIGINT and SIGTERM (logout, launchctl, kill) run the same
// teardown as Quit, so a held warmth key is saved and the socket is
// removed. Handled on the main queue through dispatch
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
    });
    dispatch_resume(gTimer);

    // Finding 5: accept and read off the main thread, so a client that
    // connects and stalls can't freeze the menu or the warmth keys.
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
        handleLine(line, connection);
        free(line);
        refreshMenu();
        if (gMenu != nil) {
          [gMenu syncLoginItem];
        }
        close(connection);
      });
    });
    dispatch_resume(gListener);
    installMenu();
    [NSApp run];
  }
  return 0;
}
