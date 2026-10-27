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

#import <Foundation/Foundation.h>

@class CBBlueLightClient;

// Linked into nightshift-swift only. Night Shift schedule, True Tone, and
// Dark mode for the menu. No ramp glide.
BOOL nsSwiftSetMode(CBBlueLightClient *client, int mode);
// NO when this Mac has no True Tone. Otherwise writes the switch.
BOOL nsSwiftReadTrueTone(BOOL *enabled);
BOOL nsSwiftSetTrueTone(BOOL on);
BOOL nsSwiftDarkMode(void);
void nsSwiftSetDarkMode(BOOL on);
