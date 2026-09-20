# palmos guest

Status: **LIVE** on `/os/palmos` since 2026-09-20. Host-native MAME — no QEMU,
no guest OS filesystem, no network. See `docs/lab/PALMOS-WAVE.md` for the wave
brief, the measurements behind every choice below, and the OPEN items.

## Identity and source

- Public ID / tile directory: `palmos`
- Slot / UDP port / VMID: `207` / `54207` / `207`
- Machine: **PalmPilot Professional** (1997) — Motorola MC68328 "DragonBall"
  @ 16.58 MHz, 1 MB RAM. MAME 0.289 driver `palmpro`, `src/mame/palm/palm.cpp`
- OS: **Palm OS 2.0 Professional, English**
- ROM: `palmos20-en-pro.rom`, 1 048 576 B, SHA-1
  `535bd9548365d300f85f514f318460443a021476` — byte-exact for the `2.0epro`
  BIOS option the driver defines. Sourced as `Palm-OS-2.0-Pro-en.rom` from
  https://palmdb.net/app/palm-roms-complete, staged at
  `/data/assets-staging/palmos/roms/` on labhost. **Never committed.**
- Scene body: `phoneDock` / `palmPda`

**Why not the Palm III.** The wave opened on `palmiii` with Palm OS 3.3. That
combination boots and draws its splash into guest RAM but never enables the
MC68328's LCD controller, so the screen stays blank forever — measured, and the
same is true of 3.0/3.5/4.0 across `palmiii`, `palmiiic` and `palmm100`. Palm
OS 2.0 on this hardware displays correctly. The wave doc has the register
trace.

## Surface

Published surface is `160x220`, the driver's own visarea. The **LCD is only the
top 160x160**. Rows 160..219 are the printed Graffiti silkscreen — unlit on
real hardware too, so a blank strip there is correct, not a fault — but they
are part of the digitizer, so the Applications / Menu / Calculator / Find
buttons along it are tappable. That is the only route back to the Launcher
from an app.

## Pointer

Absolute pen, no cursor. `MAME_CTL_ABS=1` with tags `:PENB,:PENX,:PENY` and
`MAME_CTL_SCREEN=160x220`; `MOVEA` writes the `IPT_LIGHTGUN_X/Y` ioport fields
directly. Accuracy is exact by construction — the boot script calibrates the
digitizer with the pointer patch's own map — leaving only the pen field's 161
steps: ~1.0 px across, ~1.37 px down.

PROVEN 2026-09-20 over the real ctlsock: six Launcher icons (Address, Date
Book, Memo Pad, To Do List, Expense, Security) each opening the intended app,
plus the silkscreen Applications button returning from each.

## Keyboard

**None — this is a pen-only exhibit, deliberately.** A PalmPilot has no
keyboard; text is Graffiti handwriting. The driver's seven hardware buttons
are worse than unreachable: MEASURED 2026-09-20 driving each from the
Launcher, Button 2 (Address) and Button 3 (To Do List) corrupt the screen into
visible garbage, and Button 4 (Memo Pad) crashes Palm OS into a "Fatal
Exception" dialog. Only Button 1 (Date Book) and Power behave as documented,
and Power is itself a one-way sleep trap (see Known limits). No keymap ships
for this row — `palmos.keymap` was deleted, not left unpromoted — because the
previous placeholder wired exactly those broken buttons onto the on-screen
keyboard. Everything the exhibit needs is on the touchscreen, including the
silkscreen Applications/Menu/Calculator/Find row. Evidence:
`docs/lab/palmos-evidence/05`-`08`.

## Scene and reset

The scene is the **Applications Launcher**.

There is **no checkpoint**: restoring a savestate in a fresh process segfaults
inside zlib (heap corruption in `palmpro`'s setup, no contained fix — see the
wave doc). Instead `streamhost/stations/palmos/palmos-boot.lua` drives the
machine there on every cold boot: it taps through Palm OS's unskippable
three-target digitizer calibration and opens the Launcher, at fixed emulated
frame numbers, which is deterministic because this is a cold boot from mask ROM
into zeroed RAM with no NVRAM and no disk.

`SH_RESET_MODE=relaunch`, so a reset replays that boot. At the guest's current
speed that is minutes, not seconds — see OPEN 1 and 2 in the wave doc.

## Known limits

- **13% of real time.** ~7 CPU-seconds per emulated second; the suspect is
  MAME's per-pixel MC68328 LCD shift-out. Everything slow about this station
  descends from it.
- **`SH_IDLE_PAUSE_SECS=420`**, not the fleet's 60, because a frozen guest
  never finishes its scripted boot. An unwatched station therefore burns a core
  for 7 minutes after a session.
- **Auto-off after 2 minutes is a one-way trap.** MEASURED: once asleep
  (LCKCON's `LCDON` cleared), nothing brings the device back — not a pen tap,
  not a PORTD Power pulse, not both together, not a second Power press. Same
  root cause as the button corruption above (`pddata_r` reads the pen port
  where Palm OS expects the key matrix). Because the daemon freezes an
  unwatched guest, this mostly bites a visitor who IS connected and watching
  without touching for 2 minutes. No in-guest fix exists; the real fix is
  daemon-side (an idle-triggered relaunch inside 2 minutes). Evidence:
  `docs/lab/palmos-evidence/01`-`04`.
