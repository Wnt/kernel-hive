# beos — an absolute pointer by writing BeOS R5's own coordinate

**Status: mechanism proven on a sandbox rig 2026-08-30 (branch `beos-abs-ram`).
Not deployed.** The one step left is a cold golden re-bake under the station's
own QEMU build, which is what binds the guest-physical address the mechanism
needs. Until that exists the launcher adds no device and `beos` keeps the
relative pointer it has always had — the change is inert by construction.

This document is three things: the disproof of the two adapter routes (so nobody
spends a week rediscovering it), the recipe for deriving the address (which is
**load-bearing infrastructure**, because it must be re-run after every re-bake),
and the proof.

## 1. What beos ended up with

BeOS R5 has no absolute pointing device its driver stack supports and no
hardware cursor a device model can read. What it *does* have is its own pointer
coordinate in RAM. `app_server` keeps it as **two little-endian `int32`**, x then
y. So `-device kh-ramabs` (qemu-patch `0007`, plus the `point32le` layout this
station added as `0010`) writes the commanded pixel straight into it and injects
**one 1-unit relative PS/2 nudge** to make `app_server` republish it — a write
alone repaints nothing, because a window server redraws on an event, not on a
memory change.

There is no control law, no gain, and no convergence criterion. **The hotspot
never enters the path.** It is still a real property of the drawn sprite —
R5's arrow draws at `pointer - (1,0)`, measured across five independent
positions — but nothing in the mechanism needs to know it, so the "magnet"
failure mode that the closed-loop stations spend their hardest work guarding
against is impossible here rather than merely guarded.

## 2. The two adapter routes, and why both are dead

Recorded because both look plausible on paper and one of them looks *successful*
on a screenshot.

### `-vga mga` (reuse aix432's Matrox engine) — rejected

BeOS R5 really does ship Matrox drivers (`matrox` and `g400` kernel drivers,
`matrox.accelerant` / `g400.accelerant`, with `Init_G200` in the volume), and the
fork's `hw/display/mga.c` presents a G200 and already contains a working control
law. It is still the wrong route on x86:

- `VGA_MGA` is selected only by `hw/ppc/Kconfig`. A build for `x86_64-softmmu`
  has no `mga` in `-vga help` (measured — the binary was built to check).
- **The BARs are in the wrong order for a real G200.** `mga_realize` registers
  BAR0=vram, BAR1=ctrl, BAR2=iload; a real Matrox G200 is BAR0=control aperture,
  BAR1=framebuffer. The flip is the GXT130P/AIX presentation. R5's `matrox`
  driver would map the wrong regions, and fixing it means editing a file the
  live `aix432` station depends on.
- `mga.c` registers **no option ROM**. On PPC that is fine; on x86 SeaBIOS then
  finds no VGA BIOS, and R5's boot path today depends on the VESA BIOS (its
  `vesa` settings file is what sets 1024x768x16). R5's `matrox` driver also has
  an `MGA_MAP_ROM` ioctl, i.e. it wants the card's BIOS.

### `-device ati-vga` (Rage 128 Pro) — rejected, and it *looked* like it worked

R5 booted on `ati-vga` to a perfect 1024x768 desktop. It is not a success:

```
$ ls /dev/graphics
stub
```

**The guest silently fell back to the VESA stub driver.** A screenshot alone
would have read as a clean success and cost days before the sensor turned out
not to exist. Make driver binding an explicit positive check, always.

The full inventory, read out of the running guest, is worth having:

```
/boot/beos/system/add-ons/kernel/drivers/dev/graphics/
  3dfx 3dfx_voodoo4 ati g400 gxm i740 i810 matrox rage128 riva128 rivatnt sis620 trident
/boot/beos/system/add-ons/accelerants/
  3dfx_banshee 3dfx_voodoo4 ati g400 gxm i740 i810 matrox rage128 riva128 rivatnt sis620 stub trident
```

So `rage128` **is** installed and did not claim QEMU's card. It cannot be fixed
by lying about the PCI ID either: `ati-vga` accepts only `0x5046` and `0x5159`,
and R5 predates the Radeon. And the cursor was **visible in the screendump**,
i.e. software-composited — there would have been no hardware cursor to read even
if the driver had bound.

## 3. Deriving the address — the four-sample `pmemsave` bias search

**Re-run this after every golden re-bake.** It is about twenty minutes and it is
mechanical. It needs no patched binary and no C.

1. **Validate the proof tool first**, before you need it to adjudicate anything.
   `cursor-locate.py learn A.ppm B.ppm` **drowns on a busy desktop** — on the
   beos golden (NetPositive animating the corpus page, the Deskbar clock
   ticking) it learned a degenerate template that matched every row at `x=2`.
   Move the pointer into a quiet region, diff the two frames yourself to get the
   sprite's bounding box, and use `learn --at X,Y`. Confirm it then reports one
   position on a frame and an honest `NOTFOUND` on a frame where the sprite is
   clipped at a screen edge.
