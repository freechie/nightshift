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
#import <UserNotifications/UserNotifications.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
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
  if (gRampClock >= 0) {
    fprintf(stderr, "saved full-at is outside this schedule, using two hours\n");
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

static void rampTick(void) {
  BLStatus status;
  if (!readStatus(gClient, &status)) {
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
  }

  if (!inside) {
    clearRamp();
    int untilStart = minutesBetween(now, start);
    if (!status.enabled && untilStart >= 1 && untilStart <= kArmMinutes &&
        gArmedStart != start && stageStrength(gClient, 1)) {
      gArmedStart = start;
    }
    if (gLaunched && !status.enabled) {
      if (gSeenWarmth != 0) {
        reportWarmth(0);
      }
    } else if (gLaunched) {
      long current = 0;
      if (readStrength(gClient, &current) && current != gSeenWarmth) {
        reportWarmth(current);
      }
    }
    return;
  }

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

static NSString *currentSentence(void) {
  long now = 0;
  long maxv = 0;
  const char *state = "idle";
  int full = -1;
  if (!warmthStatus(&now, &maxv, &state, &full)) {
    return @"Night Shift is unavailable";
  }
  return warmthSentence(now, maxv, state, full);
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

static NSArray<NSString *> *numberLabels(int start, int count, BOOL pad) {
  NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:count];
  for (int i = 0; i < count; i++) {
    int value = start + i;
    [labels addObject:pad ? [NSString stringWithFormat:@"%02d", value]
                          : [NSString stringWithFormat:@"%d", value]];
  }
  return labels;
}

@interface WheelColumn : NSView
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic) NSInteger index;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) BOOL wraps;
@property(nonatomic) CGFloat carry;
@property(nonatomic) CGFloat dragStart;
@property(nonatomic) NSInteger dragIndex;
@property(nonatomic, copy) void (^changed)(WheelColumn *column);
@end

@implementation WheelColumn
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self == nil) {
    return nil;
  }
  self.enabled = YES;
  self.wraps = YES;
  self.clipsToBounds = YES;
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(72, 76);
}

- (NSInteger)wrap:(NSInteger)value {
  NSInteger count = (NSInteger)self.labels.count;
  if (count <= 0) {
    return 0;
  }
  if (!self.wraps) {
    if (value < 0) {
      return 0;
    }
    if (value >= count) {
      return count - 1;
    }
    return value;
  }
  NSInteger wrapped = value % count;
  if (wrapped < 0) {
    wrapped += count;
  }
  return wrapped;
}

- (NSString *)labelAt:(NSInteger)offset {
  if (self.labels.count == 0) {
    return @"";
  }
  NSInteger index = self.index + offset;
  if (!self.wraps && (index < 0 || index >= (NSInteger)self.labels.count)) {
    return @"";
  }
  return self.labels[[self wrap:index]];
}

- (void)setIndex:(NSInteger)index {
  _index = [self wrap:index];
  self.needsDisplay = YES;
}

- (void)setLabels:(NSArray<NSString *> *)labels {
  _labels = [labels copy];
  _index = [self wrap:_index];
  self.needsDisplay = YES;
}

- (void)step:(NSInteger)delta {
  if (!self.enabled || self.labels.count == 0 || delta == 0) {
    return;
  }
  NSInteger next = self.index + delta;
  if (!self.wraps && (next < 0 || next >= (NSInteger)self.labels.count)) {
    return;
  }
  self.index = next;
  if (self.changed != nil) {
    self.changed(self);
  }
}

- (void)scrollWheel:(NSEvent *)event {
  if (!self.enabled) {
    return;
  }
  self.carry += event.scrollingDeltaY;
  while (self.carry > 24) {
    self.carry -= 24;
    [self step:-1];
  }
  while (self.carry < -24) {
    self.carry += 24;
    [self step:1];
  }
}

- (void)mouseDown:(NSEvent *)event {
  self.dragStart = [self convertPoint:event.locationInWindow fromView:nil].y;
  self.dragIndex = self.index;
}

