#import "NightShift.h"
#include "CBBlueLightClient.h"
#import <objc/runtime.h>
#import <string.h>

static BOOL methodMatches(id client, SEL sel, const char *expected) {
  Method method = class_getInstanceMethod([client class], sel);
  const char *encoding = method ? method_getTypeEncoding(method) : NULL;
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

CBBlueLightClient *makeClient(void) {
  CBBlueLightClient *client = [[CBBlueLightClient alloc] init];
  if (client == nil ||
      !methodMatches(client, @selector(setStrength:commit:), "B24@0:8f16B20") ||
      !methodMatches(client, @selector(setEnabled:), "B20@0:8B16") ||
      !methodMatches(client, @selector(getStrength:), "B24@0:8^f16")) {
    return nil;
  }
  return client;
}

BOOL readStrength(CBBlueLightClient *client, long *stored) {
  float actual = 0;
  if (![client getStrength:&actual]) {
    return NO;
  }
  *stored = lroundf(actual * 100.0f);
  return YES;
}

BOOL applyStrength(CBBlueLightClient *client, long value, long *stored) {
  if (value == 0) {
    if (![client setStrength:0 commit:YES] || ![client setEnabled:NO]) {
      return NO;
    }
    *stored = 0;
    return YES;
  }
  float strength = (float)value / 100.0f;
  if (![client setStrength:strength commit:YES] || ![client setEnabled:YES]) {
    return NO;
  }
  return readStrength(client, stored);
}

BOOL readStatus(CBBlueLightClient *client, BLStatus *status) {
  if (!methodMatches(client, @selector(getBlueLightStatus:),
                     "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16")) {
    return NO;
  }
  memset(status, 0, sizeof(*status));
  return [client getBlueLightStatus:status];
}
