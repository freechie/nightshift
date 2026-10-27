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

#import "../NightShift.h"
#import "CNightshift/MenuBridge.h"

#import <objc/runtime.h>
#import <string.h>

extern int SLSGetAppearanceThemeLegacy(void);
extern void SLSSetAppearanceThemeLegacy(int theme);
extern void SLSSetAppearanceThemeSwitchesAutomatically(int automatic);

@interface CBBlueLightClient (NightshiftMenu)
- (BOOL)setMode:(int)mode;
@end

@interface CBTrueToneClient : NSObject
- (BOOL)supported;
- (BOOL)available;
- (BOOL)enabled;
- (BOOL)setEnabled:(BOOL)enabled;
@end

static BOOL encodingMatches(id object, SEL sel, const char *expected) {
  if (object == nil || sel == NULL || expected == NULL) {
    return NO;
  }
  Method method = class_getInstanceMethod([object class], sel);
  const char *encoding = method == NULL ? NULL : method_getTypeEncoding(method);
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

BOOL nsSwiftSetMode(CBBlueLightClient *client, int mode) {
  if (client == nil || (mode != 0 && mode != 1 && mode != 2)) {
    return NO;
  }
  if (!encodingMatches(client, @selector(setMode:), "B20@0:8i16")) {
    return NO;
  }
  return [client setMode:mode];
}

static CBTrueToneClient *toneClient(void) {
  static CBTrueToneClient *client = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    client = [[CBTrueToneClient alloc] init];
  });
  return client;
}

BOOL nsSwiftReadTrueTone(BOOL *enabled) {
  CBTrueToneClient *client = toneClient();
  if (client == nil || ![client supported] || ![client available]) {
    return NO;
  }
  if (enabled != NULL) {
    *enabled = [client enabled];
  }
  return YES;
}

BOOL nsSwiftSetTrueTone(BOOL on) {
  CBTrueToneClient *client = toneClient();
  if (client == nil || ![client supported] || ![client available]) {
    return NO;
  }
  return [client setEnabled:on];
}

BOOL nsSwiftDarkMode(void) {
  return SLSGetAppearanceThemeLegacy() == 1;
}

void nsSwiftSetDarkMode(BOOL on) {
  SLSSetAppearanceThemeSwitchesAutomatically(0);
  SLSSetAppearanceThemeLegacy(on ? 1 : 0);
}
