# A 1:1 absolute pointer from a hardware-cursor register

**Reference implementation: `hpuxvue`** (HP-UX 10.20 / HP VUE, QEMU hppa B160L,
Artist framebuffer). This is the *method* doc — what transfers to any station
whose guest drives a hardware cursor. Station specifics live in
[`docs/guests/hpuxvue.md`](../guests/hpuxvue.md); the engine is
`streamhost/qemu-patches/0008-artist-closed-loop-pointer.patch`.

Sibling routes, for choosing between them: the closed loop over a Matrox DAC
(`aix432`), over MAME's Newport VC2 (`irix`), a real tablet with no loop at all
([NEXTSTEP-ABSOLUTE-POINTER.md](NEXTSTEP-ABSOLUTE-POINTER.md)), and an absolute
*write* into guest RAM ([RHAPSODY-ABSOLUTE-POINTER.md](RHAPSODY-ABSOLUTE-POINTER.md)).

## When this route is available

The guest's own graphics driver must drive the adapter's **hardware** cursor. If
the guest paints its cursor into the framebuffer there is no sensor here. The
device model must expose a readable position **and** an enable bit — a hidden
cursor's registers stop tracking, and a reading you cannot trust must be
discarded for that window rather than believed.

`hpuxvue` was the cheapest station of its wave because upstream `artist.c`
already had all of it: `artist_get_cursor_pos()` did the register→pixel decode,
the back-porch term it depends on is forced to a constant by `artist.c` itself,
and `cursor_pos`/`cursor_cntrl` were already in `vmstate_artist`. So there was no
adapter swap, no new migration state, and **no golden re-bake**. Check for that
before assuming a port is expensive.

## THE TRAP: use the device model's accessor, never your own register decode

This is the lesson most likely to recur, and it cost this port an afternoon.

A cursor register rarely holds the pointer. On Artist, `CURSOR_CTRL`'s low
nibbles are an **offset** that `artist_get_cursor_pos()` subtracts to reach the
drawn sprite origin — they are *not* a hotspot, though they look exactly like
one. A loop closed on a private decode of `CURSOR_POS` landed every target a
constant 8 px to the left.

What makes this dangerous is how it fails. The raw register and the framebuffer
**agreed with each other exactly** — `err +0,+0` — at every single target. A
sensor can be perfectly self-consistent and still be uniformly wrong.

> **Two observers agreeing is not proof.** Only the *commanded target* is the
> third observer that separates "self-consistent" from "correct".

So report three numbers at every proof target, always:

1. the **commanded** target (what the daemon asked for),
2. the **sensor** (engine reading + measured hotspot),
3. the **framebuffer** (`scripts/dev/cursor-locate.py` on a QMP screendump,
   which sees only pixels).

A framebuffer check alone would have passed this bug. So would a register check.
Together they still would have.

## Hotspot: measured, never guessed

The registers hold the sprite origin: `reading = pointer − hotspot`. Guessing the
hotspot does not give a small error, it gives a **magnet** — on `aix432` a
guessed `(0,0)` against a real `(14,7)` produced 386 steps and 110 re-aims in 8 s
at a *stationary* target.

Measure it at a **screen clamp**, where the X server pins the pointer to a known
coordinate, so the reading *is* the negated hotspot. Do it at **two** clamps and
require them to agree — `hpuxvue` measured `(2,1)` at both the top-left and
bottom-right corners. Derive other glyphs at the swap by continuity
(`d(origin) == −d(hotspot)` while the pointer is at rest) and cache them under a
signature over the sprite planes; sampling per window instead walks the hotspot
away over a single sweep.

### "Pinned" must be verified, not inferred

A homing step concludes the pointer is against the wall when the reading stops
changing. Under TCG the guest consumes PS/2 packets **on its own schedule**, so
several windows can pass with motion still queued, and stillness then means
nothing. Require all of:

- **proof of motion** — the reading changed at least once. A reconnecting session
  usually finds the pointer *already parked* in the corner, where stillness is
  indistinguishable from a wedge, so kick outward first.
- **proof of place** — the reading is within one sprite of the corner, which is
  the only place it can be if it really is pinned.
- **a bound at the point of record** — a hotspot lives inside the sprite. Bound
  it on *every* path that records one, not only where one is used.

When it cannot establish the value, say so (`hot_exact=0` over `STAT`) rather
than asserting a default. An engine that can store an impossible value and report
it as exact has a health signal that is worthless exactly when it matters.

