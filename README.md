# nightshift

Set the macOS Night Shift warmth from the terminal. `0` is off. `100` is as warm as Night Shift goes.

Inspired by [nshift](https://github.com/jenghis/nshift) by Jenghis (Apache License 2.0), which introduced the `0`–`100` scale. This repository does not include nshift's source.

## Install

```sh
brew install freechie/tap/nightshift
```

## Usage

```sh
nightshift        # print the current warmth
nightshift 40     # set warmth to 40 and turn Night Shift on
nightshift 0      # turn Night Shift off
```

After a set, `nightshift` prints the warmth macOS stored. Anything other than one whole number from `0` to `100` prints the usage line and exits `1`.

## Daemon (optional)

```sh
brew services start freechie/tap/nightshift
```

This runs `nightshiftd` at login. When it is running, `nightshift 40` sends the value to it. When it isn't, `nightshift` sets Night Shift itself. Both work the same today. The daemon is groundwork for a warmth ramp through the evening.

The daemon listens on `~/Library/Application Support/nightshift/nightshiftd.sock`. Only your user can connect. Logs go to `$(brew --prefix)/var/log/nightshiftd.log`.

## Private API

Night Shift has no public API. Both programs use `CBBlueLightClient` from Apple's private `CoreBrightness` framework, and a macOS update can change it. Each program checks the method signatures first. If they changed, it prints `Night Shift is unavailable` and exits `1` instead of calling them.

Checked on macOS 27.0 (Golden Gate).

## Build from source

```sh
make
make install PREFIX="$HOME/.local"
```

`main.m` is the command and `nightshiftd.m` is the daemon. `NightShift.m` holds the Night Shift calls they share.

## License

Apache License 2.0. See `LICENSE`. Copyright 2026 John.
