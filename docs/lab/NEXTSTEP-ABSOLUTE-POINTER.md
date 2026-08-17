# NeXTSTEP absolute pointer — the native tablet path

**Status: PROMOTED (2026-08-10).** Angle `native-tablet` of the `nextstep`
pointer problem, method [HARD-PROBLEM-METHODOLOGY.md](HARD-PROBLEM-METHODOLOGY.md).
This page is the winning angle's own write-up, kept as the record of *why*; what
actually ships, and how a rebuild reproduces it, is in
[`docs/guests/nextstep.md`](../guests/nextstep.md) §4 and
`scripts/build-guests/tiles/nextstep.sh` +
`scripts/build-guests/nextstep-tablet-install.py`.

## The result in one line

The `nextstep` exhibit does not need its relative pointer fixed — **both halves
of a native absolute path already exist and already match each other**, so the
acceleration curve never enters the picture. Measured on a clone: 24 of 24
commanded absolute targets landed with **0 px** error, four times over.

## The two halves

**Emulator side — Previous already emulates graphics tablets.** `src/tablet.c`
(863 lines, upstream, r1847 = the revision this tile already builds) simulates
the SummaGraphics MM 961 / MM 1201 digitisers and the WACOM SD series on the
NeXT SCC **serial port B** (`tablet_send` → `scc_receive(1, val)`). Selected by
`[Tablet] nTabletType` in `previous.cfg` — a key the tile's builder **already
writes**, as `0`. `src/gui-sdl/sdlevent.c` and `sdlkeymap.c` route the host's
**absolute** SDL window coordinates to `tablet_pen_move()` whenever
`nTabletType` is set and the guest driver has enabled the tablet; only
otherwise do they fall through to the relative `kms_mouse_move()`.

| `nTabletType` | Device |
|---|---|
| 0 | none (what the tile ships today → relative KMS mouse) |
| 1 / 2 | SummaGraphics MM 961 / **MM 1201** |
| 3–7 | WACOM SD210L / SD310E / SD320E / SD420E / SD510C |

**Guest side — NeXTSTEP 3.3 ships the matching driver.** `/NextAdmin/
InstallTablet.app` (setuid root, 139264 bytes, dated 21 Oct 1994) is on the
disk image the tile already uses. It writes an embedded kernel-server
relocatable to `/usr/lib/kern_loader/Tablet/tablet_reloc`, loads it, creates
`/dev/tableta` and `/dev/tabletb`, probes `/dev/ttyb` and attaches. The
on-disk NEXTSTEP administration manual documents the supported hardware:
SummaSketch I (MM I format, 12×12) and WACOM SD-210/310/311/312/320/321/322/
420/421/422/510B/510C. The driver has explicit **absolute** and relative modes.

Nothing has to be written, compiled or patched — which matters, because the
checkpoint carries **no m68k toolchain at all** (no cc/as/ld, no `/usr/include`).

## What was done on the clone, and what it produced

`nTabletType = 2` (MM 1201) in `previous.cfg`, Previous restarted, then
`InstallTablet.app` run once. Its own status panel:

```
+++ Installing Tablet +++ / Installing driver relocatable / Installing /dev
nodes / Checking for loaded server... done / Loading tablet driver server /
Getting tablet parameters / Connected to a SummaSketch tablet / Attaching
tablet / +++ Tablet Installed +++
```

and, on the emulator side, in `/tmp/previous.err`:

```
[Tablet] Reset
[Tablet] Unknown input: ~        <- the driver probes for a WACOM first
[Tablet] Unknown input: #
[Tablet] Send configuration
[Tablet] Data collection mode: stream      <- bTabletEnabled = true
[Tablet] Tablet origin: upper left         <- same origin as the screen, no flip
```

From that point a single absolute host-pointer warp places the NeXT arrow on
the commanded pixel. Four independent 24-point sweeps — plain desktop, after
the guest itself opened and closed menus, after an HMP `loadvm golden`, and
after a **fresh QEMU process** started with `-loadvm golden` — each returned
`max = 0 px, mean = 0.00`, with no iterative hunting: one commanded move, 250 ms,
one screendump, one glyph match.

**The driver survives `loadvm golden`.** Previous's own README warns that the
tablet driver "needs to be re-installed after every boot of the guest system";
`loadvm` restores RAM and device state rather than booting, so a checkpoint
captured with the driver attached comes back with it attached. That was verified both
ways above, and it is the reason this fits the exhibit's reset model at all.

## What shipping it costs

1. `previous.cfg`: `nTabletType = 2`.
2. Run `InstallTablet.app` once and **capture the checkpoint with the driver attached**
   (`SH_RESET_MODE=loadvm` then keeps it for every visitor and every reset).
