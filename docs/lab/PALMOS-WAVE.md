# palmos wave — a PalmPilot, and the Palm OS that this emulation can actually draw

**LIVE** on `/os/palmos` since 2026-09-20. PalmPilot Professional (1997),
Palm OS 2.0 Professional (English), MAME 0.289 `palmpro`, host-native.
Stylus proven on seven targets. Slot 207 / UDP 54207 / VMID 207.

## The station

| Fact | Value |
|---|---|
| Driver | `palmpro` — PalmPilot Professional, MC68328 "DragonBall" @ 16.58 MHz, 1 MB RAM (`src/mame/palm/palm.cpp`) |
| BIOS | `2.0epro`, `palmos20-en-pro.rom`, 1 048 576 B, sha1 `535bd9548365d300f85f514f318460443a021476` — byte-exact for the option the driver defines; sourced as `Palm-OS-2.0-Pro-en.rom` from palmdb.net's palm-roms-complete |
| Surface | 160x220, the driver's own visarea. The **LCD is only the top 160x160**; rows 160..219 are the printed Graffiti silkscreen — unlit on real hardware too, but part of the digitizer, so its Applications/Menu/Calculator/Find buttons are tappable |
| Pointer | absolute pen, `MAME_CTL_ABS=1`, tags `:PENB,:PENX,:PENY` |
| Scene | Applications Launcher, reached by a scripted cold boot (`streamhost/stations/palmos/palmos-boot.lua`) |
| Checkpoint | **none** — savestate restore segfaults on this driver (below) |
| Audio / retronet | off. A PalmPilot has no network and a 1-bit PWM speaker |

## The wall that decided the station: Palm OS 3.x boots but never displays

The wave opened on `palmiii` (Palm III, 1998) with Palm OS 3.3, because
`palmiii` is one of the Palm targets that ships `MACHINE_SUPPORTS_SAVE` with no
working-flag caveat. It boots. It never displays, and nothing you press changes
that.

What is actually happening, measured rather than inferred:

- The CPU runs. It parks at PC `0x10c0bd00` in ROM, in a 68000 `STOP` — zero
  register reads while parked.
- Palm OS has **drawn the splash**. The MC68328's `LSSA` register points at
  `0x00014b90` in guest RAM, and dumping 3200 bytes from there and rendering it
  as 160x160 1bpp gives the "Palm Computing Platform" logo, pixel for pixel.
- The **LCD controller is switched off**. `LCKCON` (byte at `0xfffa27`) is
  written `0xd8` (bit 7 `LCDON` set) and `0x58` (clear) a few times during init
  and settles on `0x58` at frame 73 — about 1.2 emulated seconds — and is never
  written again. So every published pixel is `mc68328lcd`'s literal `LCD_OFF`
  colour, `(0xbd,0xbd,0xaa)`.
- Input reaches the machine and does not help. A Power press moves the PC to a
  different loop, so the interrupt lands; 19 Power presses and 19 pen presses
  over 40 emulated seconds never set `LCDON` again. The reason input cannot
  help is in the driver: `palm_base()` wires the CPU's port-D **input**
  callbacks to the **PENB** port (`in_port_d<N>().set_ioport(m_io_penb).bit(N)`),
  and PENB defines only bit 0. `button_check` pushes the real PORTD bits in
  through `port_d_in_w`, which only raises the keyboard interrupt; the value
  Palm OS then READS comes from `pddata_r`, which prefers the callbacks — i.e.
  PENB. Palm OS wakes, reads "no button held", and sleeps again.

