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
#import <readpassphrase.h>
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

static const int kReplyTimeout = 2;

static int talk(const char *line, char *reply, size_t cap, BOOL whole) {
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
  struct timeval replyTv = {.tv_sec = kReplyTimeout, .tv_usec = 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &replyTv, sizeof(replyTv));
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

  size_t used = 0;
  while (used + 1 < cap) {
    ssize_t n;
    do {
      n = read(fd, reply + used, cap - 1 - used);
    } while (n < 0 && errno == EINTR);
    if (n <= 0) {
      break;
    }
    used += (size_t)n;
    if (!whole) {
      break;
    }
  }
  close(fd);
  if (used == 0) {
    return 1;
  }
  reply[used] = '\0';
  char *nl = strchr(reply, '\n');
  if (nl == NULL) {
    return 1;
  }
  if (!whole) {
    *nl = '\0';
  }
  if (reply[0] == '\0' || strcmp(reply, "failed") == 0 ||
      strncmp(reply, "failed\n", 7) == 0) {
    return 1;
  }
  return 0;
}

static int askMode(const char *line, char *reply, size_t cap, BOOL whole) {
  int sent = talk(line, reply, cap, whole);
  if (sent != -1) {
    return sent;
  }
  if (!startDaemon()) {
    return -1;
  }
  for (int i = 0; i < 50; i++) {
    usleep(100000);
    sent = talk(line, reply, cap, whole);
    if (sent != -1) {
      return sent;
    }
  }
  return -1;
}

static int ask(const char *line, char *reply, size_t cap) {
  return askMode(line, reply, cap, NO);
}

static void printReply(const char *reply) {
  size_t len = strlen(reply);
  if (len > 0 && reply[len - 1] == '\n') {
    fputs(reply, stdout);
    return;
  }
  printf("%s\n", reply);
}

static int finishReply(int sent, const char *reply, const char *failText, BOOL setting) {
  if (sent == 0 && setting && strcmp(reply, "unsupported") == 0) {
    fprintf(stderr, "True Tone is unavailable\n");
    return 1;
  }
  if (sent == 0 && strcmp(reply, "approval") == 0) {
    fprintf(stderr, "Allow Nightshift in Login Items\n");
    return 1;
  }
  if (sent == 0) {
    printReply(reply);
    return 0;
  }
  if (sent < 0) {
    fprintf(stderr, "failed to reach nightshiftd\n");
    return 1;
  }
  fprintf(stderr, "%s\n", failText);
  return 1;
}