- (void)mouseDragged:(NSEvent *)event {
  if (!self.enabled) {
    return;
  }
  CGFloat y = [self convertPoint:event.locationInWindow fromView:nil].y;
  NSInteger steps = (NSInteger)llround((y - self.dragStart) / 22.0);
  NSInteger next = [self wrap:self.dragIndex - steps];
  if (next == self.index) {
    return;
  }
  self.index = next;
  if (self.changed != nil) {
    self.changed(self);
  }
}

- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  NSRect bounds = self.bounds;
  NSRect band = NSMakeRect(2, NSMidY(bounds) - 12, bounds.size.width - 4, 24);
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:band
                                                        xRadius:6
                                                        yRadius:6];
  [[NSColor.quaternaryLabelColor colorWithAlphaComponent:0.45] setFill];
  [path fill];
  NSDictionary *centerAttrs = @{
    NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:16
                                                            weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : NSColor.labelColor,
  };
  NSDictionary *sideAttrs = @{
    NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:13
                                                           weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
  };
  CGFloat mid = NSMidY(bounds);
  [self drawText:[self labelAt:0] centerY:mid attributes:centerAttrs];
  [self drawText:[self labelAt:-1] centerY:mid - 22 attributes:sideAttrs];
  [self drawText:[self labelAt:1] centerY:mid + 22 attributes:sideAttrs];
}

- (void)drawText:(NSString *)text
         centerY:(CGFloat)centerY
      attributes:(NSDictionary *)attributes {
  NSSize size = [text sizeWithAttributes:attributes];
  NSPoint origin = NSMakePoint(NSMidX(self.bounds) - size.width / 2,
                               centerY - size.height / 2);
  [text drawAtPoint:origin withAttributes:attributes];
}
@end

@interface StatusPanel : NSViewController
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSSlider *nowSlider;
@property(nonatomic, strong) NSSlider *maxSlider;
@property(nonatomic, strong) NSTextField *nowValue;
@property(nonatomic, strong) NSTextField *maxValue;
@property(nonatomic) long savedMax;
@property(nonatomic, strong) WheelColumn *hourWheel;
@property(nonatomic, strong) WheelColumn *minuteWheel;
@property(nonatomic, strong) WheelColumn *ampmWheel;
@property(nonatomic, strong) NSButton *cycleSwitch;
@property(nonatomic, strong) NSStackView *wheels;
- (void)setSentence:(NSString *)sentence;
- (void)syncSliders;
- (void)syncWheels;
- (void)previewMax:(long)value;
- (int)clockMinute;
@end

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