## Control law: three rules, and two that TCG adds

The generic three (identical in `ctlsock.cpp` and `mga.c`): retire in-flight by
**observed** pixels and decay it geometrically; never step *against* the measured
error and never extrapolate ahead of real movement; latch oscillation, because
repeated sign reversal means the reading is moving with the pointer (a glyph
swap), not that you keep missing.

Two more that a slow TCG guest makes mandatory:

- **Bounded in-flight gate.** Never issue a step while the previous one is
  unconsumed — otherwise you stack steps against a stale reading, overshoot,
  reverse, trip the latch and give up short. **Bounded**, or a screen clamp (where
  the step legitimately never lands) wedges the loop forever.
- **Settle before declaring convergence.** The error already has in-flight
  subtracted, so a target can *look* reached while counts are still queued — and
  those counts then carry the pointer past it, usually into a clamp it cannot
  return from.

Without these two: give-ups and 9–35 px misses. With them: 7/7 at `--tol 1`, zero
give-ups. **Gain is only a step sizer** — a wrong gain costs convergence windows,
never accuracy, because the next window re-reads the truth.

## Paused guests are a first-class case, not an edge case

Use `QEMU_CLOCK_VIRTUAL` for the window: it measures *guest* time, and the loop
must not burn its try budget against a pointer that cannot move. The consequence
is that a paused guest acks nothing — and stations that idle-auto-pause make a
returning visitor the **common** path. `hpuxvue` starts `-loadvm golden -S` *and*
pauses after 60 s.

Ack `MOVEA` on **accept**, not on convergence, so a pause can never stall the
daemon's ack pipeline; only button edges wait on the guest. Emit the `HELLO` from
the chardev open callback, not from the timer, so it lands while the guest has
never run. Verified on `hpuxvue`: HELLO in 2 ms and `STAT` answering while the
guest has never executed an instruction, `MOVEA` acked in 40 ms while paused, and
convergence with zero give-ups after `cont`.

## Keep it out of vmstate — and re-arm on restore, which is not the same thing

Every engine field must be re-derivable from registers the guest owns or from the
live socket. Then the migration format is untouched, arming the loop needs no
golden re-bake, and rollback is two lines (drop the `-chardev`/`-global` pair,
set `SH_INPUT_BACKEND=dbus-rel`).

**"Not in vmstate" is necessary and not sufficient, and the gap is the clock.**
The window timer runs on `QEMU_CLOCK_VIRTUAL` (above), and re-arms itself to
`virtual_now + window_ms` from inside its own callback. A `loadvm` *rewinds*
`QEMU_CLOCK_VIRTUAL` to the snapshot's value — on a station started
`-loadvm golden -S`, that is earlier than the live clock by the whole elapsed
session. The pending expiry therefore lands that same elapsed session **in the
future** of the restored clock, and the window never runs again. The engine is
not in a bad state; it is simply never called.

Nothing else heals it. `MOVEA` is acked from the receive path, so the daemon
keeps getting `OK`s and its ack watchdog stays quiet on move-only traffic; the
reconnect that watchdog eventually forces re-runs `CHR_EVENT_OPENED`, which
resets engine state but **does not re-arm the timer**. And because the timer is
also what applies queued button edges, the visitor loses clicks as well as
motion — and a visitor who cannot click cannot move keyboard focus, so the
report that reaches the operator is *"the keyboard stopped working"*. One
stalled timer, all three symptoms; `STAT` shows the signature, `aiming=1` with
`giveups=0` (it is not giving up, it never gets a window).

Measured on a clone with the live device set: a 60 s session before the restore
froze the pointer for 63 s, then it thawed and converged normally. A real
visitor's session freezes it for as long as they had been there, which is why
this reads as "dead", not "slow".

So register a `qemu_add_vm_change_state_handler` and re-arm the timer whenever
the machine re-enters `running` — that covers `loadvm` + `cont` (the Restore
button, `scripts/serve/reset-tile.sh`) and is a harmless re-arm on an ordinary
idle-auto-pause resume. Drop the reckoning that described the pre-restore guest
at the same moment (in-flight counts, the last reading, the try/oscillation
counters, and `ptr_edge_gap_until` — a deadline denominated in the old clock).
Keep the measured hotspot: it is a property of the cursor *glyph*, which a
restore of this station's own checkpoint does not change, and re-homing would
clamp the pointer into the corner in front of the visitor on every Restore.

