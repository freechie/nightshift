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

// One brightness owner. The DDC queue, the sleeps, and ddcWriteOnce live
// here, with the per-display control probe and the software-dimming fallback.
// Sleeps and write counts stay as they were. Nightshiftd keeps the menu,
// the hotkeys, and the Session tap, and calls this file.

#ifndef NIGHTSHIFT_BRIGHTNESS_H
#define NIGHTSHIFT_BRIGHTNESS_H

#import <AppKit/AppKit.h>
#include <stdint.h>

typedef void (^BrightnessDone)(BOOL ok);

void setBrightnessPath(NSString *path);
void noteDisplayWake(void);
BOOL queueBrightnessKeyStep(int direction);
void settleBrightnessOnQuit(void);
void drainBrightnessQueue(void);
void ddcRevalidate(void);

BOOL readCoreBrightness(uint32_t display, float *level);
NSString *displayTitle(uint32_t display);
int orderedDisplays(uint32_t *ids, int cap);
void loadBrightness(void);
BOOL ddcReady(uint32_t display);
BOOL ddcFailed(uint32_t display);
BOOL ddcUnconfirmed(uint32_t display);
BOOL ddcPending(uint32_t display);
void probeDDC(void);
BOOL externalNeedsDDC(void);
BOOL readDisplayBrightness(uint32_t display, float *level, BOOL *writable);
NSScreen *screenForDisplay(uint32_t display);
long softwareDimPercent(uint32_t display, long percent);
BOOL setDisplayBrightnessThen(uint32_t display, long percent, BrightnessDone done);
BOOL setDisplayBrightness(uint32_t display, long percent);
void holdBrightnessTick(uint32_t display, long percent);
BOOL endBrightnessDrag(uint32_t display, long percent);
void forgetOfflineDisplays(void);
void refitDimWindows(void);

// Implemented in nightshiftd.m. Brightness calls them; they
// stay with the menu, the cursor, and the keys.
void notifyPlain(NSString *body);
BOOL selectorMatches(id object, SEL sel, const char *expected);
void liftBrightnessHUD(void);
void refreshMenu(void);
void noteCursorBrightness(uint32_t display, long percent);
void noteCursorDisplaysOffline(void);
long readPercent(uint32_t display);
BOOL stepActiveBrightness(int direction);
void refreshKeyDisplays(void);

#endif
