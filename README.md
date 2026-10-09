# nightshift

Set the macOS Night Shift warmth from the terminal or the menu bar. `0` is off. `100` is as warm as Night Shift goes.

## Install

Download [Nightshift.zip](https://github.com/freechie/nightshift/releases/latest/download/Nightshift.zip) and unpack it into `~/.local`:

```sh
mkdir -p "$HOME/.local"
unzip -o -d "$HOME/.local" Nightshift.zip
open "$HOME/.local/Nightshift.app"
```

The zip holds `bin/nightshift` and `Nightshift.app`. Add `$HOME/.local/bin` to your `PATH`. The command finds the app beside `bin`.

A downloaded copy is quarantined. Clear that before the first open:

```sh
xattr -dr com.apple.quarantine "$HOME/.local/Nightshift.app" "$HOME/.local/bin/nightshift"
```

`make package` builds the same zip at `dist/Nightshift.zip`.

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

Setting a warmth is free. The evening ramp is a year at a time. `nightshift buy` opens checkout and saves the token. The menu button does the same. `nightshift license` prints the date it runs through. `nightshift license <token>` saves a token you already have.

## Menu bar

`Nightshift.app` keeps an icon in the menu bar. The first line is the same sentence `nightshift` prints. Release Now or Max to set the warmth or the max. Full at is hour, minute, and AM/PM columns. 24-hour hides AM/PM. That choice is saved in `clock`, beside `max` and `full`.

## Daemon

Open `Nightshift.app` and leave it running. It posts a banner when it starts and when the warmth changes. On a Custom schedule it begins at warmth 1 and reaches your max two hours later, or at the time you set. If no max is saved, the current warmth becomes the max. It holds that max until the schedule ends. `nightshift 40` during the schedule jumps to 40 and glides toward the max. A warmth above the max becomes the new max. `nightshift max 60` changes the max directly. Sunset to Sunrise is left alone.

Notifications say "Warmth is at 40%", or "Warmth is at 20%, reaching 40% at 7:00 PM" while it is still climbing. Clicking one leaves it on screen. Its Options menu, or the arrow at its top right, opens Set Max and Set Time. In System Settings → Notifications → Nightshift, choose Alerts so those fields stay on screen.

The daemon listens on `~/Library/Application Support/nightshift/nightshiftd.sock`. The max is stored beside it in `max`, a chosen arrival time in `full`, and 12-hour or 24-hour in `clock`. Only your user can read them.

The command starts `Nightshift.app` if the daemon is not already running, then sends the instruction to it. That is what posts the banner. A command that exits cannot show a notification on its own: macOS needs the app bundle, and the evening ramp has to keep running after the command is gone.

## Private API

Night Shift has no public API. The daemon uses `CBBlueLightClient` from Apple's private `CoreBrightness` framework, and a macOS update can change it. It checks the method signatures first. If they changed, it prints `Night Shift is unavailable` and exits `1` instead of calling them.

Checked on macOS 27.0 (Golden Gate).

## Build from source

```sh
make
open Nightshift.app
./nightshift
```

Run `Nightshift.app`, not a bare `nightshiftd`, or notifications have nowhere to go. `./nightshift` sends commands to that app.

`main.m` is the command and `nightshiftd.m` is the daemon. `NightShift.m` holds the Night Shift calls they share.

## License

Apache License 2.0. See `LICENSE`. Copyright 2026 John.
