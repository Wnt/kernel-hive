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
