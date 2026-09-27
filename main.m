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
#include <unistd.h>

static int sendToDaemon(long value, long *stored) {
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

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  memcpy(addr.sun_path, path, strlen(path) + 1);

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    return -1;
  }

  char out[16];
  int len = snprintf(out, sizeof(out), "%ld\n", value);
  if (len < 0 || (size_t)len >= sizeof(out) ||
      write(fd, out, (size_t)len) != len) {
    close(fd);
    return 1;
  }

  char buf[64];
  size_t used = 0;
  while (used + 1 < sizeof(buf)) {
    char c;
    ssize_t n = read(fd, &c, 1);
    if (n == 0) {
      break;
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      close(fd);
      return 1;
    }
    if (c == '\n') {
      break;
    }
    buf[used++] = c;
  }
  buf[used] = '\0';
  close(fd);

  char *end = NULL;
  long reply = strtol(buf, &end, 10);
  if (end == buf || *end != '\0') {
    return 1;
  }
  *stored = reply;
  return 0;
}

static void usage(void) { fprintf(stderr, "usage: nightshift [0-100]\n"); }

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 1) {
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
    long stored = 0;
    int sent = sendToDaemon(value, &stored);
    if (sent == 0) {
      printf("%ld\n", stored);
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
    if (!applyStrength(client, value, &stored)) {
      fprintf(stderr, value == 0 ? "failed to disable Night Shift\n"
                                 : "failed to set Night Shift\n");
      return 1;
    }
    printf("%ld\n", stored);
  }
  return 0;
}
