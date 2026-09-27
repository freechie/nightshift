# nightshift

Set the macOS Night Shift warmth from the terminal. `0` is off. `100` is as warm as Night Shift goes.

The idea and the `0`–`100` scale come from [nshift](https://github.com/jenghis/nshift) by Jenghis (Copyright 2017, [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)). That program calls the same private helper, `CBBlueLightClient`, and turns Night Shift off when the strength is `0`. These files were written for this repository. They do not include nshift's source.

The program calls `CBBlueLightClient` in the private `CoreBrightness` framework. There is no public Night Shift API. A macOS update can change those methods. Before it sets or reads anything, `nightshift` compares the live method encodings with the ones below. A mismatch prints `Night Shift is unavailable` and exits `1`.

| Method | Encoding on macOS 27.0 |
| --- | --- |
| `setStrength:commit:` | `B24@0:8f16B20` |
| `setEnabled:` | `B20@0:8B16` |
| `getStrength:` | `B24@0:8^f16` |

Checked on macOS 27.0 (Golden Gate), build 26A428.

## Build

From this directory, with Xcode installed:

```sh
clang -fobjc-arc -framework Foundation \
  -F"$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" \
  -framework CoreBrightness \
  -o nightshift main.m

clang -fobjc-arc -framework Foundation \
  -F"$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" \
  -framework CoreBrightness \
  -o nightshiftd nightshiftd.m
```

`-F` points the linker at the SDK copy of `CoreBrightness`. The system copy lives in the dynamic linker shared cache, so a plain `-framework CoreBrightness` does not find it.

## Usage today

`nightshift` calls `CBBlueLightClient` itself. Run it from this directory:

```sh
./nightshift        # print the stored warmth, 0-100
./nightshift 40     # set warmth to 40 and turn Night Shift on
./nightshift 0      # set warmth to 0 and turn Night Shift off
```

With no arguments it prints the warmth the helper has stored. That number can stay above `0` while Night Shift is off.

A set prints the warmth read back after the call, not the number you typed. The helper stores a fraction from `0` to `1`. The program multiplies by `100` and rounds to the nearest integer.

Anything other than one integer from `0` to `100` prints `usage: nightshift <0-100>` and exits `1`. A failed read or write also exits `1`.

## nightshiftd

`nightshiftd` is a foreground process. Leave it running in a terminal. It listens on:

```text
~/Library/Application Support/nightshift/nightshiftd.sock
```

The socket is mode `0600`. A second `nightshiftd` exits when one is already listening. Each connection sends one line, an integer from `0` to `100`. The daemon writes back the stored warmth, or `failed`. It uses the same encoding check and the same three methods as the command.

```sh
./nightshiftd
printf '70\n' | nc -U "$HOME/Library/Application Support/nightshift/nightshiftd.sock"
```

Stop it with Control-c in that terminal.

Still to build in the daemon: start it with `launchd`, reapply the last strength on wake, fade between two strengths on a timer, and follow the schedule Night Shift already stores.

## Calling it from any directory

The command to type is `nightshift 70` or `nightshift 100`, from any directory, with no shell function.

That path is not built yet. `main.m` still talks only to `CBBlueLightClient`. The next change is inside this repo:

1. `nightshift 70` connects to `nightshiftd.sock`, writes `70` and a newline, and prints the daemon’s reply.
2. If nothing is listening, the command sets Night Shift itself, as it does now.
3. `nightshift` with no arguments keeps reading the stored warmth directly. The daemon has no read command.
4. Symlink the `nightshift` binary into a directory already on `PATH`, such as `~/.local/bin`, so the name works outside this directory.

## Layout

`main.m` is the command. `nightshiftd.m` is the daemon. `CBBlueLightClient.h` declares the three methods both use.

## License

Apache License 2.0. See `LICENSE`.

Copyright 2026 John.
