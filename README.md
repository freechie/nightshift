# nightshift

Set the macOS Night Shift warmth from the terminal. `0` is off. `100` is as warm as Night Shift goes.

Inspired by [nshift](https://github.com/jenghis/nshift) by Jenghis (Apache License 2.0), which introduced the `0`–`100` scale. This repository does not include nshift's source.

## Install

```sh
brew install freechie/tap/nightshift
```

## Usage

```sh
nightshift            # Warmth is at 20%, reaching 40% at 7:00 PM, while gliding
nightshift            # Warmth is at 40%, once warmth and max are the same
nightshift 40         # set warmth to 40 and turn Night Shift on
nightshift 0          # turn Night Shift off
nightshift max 60     # set the ramp's max
nightshift ramp 8:30pm # reach the max at 8:30 PM
nightshift -h         # explain the commands, the ramp, and the notifications
```

A warmth is a whole number from `0` to `100`. A max is from `1` to `100`.

## Daemon

```sh
brew services start freechie/tap/nightshift
```

This starts the daemon inside `Nightshift.app` at login. It posts a banner when it starts and when the warmth changes. On a Custom schedule it begins at warmth 1 and reaches your max two hours later, or at the time you set. If no max is saved, the current warmth becomes the max. It holds that max until the schedule ends. `nightshift 40` during the schedule jumps to 40 and glides toward the max. A warmth above the max becomes the new max. `nightshift max 60` changes the max directly. Sunset to Sunrise is left alone.

Notifications say "Warmth is at 40%", or "Warmth is at 20%, reaching 40% at 7:00 PM" while it is still climbing. Clicking one leaves it on screen. Its Options menu, or the arrow at its top right, opens Set Max and Set Time. In System Settings → Notifications → Nightshift, choose Alerts so those fields stay on screen.

The daemon listens on `~/Library/Application Support/nightshift/nightshiftd.sock`. The max is stored beside it in `max`, and a chosen arrival time in `full`. Only your user can read them. Logs go to `$(brew --prefix)/var/log/nightshiftd.log`.

The command starts `Nightshift.app` if the daemon is not already running, then sends the instruction to it. That is what posts the banner. A command that exits cannot show a notification on its own: macOS needs the app bundle, and the evening ramp has to keep running after the command is gone.

## Private API

Night Shift has no public API. The daemon uses `CBBlueLightClient` from Apple's private `CoreBrightness` framework, and a macOS update can change it. It checks the method signatures first. If they changed, it prints `Night Shift is unavailable` and exits `1` instead of calling them.

Checked on macOS 27.0 (Golden Gate).

## Build from source

```sh
make
make install PREFIX="$HOME/.local"
"$HOME/.local/Nightshift.app/Contents/MacOS/nightshiftd"
```

`make install` puts the `nightshift` command in `PREFIX/bin` and the daemon in `PREFIX/Nightshift.app`. Run that app path, not a bare `nightshiftd`, or notifications have nowhere to go.

`main.m` is the command and `nightshiftd.m` is the daemon. `NightShift.m` holds the Night Shift calls they share.

## License

Apache License 2.0. See `LICENSE`. Copyright 2026 John.
