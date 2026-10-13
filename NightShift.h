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
// The install ID (created once, never replaced; nil if its file exists but
// can't be read) and the file it lives in.
NSString *rampInstallID(void);
NSString *rampInstallIDPath(void);
NSString *rampInstallSecret(void);
// Saves a secret from support (64 hex characters); an existing one only
// when replace is YES. On failure, *error says why.
BOOL rampSaveInstallSecret(NSString *value, BOOL replace, NSString **error);
void forgetInstallIdentityForTests(void);
// The end day a license payload grants on installID, or nil. Only
// "ramp:<install-id>:<day>" for that install; unbound "ramp" and
// "ramp:<day>" are refused. Does not check expiry.
NSString *rampPayloadDay(NSString *payload, NSString *installID);
// The license server's origin without a trailing "/", or nil when this
// build has no acceptable one (https, or loopback http in test-key builds).
NSString *rampServerOrigin(void);
// The page to open for url when it is a Stripe Checkout or billing portal
// page, or nil. No control characters; the C check reads every byte; and
// the NSURL returned prints back exactly as url, so what was checked is
// what opens.
NSURL *rampPurchasePage(NSString *url);
BOOL rampPurchaseURLAllowed(NSString *url);
NSString *rampCheckoutURL(void);
NSString *rampFetchLicenseToken(void);
int rampInstallReported(NSString *token, NSString **stdoutLine, NSString **stderrLine);
int rampBeginPurchase(NSString **openURL, BOOL *portal, NSString **stdoutLine,
                      NSString **stderrLine);
int rampTakeLicenseUpdate(NSString **stdoutLine, NSString **stderrLine);
// What to tell this Mac when the server answered a license fetch with its
// held-purchase reply (status 409): "This purchase is being reversed;
// contact support" while the refund is pending (error "pending"), "This
// purchase was refunded; contact support" once it succeeded (error
// "refunded"), else nil. rampTakeLicenseUpdate and rampBeginPurchase
// report it.
NSString *rampHeldPurchaseMessage(NSInteger status, NSData *body);
NSString *rampOffer(void);
void useRampPublicKeyForTests(const uint8_t *key);
