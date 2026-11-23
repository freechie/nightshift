# License line

The License status line has one named value. Refresh derives the standing line from the saved license. A result the user just asked for is painted after that refresh, and the next refresh restores the standing line.

The ramp, the Color temperature slider, and the warmth hotkeys stay on their current writes.

## Lines

- Not active. This Mac has no license, and checkout is not in flight.
- Waiting for checkout…. Checkout is in flight and this Mac is still unlicensed. Every refresh keeps this line until the Mac is licensed, or the purchase attempt fails.
- Active. Licensed, with no end date.
- Active through *day*. Licensed, end date further out than 14 days.
- Ends *day*. Licensed, end date within 14 days. The Buy button stays and reads Renew.
- A notice. The server's words, or "Use this code on the other Mac." Painted after the refresh that follows the action. The next refresh restores the standing line.

A licensed Mac replaces Waiting for checkout….

## Who writes the label

`licenseLineToShow` chooses the standing line. `licenseLineText` and `licenseLineTone` turn that line into the words and the color. Settings is the only caller that paints the label.

Buy stores Waiting for checkout… before the request. A purchase failure clears that hold, refresh runs, then the notice is painted. Add a Mac and Redeem paint their notice the same way, after refresh when refresh runs.

Pitch, Buy, Add a Mac, Redeem, and the seat code keep today's show and hide rules.
