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
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

extern char **environ;

static NSString *daemonBinary(void) {
  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) {
    return nil;
  }
  char resolved[PATH_MAX];
  if (realpath(exe, resolved) == NULL) {
    return nil;
  }
  NSString *dir = [NSString stringWithUTF8String:resolved].stringByDeletingLastPathComponent;
  NSFileManager *files = [NSFileManager defaultManager];
  NSString *beside = [dir stringByAppendingPathComponent:
                               @"Nightshift.app/Contents/MacOS/nightshiftd"];
  if ([files isExecutableFileAtPath:beside]) {
    return beside;
  }
  NSString *installed = [[dir stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"Nightshift.app/Contents/MacOS/nightshiftd"];
  if ([files isExecutableFileAtPath:installed]) {
    return installed;
  }
  return nil;
}

static BOOL startDaemon(void) {
  NSString *daemon = daemonBinary();
  if (daemon == nil) {
    return NO;
  }
  posix_spawnattr_t attr;
  posix_spawn_file_actions_t actions;
  pid_t pid = 0;
  if (posix_spawnattr_init(&attr) != 0) {
    return NO;
  }
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
  if (posix_spawn_file_actions_init(&actions) != 0) {
    posix_spawnattr_destroy(&attr);
    return NO;
  }
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY,
                                   0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  char *argv[] = {(char *)daemon.fileSystemRepresentation, NULL};
  int rc = posix_spawn(&pid, daemon.fileSystemRepresentation, &actions, &attr,
                       argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  return rc == 0;
}

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

static int ask(const char *line, char *reply, size_t cap) {
  int sent = talk(line, reply, cap);
  if (sent != -1) {
    return sent;
  }
  if (!startDaemon()) {
    return -1;
  }
  for (int i = 0; i < 50; i++) {
    usleep(100000);
    sent = talk(line, reply, cap);
    if (sent != -1) {
      return sent;
    }
  }
  return -1;
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
  printf("%s\n", warmthSentence(now, maxv, state, (int)full).UTF8String);
}

static void usage(void) {
  fprintf(stderr, "usage: nightshift [0-100 | max 1-100 | ramp 8:30pm | -h]\n");
}

static void help(void) {
  printf(
      "nightshift sets Night Shift warmth from the terminal and warms it up\n"
      "through the evening.\n"
      "\n"
      "Usage:\n"
      "  nightshift             Show the warmth, and when it reaches the max\n"
      "  nightshift 40          Set warmth to 40 (1-100)\n"
      "  nightshift 0           Turn Night Shift off\n"
      "  nightshift max 60      Set the warmth the evening ramp climbs to\n"
      "  nightshift ramp 8:30pm Reach the max at 8:30 PM\n"
      "  nightshift -h          Show this help\n"
      "\n"
      "Evening ramp:\n"
      "  With a Custom schedule in System Settings > Displays > Night Shift,\n"
      "  warmth starts at 1 when the schedule begins and climbs to the max\n"
      "  over two hours, or by the ramp time. It holds the max until the\n"
      "  schedule ends. Sunset to Sunrise is left alone.\n"
      "\n"
      "  Setting a warmth below the max glides from there to the max. A\n"
      "  warmth above the max becomes the new max. With no max saved, the\n"
      "  first warmth you set becomes the max. During the schedule,\n"
      "  nightshift 0 pauses the ramp until you set a warmth or the next\n"
      "  evening starts.\n"
      "\n"
      "Menu bar:\n"
      "  Nightshift.app keeps an icon in the menu bar. Release Now or Max to\n"
      "  set warmth or the max. Full at is hour, minute, and AM/PM columns.\n"
      "  24-hour hides AM/PM. The warmth line matches this command.\n"
      "\n"
      "Notifications:\n"
      "  Every command goes through Nightshift.app, which starts on its own\n"
      "  if it is not running. It posts a banner when it starts and whenever\n"
      "  warmth or the max changes.\n"
      "\n"
      "  A banner's Options menu, or its arrow, has Set Max and Set Time.\n"
      "  They do the same as nightshift max and nightshift ramp. For banners\n"
      "  that stay on screen, choose Alerts in System Settings >\n"
      "  Notifications > Nightshift.\n"
      "\n"
      "Files, in ~/Library/Application Support/nightshift:\n"
      "  max               The saved max\n"
      "  full              The ramp time\n"
      "  nightshiftd.sock  How the command talks to Nightshift.app\n");
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
    readHourCycle();
    if (argc == 1) {
      char reply[64];
      int sent = ask("status\n", reply, sizeof(reply));
      if (sent == 0) {
        printStatus(reply);
        return 0;
      }
      fprintf(stderr, "failed to reach nightshiftd\n");
      return 1;
    }

    if (argc == 2 &&
        (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0 ||
         strcmp(argv[1], "help") == 0)) {
      help();
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
      int sent = ask(line, reply, sizeof(reply));
      if (sent == 0) {
        printf("max %s\n", reply);
        return 0;
      }
      if (sent < 0) {
        fprintf(stderr, "failed to reach nightshiftd\n");
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
      int sent = ask(line, reply, sizeof(reply));
      if (sent == 0) {
        long saved = 0;
        if (parseValue(reply, 0, 1439, &saved) && saved == minute) {
          printf("Full at %s\n", clockString(minute).UTF8String);
          return 0;
        }
      }
      if (sent < 0) {
        fprintf(stderr, "failed to reach nightshiftd\n");
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
    int sent = ask(line, reply, sizeof(reply));
    if (sent == 0) {
      printf("%s\n", reply);
      return 0;
    }
    fprintf(stderr, sent < 0 ? "failed to reach nightshiftd\n"
                             : "failed to set Night Shift\n");
    return 1;
  }
  return 0;
}