- (NSStackView *)sliderRowTitled:(NSString *)title
                          slider:(NSSlider *)slider
                           value:(NSTextField *)value {
  NSTextField *name = [NSTextField labelWithString:title];
  name.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  [name setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name.widthAnchor constraintEqualToConstant:36].active = YES;
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
  NSTextField *label = [NSTextField wrappingLabelWithString:@"Nightshift"];
  label.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
  label.preferredMaxLayoutWidth = 248;
  self.label = label;

  self.nowSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:100 target:nil action:NULL];
  self.maxSlider = [NSSlider sliderWithValue:1 minValue:1 maxValue:100 target:nil action:NULL];
  self.nowSlider.continuous = YES;
  self.maxSlider.continuous = YES;
  self.nowSlider.accessibilityLabel = @"Warmth";
  self.maxSlider.accessibilityLabel = @"Max";
  self.nowValue = [self valueLabel];
  self.maxValue = [self valueLabel];

  self.hourWheel = [[WheelColumn alloc] initWithFrame:NSZeroRect];
  self.minuteWheel = [[WheelColumn alloc] initWithFrame:NSZeroRect];
  self.ampmWheel = [[WheelColumn alloc] initWithFrame:NSZeroRect];
  self.hourWheel.accessibilityLabel = @"Hour";
  self.minuteWheel.accessibilityLabel = @"Minute";
  self.ampmWheel.accessibilityLabel = @"AM or PM";
  self.ampmWheel.wraps = NO;
  self.cycleSwitch = [NSButton checkboxWithTitle:@"24-hour" target:nil action:NULL];
  self.cycleSwitch.controlSize = NSControlSizeSmall;
  self.cycleSwitch.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

  NSTextField *fullTitle = [self sectionLabel:@"Full at"];
  NSBox *rule = [[NSBox alloc] initWithFrame:NSZeroRect];
  rule.boxType = NSBoxSeparator;
  rule.translatesAutoresizingMaskIntoConstraints = NO;
  [rule.widthAnchor constraintEqualToConstant:248].active = YES;

  self.wheels = [NSStackView stackViewWithViews:@[
    self.hourWheel, self.minuteWheel, self.ampmWheel
  ]];
  self.wheels.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.wheels.spacing = 8;
  self.wheels.alignment = NSLayoutAttributeCenterY;
  self.wheels.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *wheelWell = [[NSView alloc] initWithFrame:NSZeroRect];
  [wheelWell.widthAnchor constraintEqualToConstant:248].active = YES;
  [wheelWell addSubview:self.wheels];
  [NSLayoutConstraint activateConstraints:@[
    [self.wheels.centerXAnchor constraintEqualToAnchor:wheelWell.centerXAnchor],
    [self.wheels.topAnchor constraintEqualToAnchor:wheelWell.topAnchor],
    [self.wheels.bottomAnchor constraintEqualToAnchor:wheelWell.bottomAnchor],
  ]];

  NSStackView *cycleRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
  cycleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  [cycleRow.widthAnchor constraintEqualToConstant:248].active = YES;
  [cycleRow addView:self.cycleSwitch inGravity:NSStackViewGravityCenter];

  NSStackView *nowRow =
      [self sliderRowTitled:@"Now" slider:self.nowSlider value:self.nowValue];
  NSStackView *maxRow =
      [self sliderRowTitled:@"Max" slider:self.maxSlider value:self.maxValue];
  NSStackView *stack = [NSStackView stackViewWithViews:@[
    label, [self sectionLabel:@"Intensity"], nowRow, maxRow, rule, fullTitle,
    wheelWell, cycleRow
  ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(12, 14, 4, 14);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [stack setCustomSpacing:14 afterView:label];
  [stack setCustomSpacing:16 afterView:maxRow];
  [stack setCustomSpacing:10 afterView:rule];
  [stack setCustomSpacing:2 afterView:wheelWell];

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

- (void)setSentence:(NSString *)sentence {
  (void)self.view;
  self.label.stringValue = sentence.length > 0 ? sentence : @"Nightshift";
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
  self.maxSlider.doubleValue = value;
  self.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
}

- (void)syncWheels {
  BOOL h24 = hourCycleIs24();
  self.cycleSwitch.state =
      h24 ? NSControlStateValueOn : NSControlStateValueOff;
  self.hourWheel.labels = numberLabels(h24 ? 0 : 1, h24 ? 24 : 12, h24);
  self.minuteWheel.labels = numberLabels(0, 60, YES);
  self.ampmWheel.labels = @[ @"AM", @"PM" ];
  self.ampmWheel.hidden = h24;
  self.wheels.spacing = h24 ? 12 : 8;
  int minute = gRampClock >= 0 ? gRampClock : gFullAt;
  if (minute < 0) {
    minute = minutesNow();
  }
  if (minute < 0) {
    minute = 0;
  }
  int hour = 0;
  int min = 0;
  BOOL pm = NO;
  splitClock(minute, h24, &hour, &min, &pm);
  self.hourWheel.index = h24 ? hour : hour - 1;
  self.minuteWheel.index = min;
  self.ampmWheel.index = pm ? 1 : 0;
  BOOL on = customSchedule();
  for (WheelColumn *wheel in
       @[ self.hourWheel, self.minuteWheel, self.ampmWheel ]) {
    wheel.enabled = on;
    wheel.alphaValue = on ? 1 : 0.4;
  }
}

- (int)clockMinute {
  BOOL h24 = hourCycleIs24();
  int hour = h24 ? (int)self.hourWheel.index : (int)self.hourWheel.index + 1;
  return joinClock(h24, hour, (int)self.minuteWheel.index,
                   self.ampmWheel.index == 1);
}
@end

@interface MenuBar : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) StatusPanel *panel;
@property(nonatomic) NSInteger wheelToken;
@property(nonatomic) BOOL tracking;
@property(nonatomic) BOOL menuOpen;
- (void)refresh;
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
  self.panel.cycleSwitch.target = self;
  self.panel.cycleSwitch.action = @selector(toggleCycle:);
  __weak MenuBar *menu = self;
  void (^moved)(WheelColumn *) = ^(WheelColumn *column) {
    (void)column;
    [menu wheelMoved];
  };
  self.panel.hourWheel.changed = moved;
  self.panel.minuteWheel.changed = moved;
  self.panel.ampmWheel.changed = moved;
  [self refresh];
  [self sizeMenuView];
  self.menu = [[NSMenu alloc] init];
  self.menu.autoenablesItems = NO;
  self.menu.delegate = self;
  NSMenuItem *content = [[NSMenuItem alloc] init];
  content.view = self.panel.view;
  [self.menu addItem:content];
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
  [self refresh];
}

