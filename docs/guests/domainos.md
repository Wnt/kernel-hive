# Apollo DN3500 (1988) — Domain/OS SR10.4.1 Display Manager station (:54192)

**Guest:** a **host-native** MAME 0.276 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys), no bridge VM, no QMP.
MAME's **`dn3500`** driver (`src/mame/apollo/apollo.cpp`) emulates an
**Apollo DN3500** (Motorola MC68030 @ 25 MHz, 16 MB RAM, 8-plane colour), a
1988 engineering workstation running **Domain/OS SR10.4.1**, Apollo's own
UNIX-derived, distributed, single-level-store operating system. See
**`docs/guests/samcoupe.md`** and **`docs/guests/apple2e.md`** for the
host-native MAME shape this station follows (device set, ctlsock keyboard,
`SAVEST`/`LOADST` checkpointing) — `domainos` differs from both in one large
way: it has no boot-menu program of its own, and the exhibit is the vendor's
own **Display Manager**, driven by function keys, not a typed command.

**The Machine:** Domain/OS's Display Manager (DM) has no overlapping-window
manager and, on this station, no working pointer — function keys ARE the
interaction. `F1` opens a `Command:` bar at the bottom of the screen where a
visitor can start a shell pad (`cp /com/sh`) or a live process display
(`cp /com/pst`); `F11` aborts back to input; `F6` clears the command line;
other keys (Home/End/MENU/the numpad/F2–F5/F9/F10) move, grow, pop, close and
reprompt panes and will rearrange whatever scene is on screen.

**Build scripts:** `scripts/build-guests/emulators/native.d/domainos.sh`
builds the host-native `dn3500` MAME binary, pinned to **MAME 0.276**
(commit `758c8a169a44f0ce3abfd28e8b5c44cc49148eba`) rather than the fleet's
0.289 pin — see §Traps; `scripts/build-guests/tiles/domainos.sh` stages the
boot ROMs and the winchester image.

**Station dir (host, staged):** `/data/vms/streamhost/stations/domainos/` —
`ctl.sock`, `domainos.keymap`, `station.env.fixture`,
`sta/dn3500/golden.sta` (the savestate reset restores, once captured — see
§Checkpoint).

