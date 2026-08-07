# Pen tap quantisation — agreed plan, and the data behind it

**Status: AGREED, NOT YET IMPLEMENTED** (2026-08-05). Everything in "What is
deployed" is live; everything in "The plan" is still to do. Background and tools:
[INPUT-DEBUGGING.md](INPUT-DEBUGGING.md).

## The problem in one line

Single taps with an S-Pen register as tiny drags in the guest, which also breaks
double-click — worst on IRIX.

## The measurement that explains it

Taken from the user's own Android tab through the operator eval plane:

```
IRIX guest 1288x1024  displayed in a 411x329 CSS rect  ->  3.13 guest px / CSS px
win311    1024x768    same rect                        ->  ~2.5 guest px / CSS px
```

**The quantisation thresholds are in GUEST pixels, but a hand wobbles in
physical space.** `tapPx: 24` guest px is therefore only ~7.7 CSS px (~1.3 mm)
of finger travel on IRIX — far under what a hand-held stylus does — and the
effective sensitivity *changes with each tile's resolution*. That is why the
same code behaved acceptably on win311 and badly on IRIX.

Corroborating evidence, same session:

- Daemon telemetry, moves between a click's own DOWN and UP: healthy clicks
  carried 1-3, the failing ones carried **82 and 117** (coalesced samples fan
  out, so the count far exceeds the event count). Once the radius is crossed,
  every later sample flows and the click becomes a drag.
- `pen-tap` shows `dbl:true` on every second tap with both clicks reported on
  the SAME guest pixel (e.g. `942,823` twice) — recognition and snapping are
  already correct. The defect is purely the movement gate.
- 52 button events with **zero** consecutive repeats: no lost UP on the wire
  during that window, so the separately-reported "mouse stays down in the guest"
  is not an event lost between browser and daemon. Suspect guest-side drag state
  (4Dwm) and re-check with the same command if it recurs.

## What is deployed now

- Tap quantisation shared by both input paths: `input/touchGestures.createTapQuantiser()`,
  driven by the touch recognizer and — separately — by the stylus path through
  `input/penContact.ts` (a stylus is `pointerType: 'pen'` and never reaches the
  recognizer; see INPUT-DEBUGGING.md).
- Wobble measured from the REAL contact point, never the snapped one.
- Second tap snapped onto the first tap's pixel; no synthetic extra click.
- A clean tap releases with no coordinates (avoids re-arming the warpd guard).
- Pen hover muted for the double-tap window after a contact.
- `TAP` = `tapPx 24`, `doublePx 32`, `doubleMs 500` — **all in guest px, which
  is the bug above.**

## The plan

**1. Move the quantiser into CLIENT space.** Do all tap/drag/double-tap maths in
CSS px and map to guest px only for what is sent. CSS px is ~1/96", so the
thresholds become physically meaningful and identical on every tile instead of
scaling with guest resolution.

**2. Add a time-based hold alongside the distance gate.** Distance alone cannot
catch a wobble that happens to exceed the radius. On pen down, hold movement; if
the pen lifts inside the hold, emit only down+up. Release the hold early when
travel exceeds a clear drag radius, so a deliberate fast drag is not delayed.

**3. Numbers** (CSS px / ms):

| Knob | Value | Why |
|---|---|---|
| `tapPx` | 12 (~3 mm) | Above hectic wobble; Android's own touch slop is 8dp |
| `dragEscapePx` | 30 (~8 mm) | Unambiguous drag — releases the hold immediately |
| `tapHoldMs` | 200 | Measured taps are 37-52 ms, so a wide margin |
| `doublePx` | 20 (~5 mm) | Must stay INSIDE one icon: an IRIX icon is ~64 guest px ≈ 20 CSS px, so larger would snap onto a neighbour |
| `doubleMs` | 500 | Unchanged |

## Known limit that no client change fixes

IRIX is Motif, whose double-click interval is ~200-250 ms — the tightest of any
guest here, against measured human gaps of 135-200 ms. Some legitimate
double-taps will simply be too slow *for the guest*. If it stays marginal after
this work, the fix is IRIX's own double-click setting, which is separate.

## Live instrumentation to tear down when this closes

```bash
# daemon input telemetry drop-ins (win311 + irix)
ssh lab 'rm -f /etc/systemd/system/streamhost@{win311,irix}.service.d/input-telemetry.conf
  rmdir /etc/systemd/system/streamhost@{win311,irix}.service.d 2>/dev/null
  systemctl daemon-reload && systemctl restart streamhost@win311 streamhost@irix'

# arbitrary-JS eval (also clears itself on reboot)
ssh lab 'printf "OSG_ADMIN_EVAL=0\n" > /run/osgallery-https.env && systemctl restart osgallery-https'
```

The in-tab recorder disappears on reload; re-inject
`tests/e2e-live/pen-recorder.eval.js` when needed.
