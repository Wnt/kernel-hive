# riscos3 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[RISC OS 3.11](station:riscos3) joins the museum</u> — an **Acorn
Archimedes 310** (1992) running Acorn's ARM2 desktop OS, entirely
ROM-resident: there is no disk image at all, the whole guest is the romset.
It boots to the RISC OS Desktop in about 21 seconds, with the Apps filer
window open (`!Alarm`, `!Calc`, `!Chars`, `!Configure`, `!Draw`, `!Edit`,
`!Help`, `!Paint`) and an icon bar along the bottom. A visitor can open and
close windows, drop the Pinboard menu, and use all three mouse buttons with
their distinct RISC OS meanings — Select opens things, Menu (the middle
button) opens context menus at the pointer, and Adjust does the "do it but
keep the window open" variant, proven here by opening the parent directory
without closing the child. The pointer tracks 1:1.

What was hard: MAME already inverts the Archimedes' active-low buttons
internally, so setting the station's usual active-low flag double-inverted
them. Every automated check looked fine with the flag set — every
acknowledgement came back OK, every screen genuinely changed, the menus
really opened — because a press-then-release still moves things on screen
even when the button never actually lets go underneath. The tell only
showed up on the very first live frame after the station went out: a
dashed rubber-band selection box being dragged across the Filer window,
untouched, because the last click of the bring-up had left Select stuck
down. The fix was simply not setting that flag. It's the clearest case this
wave had for why the museum insists on looking at the actual screen rather
than trusting a log of acknowledgements.

The keyboard goes through two layers of scanning (a matrix, then the
Archimedes' own keyboard microcontroller), so it runs at the slower end of
the fleet's timing — proven with F12 opening the RISC OS command line.

What's open: nothing flagged in the station's own record beyond the above.
