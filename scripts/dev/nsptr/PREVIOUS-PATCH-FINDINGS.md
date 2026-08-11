# nextstep pointer — the PREVIOUS-PATCH angle (PASS, 2026-08-09)

Sandbox: `/data/vms/soltest/NSPTR-previous-patch/` (torn down). The live tile
was never touched: no `streamhost@` unit was acted on and nothing under
`/data/vms/streamhost/stations/` was written. The clone is a `qemu-img convert` of
the live tile overlay's `golden` snapshot, booted cold with its own VMID,
`qmp.sock`, pidfile and hostfwd port 5937, `-display none`.

**Verdict: PASS.** 24 of 24 targets at **0 px error**, on two independent
instruments, one commanded move per target, no hunting; unchanged after the
guest opens and closes a menu; unchanged across `savevm`/`loadvm`; the shipped
path is compiled C inside the emulator; added input-to-photon cost is inside
+/-0.9 ms.

## 1. What the emulator does today, and where the absolute path was cut in

Previous r1847 has no absolute pointer at all. `Keymap_MouseMove()`
(`src/gui-sdl/sdlkeymap.c`) hands `sdlmotion->xrel/yrel` to `kms_mouse_move()`
(`src/kms.c`), which packs a **signed 6-bit delta** into the KMS mouse register
and pokes the machine. `src/tablet.c` (SummaGraphics MM / Wacom SD over the
SCC) is the only absolute device in the tree and needs drivers inside NeXTSTEP.

The patch adds `src/abspointer.c` + `src/includes/abspointer.h` and two hooks
(`scripts/build-guests/previous-abspointer.patch`):

* `AbsPointer_Init()` in `Main_Loop()` — binds `$PREVIOUS_ABS_SOCKET`
  (default `/tmp/previous-abs.sock`) and starts one listener thread.
* `AbsPointer_Poll()` in `Main_EventHandler()`, immediately after
  `GuiEvent_EventHandler()` — drains the channel **on the emulation thread**,
  at the same 200 Hz tick where SDL's own input is already drained. Guest RAM
  and the KMS registers are therefore touched from the thread that runs the
  68040 (no race with the CPU), and an absolute placement is scheduled at
  exactly the same instant a relative SDL motion would have been.

## 2. The mechanism: write the driver's own cursorLoc, then nudge it by one

NeXTSTEP 3.3's Mach event driver keeps the cursor location in guest RAM as a
big-endian `(int16 x, int16 y)` pair, and **re-reads it on every mouse packet**:
the new position is *(the value it finds in RAM)* + *(the accelerated delta)*.
It does not keep a private copy. That is the whole trick:

    write cursorLoc = target - (sx, sy)      sx, sy in {-1, +1}
    kms_mouse_move(sx, sy)                   one unit KMS packet

because the acceleration curve is exactly **1:1 at magnitude 1** (measured
through the same word: 1 -> 1, 2 -> 8, 3 -> 24, 5 -> 50, 10 -> 100, 20 -> 200,
40 -> 400 px; -1 -> -1, -4 -> -40). The driver then does its own clipping and
posts its own `NX_MOUSEMOVED`, so the WindowServer redraws through its normal
path — nothing is fighting the OS. The sign is chosen away from the near edge
so the pre-compensated value is always on screen, which is why `x = 0` and
`y = 0` work.

Two things that do **not** work, both proven on the framebuffer:

* A **zero-delta** packet after writing cursorLoc leaves the word at the value
  written and produces **no redraw** — the driver discards it, so there is no
  event for the WindowServer to act on.
* Writing a *mirror* of the position instead of the driver's own copy does
  nothing: the real cursor advances by the nudge and the mirror is overwritten
  with the real position on the next redraw.

## 3. Finding the word: it moves every boot, so the patch discovers it

Observed addresses, as offsets into `NEXTRam` (guest physical =
`0x04000000 + offset`): `0x1f98020`, `0x1fa6020`, `0x1fa2020`, `0x1f8c020` on
four consecutive boots. A constant would have been a trap.

`abs_discover_tick()` is a state machine stepped once per 200 Hz tick:

1. slam into the bottom-right corner, where the driver clamps to a value the
   patch knows exactly (1119, 831), and scan all 64 MB for a big-endian int16
   pair holding it;
2. slam into the top-left corner and re-filter the survivors on (0..40, 0..40);
3. slam right along the top edge and re-filter again;
4. **prove** one survivor by writing through it and posting a unit packet:
   only the driver's own copy reads back as *exactly* the probe target. Two
   probes far apart (300,200) then (800,600), so a mirror cannot pass by
   happening to sit one pixel short of the first.

Typically 4-5 survivors, of which one passes. Whole run ~1.5 s.

**This corrects a method the closed-loop angle used.** Voting a majority over
the surviving shadows is not safe: measured at six placements, the shadows
agreeing with the true position were 5/5, 5/5, 5/5, **2/5**, **3/5**, **2/5** —
a majority vote would have returned the wrong answer at three of them. The
write-through proof picks the one word that is authoritative, and that word
agreed with the framebuffer at every one of the 78 measured placements.