2. Drive the pointer to **three or four** well-separated positions. Park it
   against a corner first each time so the run is repeatable. At each position:
   `screendump` to a PPM, locate the sprite, and `pmemsave val=0
   size=0x20000000` the whole 512 MB.
3. Search for an address whose `(value - observed position)` bias is **constant
   across every sample**, as two `int32` little-endian, x then y. A chunked
   numpy pass over the memmapped dumps takes under a minute.
4. Confirm the survivors **track live** with HMP `xp /2dw <addr>` at further
   positions. On the golden this produced, at two positions:
   located `165,600` -> RAM `166,600`; located `696,735` -> RAM `697,735`.
   Exact, every time — which is also how the hotspot `(1,0)` was measured
   rather than guessed.
5. **Test writability. This is the only step that finds the input.** The search
   returns two bias families and several addresses in each:
   - bias `(1,0)` — four or five addresses that all hold the pointer;
   - bias `(-1,-2)` / `(14,13)` — a *draw rectangle*, not a position. It goes
     negative at a screen edge (read back as `4294967294` = -2), which is how
     you know it is a rect corner.

   Every one of them tracks perfectly. Only one is an input. Write a test
   coordinate into each and inject one nudge:

   | address | before | after write | after nudge | |
   |---|---|---|---|---|
   | `0x02a10b28` | 53 714 | 53 714 | 54 714 | read-only copy |
   | `0x02a36f44` | 54 712 | 54 712 | 55 712 | read-only copy |
   | `0x02a374e8` | 53 712 | 53 712 | 54 712 | read-only copy |
   | **`0x038f1ae4`** | 53 712 | 53 712 | **400 300** | **the input** |
   | `0x038f1aec` | 54 712 | 54 712 | 55 712 | read-only copy |

   Note that the write is invisible until the nudge — which is exactly why a
   write test without a publish step would have found nothing and concluded,
   wrongly, that none of them is writable.

   **Check the copies are inert, not load-bearing — and check it the right
   way.** On some guests a derived copy is the redraw path's own *change
   detector*: the repaint happens only when a freshly computed value differs
   from the one the copy holds, so pre-writing it makes the guest conclude
   nothing moved, clear its publish flag and draw nothing — **while every
   coordinate still reads back exactly correct**. That is how it presents on
   Mac OS (`Mouse`), and it is indistinguishable from "the write did nothing"
   unless you test for it precisely.

   Writing some *other* value does not test this, because a detector fires on
   that anyway. The check is to pre-write the copy with **exactly the value the
   guest is about to compute** — current + the nudge's own delta — and then
   nudge. On R5, all four are genuinely inert:

   ```
   pre-wrote 0x02a10b28   pointer 36,34 -> 37,34   framebuffer 36 34   MOVED
   pre-wrote 0x02a36f44   pointer 37,34 -> 38,34   framebuffer 37 34   MOVED
   pre-wrote 0x02a374e8   pointer 38,34 -> 39,34   framebuffer 38 34   MOVED
   pre-wrote 0x038f1aec   pointer 39,34 -> 40,34   framebuffer 39 34   MOVED
   control (no pre-write) pointer 40,34 -> 41,34   framebuffer 40 34   MOVED
   ```

   Every row behaves exactly like the control, and the drawn sprite tracks the
   pointer at `pointer - (1,0)` throughout, so none of the copies gates
   `app_server`'s repaint. That run is also a **quiescence demonstration**: five
   successive nudges walked the pointer 36 -> 41, each one publishing, so a
   wedged guest would show as a pointer that stops rather than as a probe that
   quietly passes.

**A probe-only HMP `pmemwrite` was used for step 5 and is deliberately not
shipped.** A generic guest-physical memory write at the monitor is not a
capability to land, even guarded. Re-add it to a sandbox build for the twenty
minutes you need it: ~30 lines in `hw/core/machine-hmp-cmds.c` calling
`cpu_physical_memory_write`, plus an entry in `hmp-commands.hx`.

## 4. The proof (rule 9)

Run through the real `kh-ramabs` device on a sandbox rig, `-loadvm` of a
checkpoint the address was derived against. Three observers at every target:
what was **commanded**, what the **device read back** (`STAT`), and where
`cursor-locate.py` finds the sprite in a QMP screendump. Expected sprite origin
is `commanded - (1,0)`, and the match is **exact**, not `--tol 1`.

