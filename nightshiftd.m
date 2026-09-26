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

#import "CBBlueLightClient.h"
#import <objc/runtime.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static BOOL methodMatches(id client, SEL sel, const char *expected) {
  Method method = class_getInstanceMethod([client class], sel);
  const char *encoding = method ? method_getTypeEncoding(method) : NULL;
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

static int applyStrength(CBBlueLightClient *client, long value, long *stored) {
  if (value == 0) {
    if (![client setStrength:0 commit:(YES)] || ![client setEnabled:NO]) {
      return 1;
    }
    *stored = 0;
    return 0;
  }
}
