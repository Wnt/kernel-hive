# Cursor template banks

Glyph banks for `scripts/dev/cursor-locate.py`, kept per station so a proof or a
retry **reuses a known template set instead of learning its own**. That matters
more than it sounds: if the harness learns its own bank, a `NOTFOUND` is
ambiguous between "the pointer is not there" and "this template set does not
cover that glyph", and the ambiguity always appears at the worst moment.

Use one with `--bank`:

```sh
python3 scripts/dev/cursor-locate.py --bank tests/cursor-banks/<station>.json find frame.ppm
```

`find` reports the **sprite origin**, not the pointer: the guest draws at
`pointer - hotspot`, so add the glyph's hotspot (or pass `--hotspot X,Y`).

## What a bank is bound to

A bank is an **exact** pixel match, so it is valid only for the golden, colour
depth and resolution it was learned on. A re-bake, a depth change or a
resolution change invalidates it and it must be re-learned. Feed it QMP
`screendump` PPMs, never H.264 frames — the encoder's ringing breaks the match
and the tool will honestly tell you it found nothing.

## Extending one

Park the pointer far away for a reference frame, put it where you want the new
glyph, then learn from the changed cluster:

```sh
python3 scripts/dev/cursor-locate.py --bank tests/cursor-banks/<station>.json \
        learn REF.ppm FRAME.ppm --at <origin-x>,<origin-y>
```

The bank is keyed by content, so re-learning a glyph it already has is a no-op.

**Never learn at a screen edge.** The matcher rejects any placement that falls
outside the frame, so a clipped sprite becomes a *sub-template* that then
matches the full glyph everywhere and turns every later `find` into
`AMBIGUOUS`. Learn only where the sprite is whole.

## Reading the answers

- `AMBIGUOUS` where every hit is at the **same** coordinates is harmless — two
  templates of one glyph, learned over different backgrounds. The position is
  not in doubt.
- `AMBIGUOUS` with **differing** coordinates is a real problem.
- `NOTFOUND` at a screen edge is expected, not a failure: a sprite clipped by
  the frame cannot be exact-matched. Choose targets where the sprite is whole
  and report true corners from the sensor plus a cropped picture instead.

## `rhapsody.json`

Rhapsody 5.1 DR2, 1024x768 RGB:555/16 on Cirrus GD5446, learned on the golden
re-baked 2026-08-23 (OmniWeb on the Space Jam corpus page).

| template | size | hotspot | where it appears |
|---|---|---|---|
| `e63fa3be82bc` | 11x16 | `(1,1)` | the arrow — desktop, window frames, screen edges |
| `98f480249409` | 11x16 | `(1,1)` | the arrow again, learned over a different background |
| `c10b0ab605bc` | 13x13 | `(3,3)` | over the Bookmarks window frame |
| `3759b1ce8de5` | 14x16 | `(6,1)` | over the OmniWeb page content |

Each hotspot was measured as `commanded - located origin` and was **stable per
glyph** across widely separated targets, including both screen edges. Hotspots
are recorded here for reading the framebuffer only — this station's pointer
mechanism never uses one (`docs/lab/RHAPSODY-ABSOLUTE-POINTER.md`).

## `macos753.json`

Mac OS 7.5.3 on a Quadra 800, **1152x870x8** on `macfb`, learned on the golden
snapshot dated **2026-08-24 01:01:30** (`VM_CLOCK 0000:02:03.500`) in
`macos753-golden.qcow2` / `pram-golden.qcow2` — note this machine keeps its
vmstate in the **PRAM** qcow2, so the pair is what carries the checkpoint.

`cursorBankBoundTo` string for the acceptance block, when one is added:

> `golden 2026-08-24T01:01:30 (VM_CLOCK 0000:02:03.500, macos753-golden.qcow2 + pram-golden.qcow2); 1152x870x8 macfb, 8-bit indexed via the golden's own palette`

| template | size | hotspot | where it appears |
|---|---|---|---|
| `6ce53cf5b5a7` | 11x16 | `(1,1)` | the arrow — the whole exhibit: desktop, menu bar, icons, the Macintosh HD window and its frame, and every screen edge |

**One glyph, and a single global `--hotspot 1,1` is therefore correct here** —
unlike a mixed bank, where per-template hotspots are the only right answer. Do
not carry that simplification to another station, and do not keep it here if the
bank is ever extended.

The hotspot is confirmed twice over, from independent sources: measured as
`commanded - located origin`, stable at `(1,1)` across 8 widely separated
targets including all four screen edges; and **read directly out of the guest**
at `TheCrsr+64` (`$0884`), which reports `(1,1)`. This station can do the second
because its pointer mechanism reads Mac OS's own low-memory globals
(`docs/guests/macos753.md`).

### An eighth-bit binding this station has and a direct-colour one does not

At **8 bits per pixel the framebuffer is indexed**, so a `screendump` PPM's
literal RGB comes from the guest's palette — and `color_palette` is a member of
`vmstate_macfb`, i.e. it lives *inside the golden*. So this bank is bound to the
golden's **palette** as well as to its resolution and depth. A guest that
reprograms the LUT (a screensaver, an app that installs its own CLUT) changes
the exact bytes of an unchanged glyph and breaks the match. A 16-bit
direct-colour station like `rhapsody` has no such exposure.

### Coverage, stated honestly

Every one of **42 of 43** frames captured during this station's pointer work
matched this single template, unambiguously, at exactly the commanded origin —
desktop, menu bar, the opened Macintosh HD window and its frame, and all four
screen edges. The 43rd is a deliberately clipped corner (`NOTFOUND`, expected;
see "Reading the answers" above).

That is strong evidence the arrow is the only glyph the **fixture scene**
produces. It is **not** evidence that no other glyph can appear. Classic Mac OS
swaps the cursor for a **watch** during disk work and an **I-beam** over text,
and neither is in this bank, so either would come back `NOTFOUND` — which, per
the warning at the top of this file, is ambiguous between "the pointer is not
there" and "this bank does not cover that glyph". Under TCG the watch is the
likely one: disk operations are slow. **If a run reports `NOTFOUND` on a frame
whose sensor says the pointer is on-screen and away from an edge, suspect a
missing glyph before suspecting the device**, and extend the bank per
"Extending one" above.