## License / provenance
- **MAME `dn3500`** — emulation driver in `src/mame/apollo/apollo.cpp`,
  GPLv2 licensed. `grep -c 'save_item\|save_pointer' src/mame/apollo/*.cpp`
  is **0** in every file — the driver registers no save state of its own
  (see §Checkpoint for what that means for this station's reset).
- **Boot ROMs** — `3500_boot_12191_7.bin`, sha256
  `7f1028f990027eead992204003dc85a6f411484e8a851af677db5dbe4a630584`, plus
  the `3c505` EtherLink Plus set (`0729-12_a.3h`, `0729-62_a.3f`,
  `3000_3c505_010728-00.bin`, `3com.9h`, `apollo.9h`). Source:
  **bitsavers.org/bits/Apollo/firmware** (a User-Agent header is required by
  that host). `3c505-nw.bin` has no good dump known — expected, and it is
  why the station's every start raises MAME's startup warning panel (see
  §Traps).
- **Winchester image** — `domain_os_10.4.1.awd`, 348 701 760 bytes, sha256
  `9f9ae29c56e456e2520d9107ea2fc30eb8f0dae2d46f6475cc7aa3a92db1f917`, SR10.4.1,
  volume last recorded 2002-07-31, provided-by `andrew_warkentin` via the
  Virtual OS Museum (reference only, CC BY-NC-SA — facts read, no bits
  copied; this disk was sourced independently). The gallery is private; the
  image is never committed.
- **Credentials** — `user` / `-apollo-`, in gitignored `registry/local.env`,
  never in Git; reference only here as `guest/domainos`.

## Device set
All driver defaults, set explicitly: `-isa1 wdc` (OMTI 8621 ESDI/floppy
controller; `winchester1` is `-disk1 domain_os_10.4.1.awd`), `-isa2 ctape`
(Archive SC-499 tape, unattached), `-isa3 3c505` (3Com EtherLink Plus, the
`3c505-nw.bin` ROM missing — see §Traps).

## Published surface
`-view "Screen 0 Standard (4:3)"` — the ONLY view name honoured by the
drawshm capture target on this driver; the layout's own "XGA Screen
(1024x768)" name is not. MEASURED: the driver's default view snapshots at
**1024×844** (the raster plus a function-key legend strip along the bottom),
not the layout name's advertised 1024×768.

## §Keyboard
The Apollo keyboard is a **1200-baud serial device**, not a CPU-scanned
matrix — `MAME_CTL_KEY_EXCL` (the pacing knob the `samcoupe`/`apple2e`
matrix-scan stations depend on) does not apply here.

MEASURED, framebuffer-verified this session: **180 ms per key EDGE** is the
pacing that lands clean. At the module's default 80 ms, the Shift key lands
one character late — `echo Apollo DN3500 Domain/OS SR10.4.1` arrived as
`APollo dN#500 - dOmain/Os sr!0.4.1`. At ~180 ms per edge the same line typed
byte-perfect, twice.

The shifted number row is **DEC-style, not US**: shift-2 is `"`, shift-6
`&`, shift-7 `'`, shift-8 `(`, shift-9 `)`, shift-0 nothing; the key a US
board calls `'` is `:`/`*`, and the backtick key is `~`/`'`. `@` and `^` sit
on a real Apollo key the generated keymap does not carry, so they are
**unavailable**.

MAME names Backspace, Tab and Return all `"Unnamed Key"` on this driver, so
the daemon's name-only KEY lookup sent Backspace for every Enter — fixed by
`mame-ctlsock-field-token.patch` plus the `name#KEYCODE_TOKEN` field specs in
`scripts/dev/mame-keymap.py` (see §Traps).

## §Pointer
`stream.pointer.transport` is `none`, exactly as `apple2e` and `samcoupe`
ship — but here the cause is **proven, not suspected**, and the next step is
known. In `apollo_kbd.cpp`, `kbd_scan_timer()` only calls `read_mouse()` when
`m_mode != KBD_MODE_0_COMPATIBILITY`; a gdb `dprintf` on
`apollo_kbd_device::set_mode` recorded **zero** hits across a full boot,
login and mouse-count burst, so the emulated keyboard never leaves
compatibility mode and the mouse ports are never sampled. The ctlsock module
applies pointer counts correctly (`STAT` shows them) — nothing moves because
nothing is read. The unlock, read out of `rcv_complete()`: Domain/OS must
send the keyboard the two bytes `0xFF 0x01` to reach
`KBD_MODE_1_KEYSTATE`; `read_mouse()` then self-promotes to
`KBD_MODE_2_RELATIVE_CURSOR_CONTROL` on the first motion. A likely trigger is
the DM's own pointer init, which never runs on this disk — the DM prints
`(CMDF) user_data/startup_dm.191 - name not found` on every boot. **Next
step**: find or compose a `startup_dm` that completes the DM's own pointer
init, or send `0xFF 0x01` directly from the daemon before handing off to the
guest.

## §Traps
Three walls this station cost, and their fixes:

1. **MAME must be pinned to `mame0276`** (commit
   `758c8a169a44f0ce3abfd28e8b5c44cc49148eba`) for this station specifically —
   the fleet's 0.289 pin hangs the DN3500's Normal-mode keyboard self-test.
   Every Normal boot on 0.289 is black forever, all four front-panel LEDs
   lit; pinned by sampling the 68030 PC, which spins at 0x67a2-0x67b2 with
   A0 = 0x10400 (the SIO), polling SIO status forever. Service mode works on
   0.289 because it skips the self-tests. `build-mame-native.sh` takes a
   per-station `NATIVE_MAME_TAG`/`NATIVE_MAME_BASE` override for exactly this
   case.
2. **The boot ROM's 14-day CALENDAR halt.** "More than 14 days have elapsed
   since the last shutdown..." halts the kernel; plain Returns do not
   advance it. Neither `libfaketime` (it stalls MAME's monotonic clock) nor
   an RTC patch pinning a fixed year (Domain/OS windowed 2011 as 1981 from
   the two-digit year) satisfies it. What works: boot ONCE in Service mode
   and run `EX CALENDAR`, answering `W`, `N`, `Y`; that disk then boots
   Normal mode to the Display Manager. A visible consequence remains open:
   the guest's clock reads **1981-12-26**, which shows in the process
   display — a cosmetic item, not fixed this session.
3. **The MD prompt does baud recognition on the first Return.** Apollo's MD
   boot-monitor drops characters typed before it has synced; press Return
   two or three times (until the `MD7C REV 8.00` banner appears) before
   typing anything else.
4. **The startup warning panel PAUSES the machine.** With `3c505-nw.bin`
   missing (expected — no good dump is known, see §License), MAME raises its
   startup warning on every launch, and that panel pauses the emulated
   machine until a keypress a kiosk visitor never sends. Fixed by
   `skip_warnings 1` in `ui.ini` plus the skip-warnings patch.

## §Checkpoint
The mechanism is settled; the measured numbers below are placeholders for
the coordinator to fill in from the checkpoint stream's run — **do not
guess a byte count or restore time here.**

The `dn3500` driver registers **no** save state of its own
(`grep -c 'save_item\|save_pointer' src/mame/apollo/*.cpp` is 0 in every
file), so a stock `LOADST` restores CPU, RAM and the emulated clock (the
heartbeat `mtime` genuinely rewinds) but leaves the graphics device's image
memory untouched — and because the Display Manager repaints only on demand,
the previous visitor's screen simply stays on the glass after a reset. The
wave's fix is `mame-apollo-savestate.patch`, registering the Apollo devices'
own state; this station's reset **depends on it** — without it, `LOADST`
does not visibly change the screen.

- Golden savestate captured at: `TODO — coordinator fills in (which DM
  scene, e.g. an open shell pad vs. the bare DM)`
- File: `TODO — path, size, sha256` (once staged at
  `/data/vms/streamhost/stations/domainos/sta/dn3500/golden.sta`)
- Restore proof: `TODO — pixel-diff bbox and elapsed time, from a FRESH
  process relaunched with -state golden`
- Cold boot → DM settled, for comparison: `TODO`

## §Open
- **Pointer**: proven root cause, proven unlock mechanism, not yet
  implemented — see §Pointer above.
- **Clock**: the guest's calendar reads 1981-12-26 (a side effect of the
  CALENDAR-halt fix in §Traps) and shows in the process display; cosmetic,
  not fixed this session.
- **Checkpoint**: mechanism settled, `mame-apollo-savestate.patch` required;
  numbers pending the parallel checkpoint stream — see §Checkpoint.
- **`3c505-nw.bin`**: no good dump known; the EtherLink Plus NIC is present
  in the device set but not fully ROMed.

## Build status (2026-09-09)
- Host-native from day one (Rule 13) — no bridge kiosk was built for this
  station.
- Keyboard: verified on the framebuffer at 180 ms/edge pacing, byte-perfect;
  the DEC-style shifted number row and the missing `@`/`^` keys are
  documented above, not yet reflected in a fleet-wide keymap change.
- Pointer: OPEN, ships keyboard-only, `pointer.transport: "none"`, cause and
  unlock both proven (see §Pointer).
- Checkpoint: mechanism proven, capture pending the parallel checkpoint
  stream — see §Checkpoint.