- (void)menuDidClose:(NSMenu *)menu {
  (void)menu;
  self.menuOpen = NO;
  self.tracking = NO;
  self.wheelToken += 1;
}

- (void)refresh {
  if (self.tracking) {
    return;
  }
  [self.panel setSentence:currentSentence()];
  [self.panel syncSliders];
  [self.panel syncWheels];
  [self sizeMenuView];
}

- (void)nowMoved:(NSSlider *)slider {
  long value = (long)llround(slider.doubleValue);
  self.panel.nowValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
  long saved = self.panel.savedMax;
  if (saved >= 1 && value > saved) {
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
  long value = (long)llround(slider.doubleValue);
  self.panel.maxValue.stringValue = [NSString stringWithFormat:@"%ld%%", value];
  if (!sliderSettled()) {
    self.tracking = YES;
    return;
  }
  self.tracking = NO;
  if (value == self.panel.savedMax) {
    [self refresh];
    return;
  }
  if (!commitMax(value)) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)wheelMoved {
  self.tracking = YES;
  self.wheelToken += 1;
  NSInteger token = self.wheelToken;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
                   if (token != self.wheelToken) {
                     return;
                   }
                   [self commitWheels];
                 });
}

- (void)commitWheels {
  self.tracking = NO;
  if (!customSchedule()) {
    [self refresh];
    return;
  }
  int minute = [self.panel clockMinute];
  if (minute == gRampClock) {
    [self refresh];
    return;
  }
  if (!setRampClock(minute)) {
    [self refresh];
    return;
  }
  [self refresh];
}

- (void)toggleCycle:(NSButton *)button {
  (void)button;
  self.wheelToken += 1;
  self.tracking = NO;
  int cycle = hourCycleIs24() ? 12 : 24;
  if (!writeHourCycle(cycle)) {
    [self refresh];
    return;
  }
  [self refresh];
}

@end

static MenuBar *gMenu = nil;

static void refreshMenu(void) {
  if (gMenu == nil || !gMenu.menuOpen) {
    return;
  }
  [gMenu refresh];
}

static void installMenu(void) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  gMenu = [[MenuBar alloc] init];
  [gMenu refresh];
}

static char gSockPath[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void stopDaemon(int sig) {
  (void)sig;
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
      char buf[64];
      if (!readMessage(connection, buf, sizeof(buf))) {
        dprintf(connection, "failed\n");
        close(connection);
        return;
      }
      handleLine(buf, connection);
      refreshMenu();
      close(connection);
    });
    dispatch_resume(gListener);
    installMenu();
    [NSApp run];
  }
  return 0;
}
