# indyr4400 — facts for the week closing 2026-09-13

Raw material for the Sunday authoring pass, not publishable prose. Nothing here
is a new machine: `indyr4400` has been on the floor since 2026-08-10. What
changed is what is underneath it.

## Bullets

- The museum's second [SGI Indy](station:indyr4400) — the *1993* MIPS **R4400**
  one, running the same **IRIX 6.5** install as its R4600 neighbour — came out
  of the Linux virtual machine it had been living inside. The Iris emulator now
  runs straight on the museum's own hardware and hands its picture to the
  gallery directly, the same route the MAME and VICE machines already take.
- The reason was the mouse. Timed side by side, a pointer move took **250–400
  milliseconds** to show up on the Indy and **68 milliseconds** on its
  neighbour — and three different builds of the emulator, including a brand-new
  one four times faster at raw arithmetic, made no difference at all. The delay
  was never the emulator; it was the six layers of virtual machine, virtual
  display and screen-scraping stacked between the two. Removing them is the fix.
- A side effect worth a sentence if the week needs one: the emulator used to
  draw a little status readout across the top of its own window — clock speed,
  disk and network lights — and the exhibit had to crop it off so visitors saw
  the machine and not the emulator. Running directly, that readout is never
  drawn at all.

- **The pointer became absolute.** It used to be click-to-grab: the browser had
  to capture your mouse, and Right-Ctrl gave it back. Now the arrow simply goes
  where you put it — the exhibit reads the emulated machine's own cursor
  hardware and steers until the two agree. Measured on eight targets across the
  screen, the arrow landed on the exact pixel asked for, eight times out of
  eight.
- **The number the conversion was after: 361 milliseconds became 80.** Its
  neighbour, the machine that started the argument, sits at 68. A stream of
  pointer movement now settles 60 milliseconds after the last one instead of
  216–397.
- **And a reset that used to be unthinkable is now instant.** Putting the
  exhibit back to its starting scene takes **four tenths of a second**, because
  the emulator rewinds itself in place instead of the whole machine restarting.
  The saved scene is 9 MB, where the old one was three quarters of a gigabyte.
- The machine also got **cheaper to run**, which is not the kind of thing
  visitors see but is why more machines can share one museum: the virtual
  machine it lived in cost about one and a half processor cores all by itself,
  and it is gone.

## Not yet true when this note was written — check before publishing

Two things were still open at the integration pass and may still be:
the exhibit's **starting scene** has to be re-baked by hand at cutover (a cold
boot stops short of the full desktop), and a **menu drawn by the IRIX window
manager comes out black** — an emulator gap, not a conversion one. Do not write
prose that describes a visitor opening a menu until that is fixed. See
`docs/lab/IRIS-DEBRIDGE-BRIEF.md` §7.
## Sources

- `docs/lab/IRIS-DEBRIDGE-BRIEF.md` — design and results record
- `docs/guests/indyr4400.md` — the station's own doc, incl. the 2026-09-09
  measurement table the conversion started from
