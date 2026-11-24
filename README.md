# Night Shift

Easily set your nightshift warmth from the terminal or the menu bar. Set an Evening Ramp max value and set the time needed to reach it to have your night shift warmth automatically increase throughout the day available as a one-time purchase.

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

## Evening

Nightshift applies your schedule and **max** intensity from System Settings. The Evening Ramp, if unlocked, glides on a pleasant curve towards your max intensity. The value and times can be changed right in the app or via **CLI**.

Until you set a new max intensity, the current warmth is the max. It ramps towards that maximum night shift intensity until the schedule ends. Sunset to Sunrise stays as is.

## Menu bar

Release the **Color temperature** slider to set the warmth. Release the **Max** slider to set the max. **Full at** is the time the warmth reaches the max. You have the option of **24-hour** time in Settings.

## Buy

Setting warmth intensity is free. The evening ramp is a one-time purchase for up to 3 devices.

`nightshift buy` opens checkout. `nightshift license` prints the date the ramp runs through.

## Customer Support

Please contact support with your receipt and the output of `nightshift license id` from your favorite terminal.
