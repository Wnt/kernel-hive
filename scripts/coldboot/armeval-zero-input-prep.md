# armeval boot capture — bridge prep

Status: **AUTHORED-UNTESTED, AND ZERO INPUT IS NOT GENUINE.** No clip is recorded
and `spa.bootVideo` is unset; this file and the `armeval)` arm in
`bootrec-tiles.conf` exist so the cold-boot path is audited, as the playbook
requires before a tile ships. Unlike its sibling `bbcmicro`, this tile cannot
have an honest clip until someone writes the record driver described below.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5838→6838. Before recording it stops `getty@tty1` and the
kiosk's MAME; after capture it starts the kiosk again. Bridge kind intentionally
skips `savevm`.

## Why zero input does not reach the fixture

The ARM Evaluation System has **no operating system and no language of its own**.
It is an ARM, 4 MB and a 16 KB supervisor ROM on the end of a BBC Micro's Tube.
Left alone, a cold boot stops here:

```
ARM Second Processor 4096K

Acorn ADFS

BASIC

  A*
```

The golden holds this instead:

```
ARM Second Processor 4096K

Acorn ADFS

BASIC

  A* *LIB $
  A* AB
ARM BBC Basic V version 1.00 for ARM Second Processor (C) Acorn 1986

>_
```

Two commands separate them, and they are baked in at bake time, not typed by a
visitor. `AB` is ARM BBC Basic V on Disc 3 of the ARM Evaluation System floppy
set; `*LIB $` has to come first because the ADFS library is `Unset` on a cold
boot and both `AB` and `*AB` answer `No directory (169)` without it.

Measured on the tile's own framebuffer: the cold-boot supervisor screen is
**4926 lit white pixels**, the golden **12647**. A clip that stopped at the
supervisor prompt would hand off to the golden's first frame with three lines of
text appearing out of nowhere. That is a visible jump, so this arm as written
records only as far as the supervisor.

**To make a clip that hands off cleanly** a record driver must repeat the two
steps the builder performs — `scripts/build-guests/armeval.sh`'s
`load_arm_basic()` — through the guest's own key path at the tile's shipped
80/80 ms pacing, and assert the ARM BASIC banner by framebuffer (white ink over
9000) rather than by a fixed sleep. A fixed sleep is specifically wrong here:
`AB` is ~40 KB coming off an emulated 1770 through ADFS, and 6 s after the
keystroke the screen still shows both `A*` lines and an empty cursor row — a
load in flight, which reads exactly like "ARM BASIC did not start".

## Ready, and the canvas

Ready (for the supervisor-only clip this arm can record today) means the three
white banner lines painted on black with the **blue** reverse-video `A*` field
present. The blue is the whole identity check: a plain BBC Micro power-on screen
contains not one blue pixel, so a capture that came up without `-tube arm` is
distinguishable from a correct one by colour alone.

Canvas is the QEMU kiosk's scanout at 30 fps. The X root is **800×600**, not the
bridge base's stock 1024×768 that `bbcmicro` uses — the launcher drops it with
`xrandr`, because `-video soft` is the only usable renderer under std-VGA
capture and the CPU bill scales with the root's pixels.

## Two things that would make a correct capture look wrong

- **`-artwork_crop` must stay in the launcher.** Without it MAME draws the Model
  B's keyboard LEDs as a labelled strip under the screen, so the framebuffer is
  a picture with emulator chrome beneath it and a different letterbox from the
  golden's.
- **The blinking MODE 7 cursor.** Two frames of the same state, sampled a fixed
  number of wall-clock seconds apart, differ by exactly one ~40 px cell. Any
  frame comparison in a record driver must sample at a fixed *machine* instant
  (`stop; loadvm golden; stop; screendump; cont`) or tolerate 40 pixels.

## Related

- `docs/guests/armeval.md` — the exhibit, its media, and the paths that failed.
- `scripts/coldboot/bbcmicro-zero-input-prep.md` — the host machine's own arm,
  where zero input *is* genuine.
