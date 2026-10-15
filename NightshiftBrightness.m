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

#import "NightshiftBrightness.h"
#import "NightshiftLogic.h"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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

@interface NightshiftBrightnessClient : NSObject
- (BOOL)activateWithError:(NSError **)error;
- (id)copyPropertyForKey:(NSString *)key andDisplay:(unsigned long long)display;
- (BOOL)setProperty:(id)property withKey:(NSString *)key andDisplay:(unsigned long long)display;
@end

static NSString *gBrightnessPath = nil;

void setBrightnessPath(NSString *path) {
  gBrightnessPath = path;
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

BOOL readCoreBrightness(uint32_t display, float *level) {
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

NSString *displayTitle(uint32_t display) {
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (number.unsignedIntValue == display && screen.localizedName.length > 0) {
      return screen.localizedName;
    }
  }
  return [NSString stringWithFormat:@"Display %u", display];
}

int orderedDisplays(uint32_t *ids, int cap) {
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
NSScreen *screenForDisplay(uint32_t display);

static NSString *displayBrightnessKey(uint32_t display) {
  return [NSString stringWithFormat:@"%u %u %u", CGDisplayVendorNumber(display),
                                    CGDisplayModelNumber(display),
                                    CGDisplaySerialNumber(display)];
}

void loadBrightness(void) {
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

BOOL ddcReady(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display &&
        __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE) > 0) {
      return YES;
    }
  }
  return NO;
}

BOOL ddcFailed(uint32_t display) {
  for (int i = 0; i < 8; i++) {
    if (gDDC[i].display == display &&
        __atomic_load_n(&gDDC[i].max, __ATOMIC_ACQUIRE) < 0) {
      return YES;
    }
  }
  return NO;
}

