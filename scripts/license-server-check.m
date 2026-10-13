// Checks LICENSE_SERVER with the app's own rule (nsLicenseOriginVerdict in
// NightshiftLogic, the function the app's license-server check calls, with
// no loopback http, as in every build but the test-key one). make exports
// LICENSE_SERVER, so the value never passes through a shell command line.
//
//   license-server-check package  refuses (exit 1) without a usable server
//   license-server-check install  warns (exit 0) without one
#include "NightshiftLogic.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  bool install = argc > 1 && strcmp(argv[1], "install") == 0;
  const char *target = install ? "make install" : "make package";
  const char *value = getenv("LICENSE_SERVER");
  size_t length = value != NULL ? strlen(value) : 0;
  NSLinkVerdict verdict = nsLicenseOriginVerdict(value, length, false);
  if (verdict == kNSLinkOK) {
    printf("license server: %s\n", value);
    return 0;
  }
  if (install) {
    fprintf(stderr, "%s: warning: this build has no license server compiled in", target);
    if (length == 0) {
      fprintf(stderr, " (LICENSE_SERVER is not set).\n");
    } else {
      fprintf(stderr, " (LICENSE_SERVER is not usable: %s).\n", nsLinkVerdictText(verdict));
    }
    fprintf(stderr,
            "Buying and renewing will report the server unreachable. Build with\n"
            "  make install LICENSE_SERVER=https://license.example.com\n");
    return 0;
  }
  if (length == 0) {
    fprintf(stderr,
            "%s: LICENSE_SERVER is not set. A release needs its license server:\n"
            "  make package LICENSE_SERVER=https://license.example.com\n",
            target);
    return 1;
  }
  fprintf(stderr,
          "%s: LICENSE_SERVER is not a usable license server: %s.\n"
          "It must be a lowercase https origin, like https://license.example.com or\n"
          "https://license.example.com:8443, with nothing after the host.\n",
          target, nsLinkVerdictText(verdict));
  return 1;
}
