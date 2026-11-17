# Swift `nightshiftd.sock` listener

## Goal

Nightshift Swift owns `~/Library/Application Support/nightshift/nightshiftd.sock` the same way `nightshiftd` does. `main.m` stays the `nightshift` command. A bare `nightshift` never launches an app.

## Shape

1. `CommandListener` — flock `nightshiftd.lock`, bind the sock, accept on a serial queue, handle on the main actor.
2. `MenuFacade.reply(to:)` — same tokens as `handleLine` in `nightshiftd.m`.
3. Ramp CLI paths — `max` and `ramp` match the daemon wire: leave strength alone outside the evening window and when the schedule is Off or Sunset. Menu Max keep the #37 cap.
4. Status uses Swift `MenuFiles` max/full; unset max is `-1`.
5. Start the listener in `applicationDidFinishLaunching` after the facade exists and before (or with) the first ramp tick. If the lock is held, the menu still runs and the CLI keeps talking to the holder.

## Out of scope

Moving `nightshiftd.m` / Nightshift.app. Help, license, buy, notifications stay in `main.m`. Making the Swift binary the command.

## Test

Pure reply helpers and CLI max/ramp outcomes in `swift/Tests/main.swift`. Live check: quit other Nightshift processes, open `pr4/NightshiftSwift.app`, run `nightshift` / `nightshift status` against the sock.