3. QEMU: add `-device usb-tablet` so the browser's absolute coordinates reach
   the kiosk's X server as absolute; station `SH_POINTER=abs`, UI `pointerRel:
   false`; revisit `vmport=off`, which exists only to protect the relative path.
4. The X root must stay exactly 1120×832 at +0+0 — already true, and now it is
   load-bearing for a 1:1 mapping rather than merely for edge registration.

Step 3 changes the device set, so a checkpoint recapture is required — but step 2
requires one anyway.

**Hot path: there is no new code.** The shipped chain is compiled end to end
already — streamhost (Rust) → QEMU `usb-tablet` (C) → Xorg (C) → SDL3 (C) →
Previous `tablet.c` (C) → NeXTSTEP `tabletdriver` (m68k kernel server, 1994).
The Python in this angle was only the test harness.

## Cost, and the honest limit of the latency figure

The Summa position report is 5 bytes and `Tablet_IO_Handler` clocks them out one
per `CycInt_AddTimeEvent(1000, …)`, which `src/cycInt.c` documents as
**microseconds** — so **~4 ms** of emulated serial time per absolute report,
against a relative `kms_mouse_move()` that writes its register directly. That is
a bound read out of the code, **not a measurement**: the only instrument this
station has for input→photon is a screendump poll loop whose floor is ~0.58 s
(`docs/guests/nextstep.md` §6), which cannot resolve 4 ms, and labhost was
carrying a load average of ~10 from sibling clones throughout. Treat 4 ms as the
number to confirm on quiesced labhost with a real instrument before promotion.

## The measurement instrument

The cursor locator matches the NeXT arrow's exact 11×16 glyph (the display is
2-bit greyscale, so every pixel is one of 0/85/170/255 and the 96 glyph pixels
that are 0 or 255 form an exact template; background pixels are excluded, so the
match is background-independent). It was validated before use: it returns
**exactly one** hit on every frame tested, at positions independently confirmed
by eye, across four different desktop states, and it degrades gracefully at
screen edges by matching only the in-bounds portion. Its one known blind spot is
that NeXTSTEP swaps in an I-beam over text views, which is not the arrow.

## What the promotion closed, and what it did not

Closed during promotion (see the guest doc for the evidence):

- **Buttons and drag.** A single click selects a Workspace icon; a press-drag-
  release on the File Viewer's title bar moves the window by exactly the
  commanded offset and lands where it was let go, round trip.
- **The install is now automated and reproducible**, not hand-driven:
  `nextstep-tablet-install.py`, invoked by the builder between its last cold boot
  and `savevm golden`, and re-runnable by an operator after any cold boot.
- **The cold-boot asymmetry** is written down where it will be read (guest doc
  §4, `scripts/coldboot/nextstep-zero-input-prep.md`) rather than left implicit.

Closed on the second promotion attempt (2026-08-10), after the first one blocked
on the pre-driver click:

- **The bootstrap click.** It is a one-time bake step and it did not need the
  general controller the first attempt tried to build. Fixed **1 px** relative
  steps are exactly 1:1 on this machine (100 steps → 100 px, both axes), because
  a single-pixel event is below anything NeXTSTEP's acceleration curve can
  amplify; the walker takes |error| of them and re-reads the framebuffer. It
  landed dead centre on the Install button from 634 px away, in one round, on
  the station that had defeated four controller variants.
- **RETURN was tested and does not work**, despite the button carrying the
  default-button ⏎ glyph: the panel never becomes key.
- **Buttons need a slow press/release** once the tablet is live — `xdotool
  click 1` is too fast and silently does nothing.

Still unproven:

- The 4 ms serial-report figure. It is read out of `tablet.c` +
  `cycInt.c`, not measured: this station's only input→photon instrument is a
  screendump poll loop with a floor three orders of magnitude coarser, and
  labhost was carrying a load average of ~10-12 from the rest of the fleet.
- Only MM 1201 was tried. The WACOM types report a finer coordinate range and
  might behave differently at the edges; there was no need to look.

## Addendum 2026-08-11 — the cold-boot asymmetry is closed

The "driver must be reinstalled after every boot" limit was NeXTSTEP default
behavior, not an emulator fact, and it fell to a two-line rc.local hook. What a
sandbox clone (`NSTAB-coldboot`) established, in order:

- `kl_util -a <reloc>` allocates AND loads the server, but persists nothing:
  **kern_loader owns `/etc/kern_loader.conf`** and rewrites it (a manual append
  was pruned; so was the stale NeXTdimension line). rc.local is the reliable
  hook: `kl_util -l tablet` + `kl_util -a /usr/lib/kern_loader/Tablet/
  tablet_reloc`, one of which always lands.
- The reloc's Mach-O has a `Loaded Server/Load Commands` section ending in
  `CALL tablet_attach 0` — **loading is attaching**. Disassembly of
  `tablet_attach` (m68k, 186 bytes): check an "already attached" flag via an
  ioctl on dev 0x1001 (= /dev/tabletb, major 16 minor 1), then with interrupts
  masked copy 11 function pointers from the reloc's `__DATA` over the kernel's
  low-memory pointer vectors at 0x2c0–0x2e8. `tablet_detach` (the Unload
  Command) restores the saved KMS vectors.
- **Timing is everything.** Loaded mid-session (WindowServer already up), the
  swap disconnects the KMS mouse and probes nothing — the pointer freezes
  (observed; `kl_util -u tablet` recovers). Loaded during `/etc/rc`, the
  WindowServer's own device init runs the serial probe and the pointer comes up
  absolute: after a plain guest boot with the hook, a commanded warp to
  (100,100) put the NeXT arrow at exactly (100,100), no GUI touched.
- The InstallTablet.app GUI dance is therefore a ONCE-PER-DISK event (it writes
  tablet_reloc and the /dev nodes); `nextstep-tablet-install.py` now probes
  first, skips the GUI when a boot is already absolute, and writes the rc hook
  on both paths. The live checkpoint was recaptured 2026-08-11 with the hook on disk.
