# Night Shift

Set your nightshift warmth intensity from the menu bar or CLI.
Save an Evening Ramp time to set when the ramp will reach max intensity.

The evening ramp is available as a one-time purchase for pro users.

## Menu bar

Release the **Color temperature** slider to set the warmth intensity. Release the **Max** slider to set the max intensity.

**Full at** is when the warmth intensity reaches the max value pro users set. You have the option of **24-hour** time in Settings.

## Evening Ramp

Nightshift applies your schedule and **current** warmth intensity from System Settings.

The Evening Ramp, once purchased, glides on a pleasant curve towards your max intensity.

Until you set a new max warmth, the current warmth is the max. Sunset to Sunrise works as is.


## Commands

```sh
nightshift              # where the warmth intensity currently is
nightshift 40           # set warmth to 40 and turn Night Shift on
nightshift 0            # turn Night Shift off
nightshift max 60       # set the ramp's max
nightshift ramp 8:30pm  # reach the max at 8:30 PM
nightshift -h           # the rest of the commands
```

A warmth is a whole number from `0` to `100`. A max is from `1` to `100`.

## Pro Users

Setting warmth intensity will always be free.

The evening ramp is a one-time Pro user purchase for up to 3 devices.

`nightshift buy` opens checkout. `nightshift license` prints the date the ramp runs through.

## Customer Support

Please contact support with your receipt and the output of `nightshift license id` from your favorite terminal.
