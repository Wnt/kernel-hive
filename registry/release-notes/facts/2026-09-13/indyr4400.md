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

## Not yet true when this note was written — check before publishing

The conversion's own measurements were still open: the landed pointer latency,
the CPU the station costs now, and whether the pointer ended up absolute
(click anywhere) or relative (click-to-grab, as it shipped). See
`docs/lab/IRIS-DEBRIDGE-BRIEF.md` §7, which is the ledger those numbers land in.
**Do not publish a latency figure from this note** — the 68 ms above is the
*neighbouring* station's measurement and the target, not this one's result.

## Sources

- `docs/lab/IRIS-DEBRIDGE-BRIEF.md` — design and results record
- `docs/guests/indyr4400.md` — the station's own doc, incl. the 2026-09-09
  measurement table the conversion started from