static int openSettings(const char *url) {
  pid_t opened = 0;
  char *argv[] = {"/usr/bin/open", (char *)url, NULL};
  if (posix_spawn(&opened, "/usr/bin/open", NULL, NULL, argv, environ) != 0) {
    fprintf(stderr, "could not open System Settings\n");
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
  printf("%s\n", warmthSentence(now, maxv, state, (int)full).UTF8String);
}

static BOOL paidReply(const char *reply) {
  if (strcmp(reply, "locked") != 0) {
    return NO;
  }
  fprintf(stderr, "%s\n", rampOffer().UTF8String);
  return YES;
}

static void usage(void) {
  fprintf(stderr,
          "usage: nightshift [0-100 | max 1-100 | ramp 8:30pm | schedule | "
          "clock | login | dark | tone | notifications | "
          "license | buy | -h]\n");
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
      "  nightshift license     Show whether the ramp is unlocked\n"
      "  nightshift license id  Show this Mac's install ID, for support\n"
      "  nightshift license secret [--replace]\n"
      "                         Enter the install secret support gave you\n"

      "  nightshift buy         Pay for a year of the ramp\n"
      "  nightshift schedule    Show off, custom, or sunset\n"
      "  nightshift schedule custom\n"
      "                         Use a Custom schedule\n"
      "  nightshift clock       Show 12 or 24\n"
      "  nightshift clock 24    Use 24-hour Full at\n"
      "  nightshift login       Show whether Nightshift opens at login\n"
      "  nightshift login on    Open Nightshift at login\n"
      "  nightshift dark        Show whether Dark mode is on\n"
      "  nightshift dark on     Turn Dark mode on\n"
      "  nightshift tone        Show True Tone, or unsupported\n"
      "  nightshift tone off    Turn True Tone off\n"
      "  nightshift notifications\n"
      "                         Open Notification settings\n"
      "  nightshift -h          Show this help\n"
      "\n"
      "License:\n"
      "  Setting a warmth is free. The evening ramp is paid: nightshift max,\n"
      "  nightshift ramp, and the climb to the max. nightshift buy opens\n"
      "  checkout and saves the token. nightshift license <token> saves one\n"
      "  you already have. nightshift license secret reads a secret from\n"
      "  support from the keyboard (not shown) or one line of a pipe, never\n"
      "  the command line, saves it, and fetches the license. It won't\n"
      "  replace a secret this Mac already has without --replace.\n"
      "\n"
      "Evening ramp:\n"
      "  With a Custom schedule (nightshift schedule custom), warmth starts\n"
      "  at 1 when the schedule begins and climbs to the max\n"
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
      "  Nightshift.app keeps an icon in the menu bar. Release Current or Max to\n"
      "  set warmth or the max. Type the Full at time, hour then minute.\n"
      "  24-hour hides AM/PM. The menu also has Dark mode, True Tone,\n"
      "  Night Shift Off, Custom, or Sunset, and Quit. Settings opens\n"
      "  General, Night Shift, Keyboard, and Nightshift Pro.\n"
      "  Control-Option-Command-Minus and Control-Option-Command-Equals lower\n"
      "  and raise warmth. The same controls are available from the\n"
      "  nightshift command.\n"
      "\n"
      "Notifications:\n"
      "  Every command goes through Nightshift.app, which starts on its own\n"
      "  if it is not running. Plain nightshift only reports, so it says\n"
      "  Nightshift isn't running instead. The app posts a banner when it\n"
      "  starts and whenever warmth or the max changes.\n"
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

// One line of input for `nightshift license secret`: typed with echo off
// when stdin is a terminal, else the first line of the pipe. The secret is
// never an argument, which would leave it in shell history and ps.
static BOOL readSecretLine(char *buf, size_t size) {
  if (isatty(STDIN_FILENO)) {
    return readpassphrase("Install secret: ", buf, size, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != NULL;
  }
  size_t used = 0;
  int c;
  while ((c = getchar()) != EOF && c != '\n') {
    if (used + 1 >= size) {
      return NO;
    }
    buf[used++] = (char)c;
  }
  buf[used] = '\0';
  return used > 0;
}

static void wipe(char *buf, size_t size) {
  volatile char *p = buf;
  while (size-- > 0) {
    *p++ = 0;
  }
}

static int licenseSecret(BOOL replace) {
  char line[256];
  BOOL got = readSecretLine(line, sizeof(line));
  NSString *value = got ? [NSString stringWithUTF8String:line] : nil;
  wipe(line, sizeof(line));
  if (value == nil) {
    fprintf(stderr, "no install secret was entered\n");
    return 1;
  }
  NSString *err = nil;
  if (!rampSaveInstallSecret(value, replace, &err)) {
    fprintf(stderr, "%s\n", (err != nil ? err : @"couldn't save the install secret").UTF8String);
    return 1;
  }
  printf("Saved the install secret\n");
  NSString *out = nil;
  err = nil;
  int fetched = rampTakeLicenseUpdate(&out, &err);
  if (fetched == 0) {
    if (out != nil) {
      printf("%s\n", out.UTF8String);
    }
    return 0;
  }
  if (fetched == 2) {
    fprintf(stderr, "%s\n", (err != nil ? err : @"could not save the license").UTF8String);
    return 1;
  }
  fprintf(stderr,
          "No license came with this secret yet. Check that support has this Mac's\n"
          "install ID (nightshift license id), or try nightshift license later.\n");
  return 1;
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
      int sent = talk("status\n", reply, sizeof(reply), NO);
      if (sent == 0) {
        printStatus(reply);
        return 0;
      }
      fprintf(stderr, sent < 0 ? "Nightshift isn't running\n"
                                 "Open Nightshift.app, or set a warmth with nightshift <0-100>\n"
                               : "failed to reach nightshiftd\n");
      return 1;
    }

    if (argc == 2 &&
        (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0 ||
         strcmp(argv[1], "help") == 0)) {
      help();
      return 0;
    }

    if (argc == 3 && strcmp(argv[1], "license") == 0 && strcmp(argv[2], "id") == 0) {
      NSString *installID = rampInstallID();
      if (installID == nil) {
        fprintf(stderr, "could not read the install ID in %s; it was left as is\n",
                rampInstallIDPath().fileSystemRepresentation);
        return 1;
      }
      printf("%s\n", installID.UTF8String);
      return 0;
    }

    // A license moves to a new install ID only through support, who check
    // the purchase first: install IDs aren't secret (patch review v2, R1).
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "license") == 0 &&
        strcmp(argv[2], "rebind") == 0) {
      fprintf(stderr,
              "To move a license to this Mac, contact support with the email you paid with\n"
              "and this Mac's install ID (nightshift license id).\n");
      return 1;
    }

    if (argc >= 3 && strcmp(argv[1], "license") == 0 && strcmp(argv[2], "secret") == 0) {
      if (argc == 3) {
        return licenseSecret(NO);
      }
      if (argc == 4 && strcmp(argv[3], "--replace") == 0) {
        return licenseSecret(YES);
      }
      fprintf(stderr,
              "nightshift license secret takes no value: it reads the secret from the\n"
              "keyboard or a pipe, so it stays out of shell history and ps.\n"
              "usage: nightshift license secret [--replace] < file\n");
      return 1;
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "license") == 0) {
      if (argc == 3) {
        NSString *token = [@(argv[2]) stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *out = nil;
        NSString *err = nil;
        int saved = rampInstallReported(token, &out, &err);
        if (out != nil) {
          printf("%s\n", out.UTF8String);
        }
        if (err != nil) {
          fprintf(stderr, "%s\n", err.UTF8String);
        }
        return saved;
      }
      if (rampLicensed()) {
        NSString *until = rampLicenseUntil();
        if (until != nil) {
          printf("Ramp is unlocked through %s\n", until.UTF8String);
        } else {
          printf("Ramp is unlocked\n");
        }
        return 0;
      }
      fprintf(stderr, "%s\n", rampOffer().UTF8String);
      return 1;
    }

    if (argc == 2 && strcmp(argv[1], "buy") == 0) {
      NSString *url = nil;
      BOOL portal = NO;
      NSString *out = nil;
      NSString *err = nil;
      int step = rampBeginPurchase(&url, &portal, &out, &err);
      if (step == 0) {
        if (out != nil) {
          printf("%s\n", out.UTF8String);
        }
        if (err != nil) {
          fprintf(stderr, "%s\n", err.UTF8String);
        }
        return 0;
      }
      if (step != 1 || url == nil) {
        fprintf(stderr, "%s\n", (err != nil ? err : @"could not open checkout").UTF8String);
        return 1;
      }
      NSURL *page = rampPurchasePage(url);
      if (page == nil) {
        fprintf(stderr, "could not open checkout\n");
        return 1;
      }
      // The checked text, which page prints back exactly. It starts with
      // "https://", so open never reads it as an option. Held in a local that
      // ARC keeps to the end of the scope, so the C string stays valid
      // through printf and open.
      NS_VALID_UNTIL_END_OF_SCOPE NSString *pageString = page.absoluteString;
      const char *pageText = pageString.UTF8String;
      printf("%s\n", pageText);
      pid_t opened = 0;
      char *openArgv[] = {"/usr/bin/open", (char *)pageText, NULL};
      if (posix_spawn(&opened, "/usr/bin/open", NULL, NULL, openArgv, environ) != 0) {
        fprintf(stderr, "could not open checkout\n");
        return 1;
      }
      if (portal) {
        return 0;
      }
      for (int i = 0; i < 90; i++) {
        sleep(2);
        int got = rampTakeLicenseUpdate(&out, &err);
        if (got == 0) {
          if (out != nil) {
            printf("%s\n", out.UTF8String);
          }
          if (err != nil) {
            fprintf(stderr, "%s\n", err.UTF8String);
          }
          return 0;
        }
        if (got == 2) {
          fprintf(stderr, "%s\n", (err != nil ? err : @"could not save the license").UTF8String);
          return 1;
        }
      }
      fprintf(stderr, "checkout did not finish\n");
      return 1;
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
      if (sent == 0 && paidReply(reply)) {
        return 1;
      }
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
      if (sent == 0 && paidReply(reply)) {
        return 1;
      }
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

    if (argc == 2 && strcmp(argv[1], "notifications") == 0) {
      printf("Notifications for Nightshift\n");
      return openSettings(
          "x-apple.systempreferences:com.apple.Notifications-Settings.extension");
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "schedule") == 0) {
      if (argc == 3 && strcmp(argv[2], "off") != 0 &&
          strcmp(argv[2], "custom") != 0 && strcmp(argv[2], "sunset") != 0) {
        fprintf(stderr, "use off, custom, or sunset\n");
        return 1;
      }
      char line[32];
      char reply[32];
      snprintf(line, sizeof(line), argc == 2 ? "schedule\n" : "schedule %s\n",
               argc == 2 ? "" : argv[2]);
      return finishReply(ask(line, reply, sizeof(reply)), reply,
                         "failed to set the schedule", argc == 3);
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "clock") == 0) {
      if (argc == 3 && strcmp(argv[2], "12") != 0 && strcmp(argv[2], "24") != 0) {
        fprintf(stderr, "use 12 or 24\n");
        return 1;
      }
      char line[16];
      char reply[16];
      snprintf(line, sizeof(line), argc == 2 ? "clock\n" : "clock %s\n",
               argc == 2 ? "" : argv[2]);
      return finishReply(ask(line, reply, sizeof(reply)), reply,
                         "failed to set the clock", argc == 3);
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "login") == 0) {
      if (argc == 3 && strcmp(argv[2], "on") != 0 && strcmp(argv[2], "off") != 0) {
        fprintf(stderr, "use on or off\n");
        return 1;
      }
      char line[16];
      char reply[16];
      snprintf(line, sizeof(line), argc == 2 ? "login\n" : "login %s\n",
               argc == 2 ? "" : argv[2]);
      return finishReply(ask(line, reply, sizeof(reply)), reply,
                         "failed to set login", argc == 3);
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "dark") == 0) {
      if (argc == 3 && strcmp(argv[2], "on") != 0 && strcmp(argv[2], "off") != 0) {
        fprintf(stderr, "use on or off\n");
        return 1;
      }
      char line[16];
      char reply[16];
      snprintf(line, sizeof(line), argc == 2 ? "dark\n" : "dark %s\n",
               argc == 2 ? "" : argv[2]);
      return finishReply(ask(line, reply, sizeof(reply)), reply,
                         "failed to set Dark mode", argc == 3);
    }

    if ((argc == 2 || argc == 3) && strcmp(argv[1], "tone") == 0) {
      if (argc == 3 && strcmp(argv[2], "on") != 0 && strcmp(argv[2], "off") != 0) {
        fprintf(stderr, "use on or off\n");
        return 1;
      }
      char line[16];
      char reply[16];
      snprintf(line, sizeof(line), argc == 2 ? "tone\n" : "tone %s\n",
               argc == 2 ? "" : argv[2]);
      return finishReply(ask(line, reply, sizeof(reply)), reply,
                         "failed to set True Tone", argc == 3);
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
}
