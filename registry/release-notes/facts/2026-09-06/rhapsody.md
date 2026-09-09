# rhapsody — facts from week ending 2026-09-06 ("The mouse finally lands")

Extracted mechanically from the in-progress/append-only week JSON; raw material
for the Sunday authoring pass, not publishable prose on its own.

## From the summary prose

- (Major features) [Rhapsody](station:rhapsody), [Mac OS 7.5.3](station:macos753) and [BeOS](station:beos) have no such chip, so instead the emulator writes the coordinate straight into the place each operating system keeps its own pointer, and nudges it awake.

## Bullets

- [Rhapsody](station:rhapsody)'s pointer lives at an address belonging to one saved disk, so the emulator checks it before every write and refuses if it moved
