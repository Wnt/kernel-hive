# Apollo DN3500 (1989) — Domain/OS SR10.4.1 Display Manager station (:54192)

**Guest:** a **host-native** MAME 0.276 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys), no bridge VM, no QMP.
MAME's **`dn3500`** driver (`src/mame/apollo/apollo.cpp`) emulates an
**Apollo DN3500** (Motorola MC68030 @ 25 MHz, 16 MB RAM, 8-plane colour), a
1989 engineering workstation running **Domain/OS SR10.4.1**, Apollo's own
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
   the guest's clock reads **2003-01-10**, which shows in the process
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
The `dn3500` driver ships registering **no** save state of its own
(`grep -c 'save_item\|save_pointer' src/mame/apollo/*.cpp` is 0 in every
file), so a stock `LOADST` restores CPU, RAM and the emulated clock (the
heartbeat `mtime` genuinely rewinds) but leaves the graphics device's image
memory untouched. The wave's `mame-apollo-savestate.patch` registers what the
driver does not: the graphics device's image memory and its CR/ROP/write-enable
registers and palette state, the keyboard's serial state machine and mouse
counters (without which the keyboard wedges after a restore), and the
machine-level DMA and CSR members. This station's checkpoint depends on it.

**And the reset takes the SERVICE-RESTART path, not the fleet's fast
in-process `LOADST`** — `SH_MAME_RESET_INPROCESS=0` in the fixture, honoured
by `scripts/serve/reset-tile.sh`. The distinction is worth understanding
because it is not the one the patch was written for:

- An in-process `LOADST` **does** restore the machine. Measured by asking the
  guest rather than by looking: after a restore, a fresh `cp /com/pst` came
  back numbered `pad0003` again, its process list holding pad0000/pad0001/
  pad0003 and no pad0002, the Null Process time falling 198.572 → 127.539 and
  the guest clock rewinding 1:04:43 → 1:03:18 pm.
- It does **not** repaint. `apollo_v.cpp`'s `screen_update()` copies
  `m_image_memory` into the bitmap only when `m_update_flag` is set, and a
  restore faithfully brings that flag back as it was — so a window opened
  after the save was still on the glass afterwards, `fbdiff` bbox byte-identical
  before and after the restore (407 829 px both ways).
- A **fresh process** starts with a blank framebuffer and paints the restored
  state in full, which is why launching with `-state golden` looks right.

So the station restarts its service to reset: ~16 s (10 s for `ExecStop` to
give up on a SIGTERM this binary ignores, then SIGKILL and relaunch) instead
of ~0.4 s. Correctness wins. Remove the opt-out when the driver repaints
after a restore — not before.

- Golden savestate: the DM desktop, logged in, with the shell pads and the
  process display open (the scene in `registry/posters/domainos.md`'s hero).
- File: `sta/dn3500/golden.sta`, 5 142 737 bytes, staged at
  `/data/vms/streamhost/stations/domainos/sta/dn3500/golden.sta`. It pairs
  with `cfg/dn3500.cfg` (Normal mode), `nvram/`, and the post-CALENDAR
  `media/domainos-station.awd` — **one combination**, per AGENTS.md rule 6.
- Restore proof: a fresh process launched `-state golden` paints the desktop
  within a few seconds of start (`rig2/r0-fromstate.png`); in-process `LOADST`
  acks in 130-131 ms and restores the machine, with the repaint caveat above.
- Cold boot → DM settled, for comparison: ~135-165 s to the `login:` bar plus
  ~30 s for the login, i.e. roughly 3 minutes — which is why the checkpoint
  exists at all.

## §Open
- **Pointer**: proven root cause, proven unlock mechanism, not yet
  implemented — see §Pointer above.
- **Clock, and the disk's shelf life**: the guest's calendar reads 2003-01-10
  (a side effect of the CALENDAR-halt fix in §Traps) and shows in the process
  display — cosmetic. What is not cosmetic is that a composed disk's CALENDAR
  answer expires against real host time, so `tiles/domainos.sh` has to be
  re-run to rebuild it. The tolerance is TIGHTER than the 14 days of the
  original halt: a second cold boot of a freshly composed disk, minutes of
  wall-clock later, halted with "the calendar is more than a minute slow" —
  so there appear to be two checks, and only the loose one is documented
  upstream. Not characterised; a running station never cold-boots, so this
  bites rebuilds only.
- **Checkpoint repaint** (the fast reset path): the reset works via a service
  restart; the in-process path is off. The cause is NOT the driver's save
  state, which was chased to the end and cleared: a checksum of the whole
  image-memory buffer logged from inside a save postload is **identical**
  between a cold `-state golden` load and a dirty-then-`LOADST` cycle
  (`sum=14f4f9ef size=524288 planes=8 w=1024 h=800`), and the postload fires
  every time. Forcing a repaint from the postload does not help either:
  `m_screen->update_now()` changes nothing, and adding
  `machine().video().frame_update()` **freezes the published frame entirely**
  (it stops responding to fresh keystrokes) — do not repeat that. So the stale
  pixels live between `screen_update1()` writing a correct bitmap and
  `mame-drawshm-0276.patch` publishing it. The drawshm patch's header claims
  every published frame is flagged whole-frame dirty, which is inconsistent
  with the measurement; the next step is to check whether it publishes from a
  stale bitmap/texture reference, or whether `screen_device::m_changed` gates
  it. That is a render-path question, not an Apollo one.
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
