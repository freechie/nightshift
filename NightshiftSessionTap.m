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

#import "NightshiftSessionTap.h"
#import "NightshiftLogic.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static CFRunLoopRef gTapRunLoop = NULL;
static CFMachPortRef gSessionTap = NULL;
static CFRunLoopSourceRef gSessionSource = NULL;

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

bool nsSessionTapInstalled(void) {
  return gSessionTap != NULL;
}

void nsSessionTapRemove(void) {
  if (gSessionTap != NULL) {
    CGEventTapEnable(gSessionTap, false);
    CFMachPortInvalidate(gSessionTap);
    CFRelease(gSessionTap);
    gSessionTap = NULL;
  }
  if (gSessionSource != NULL) {
    CFRunLoopRemoveSource(tapRunLoop(), gSessionSource, kCFRunLoopCommonModes);
    CFRelease(gSessionSource);
    gSessionSource = NULL;
  }
}

void nsSessionTapSetEnabled(bool enabled) {
  if (gSessionTap != NULL) {
    CGEventTapEnable(gSessionTap, enabled);
  }
}

bool nsSessionTapCreate(CGEventTapCallBack callback) {
  if (gSessionTap != NULL) {
    return true;
  }
  // One Session tap, system-defined events only. An Annotated Session tap
  // breaks volume and mute even when it returns their events.
  CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                       kCGEventTapOptionDefault,
                                       (CGEventMask)nsMediaTapMaskBits(), callback, NULL);
  if (tap == NULL) {
    return false;
  }
  CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
  CFRunLoopRef loop = tapRunLoop();
  gSessionSource = source;
  gSessionTap = tap;
  CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
  CGEventTapEnable(tap, true);
  CFRunLoopWakeUp(loop);
  return true;
}

static void checkAccessibility(void) {
  switch (nsAccessAction(AXIsProcessTrusted(), nsSessionTapInstalled())) {
  case kNSAccessDrop:
    dropTapsAndRetry();
    refreshKeysState();
    break;
  case kNSAccessRebuild:
    if (installBrightnessTap()) {
      nsSessionHostNoteRebuilt();
      refreshKeysState();
    }
    break;
  case kNSAccessKeep:
    break;
  }
}

void nsSessionTapWatch(void) {
  NSTimer *timer = [NSTimer timerWithTimeInterval:1
                                          repeats:YES
                                            block:^(NSTimer *t) {
                                              (void)t;
                                              checkAccessibility();
                                            }];
  timer.tolerance = 0.1;
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  // Undocumented and sent before the change lands, so it only shortens the
  // wait; the timer works alone.
  [NSDistributedNotificationCenter.defaultCenter
      addObserverForName:@"com.apple.accessibility.api"
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *note) {
                (void)note;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 checkAccessibility();
                               });
              }];
}
