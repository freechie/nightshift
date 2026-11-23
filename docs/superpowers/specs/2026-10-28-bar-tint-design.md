# Bar and icon color

One Color setting in Settings paints the Color temperature bar, the Max bar, and the menu icon.

## Choice

Accent is the default. It follows the macOS accent color, including when that color changes in System Settings.

The other choices are the primaries Blue, Purple, Pink, Red, Orange, Yellow, Green, and Graphite, plus Custom. Custom opens the macOS color picker.

The same choice paints all three. A disabled Max bar stays gray. The PRO badge and the schedule control stay on the system accent.

## Storage

The choice is one line in `~/Library/Application Support/nightshift/menubar`, beside warmth and icon.

- missing line, `tint accent`, or an unreadable line: accent
- `tint blue` (and the other primary names): that primary
- `tint custom rrggbb`: the picked color, six hex digits

Saving warmth or tint keeps the other lines.

## Paint

On macOS 26 and later the system slider keeps its glass knob. `trackFillColor` paints the filled part of both bars. Before macOS 26 the hand-drawn bar uses the same color.

The menu icon is drawn in the color, so the color shows in the menu bar. Accent and the primaries are resolved when the icon is drawn, and again when the system accent or appearance changes.
