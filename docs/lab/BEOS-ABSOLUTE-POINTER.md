# beos — an absolute pointer by writing BeOS R5's own coordinate

**Status: LIVE since 2026-08-31.** The station runs its own QEMU build at
`/opt/qemu-beos` (fork `c5449c80`), a golden cold re-baked under that binary,
and `SH_INPUT_BACKEND=ramabs` against `KH_RAMABS_ADDR=0x03a5fae4`.

This document is four things: the disproof of the two adapter routes (so nobody
spends a week rediscovering it), the recipe for deriving the address (which is
**load-bearing infrastructure**, because it must be re-run after every re-bake),
the proof, and the record of what the cutover cost.

**BINARY AND GOLDEN ARE ONE UNIT HERE.** The pre-cutover golden was baked under
the host `pve-qemu-kvm` package and carries a Proxmox-only `pbs-state` vmstate
section that a standalone build refuses; the post-cutover golden cannot be
restored by the host binary either. Neither half is independently revertible, so
`BEOS_QEMU` and the golden file move together in both directions. See §5.
## 1. What beos ended up with

BeOS R5 has no absolute pointing device its driver stack supports and no
hardware cursor a device model can read. What it *does* have is its own pointer
coordinate in RAM. `app_server` keeps it as **two little-endian `int32`**, x then
y. So `-device kh-ramabs` — qemu-patch `0007`, the ONE shared device patch,
whose `point32le` layout is this station's contribution (it was briefly numbered
`0010`; that number is **retired and merged into `0007`**, and adding a guest
profile to `kh-ramabs` takes no patch number at all) — writes the commanded
pixel straight into it and injects
**one 1-unit relative PS/2 nudge** to make `app_server` republish it — a write
alone repaints nothing, because a window server redraws on an event, not on a
memory change.

There is no control law, no gain, and no convergence criterion. **The hotspot
never enters the path.** It is still a real property of the drawn sprite —
R5's arrow draws at `pointer - (1,0)`, and so does its hand cursor, measured at
every target of the §4 sweep — but nothing in the mechanism needs to know it, so
the "magnet"
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

**You do not need an HMP `pmemwrite` for step 5, and should not build one.**
The 2026-08-30 bring-up added a probe-only monitor command for this and
deliberately did not ship it. It turns out to be unnecessary: **`kh-ramabs`'
own connect-time verification IS the write test, and a stricter one.** It
writes a DELIBERATELY WRONG value (the target minus the nudge's own delta),
reads it straight back to prove the write LANDED AT ALL — a write to unbacked
guest-physical memory is silently discarded, and a probe alone would then read
the guest's real unchanged pointer, find it exactly where it wanted it, and
declare a bad address good — and only then injects the nudge and requires **the
guest** to turn that wrong value into the right one. A derived copy fails by
construction: the write lands in the copy, but the guest's real pointer is
elsewhere, so after the nudge the guest republishes its own value over the top
and the read-back disagrees. Quiescence fails it too, rather than passing it.

So the procedure is: run the shipping device against each candidate, one per
QEMU start, and read `STAT`. On the 2026-08-31 bake this separated four
identically-tracking addresses on the first attempt:

| address | verified | device's own words |
|---|---|---|
| `0x02a8ff44` | no | `probe wanted 69,747, guest holds 77,740` |
| `0x02a904e8` | no | `probe wanted 69,747, guest holds 77,740` |
| **`0x03a5fae4`** | **yes** | `VERIFIED (probe landed at 69,747)` |
| `0x03a5faec` | no | `probe wanted 69,747, guest holds 77,740` |

**If more than one verifies, stop and escalate — that is not a tie to break by
preference.**

## 4. The proof (rule 9)

Run through the real `kh-ramabs` device on a sandbox rig, `-loadvm` of the
golden the address was derived against. **Three observers at every target**:
what was **commanded**, what the **device read back** (`STAT pos=`), and where
`cursor-locate.py` finds the sprite in a QMP screendump. The match is **exact**,
not `--tol 1` — there is no control loop and no deadband here, so a pixel of
slop would mean something is wrong rather than something is converging.

```
commanded  where                     sensor     framebuffer  hotspot
200,600    open desktop              200,600    199,600      (1,0)
800,300    over the corpus page      800,300    799,300      (1,0)
400,120    image-map link (hand)     400,120    399,120      (1,0)
300,34     NetPositive menu (hand)   300,34     299,34       (1,0)
60,430     Terminal window           60,430     59,430       (1,0)
950,700    bare desktop, right       950,700    949,700      (1,0)
512,384    screen centre (hand)      512,384    511,384      (1,0)

final STAT: addr=0x3a5fae4 layout=point32le verified=yes pos=512,384
            nudge=1/1px refused=2 reissued=4 probefail=0 converged=8
            gaveup=0 paused=0
```

**7/7 targets pixel-exact on all three observers**, across two different glyphs
and both window chrome and page content. `refused=2` is the first `MOVEA` of
each of two connections, refused while the device verifies — send a warm-up
target before any sweep or the first row of your table will show the previous
position and read as a failure.

**`reissued=4` is expected here, and the expected value differs per station** —
record it rather than normalising the three against each other. beos publishes
with `nudge-units=1/nudge-px=1`, so it has the same read-back-and-re-issue
behaviour as `rhapsody` (which showed `try=1` twice in 33 issues). `macos753`
shows **zero**, because `crsrnew` is a flag write with no injected event and
therefore no nudge race at all. Three stations, three different healthy values
for one counter.

**The golden's baked pointer is `69,747`** (sprite origin `68,747` plus the
`(1,0)` hotspot), and that number is operationally load-bearing rather than
trivia: the connect probe re-states where the guest already is, so `69,747` is
what the device reports `VERIFIED` at on every future connection. An earlier
draft of this work recorded `68,749`, measured during the bake window with the
relative actuator — the same actuator §4 shows cannot hit what it aims at. That
figure is **superseded**; it was not a position, for the same reason the
"no link glyph" result was not a negative.