## 4. The one hole that was found, and closed

At the **200 Hz queue drain rate** the 1:1 unit-delta gain rises to about 1.9,
and a burst of 30 back-to-back placements ended **7 px past** its target (both
instruments agreeing). A gap sweep pinned it down: unit packets 5 ms apart give
1.9 px each; at 10, 20, 50 and 100 ms apart they give exactly 1.0.

Placements are therefore paced at one per two ticks (100 Hz) and a faster burst
**coalesces to its latest target** — which is what a pointer stream wants
anyway. Re-measured after the change: the same 30-placement burst lands at
**0 px error**, as does a 30-placement stream at 16 ms spacing.

## 5. Instruments

Every number was taken with two instruments that disagree nowhere:

* **RAM** — the driver's own cursorLoc, read inside Previous. Exact, works at
  every position including the clamps.
* **PIXEL** — an exhaustive, full-frame, **exact-match** search for the arrow
  silhouette in a QEMU `screendump`. The silhouette (11x16, 96 opaque pixels)
  is derived at runtime from two frames over the empty desktop; template pixels
  that fall outside the frame do not constrain the match, so an edge-clipped
  sprite is still found; an origin with fewer than half its pixels on screen is
  rejected; and because the search is exhaustive every time it **cannot return
  a remembered position** — an ambiguous or absent match is reported as such.

The hot spot is calibrated against a fact the driver owns and the mechanism
does not touch: a hard slam into the top-left corner puts the hot spot on guest
pixel (0,0) by definition of the clamp. That gives hot spot = template origin
+ (1,1), i.e. the first black pixel of the arrow tip. PIXEL is blind at the
bottom and right clamps (only ~2 of 16 rows on screen), which is exactly where
RAM covers for it — and RAM reads (1119,831) there, as the clamp requires.

**A trap worth writing down:** the Previous window is not always at the X
root's origin. SDL centres it and lands the 1120x832 NeXT screen at +16+12 on a
1120x832 root; `nextstep-kiosk-frame.sh` re-anchors it, but on one boot of this
clone the anchor had not landed when measurement started, and the guest-to-root
mapping was off by (16,12) with the right 16 columns and bottom 12 rows of the
NeXT screen scrolled off the captured framebuffer entirely. Any framebuffer
instrument for this tile must assert the window origin before it trusts a
coordinate.

## 6. Results

| criterion | verdict | evidence |
| --- | --- | --- |
| 1 accuracy, 24 targets, one move each | **PASS**, max 0 px, mean 0 px | `previous-abs-run6-paced.json`, shots `run6-paced-t00..t23` |
| 2 after the guest moved the cursor | **PASS**, max 0 px | `previous-abs-run4-robust.json`, shots `run4-menu-{before,open,closed}` |
| 3 survives `loadvm` | **PASS**, max 0 px, no re-discovery | `previous-abs-run5-loadvm.json` |
| 4 compiled hot path | **PASS** | `src/abspointer.c` in the `previous` binary |
| 5 latency | **PASS**, delta within +/-0.9 ms | three interleaved rounds, n=24 per arm |

Criterion 2 is framebuffer-proven at both transitions: a click delivered at an
absolutely placed cursor opens the Workspace **View** submenu, the cursor is
then walked with the driver's own accelerated relative path, and a second click
closes it again.

Criterion 5 compares two arms that differ **only** in the two int16 writes:
both enter through the same control channel, are drained on the same tick, call
the same `kms_mouse_move()`, and move the cursor the same 200 px, so everything
upstream of Previous and downstream of the KMS cancels. "Photon" is the
emulated NeXT framebuffer itself — `NEXTVideo` is hashed in C through the
control channel until it changes, poll period 0.65 ms.

## 7. What is NOT proven

* Nothing was promoted, and nothing was measured on the live tile.
* Promotion will need a **golden re-bake**: the golden snapshot carries the RAM
  image of the running `previous`, so a new binary is not picked up by
  `loadvm golden` alone. The QEMU device set is untouched.
* streamhost does not speak this channel yet. Wiring `SH_POINTER=abs` to
  `abs X Y` over a hostfwd'd port is unwritten.
* The discovery routine assumes the 1120x832 MegaPixel screen (true for every
  machine Previous emulates) and a NeXTSTEP that keeps cursorLoc where 3.3
  does. It fails loudly (`status result=3`) rather than guessing.
* The channel is unauthenticated and can read and write all of guest RAM. It is
  a UNIX socket inside the kiosk, reachable only by root and the kiosk user,
  but it is a capability the tile does not have today.
* Not tested: a cursor sprite other than the arrow (the boot "wait" disc would
  defeat the PIXEL instrument, though not the mechanism), multiple concurrent
  clients, or the ADB/Turbo machine types.
