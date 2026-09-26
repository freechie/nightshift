#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import "CBBlueLightClient.h"

static BOOL methodMatches(id client, SEL sel, const char *expected) {
  Method method = class_getInstanceMethod([client class], sel);
  const char *encoding = method ? method_getTypeEncoding(method) : NULL;
  return encoding != NULL && strcmp(encoding, expected) == 0;
}

static void usage(void) {
  fprintf(stderr, "usage: nshift <0-100>\n");
}

int main(int argc, const char *argv[]) {

  @autoreleasepool {
    CBBlueLightClient *client = [[CBBlueLightClient alloc] init];

    if (client == nil
        || !methodMatches(client, @selector(setStrength:commit:), "B24@0:8f16B20")
        || !methodMatches(client, @selector(setEnabled:), "B20@0:8B16")
        || !methodMatches(client, @selector(getStrength:), "B24@0:8^f16")) {
      fprintf(stderr, "Night Shift is unavailable\n");
      return 1;
    }

    if (argc == 1) {
      float actual = 0;
      if (![client getStrength:&actual]) {
        fprintf(stderr, "failed to read Night Shift\n");
        return 1;
      }
     printf("%ld\n", lroundf(actual * 100.0f));
      return 0;
    }
    if (argc != 2) {
      usage();
      return 1;
    }

    char *end = NULL;
    long value = strtol(argv[1], &end, 10);

    if (end == argv[1] || *end != '\0' || value < 0 || value > 100) {
      usage();
      return 1;
    }

    if (value == 0) {
      if (![client setStrength:0 commit:YES] || ![client setEnabled:NO]) {
        fprintf(stderr, "Failed to disable Night Shift\n");
        return 1;
      }
      printf("0\n");
      return 0;
    }

    float strength = (float)value / 100.0f;

    if (![client setStrength:strength commit:YES] || ![client setEnabled:YES]) {
      fprintf(stderr, "failed to set Night Shift\n");
      return 1;
    }

    float actual = 0;

    if (![client getStrength:&actual]) {
      fprintf(stderr, "failed to read Night Shift\n");
      return 1;
    }
    printf("%ld\n", lroundf(actual * 100.0f));
  }
  return 0;
}