### The hotspot is `(1,0)`, measured twice and never guessed

Two independent derivations agree, and neither assumes the other:

- the RAM **bias search** returns a `(1,0)` family. Because sprite ORIGINS are
  what is fed to it, `value - origin` being constant means that constant *is*
  the hotspot — so the search measures it rather than requiring it. That matters:
  assuming a hotspot in order to find an address and then "confirming" the
  hotspot from that address would be circular.
- the sweep above gives `commanded - located origin` at every target.

**Take it only from the write-test-confirmed address.** The derived copies track
the pointer perfectly and each yields its own constant offset; the same search
also returned `(-1,-2)` and `(14,13)` families, which are a *draw rectangle*
rather than a position (a rect corner goes negative at a screen edge, which is
how you know). A decoy's constant is not a hotspot.

### The restore proof, and the one thing it cannot see

Three `loadvm` cycles driven by **sourcing the guard's own**
`scripts/lib/checkpoint-guard-proof.sh` — `cpg_reference()` and
`cpg_prove_label()`, so `_cpg_same()` is the definition of "came back" and there
is no second SSIM implementation to disagree with it. Cycles 1 and 2 on one QEMU
process, **cycle 3 on a fresh one**, because a warm restore can pass where the
visitor path fails and the visitor path always starts with a new process.

```
cycle 1  process A  SSIM 1.0 (byte-identical)  cursor origin 68,747 == reference
cycle 2  process A  SSIM 1.0 (byte-identical)  cursor origin 68,747 == reference
cycle 3  process B  SSIM 1.0 (byte-identical)  cursor origin 68,747 == reference
```

**The cursor assertion is not decoration.** `_cpg_same` accepts SSIM >= 0.999,
and `checkpoint-guard-proof.sh` says in its own comment that a cursor move
scores `0.999756` — i.e. *"unchanged"*. So the guard's whole-frame comparison is
**blind to where the pointer is**, and on this station that blind spot sits
exactly on the property being cut over: `kh-ramabs`' connect probe RE-STATES
wherever the golden left the pointer, so a checkpoint that restored it
inconsistently would make verification behave differently run to run — and it
would present as an address problem rather than a checkpoint one. Assert the
sprite origin alongside the SSIM.

Also worth carrying to the next station: **typing dirties this guest.** BeOS is
not click-to-focus and the golden's Terminal holds the caret, so
`cpg_prove_label`'s typed `CPG_DIRTY_TEXT` moved the framebuffer below the SSIM
bar on all three cycles — no `CPG_DIRTY_CMD` and no telnet fallback needed.

### The calibration that mattered

`nudge-units` is guest-specific and getting it wrong is visible but subtle.
At rhapsody's `nudge-units=2` the targets landed 1-2 px off with `reissued=24`
across six targets; at **`nudge-units=1, nudge-px=1`** — R5's PS/2 path is 1 px
per unit at nudge speed — every target lands exactly. Symptom of a wrong nudge:
the read-back converges (so `STAT` looks healthy) while the drawn cursor sits a
pixel or two away, because the last *draw* happened at an intermediate value.

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

