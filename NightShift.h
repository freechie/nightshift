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

CBBlueLightClient *makeClient(void);
BOOL readStrength(CBBlueLightClient *client, long *stored);
BOOL applyStrength(CBBlueLightClient *client, long value, long *stored);
BOOL stageStrength(CBBlueLightClient *client, long value);
BOOL readStatus(CBBlueLightClient *client, BLStatus *status);
BOOL parseNumber(const char *s, long min, long max, long *out);
BOOL parseMaxText(NSString *text, long *out);
BOOL parseClockText(NSString *text, int *out);
int minutesBetween(int from, int to);
BOOL insideWindow(int start, int end, int now);
BOOL holdingFullAt(int start, int end, int fullAt, int now);
long glideWarmth(int fromMinute, int toMinute, long fromValue, long maxv, int now);
long warmthCappedByMax(long now, long maxv);
void splitClock(int minute, BOOL h24, int *hour, int *min, BOOL *pm);
int joinClock(BOOL h24, int hour, int min, BOOL pm);
NSString *clockString(int minute);
NSString *warmthSentence(long now, long maxv, const char *state, int full);
void readHourCycle(void);
BOOL writeHourCycle(int cycle);
BOOL hourCycleIs24(void);
void useHourCycleForTests(int cycle);
BOOL rampLicenseAllows(NSString *token);
BOOL rampLicensed(void);
BOOL installRampLicense(NSString *token);
NSString *rampLicenseUntilToken(NSString *token);
NSString *rampLicenseUntil(void);
BOOL rampLicenseRenewingSoon(void);
BOOL rampLicenseNeedsRefresh(void);
BOOL rampSaveNewerLicense(NSString *token);
NSString *rampInstallID(void);
NSString *rampServerOrigin(void);
NSString *rampCheckoutURL(void);
NSString *rampFetchLicenseToken(void);
int rampInstallReported(NSString *token, NSString **stdoutLine, NSString **stderrLine);
int rampBeginPurchase(NSString **openURL, BOOL *portal, NSString **stdoutLine,
                      NSString **stderrLine);
int rampTakeLicenseUpdate(NSString **stdoutLine, NSString **stderrLine);
NSString *rampOffer(void);
void useRampPublicKeyForTests(const uint8_t *key);