The same blank screen appears on `palmiii` with Palm OS 3.0 English (the
driver's own `ROM_DEFAULT_BIOS`), on `palmiiic` with 3.5 and 4.0, and on
`palmm100` with 3.51. **Palm OS 2.0 Professional settles `LCKCON` on `0xd8`
and renders.** So the exhibit is the machine that OS shipped on — the
PalmPilot Professional — which also happens to close the wave's other gap: the
2.0 dump is English, where no byte-exact English 3.x dump for `palmiii` exists
(palmdb's `Palm-III-3.3-en.rom` is a different, 1 343 488-byte file that matches
no BIOS option this driver defines).

This is a real gap in MAME's Palm emulation, not a configuration mistake. MAME
0.289 is the newest tag, and no commit has touched `src/mame/palm/palm.cpp`,
`src/devices/machine/mc68328.cpp` or `src/devices/video/mc68328lcd.cpp` since
it, so there is nothing to upgrade to.

### The gate that let it through

`native_gate_nonblack` counts LIT pixels, and on this machine a DEAD LCD is
uniformly "lit": the 3.3 build passed the fleet smoke gate at **35200/35200
pixels** while showing a visitor nothing. `native.d/palmos.sh` therefore
overrides the gate to demand **more than one distinct colour** on the published
surface, which is what a lit LCD actually produces. Any future station whose
"off" state is a flat non-black fill wants the same override.

## The pointer: a fourth route, and the binding it was missing

Palm's pen is `IPT_LIGHTGUN_X/Y` with `PORT_MINMAX(0,0xa0)` — a true absolute
analog ioport field whose current value *is* the pen position, latched by the
`Pen Button` field's `PORT_CHANGED_MEMBER`. There is no delta to integrate and
no on-screen cursor to read back, so none of the fleet's three existing pointer
routes fit. `mame-ctlsock-abs-fields.patch` adds `MAME_CTL_ABS=1`: `MOVEA`
writes `m_x_field`/`m_y_field` directly, scaled from the published surface into
each field's own declared range via `minval()`/`maxval()`.

**The patch as first written could not work at all**, and its acks hid it. The
`ptr-tags` patch binds the axis handles by matching `IPT_MOUSE_X/Y` — which no
absolute-axis machine has — so on exactly the machines `MAME_CTL_ABS` exists
for, `m_x_field`/`m_y_field` stayed null, the new branch never fired, and every
`MOVEA` still replied `OK` while the pen sat at its `0x50,0x50` power-on centre.
Measured by watching the live field values from a Lua frame notifier while
driving the real ctlsock. The patch now carries an absolute-axis fallback,
gated on `MAME_CTL_ABS` and only ever filling a handle that would otherwise be
null, so it is inert for every existing station.

### Why the accuracy is exact by construction

Palm OS's digitizer calibration cannot be skipped, and it is the thing that
defines the raw-to-screen map. `palmos-boot.lua` taps the three calibration
targets at the raw values **the pointer patch itself would compute** for those
surface pixels (`raw = round(px * 0xa0 / (surface - 1))`, i.e. `x*160/159` and
`y*160/219`). Whatever affine map Palm OS derives is therefore the exact inverse
of the map every later `MOVEA` goes through. The only residual error is the pen
field's own 161 steps: **~1.0 px across, ~1.37 px down**. Launcher icons are
about 22x30 px, so no tap is ambiguous.

A happy side effect: because the Y calibration is deliberately compressed
(surface row 219 maps to raw 160 rather than row 160 doing so), the whole
160x220 digitizer is addressable, including the unlit silkscreen strip. That is
the only way to reach the Applications button, and therefore the only way back
to the Launcher from an app.

### Measured: seven targets, every one landing

Driven over the real ctlsock (`MOVEA` / `DOWN1` / `UP1`) on the station's own
binary, 2026-09-20. Each tap had to open a *different screen*, and the return
trip went through the silkscreen:

| Target | Surface (x,y) | Result |
|---|---|---|
| Address | 29,16 | Address List, with the stock PalmPilot Accessories / Technical Support records |
| Date Book | 127,16 | day view, "Jan 1, 97", hour grid |
| Memo Pad | 78,84 | Memo List: "Entering text into your PalmPilot", "PalmPilot Basics" |
| To Do List | 127,116 | To Do List, "Send in PalmPilot registration card" |
| Expense | 29,48 | Expense |
| Security | 78,116 | Security: Private Records, Password, Turn Off & Lock Device |
| Applications (silkscreen) | 14,175 | back to the Launcher, from each of the six |

The frames were looked at, not counted: a colour histogram would have passed a
blank LCD here, which is exactly how the 3.3 build nearly shipped. No held
button and no phantom drag — the returned Launcher is pristine in every frame.

## Why there is no checkpoint

Restoring **any** savestate in a fresh process segfaults inside zlib's
`inflate()` under `save_manager::read_file()`. Run to ground:

- the `.sta` is complete — Python inflates it cleanly to exactly the
  **7,198,225** bytes the machine registers, `eof=True`, no trailing data;
- the savestate **signature matches** (`sig=44b5f5a5`, 1001 entries, and the
  same value sits in the file header);
- the entry list walked live under gdb at the `handle_saveload()` breakpoint is
  **structurally identical** — 1001 entries, 7,198,225 bytes, the RAM device's
  1 MB `save_pointer` present and correctly sized;
- but zlib's own `internal_state` is **already corrupt** by the 343rd
  `inflate()` call, only 1288 bytes into the stream, with plenty of valid input
  buffered, and dies on a runaway `stos` with `RCX=0xFFFFFFFF`.

That is heap corruption during `palmpro`'s setup surfacing later inside zlib,
not savestate bookkeeping — so there is no contained patch to carry, and
writing one blind would be a guess. It is reproducible from Lua `machine:save()`
states and ctlsock `SAVEST` states alike, under `-video none`/`soft`/`shm`, with
and without the ctlsock environment. The station therefore sets
`MAME_NATIVE_CHECKPOINT=0`; setting it to 1 makes the launcher pass
`-state golden` and the station crashes on start.

The scene is reached by driving the machine instead. Fixed frame numbers are
legitimate here because this is a cold boot from mask ROM into zeroed RAM with
no NVRAM and no disk — `machine_reset()` memsets RAM and copies the boot ROM, so
the path is identical every time, and the numbers count *emulated* frames.

## OPEN

1. **Speed — the headline problem.** The guest runs at **13%** of real time:
   `/usr/bin/time` says ~7 CPU-seconds per emulated second, and it gets 81% of a
   core, so this is emulation cost, not starvation. The prime suspect is
   MAME's MC68328 LCD model, which shifts the panel out **one pixel at a time**
   through an `emu_timer` (`lcd_scan_tick` toggles `lsclk` twice per pixel —
   roughly 3M timer callbacks per emulated second at 160x160x60 Hz). A
   line-at-a-time DMA would be the fix and would improve everything below at
   once. Not attempted: it is emulation surgery and wants its own stream.
2. **Scene build vs the idle freeze.** Because there is no checkpoint, the
   ~23 emulated seconds of scripted boot are ~3 minutes of wall clock, and with
   the fleet-default 60 s idle grace the daemon froze the emulator 8 emulated
   seconds in — a frozen guest never finishes booting, so the station sat
   stopped on a blank screen forever. `SH_IDLE_PAUSE_SECS=420` buys the scene
   time to build; the price is that an unwatched station burns a core for 7
   minutes after each session instead of one. Fixing (1) or the savestate crash
   retires this.
3. **Auto-off is a one-way trap. MEASURED, not fixed.** Palm OS has "Auto-off
   after: 2 minutes" and no "never". A separate stream put the device to sleep
   via a PORTD Power press (the same LCD-off path the auto-off timer drives —
   confirmed with the LCKCON write-tap: `0xd8`→`0x58` on sleep) and then tried
   every plausible wake: a pen tap held up to 6.7 emulated seconds, a PORTD
   Power pulse alone, pen-held-plus-Power together, and a second identical
   Power press. **None re-set `LCDON`.** Every framebuffer stayed the sleep
   colour. This is the same root cause as the button corruption below —
   `pddata_r` reads the pen-button port where Palm OS expects the key matrix,
   so whatever a real Palm reads to wake itself has nothing to read here.
   Because the daemon freezes the guest (`SIGSTOP`) once nobody is connected,
   the 2-minute clock mostly only runs while a visitor IS watching and NOT
   touching — precisely the visitor the idle grace exists to protect. There is
   no in-guest recovery. The only real fix is daemon-side: an idle-triggered
   relaunch comfortably inside 2 minutes, or the savestate crash fixed so a
   fast checkpoint reload can serve as that reset. Neither is done. Evidence:
   `docs/lab/palmos-evidence/01`-`04` (awake → Power-sleep → pen tap fails to
   wake → a second Power press fails to wake).
4. **Hardware buttons are worse than inert — three of seven break the guest.
   MEASURED, removed from the fixture.** Driven from the Launcher: Button 1
   (Date Book) opens the Week view cleanly and Power sleeps the device as
   above, but Button 2 (Address) and Button 3 (To Do List) corrupt the screen
   into visible garbage, and Button 4 (Memo Pad) crashes Palm OS outright into
   a "Fatal Exception" dialog with only a Reset button. Up/Down show no effect
   on the Launcher — plausibly genuinely inert there, not corrupting. The
   station therefore ships with **no keymap at all** — `palmos.keymap` is
   deleted and `SH_MAMESOCK_KEYMAP` is unset, not merely unpromoted — because
   the previously-committed placeholder wired exactly the two corrupting and
   one crashing button onto the on-screen keyboard. Evidence:
   `docs/lab/palmos-evidence/05`-`08` (Date Book works, Address corrupts, To
   Do List corrupts, Memo Pad's Fatal Exception dialog).
5. **Scene body.** `palmPda` is the `phone-a` handheld shell at the PalmPilot's
   own height (119.4 mm), scaled uniformly so the proven geometry is not
   distorted. A real PDA mesh — flatter, wider, with the silkscreen area printed
   below the glass — would be a better exhibit.
6. **Graffiti.** Not attempted. The silkscreen writing area is tappable and the
   pointer is exact, so a stroke demo is reachable; it needs drag paths, not
   taps.

## Timeline (measured, `date -u`)

| | |
|---|---|
| 15:54Z | resume: worktree, merge main, orders bumped off a collision with msx2 |
| 16:01Z | first framebuffer of the predecessor's `palmiii` build: **uniformly blank** |
| 16:2xZ | CPU alive but parked; LCD registers configured; splash found in guest RAM |
| 16:39Z | `palmpro` + Palm OS 2.0 renders — digitizer calibration on screen |
| 17:03Z | Applications Launcher reached (compressed-Y calibration, silkscreen tap) |
| ~17:5xZ | pointer binding bug found: pen never moved; patch fixed; MAME rebuilt |
| 18:4xZ | **six-target stylus proof green** on the real ctlsock |
| 18:57Z | station retargeted to `palmpro`, gates green, committed |
| 19:0xZ | landed on main, deployed, binary + ROM on labhost |
| 19:28Z | **live station framebuffer shows the Applications Launcher** |