## 6. What the cutover cost, and what it left behind

All four steps that used to be listed here are done:

1. `/opt/qemu-beos` built from fork `c5449c80`, `--target-list=x86_64-softmmu`,
   **with nothing applied on top** — that tip already carries fast-poll (`0001`)
   and the shared `kh-ramabs` device (`0007`, including this station's
   `point32le`) as commits, so applying the patch files as well would only have
   been a chance to misapply them. `binarySha256`
   `90baceeb55935aa28c0f7637cb5218cda41bd24413ea870d2637c43415708669`, read from
   the installed file. Fast-poll is **not optional**: on the host package it
   arrives as pve quilt slot `0047`, and a build without it silently drops this
   tile to the stock 30 ms display scan.
2. Golden cold re-baked 2026-08-31 12:12:00 (`VM_CLOCK 0000:26:11.140`) with the
   retronet live, restore-proven under the new binary (§4).
3. Address re-derived against that bake: `0x03a5fae4`.
4. Deployed binary -> launcher -> streamhost -> env fixture.

### The bake needs the network, and therefore needs the station down

Not obvious until you try it, and it is the expensive part of any future
re-bake. The fixture is only correct with DNS, the corpus and ICQ live; that
needs a tap on `vmbr-rn`; the guest's address comes from a DHCP reservation
keyed on `RN_BEOS_MAC`; **and that MAC is in the golden's device vmstate**, so
you cannot bake under a substitute MAC to dodge the clash. Two `rtl8139`s with
one MAC on one bridge collapse to a single FDB entry. So exactly one beos may be
on `vmbr-rn`, and during a cold bake it has to be the rig: **the live station
must be stopped for the duration.** The 2026-08-31 window was 34 minutes.

That same fact is why everything *downstream* of the bake is free: an unenslaved
tap with an unchanged `-device` is safe beside the live station, because bridge
membership is a pure backend property and is not in the vmstate. The address
derivation, the cursor bank and the whole restore proof ran on a bridgeless tap
with the exhibit back in service.

### ICBM loses the boot race, and the watchdog does not catch it

Found during the bake and **not fixed here**. On the cold boot ICBM started
before R5's resolver was ready and sat at `Could not locate server` — the same
race `UserBootscript` already guards for NetPositive by polling until a *name*
resolves, and which nothing guards for ICBM. The watchdog does not recover it:
`icbm-watchdog.sh`'s `offline()` returns "not offline" when there is no
`LoginSuccessful` line at all, which is exactly the never-logged-in case. It
covers a **dropped** session and not a **never-started** one, so the client
stays offline indefinitely. Killing the team let the watchdog relaunch it into a
working resolver, after which it signed on and HiveBot greeted it.

The fix is not to invert that line: "no `LoginSuccessful` yet" is genuinely
ambiguous between "still logging in" and "never will", so it needs a
first-login deadline rather than a flipped return.

### The greeting window is a function of elapsed time, not of the scene

HiveBot greets every sign-on about 30 s later, and the message window lands over
the corpus page — over the exhibit. So there is no single "what a cold boot
produces": bake early and it is absent, bake late and it is there. The incumbent
golden settles it, and the incumbent has no message window, so the 2026-08-31
bake closed it before `savevm`. That is reproduction rather than curation, but
it is the one hand-arrangement in an otherwise script-reproduced fixture, and
`SH_FIXTURE_DESC` now records it so the next re-bake does not have to restore
the old golden to find out.

Note this only sets the INITIAL scene. A live re-sign-on still pops a greeting
over the exhibit in front of a visitor. Whether that is charm or defect is an
operator call, not a bring-up one.

### Rollback

Two lines, and they move **together** (§5): `BEOS_QEMU=/usr/bin/qemu-system-x86_64`
plus restoring `beos-golden.qcow2` from
`beos-golden.qcow2.cpg-bak-20260831T083703Z`
(sha256 `12300e30486c5c2f792d0fe60e5a075718e19de23bc95b391e3cf5ce25109660`).
Unsetting `KH_RAMABS_ADDR` alone drops the device and returns the relative
pointer, but leaves the new golden in place, which the host binary cannot read.

**This rollback has been run, not merely argued.** On 2026-08-31 that backup was
restored under `/usr/bin/qemu-system-x86_64` on an isolated tap and came back to
the fixture scene. Every other station in the wave has a rollback path that is
only reasoned about; this one has been exercised.
