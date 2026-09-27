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
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static BOOL daemonAlreadyRunning(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return NO;
  }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

  BOOL running = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
  close(fd);
  return running;
}

static int listenSocket(const char *path) {
  if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    return -1;
  }
  if (daemonAlreadyRunning(path)) {
    return -1;
  }
  unlink(path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
      chmod(path, S_IRUSR | S_IWUSR) < 0 || listen(fd, 4) < 0) {
    close(fd);
    unlink(path);
    return -1;
  }

  return fd;
}

static BOOL readMessage(int fd, char *buf, size_t cap) {
  size_t used = 0;

  while (used + 1 < cap) {
    char c;
    ssize_t n = read(fd, &c, 1);
    if (n == 0) {
      buf[used] = '\0';
      return used > 0;
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return NO;
    }
    if (c == '\n') {
      buf[used] = '\0';
      return YES;
    }
    buf[used++] = c;
  }
  return NO;
}

int main(void) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);

    CBBlueLightClient *client = makeClient();
    if (client == nil) {
      fprintf(stderr, "Night Shift is unavailable\n");
      return 1;
    }

    NSString *dir =
        [NSHomeDirectory() stringByAppendingPathComponent:
                               @"Library/Application Support/nightshift"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
      fprintf(stderr, "failed to create %s\n", dir.fileSystemRepresentation);
      return 1;
    }

    NSString *sock = [dir stringByAppendingPathComponent:@"nightshiftd.sock"];
    int server = listenSocket(sock.fileSystemRepresentation);
    if (server < 0) {
      fprintf(stderr, "failed to listen on %s\n",
              sock.fileSystemRepresentation);
      return 1;
    }
    fprintf(stderr, "listening on %s\n", sock.fileSystemRepresentation);

    for (;;) {
      int connection = accept(server, NULL, NULL);
      if (connection < 0) {
        if (errno == EINTR) {
          continue;
        }
        fprintf(stderr, "accept failed\n");
        close(server);
        unlink(sock.fileSystemRepresentation);
        return 1;
      }

      struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
      setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

      char buf[64];
      char *end = NULL;
      BOOL gotLine = readMessage(connection, buf, sizeof(buf));
      long value = gotLine ? strtol(buf, &end, 10) : -1;
      BOOL numeric = gotLine && end != buf && *end == '\0';
      long stored = 0;
      if (numeric && value >= 0 && value <= 100 &&
          applyStrength(client, value, &stored)) {
        dprintf(connection, "%ld\n", stored);
      } else {
        dprintf(connection, "failed\n");
      }
      close(connection);
    }
  }
}