**One measured cost of keeping the hotspot.** The glyph is stable across a
restore of the same checkpoint, but not across the *visitor's* session: if they
left the pointer over a widget with a different cursor (Mosaic's, say) and then
pressed Restore, the surviving hotspot belongs to the old glyph. Live
`cursor-track.mjs` showed exactly that — the first two targets after such a
restore read 14 px against this station's own 2-4 px baseline, then points 3-5
came back to 2-4 px as `artist_ptr_track_glyph()` re-learned the hotspot at
rest. It is a bounded transient of one or two targets that self-corrects, and it
is the price of not clamping the pointer into the corner in front of the visitor
on every Restore. Do not read those first samples as a tracking fault; re-run,
or compare points 3-5.

## A resize-border fix that did NOT work, and the measurements that killed it

Attempted 2026-08-31 against the standing finding *"the engine cannot hold the
pointer on resize borders"*. **Not deployed.** Written down because the negative
is worth more than the attempt, and because the obvious design is the one that
fails.

**First, the premise did not survive measurement.** Parked on the File Manager's
title bar the engine holds perfectly: one distinct reading over 17 s, `hot=2,1
exact=1`, `aiming=0`, `giveups=0`, `reaims` flat. `cursor-locate.py` reports the
SAME sprite id there as on the desktop, so no glyph swaps at that spot and the
magnet mechanism is not active. Whatever makes a title-bar click go missing, it
is not the engine failing to hold position.

**The hazard is real elsewhere, though, and now quantified.** Sweeping the
desktop finds **four** distinct cursor sprites (arrow, and three others over the
window frame, a page area and a bottom-right corner) and the engine uses the
ARROW's `hot=2,1` for all of them, because continuity at rest can only name a
glyph that swaps while the loop is idle, and a frame swaps it while the loop is
driving through. Measured cost at the resize corner: commanded (674,738),
landed (650,716) — a 24 px miss.

**The attempt** was aix432's answer ported: learn a glyph's hotspot AT THE
CURSOR_POS/CURSOR_CTRL WRITE, where a sprite change forces a compensating write
with no motion to subtract, plus a rule that a mid-flight swap may never drive a
correction (adopt a known hotspot and carry on, else end the aim).

**Why it failed, in one number: `glyphs=0`.** The write-time learner never fired
— not on a sweep, not on a 4 px walk across the frame, not on a 1 px crawl with
one-second pauses. Its guard requires the engine to be idle with nothing in
flight at the moment of the write, and a glyph swap happens precisely when the
loop is driving through the frame. So every swap stayed unnamed, so the
"end the aim" branch fired on every crossing (`glyphstops` climbing), and a move
that crossed regions stopped short again and again: commanded (700,200), landed
(275,193) — a **425 px** miss. That is far worse than the magnet it replaced.

**What a working fix has to do.** Name the glyph without requiring an idle loop:
account for the counts injected since the previous cursor write so the motion can
be subtracted from the origin delta, rather than demanding there be no motion.
Until a glyph can be named while the loop is driving, do NOT add the
"end the aim on an unnamed swap" rule on its own — unnamed is the common case,
and the rule then converts a small oscillation into a large miss.

**The general rule for the next port:** any engine timer on `QEMU_CLOCK_VIRTUAL`
needs a restore hook. A sibling that uses `QEMU_CLOCK_REALTIME` (`kh-ramabs`,
patch `0007`) is not exposed to this, and the two are worth telling apart before
you copy either.

## Single injector (binding)

While the control socket is connected the engine **owns** the guest pointer: no
rel bridge, no QMP `input-send-event`, no `labctl` pointer helper. Two injectors
and the loop reads motion it did not cause.

## Don't forget `backend_routes_buttons`

Motion routes to any router unconditionally; button edges do not. A sink missing
from `backend_routes_buttons` in
`streamhost/streamhost/src/realtime_input.rs` gives you a *perfect pointer* and
clicks that fire down the D-Bus PS/2 path while the engine is still walking — the
guest sees press-at-A / motion / release-at-B, a **drag**, and it gets reported as
"the keyboard stopped working". The enumerating test
`routes_buttons_invariant_every_pointer_sink_takes_its_edges` exists to catch it.
Prove it catches *your* backend by removing the entry and watching it fail —
and check the sabotage actually landed before believing the result.
