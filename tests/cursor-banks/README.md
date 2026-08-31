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

## What a bank is bound to on an INDEXED-COLOUR station

Everything above applies everywhere. This applies to any station running at 8
bits per pixel or fewer, and nobody would infer it from a direct-colour
station's bank:

**At indexed colour the framebuffer holds palette INDICES, so a `screendump`
PPM's literal RGB comes from the guest's palette** — and on `macfb` the palette
(`color_palette`) is a member of the device's `VMStateDescription`, i.e. it
lives *inside the golden*. So on such a station an exact-match bank is bound to
the golden's **palette** as well as to its resolution and depth, and a guest
that reprograms the LUT — a screensaver, an app installing its own CLUT —
changes the exact bytes of an *unchanged* glyph and breaks every match. A 16-bit
direct-colour station has no such exposure. Say the palette out loud in
`cursorBankBoundTo` where it applies.

## A glyph an exact matcher cannot safely carry

A template is matched by requiring every OPAQUE pixel to equal the frame. That
makes a **sparse, single-coloured** template dangerous: it matches any region of
that colour big enough to cover it.

The case that produced this note is the classic **I-beam over a white text
area**. `learn` only captures pixels that CHANGED, and over white paper the
cursor's white outline changes nothing, so the template is just the black
strokes — measured here at 7x16 with **24 opaque pixels, all black**. It then
matched a solid black window rule, and put **18 of 76** frames into AMBIGUOUS.

So it is excluded from `macos753.json` deliberately. The reasoning generalises:
before adding a glyph, check its opaque-pixel count and colour spread, and
prefer an honest `NOTFOUND` over a template that can match furniture. A dark,
thin cursor learned on a light background is the shape to watch for.

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
vmstate in the **PRAM** qcow2, so the pair is what carries the checkpoint. This
is an INDEXED-colour station, so see the palette section above.

`cursorBankBoundTo` string for the acceptance block, when one is added:

> `golden 2026-08-24T01:01:30 (VM_CLOCK 0000:02:03.500, macos753-golden.qcow2 + pram-golden.qcow2); 1152x870x8 macfb, 8-bit indexed via the golden's own palette`

| template | size | hotspot | where it appears |
|---|---|---|---|
| `6ce53cf5b5a7` | 11x16 | `(1,1)` | the arrow — desktop, menu bar, icons, window frames, every screen edge |
| `34cb9d7fafb0` | 15x15 | `(7,7)` | the quartered-disc busy cursor, during disk work |
| `43a5176b76b8` | 11x16 | `(8,8)` | the wristwatch, the other busy cursor |

**Hotspots differ per glyph here, so a single global `--hotspot` is wrong.** Use
the table. Every hotspot was read directly out of the guest at `TheCrsr+64`
(`$0884`) at the moment that glyph was live, not inferred — this station can do
that because its pointer mechanism already reads Mac OS's low-memory globals
(`docs/guests/macos753.md`). The arrow's `(1,1)` is corroborated independently
as `commanded - located origin` across 8 targets including all four edges.

Validation: over **76** captured frames the bank reports **70 found, 0
AMBIGUOUS, 6 NOTFOUND** — and every NOTFOUND is accounted for (one deliberately
clipped corner, and five frames whose cursor is the excluded I-beam).

**The I-beam is deliberately absent.** Its hotspot is `(7,4)` if you ever need
it, but see "A glyph an exact matcher cannot safely carry" above: it is 24
opaque black pixels and it matched solid black furniture in 18 of 76 frames. A
`NOTFOUND` over a text field is the expected, honest answer here.

### The trap that cost two bad templates

**Mac OS calls `SetCursor` — updating `TheCrsr` in RAM — BEFORE the cursor VBL
task repaints, and under TCG that lag is long.** So "the guest's cursor record
says watch" does NOT mean "the framebuffer shows a watch". Learning on the RAM
signal alone produced a template that was the *arrow*, captured at the watch's
`(8,8)` origin — i.e. the right glyph name on the wrong bitmap, offset by 7px,
which would have silently reported every position 7px out.

A diff-based freshness check cannot catch it either: the frame genuinely differs
from the reference, just with the wrong glyph in it. **Discriminate on the
picture**: keep capturing while the *previous* glyph is still findable at the
park position, and only trust a frame where it has gone.

And **`learn` writes to the bank before anything verifies it**, so a degenerate
capture poisons the bank for every later `find`. Snapshot the bank, learn,
re-`find` the new template, and restore the snapshot unless it lands at exactly
the commanded origin. Both guards are in the archived harness for this station.