BOOL ddcUnconfirmed(uint32_t display) {
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

BOOL ddcPending(uint32_t display) {
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
void refreshMenu(void);
BOOL stepActiveBrightness(int direction);

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
static BOOL displayWasRestored(uint32_t display);
// Raw VCP reads and writes. Not readDisplayBrightness: that returns the
// saved slider value (slot->combined) and would make this probe look green
// without the panel moving.
static bool ddcProbeRead(void *ctx, int *current, int *max);
static bool ddcProbeWrite(void *ctx, int value);

BOOL setDisplayBrightness(uint32_t display, long percent);

// The percent the user asked for. The slot's combined value when a drag set
// one, otherwise the session or saved number. Not the lamp reading: listing
// displays from that reading is what made a stuck panel look like it moved.
// -1 when Nightshift has no number for it yet.
static long rememberedBrightness(uint32_t display) {
  DDCSlot *slot = ddcSlot(display);
  if (slot != NULL && slot->combined >= 0 && slot->combined <= 100) {
    return slot->combined;
  }
  NSNumber *saved = nil;
  if (gSoftwareBrightness != nil) {
    saved = gSoftwareBrightness[@(display)];
  }
  if (saved == nil && gBrightnessSaved != nil) {
    saved = gBrightnessSaved[displayBrightnessKey(display)];
  }
  if (saved == nil) {
    return -1;
  }
  long percent = (long)llround(saved.doubleValue * 100.0);
  if (percent < 0) {
    return 0;
  }
  if (percent > 100) {
    return 100;
  }
  return percent;
}

static double secondsSince(CFAbsoluteTime at) {
  return at == 0 ? -1 : CFAbsoluteTimeGetCurrent() - at;
}

// Main thread. A probe proved this channel still follows writes (after wake,
// replug or a screen change) and re-read it. The service is always the fresh
// one, so a dead IOAVService from before the change is dropped. A probe that
// did not prove control is not delivered here; the caller marks that display
// software-only.
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

void probeDDC(void) {
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
      results[i].display = targets[i];
      results[i].service = service;
      results[i].current = 0;
      results[i].max = -1;
      // A readable VCP is not control. Nudge the panel and require the next
      // raw read to come back as that value. Wake, replug and a screen
      // change all come through here, so a monitor is not trusted forever
      // from the first launch.
      if (service != NULL) {
        int current = 0;
        int max = 0;
        NSDDCProbeIO io = {ddcProbeRead, ddcProbeWrite, (void *)service};
        if (nsDDCProbeControl(&io, &current, &max) == kNSDDCProbeControllable && max > 0) {
          results[i].current = current;
          results[i].max = max;
        }
      }
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
        if (results[i].max > 0 && snapshotReady(&seen, results[i].display)) {
          revalidateDDC(results[i].display, results[i].service, results[i].current,
                        results[i].max);
          continue;
        }
        if (results[i].max > 0) {
          // Was software-only and now answers. Push the saved percent through
          // the backlight path. The first probe leaves that to
          // restoreSavedBrightness, which has not marked the display yet.
          BOOL restored = displayWasRestored(results[i].display);
          long shown = restored ? rememberedBrightness(results[i].display) : -1;
          publishDDC(results[i].display, results[i].service, results[i].current,
                     results[i].max);
          if (restored && shown >= 0) {
            setDisplayBrightness(results[i].display, shown);
          }
          continue;
        }
        // Unchanged readback, or the read/write failed: software dimming
        // only. Drop the service so later slider moves do not write DDC.
        long shown = rememberedBrightness(results[i].display);
        BOOL wasReady = snapshotReady(&seen, results[i].display);
        if (results[i].service != NULL) {
          CFRelease(results[i].service);
          results[i].service = NULL;
        }
        publishDDC(results[i].display, NULL, 0, -1);
        if (wasReady && shown >= 0) {
          setDisplayBrightness(results[i].display, shown);
        }
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

static bool ddcProbeRead(void *ctx, int *current, int *max) {
  IOAVServiceRef service = (IOAVServiceRef)ctx;
  for (int attempt = 0; attempt < 4; attempt++) {
    if (attempt > 0) {
      usleep(kDDCBetweenReads);
    }
    if (ddcReadOnce(service, current, max)) {
      return true;
    }
  }
  return false;
}

static bool ddcProbeWrite(void *ctx, int value) {
  return ddcWriteOnce((IOAVServiceRef)ctx, value) ? true : false;
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

long ddcBrightnessFloor(uint32_t display) {
  if (!ddcReady(display)) {
    return -1;
  }
  return ddcFloorPercent(display);
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


BOOL externalNeedsDDC(void) {
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

BOOL readDisplayBrightness(uint32_t display, float *level, BOOL *writable) {
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
void liftBrightnessHUD(void);

NSScreen *screenForDisplay(uint32_t display) {
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

// Software-only displays follow the slider across the whole 0-100 range.
// A controllable backlight keeps the combined split instead.
long softwareDimPercent(uint32_t display, long percent) {
  (void)display;
  if (percent < 0) {
    return 0;
  }
  if (percent > 100) {
    return 100;
  }
  return percent;
}

static BOOL ddcPost(uint32_t display, DDCSlot *slot, long percent, long floor);
void probeDDC(void);

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
// of the dimming, across the whole slider range.
static BOOL shadeInstead(uint32_t display, long percent, int saving) {
  if (screenForDisplay(display) == nil) {
    return NO;
  }
  restoreGamma(display);
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

int otherLitDisplayCount(uint32_t display) {
  return litDisplaysBesides(display);
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
BOOL setDisplayBrightness(uint32_t display, long percent);

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
BOOL setDisplayBrightnessThen(uint32_t display, long percent, BrightnessDone done) {
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
  } else if (gDDCBusy && (ddcUnconfirmed(display) || ddcPending(display)) &&
             putDisplayPercent(&gDeferredBrightness, display, percent)) {
    if (gSoftwareBrightness == nil) {
      gSoftwareBrightness = [NSMutableDictionary dictionary];
    }
    gSoftwareBrightness[@(display)] = @((float)percent / 100.0f);
    return YES;
  }
  long floor = ddcFloorPercent(display);
  long hardware = percent;
  long software = 100;
  nsExternalBrightness(kNSDDCProbeControllable, percent, floor, &hardware, &software);
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
    nsExternalBrightness(kNSDDCProbeSoftware, percent, floor, &hardware, &software);
    // software is the gamma percent. The saved number stays the slider
    // percent, so a later move does not curve the curve.
    applyDim(display, software);
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

BOOL setDisplayBrightness(uint32_t display, long percent) {
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
void holdBrightnessTick(uint32_t display, long percent) {
  gBrightnessSaving = kSaveHeld;
  setDisplayBrightness(display, percent);
  gBrightnessSaving = kSaveNow;
}

// Main thread. A drag ended at percent, on release or when the menu closed
// under it. This is its one save. A failed set saves nothing, so the file
// keeps the value from before the drag.
BOOL endBrightnessDrag(uint32_t display, long percent) {
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

void forgetOfflineDisplays(void) {
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
void refitDimWindows(void) {
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

void noteDisplayWake(void) {
  gWokeAt = CFAbsoluteTimeGetCurrent();
}

// A key arrived before this display's probe finished. The step waits with
// the others and is applied when the probe lands. The same -16..16 cap the
// key path used before this file existed.
BOOL queueBrightnessKeyStep(int direction) {
  if (gPendingKeySteps > -16 && gPendingKeySteps < 16) {
    gPendingKeySteps += direction;
    return YES;
  }
  return NO;
}

// Main thread. Re-reads every DDC channel, the confirmed ones included, as
// soon as the queue is free.
void ddcRevalidate(void) {
  gDDCRevalidate = YES;
  gDDCLast = 0;
  probeDDC();
}

// A drag, or a release still waiting on its lamp write: the display shows
// these values, so keep them rather than restore the old ones next launch.
// Quit can't wait for the readback, so a pending release counts as landed.
void settleBrightnessOnQuit(void) {
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
}

// Let a queued lamp write finish instead of exiting mid-transaction. A
// probe can run long, so wait only a moment.
void drainBrightnessQueue(void) {
  dispatch_semaphore_t drained = dispatch_semaphore_create(0);
  dispatch_async(ddcQueue(), ^{
    dispatch_semaphore_signal(drained);
  });
  dispatch_semaphore_wait(drained,
                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)));
}
