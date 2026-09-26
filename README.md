# nshift

Set the macOS Night Shift warmth from the terminal. `0` is off. `100` is as warm as Night Shift goes.

The idea and the `0`–`100` scale come from [nshift](https://github.com/jenghis/nshift) by Jenghis, the parked shell utility this project started from. That program calls the same private helper, `CBBlueLightClient`, and turns Night Shift off when the strength is `0`.

The program calls `CBBlueLightClient` in the private `CoreBrightness` framework. There is no public Night Shift API. A macOS update can change those methods. Before it sets or reads anything, `nshift` compares the live method encodings with the ones below. A mismatch prints `Night Shift is unavailable` and exits `1`.

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
  -o nshift main.m
```

`-F` points the linker at the SDK copy of `CoreBrightness`. The system copy lives in the dynamic linker shared cache, so a plain `-framework CoreBrightness` does not find it.

## Usage

```sh
./nshift        # print the stored warmth, 0-100
./nshift 40     # set warmth to 40 and turn Night Shift on
./nshift 0      # set warmth to 0 and turn Night Shift off
```

`nshift` with no arguments prints the warmth the helper has stored. That number can stay above `0` while Night Shift is off.

A set prints the warmth read back after the call, not the number you typed. The helper stores a fraction from `0` to `1`. The program multiplies by `100` and rounds to the nearest integer.

Anything other than one integer from `0` to `100` prints `usage: nshift <0-100>` and exits `1`. A failed read or write also exits `1`.

## Layout

`main.m` is the command. `CBBlueLightClient.h` declares the three methods the command uses.

## nshiftd

Not built yet. This is the program to write next.

`nshiftd` stays running under `launchd`. `nshift` keeps working when `nshiftd` is absent: it calls `CBBlueLightClient` itself, as it does now. When `nshiftd` is running, `nshift 40` sends `40` to the daemon, and the daemon makes the Night Shift call.

The daemon uses the same encoding check and the same three methods.

1. Accept one integer over a Unix socket and set Night Shift.
2. On wake, reapply the last strength. On sleep, leave the current setting in place. Fade from the current strength to a new one by stepping the value on a timer.
3. Read the schedule Night Shift already stores and follow sunset with that, rather than calculating the sun position in this program.

The socket path is `~/Library/Application Support/nshift/nshiftd.sock`. The daemon listens there. The command connects, writes one line containing the integer, and reads back one line containing the stored warmth or an error.
