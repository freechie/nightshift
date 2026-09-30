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

#import "NightShift.h"
#import <errno.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static int talk(const char *line, char *reply, size_t cap) {
  NSString *sock = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/nightshift"]
      stringByAppendingPathComponent:@"nightshiftd.sock"];
  const char *path = sock.fileSystemRepresentation;

  struct stat st;
  if (stat(path, &st) < 0 || !S_ISSOCK(st.st_mode) || st.st_uid != getuid()) {
    return -1;
  }
  if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    return -1;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }

  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  memcpy(addr.sun_path, path, strlen(path) + 1);

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    return -1;
  }

  size_t len = strlen(line);
  if (write(fd, line, len) != (ssize_t)len) {
    close(fd);
    return 1;
  }

  ssize_t n;
  do {
    n = read(fd, reply, cap - 1);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) {
    close(fd);
    return 1;
  }
  reply[n] = '\0';
  char *nl = strchr(reply, '\n');
  if (nl == NULL) {
    close(fd);
    return 1;
  }
  *nl = '\0';
  close(fd);
  if (reply[0] == '\0' || strcmp(reply, "failed") == 0) {
    return 1;
  }
  return 0;
}

static void printStatus(const char *reply) {
  long now = 0;
  long maxv = 0;
  long full = -1;
  char state[16];
  if (sscanf(reply, "%ld %ld %15s %ld", &now, &maxv, state, &full) != 4) {
    fprintf(stderr, "unexpected reply\n");
    return;
  }
  if (maxv < 0) {
    printf("%ld, no max set\n", now);
    return;
  }
  if (strcmp(state, "off") == 0) {
    printf("off, max %ld\n", maxv);
    return;
  }
  if (now == maxv) {
    printf("Warmth is at %ld%%\n", now);
    return;
  }
  if (full >= 0 && strcmp(state, "ramping") == 0) {
    printf("Warmth is at %ld%%, reaching %ld%% at %s\n", now, maxv,
           clockString((int)full).UTF8String);
    return;
  }
  printf("Warmth is at %ld%%, max %ld%%\n", now, maxv);
}

static void usage(void) {
  fprintf(stderr, "usage: nightshift [0-100 | max 1-100 | ramp 8:30pm]\n");
}

static BOOL parseValue(const char *s, long min, long max, long *out) {
  char *end = NULL;
  long value = strtol(s, &end, 10);
  if (end == s || *end != '\0' || value < min || value > max) {
    return NO;
  }
  *out = value;
  return YES;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 1) {
      char reply[64];
      int sent = talk("status\n", reply, sizeof(reply));
      if (sent == 0) {
        printStatus(reply);
        return 0;
      }
      CBBlueLightClient *client = makeClient();
      if (client == nil) {
        fprintf(stderr, "Night Shift is unavailable\n");
        return 1;
      }
      long stored = 0;
      if (!readStrength(client, &stored)) {
        fprintf(stderr, "failed to read Night Shift\n");
        return 1;
      }
      printf("%ld\n", stored);
      return 0;
    }

    if (argc == 3 && strcmp(argv[1], "max") == 0) {
      long value = 0;
      if (!parseValue(argv[2], 1, 100, &value)) {
        usage();
        return 1;
      }
      char line[32];
      char reply[64];
      snprintf(line, sizeof(line), "max %ld\n", value);
      int sent = talk(line, reply, sizeof(reply));
      if (sent == 0) {
        printf("max %s\n", reply);
        return 0;
      }
      if (sent < 0) {
        fprintf(stderr, "nightshift max needs nightshiftd running\n");
        return 1;
      }
      fprintf(stderr, "failed to set max\n");
      return 1;
    }

    if ((argc == 3 || argc == 4) && strcmp(argv[1], "ramp") == 0) {
      NSString *first = [NSString stringWithUTF8String:argv[2]];
      NSString *when = first;
      if (argc == 4) {
        NSString *second = [NSString stringWithUTF8String:argv[3]];
        when = first != nil && second != nil
                   ? [NSString stringWithFormat:@"%@ %@", first, second]
                   : nil;
      }
      int minute = 0;
      if (when == nil || !parseClockText(when, &minute)) {
        fprintf(stderr, "use a time like 8:30 PM\n");
        return 1;
      }
      char line[32];
      char reply[64];
      snprintf(line, sizeof(line), "ramp %d\n", minute);
      int sent = talk(line, reply, sizeof(reply));
      if (sent == 0) {
        long saved = 0;
        if (parseValue(reply, 0, 1439, &saved) && saved == minute) {
          printf("Full at %s\n", clockString(minute).UTF8String);
          return 0;
        }
      }
      if (sent < 0) {
        fprintf(stderr, "nightshift ramp needs nightshiftd running\n");
        return 1;
      }
      fprintf(stderr, "failed to set the time\n");
      return 1;
    }

    if (argc != 2) {
      usage();
      return 1;
    }
    long value = 0;
    if (!parseValue(argv[1], 0, 100, &value)) {
      usage();
      return 1;
    }

    char line[16];
    char reply[64];
    snprintf(line, sizeof(line), "%ld\n", value);
    int sent = talk(line, reply, sizeof(reply));
    if (sent == 0) {
      printf("%s\n", reply);
      return 0;
    }
    if (sent == 1) {
      fprintf(stderr, "failed to set Night Shift\n");
      return 1;
    }

    CBBlueLightClient *client = makeClient();
    if (client == nil) {
      fprintf(stderr, "Night Shift is unavailable\n");
      return 1;
    }
    long stored = 0;
    if (!applyStrength(client, value, &stored)) {
      fprintf(stderr, value == 0 ? "failed to disable Night Shift\n"
                                 : "failed to set Night Shift\n");
      return 1;
    }
    printf("%ld\n", stored);
  }
  return 0;
}
