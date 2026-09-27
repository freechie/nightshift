# nightshift

Set the macOS Night Shift warmth from the terminal. `0` is off. `100` is as warm as Night Shift goes.

The idea and the `0`–`100` scale come from [nshift](https://github.com/jenghis/nshift) by Jenghis (Copyright 2017, [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)). That program calls the same private helper, `CBBlueLightClient`, and turns Night Shift off when the strength is `0`. These files were written for this repository. They do not include nshift's source.

## Install

```sh
brew install freechie/tap/nightshift
```

This installs `nightshift` and `nightshiftd`. Homebrew builds them from source with the Command Line Tools.

## Usage

```sh
nightshift        # print the stored warmth, 0-100
nightshift 40     # set warmth to 40 and turn Night Shift on
nightshift 0      # set warmth to 0 and turn Night Shift off
```

With no arguments it prints the warmth Night Shift has stored. That number can stay above `0` while Night Shift is off.

A set prints the warmth read back after the call, not the number you typed. Night Shift stores a fraction from `0` to `1`. The program multiplies by `100` and rounds to the nearest integer.

Anything other than one integer from `0` to `100` prints `usage: nightshift [0-100]` and exits `1`. A failed read or write also exits `1`.

`nightshift` does not need the daemon. When `nightshiftd` is listening, `nightshift 40` sends `40` to it and prints the daemon's reply. When nothing is listening, `nightshift` sets Night Shift itself. Once the daemon has accepted a value, a failed reply exits `1` instead of setting Night Shift a second time. With no arguments, `nightshift` always reads the warmth directly.

## nightshiftd (optional)

Start it now and at every login:

```sh
brew services start freechie/tap/nightshift
```

`brew services` takes the formula name. The program it runs is `nightshiftd`. To run the daemon in a terminal instead, type `nightshiftd` and stop it with Control-c. The service logs to `$(brew --prefix)/var/log/nightshiftd.log`.

It listens on:

```text
~/Library/Application Support/nightshift/nightshiftd.sock
```

The socket is mode `0600`, so only your user can connect. A second `nightshiftd` exits when one is already listening. Each connection sends one line, an integer from `0` to `100`. The daemon writes back the stored warmth, or `failed`.

Still to build: reapply the last strength on wake, fade between two strengths on a timer, and follow the schedule Night Shift already stores.

## Private API

Both programs call `CBBlueLightClient` in the private `CoreBrightness` framework. There is no public Night Shift API, and a macOS update can change these methods. Before setting or reading anything, each program compares the live method encodings with the ones below. A mismatch prints `Night Shift is unavailable` and exits `1`.

| Method | Encoding on macOS 27.0 |
| --- | --- |
| `setStrength:commit:` | `B24@0:8f16B20` |
| `setEnabled:` | `B20@0:8B16` |
| `getStrength:` | `B24@0:8^f16` |

Checked on macOS 27.0 (Golden Gate), build 26A428.

## Build from source

```sh
make
make install PREFIX="$HOME/.local"
```

`make install` copies both programs into `PREFIX/bin`. The Makefile passes `-F` with the SDK's `PrivateFrameworks` folder. The system copy of `CoreBrightness` lives in the dynamic linker shared cache, so a plain `-framework CoreBrightness` does not find it.

`main.m` is the command. `nightshiftd.m` is the daemon. `CBBlueLightClient.h` declares the three methods both use.

## License

Apache License 2.0. See `LICENSE`.

Copyright 2026 John.
