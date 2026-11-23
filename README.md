# nightshift

Set the macOS Night Shift warmth from the terminal or the menu bar. `0` is off. `100` is as warm as Night Shift goes.

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

Leave Nightshift Swift running. On a Custom schedule it begins at warmth 1 and reaches your max two hours later, or at the time you set. If no max is saved, the current warmth becomes the max. It holds that max until the schedule ends. `nightshift 40` during the schedule jumps to 40 and glides toward the max. A warmth above the max becomes the new max. `nightshift max 60` changes the max directly. Sunset to Sunrise is left alone.

## Menu bar

The menu bar icon shows the same sentence `nightshift` prints. Release Color temperature or Max to set the warmth or the max. Full at uses the system date picker. 24-hour is a Settings switch.

## The evening ramp

Setting a warmth is free. The evening ramp is a year at a time. `nightshift buy` opens checkout and saves the license. The menu button does the same. `nightshift license` prints the date it runs through. `nightshift license <token>` saves a license you already have. A license works only on the Mac it was issued for. If a license needs to move to another Mac, contact support with the email you paid with and the output of `nightshift license id`.

If support gives you a secret, enter it with `nightshift license secret`. It asks for the secret without showing it, or reads one line from a pipe (`nightshift license secret < secret.txt`). It won't replace a secret this Mac already has unless you add `--replace`. If `nightshift buy` says to contact support, this Mac already has a license under another secret: support can give you a new one, so don't buy again.
