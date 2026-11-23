# Liquid glass beads

Color temperature and Max should use the system slider knob. While a bead is held it becomes liquid glass, it bounces on click, and it bounces off either end of the bar. That behavior is AppKit's, on macOS 26 and later. The custom track drawing is what blocks it.

## Behavior

On macOS 26 and later, both sliders use the system cell. Each has three tick marks under the bar, an accent fill, and free values. The mid magnet still snaps to 50. Color temperature still previews warmth while the bead moves and saves on release. Max still saves on release.

On earlier systems the existing hand-drawn track stays, because the system knob there has no liquid glass.

## Out of scope

The warmth write path does not change. Arrow keys do not need a bounce.
