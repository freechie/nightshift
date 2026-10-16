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

// The one active Session event tap, and the Accessibility poll that drops
// it on revoke and rebuilds it on regrant. nightshiftd.m owns the warmth
// hotkeys (Cmd+F1 / Cmd+F2) and the Settings row this poll refreshes.

#ifndef NIGHTSHIFT_SESSION_TAP_H
#define NIGHTSHIFT_SESSION_TAP_H

#include <CoreGraphics/CGEvent.h>
#include <stdbool.h>

void nsSessionTapWatch(void);
bool nsSessionTapInstalled(void);
void nsSessionTapRemove(void);
bool nsSessionTapCreate(CGEventTapCallBack callback);
void nsSessionTapSetEnabled(bool enabled);

// Implemented in nightshiftd.m. The poll calls them in the same order the
// revoke path used before this file existed.
void dropTapsAndRetry(void);
bool installWarmthKeyTap(void);
void refreshKeysState(void);
void nsSessionHostNoteRebuilt(void);

#endif