```
commanded    sensor (STAT)          framebuffer   verdict
200,600      verified=yes 200,600   199 600       OK
800,300      verified=yes 800,300   799 300       OK
400,0        verified=yes 400,0     399 0         OK   <- top screen edge
300,34       verified=yes 300,34    299 34        OK   <- Terminal title bar
588,240      verified=yes 588,240   587 240       OK   <- Terminal right frame
60,430       verified=yes 60,430    59 430        OK   <- Terminal bottom frame
1000,760     verified=yes 1000,760  NOTFOUND           <- sprite clipped at the corner
0,400        verified=yes 0,400     NOTFOUND           <- sprite clipped at x=0

DOWN1/UP1 at 36,34 -> 11958 px repainted, bbox x 6-194 y 25-107
  (the Terminal menu opened -- a real repaint, not a cursor blit)
STAT: addr=0x38f1ae4 layout=point32le verified=yes nudge=1/1px
      converged=9 gaveup=0 paused=0 refused=1 probefail=0
```

**Run twice, agreeing to the pixel.** The table above is the shipped stack
(`0007` + `0009` + `0010`). An earlier run on `0007` + a standalone `point32le`
— before `0009` restructured the accessors into offset-taking primitives —
produced the identical eight rows. Two independent builds of the mechanism
landing on the same pixel at every target is what makes this a proof rather
than a measurement of one binary.

The `refused=1` is the first `MOVEA` after connect, refused while the device
verifies its address — see the warm-up note below.

Six targets pixel-exact with all three observers agreeing, including a screen
edge and three window-frame positions. The two `NOTFOUND` rows are the matcher
being **honest** where the sprite is clipped off-screen, and the sensor still
reports the commanded pixel there — which is the case a framebuffer alone cannot
adjudicate.

### The calibration that mattered

`nudge-units` is guest-specific and getting it wrong is visible but subtle.
At rhapsody's `nudge-units=2` the targets landed 1-2 px off with `reissued=24`
across six targets; at **`nudge-units=1, nudge-px=1`** — R5's PS/2 path is 1 px
per unit at nudge speed — every target landed exactly, `reissued=7`. Symptom of
a wrong nudge: the read-back converges (so `STAT` looks healthy) while the drawn
cursor sits a pixel or two away, because the last *draw* happened at an
intermediate value.

Also: **the first `MOVEA` after connect is refused** while the device runs its
verification, so send a warm-up target before any proof sweep or the first row
of your table will show the previous position and read as a failure.

## 5. `pbs-state` — a fleet-wide constraint on build strategy

**A golden baked under the host `pve-qemu-kvm` package cannot be restored by a
standalone `/opt/qemu-*` binary.** Measured on beos:

```
qemu-system-x86_64: Unknown section or instance 'pbs-state' 0.
Make sure that your current VM setup matches your saved VM setup ...
```

`pbs-state` is a Proxmox Backup Server vmstate section added by the pve patch
series. It is a property of **the golden**, not of the guest, so:

- it binds **every station that runs the host package** and whose golden was
  baked under it — for those, adopting any fork/patched binary costs one cold
  re-bake;
- it does **not** bind stations already on a standalone build (`rhapsody`,
  `hpuxvue`, `macos753`, `sunos414`): their goldens never carried the section.

Read this **before choosing a build strategy for a port**, because it silently
decides whether a station can use a fork build at all. beos was the wave's only
station on the host package, and the choice it forced was: rebuild the
`pve-qemu-kvm` package that every other guest on this hardware runs (including
other projects'), or spend one cold re-bake and move beos onto its own build.
**We chose the re-bake**, because a per-station binary has a blast radius of one
station and the package rebuild does not.

## 6. What is left

1. Build `/opt/qemu-beos` — QEMU 11.0.2 with qemu-patches `0001` + `0007` +
   `0009` + `0010` (verified to apply cleanly in that order and to compile
   under `-Werror`; `0009` is macos753's layout-table restructure, which
   `0010` extends rather than replaces). `0001` is not optional: on the host package fast-poll arrives as pve
   quilt slot `0047`, and a build without it drops this tile back to the stock
   30 ms display scan.
2. Cold re-bake the golden on that binary, same device set. The fixture is
   reproducible from cold by design — `UserBootscript` opens the Terminal and
   NetPositive and the ICQ client, which is exactly why the 2026-08-23 MAC/NIC
   re-bake was repeatable — so this is a mechanical bake, not a hand-arranged
   scene. **Rule 6: do not retire the old golden until the new one is
   restore-proven, and here that proof is stronger than usual because it is a
   restore under a different binary.**
3. Re-derive the address against the new golden (§3), put it in
   `runtime.qemu.pointerRamAddress` and in `KH_RAMABS_ADDR`.
4. Deploy in order: **binary, then launcher, then streamhost, then the env
   fixture.** The launcher is safe to deploy ahead of the address because it
   omits the device entirely when `KH_RAMABS_ADDR` is unset.

Rollback is two lines: unset `KH_RAMABS_ADDR` and put `SH_INPUT_BACKEND` back to
`dbus-rel`.
