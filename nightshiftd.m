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
static NSString *const kCategory = @"warmth";

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

static int minutesBetween(int from, int to) {
  return (to - from + 1440) % 1440;
}

static BOOL insideWindow(int start, int end, int now) {
  int length = minutesBetween(start, end);
  if (length == 0) {
    return NO;
  }
  return minutesBetween(start, now) < length;
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
  if (gFromMinute < 0 || gToMinute < 0) {
    return -1;
  }
  int span = minutesBetween(gFromMinute, gToMinute);
  int elapsed = minutesBetween(gFromMinute, now);
  if (span == 0 || elapsed >= span) {
    return gMax;
  }
  long value = gFromValue + (gMax - gFromValue) * elapsed / span;
  if (value < 1) {
    return 1;
  }
  if (value > 100) {
    return 100;
  }
  return value;
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
  UNNotificationRequest *request =
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

static void writeStatus(int fd) {
  BLStatus status;
  long current = 0;
  if (!readStrength(gClient, &current)) {
    dprintf(fd, "failed\n");
    return;
  }
  const char *state = "idle";
  int full = -1;
  if (!readStatus(gClient, &status) || !status.enabled) {
    state = "off";
  } else if (gFromMinute >= 0) {
    int now = minutesNow();
    state = now >= 0 && glideStage(now) >= 3 ? "holding" : "ramping";
    full = gToMinute;
  }
  dprintf(fd, "%ld %ld %s %d\n", current, gMaxKnown ? gMax : -1L, state, full);
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
  notify([NSString stringWithFormat:@"Max set to %ld", value]);
}

static void setMax(long value, int fd) {
  if (!rememberMax(value)) {
    dprintf(fd, "failed\n");
    return;
  }
  noteMax(value);
  dprintf(fd, "%ld\n", gMax);
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
  if (!parseNumber(buf, 0, 100, &value) ||
      !applyStrength(gClient, value, &stored)) {
    dprintf(fd, "failed\n");
    return;
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
    dprintf(fd, "%ld\n", stored);
    return;
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
                       title:@"Full at"
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
      close(connection);
    });
    dispatch_resume(gListener);
    dispatch_main();
  }
  return 0;
}
