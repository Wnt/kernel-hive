# domainos wave — Apollo DN3500, Domain/OS SR10.4.1 (the Display Manager desktop)

Operator ask (2026-09-09): add four distinctive graphical-desktop stations from
the Virtual OS Museum extraction in one fast-path wave (sculpt, medley, lisa,
domainos). This is Domain/OS. The first session was **stopped by operator order
2026-09-10 00:15 UTC+3** with the desktop reached and no golden baked; this file
is the whole station, not that session's diary.

Apollo's Domain/OS on a DN3500 runs the **Display Manager** (DM): a
pane-and-transcript desktop with no icons and no menus, unlike anything else in
the lineup. Host-native on MAME's `dn3500` driver (rule 13), the same shape as
`apple2e`/`samcoupe`/`atari800xl`; `samcoupe` is the `--like` sibling.

**Read `docs/guests/domainos.md` first** — it is the station's operating manual
(device set, keyboard, checkpoint, traps). This file carries the wave: the
ledger, the walls and their fixes, and what is still open.

## Ledger

| Station | Session | Slot / UDP / VMID | Display | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| domainos | domainos | 192 / 54192 / 192 | :92 (127.0.0.1:6092) | 10.99.0.40 / `domainosrn0` / `DOMAINOSRN-IN` / UIN 19200 |

| Fact | Value | Measured by |
|---|---|---|
| MAME | **`mame0276`** (`758c8a169a44f0ce3abfd28e8b5c44cc49148eba`) — a deliberate per-station deviation from the fleet's 0.289; see wall 1 | this wave, PC sampling + bisect |
| Driver / machine | `dn3500` — `src/mame/apollo/apollo.cpp` (DN_FLAGS = 0) | spine |
| Device set | `-isa1 wdc` (OMTI 8621; `-disk1 .awd`), `-isa2 ctape`, `-isa3 3c505` — driver defaults, set explicitly | stock 0.276 `-listslots` |
| Published surface | 1024x768 via `-view "Screen 0 Standard (4:3)"`. The default view snapshots at **1024x844** (raster + a function-key legend strip) and the layout's own "XGA Screen (1024x768)" name is **not** honoured by the drawshm target | native stream, measured |
| Boot ROMs | `3500_boot_12191_7.bin` (sha256 `7f1028f9…`) + the `3c505` set. Origin **bitsavers.org/bits/Apollo/firmware** (needs a UA header); `3c505-nw.bin` has no good dump (expected) | build stream, re-fetched and hash-verified |
| Winchester image | `domain_os_10.4.1.awd`, 348 701 760 bytes, sha256 `9f9ae29c56e456e2520d9107ea2fc30eb8f0dae2d46f6475cc7aa3a92db1f917`; SR10.4.1, volume last recorded 2002-07-31; provided-by `andrew_warkentin` (VOM). Not committed — the gallery is private | spine |
| Station disk | the **post-CALENDAR** disk composed by `tiles/domainos.sh`. The pristine image halts in the boot ROM (wall 2) and is never the station disk | this wave |
| Credentials | `user` / `-apollo-` (`registry/local.env`) | this wave |
| Keyboard | Apollo serial keyboard, 1200 baud — NOT a scanned matrix, so `MAME_CTL_KEY_EXCL` does not apply. **180 ms per key edge** (wall 4). Shifted number row is DEC-style (wall 5) | this wave, framebuffer |
| Pointer | **none**, cause proven (wall 6) | this wave, gdb + framebuffer |

## The walls, and what each one is worth remembering for

### 1. MAME 0.289 cannot boot this machine in Normal mode — pin the station to 0.276

Every Normal-mode boot on a 0.289 build is BLACK forever with all four
front-panel LEDs lit: the shipping binary, a pristine unpatched 0.289 build,
mono/4-plane/8-plane, with and without the 3C505, for 220 s. Service mode works
on 0.289 — which is exactly what makes this look like a disk fault.

Pinned by sampling the 68030's PC from a Lua autoboot: it spins at
0x67a2–0x67b2 with A0 = 0x10400 (the SIO), a send-and-compare loop polling SIO
status with a 65535-iteration timeout, retrying forever — the ROM's KEYBOARD
self-test, which Service mode skips. Bisected by whole-file and hunk swaps
(diserial.cpp, the DUART receiver condition, the DUART transmitter
TxRDY/`m_tx_enabled`/`write_CR` hunks) without finding the 0.276→0.289
regression. It was not worth finding: the fix is to build the station binary
from `mame0276`.

**The reusable part:** `build-mame-native.sh` now takes a per-station
`NATIVE_MAME_TAG` / `NATIVE_MAME_BASE` / `NATIVE_BASE_PATCHES` override, and
`patches/mame-{ctlsock,drawshm,kiosk-no-ui}-0276.patch` are the 0.276 variants
(the others in the stack apply cleanly to both tags). Any future station that
needs a different MAME now has a paved path instead of a fork.
**And the lesson worth more than the patch:** a fleet-pin regression is bisected
by *sampling the PC in Lua* before touching a single patch file.

### 2. The boot ROM's 14-day CALENDAR halt — answer it once, in Service mode

"More than 14 days have elapsed since the last shutdown. Switch to service
mode, press reset and run CALENDAR." halts the kernel; Returns do not advance
it. The RTC cannot be made to satisfy it: the volume's last recorded time is
2002-07-31, MAME's "N years ago" config bits reach only 1996/1999 from a 2026
host, libfaketime stalls MAME (monotonic clock), and an RTC patch pinning
2011-08-19 was read by Domain/OS as 1981-12-26 because the OS windows the
two-digit year.

What works: boot the disk ONCE in Service mode (`apollo_config` mask 1 value 0)
and run `EX CALENDAR`, answering `W`, `N`, `Y` → "Done." That disk then boots
Normal mode straight through to the DM. `tiles/domainos.sh` does it.

**Cosmetic consequence, still open:** the guest clock reads 1981-12-26, which is
visible in the process display and therefore in the poster hero.

### 3. The MD prompt needs Return pressed first

Programmatic typing at the Service-mode MD `>` prompt dropped most characters.
The MD does **baud recognition on the first Return** (`apollo_sio::read` says so
in its own comment). Press Return two or three times — the `MD7C REV 8.00`
banner appears — and then every character lands. Second fact: MAME names
Backspace, Tab and Return all "Unnamed Key" on this driver, so a name-only KEY
lookup sends Backspace for every Enter; `mame-ctlsock-field-token.patch` plus
`scripts/dev/mame-keymap.py`'s `name#KEYCODE_TOKEN` specs fix it fleet-wide.

### 4. The fleet's key pacing floor leaks Shift by exactly one character

At the module's 80 ms per edge, `echo Apollo DN3500 Domain/OS SR10.4.1` arrived
on the framebuffer as `APollo dN#500 - dOmain/Os sr!0.4.1` — every shifted
character one key late, because the Shift field and the character field are
paced independently and Shift is on a different port. At ~180 ms per edge the
same line typed byte-perfect, twice. `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS`
are 180, and `demoProgram.perCharMs` follows the validator's drain rate (360
ms/char) at 380.

This is samcoupe's per-field pacing finding on a completely different keyboard —
a serial one, where `MAME_CTL_KEY_EXCL` does not even apply. **Treat "Shift
lands one character late" as a fleet-wide symptom with a known shape**, not a
new mystery, whenever a MAME station mangles capitals.

### 5. `new --like` copies the sibling's charMap, and nobody re-derives it

`registry/stations/domainos.json` shipped samcoupe's `keyboard.charMap`
verbatim, because that is what a deep copy does. The Apollo's shifted number row
is DEC-style: shift-2 is `"`, shift-6 `&`, shift-7 `'`, shift-8 `(`, shift-9
`)`, shift-0 nothing; the key a US board calls `'` is `:`/`*`, and the backtick
key is `~`/`'`. `@` and `^` are on a real Apollo key that `mame-keymap.py` does
not carry, so they are unavailable on this station.

The map is derivable **from the station's own generated keymap**, whose field
names carry each key's legend (`8 (`, `2 "`). That is a check any `--like`
station can run in one command, and the wave's `ktype2.py` does exactly it.

### 6. The pointer: the emulated keyboard never leaves compatibility mode — OPEN

The Apollo's 3-button mouse hangs off the keyboard. apple2e's whole open-loop
stack is compiled in and correctly configured, and the module applies every
count (`STAT` → `applied=660,300`, belief integrating). **Nothing moves.**

Cause, proven with gdb on the live guest rather than guessed:
`apollo_kbd.cpp`'s `kbd_scan_timer()` calls `m_mouse.read_mouse()` only when
`m_mode != KBD_MODE_0_COMPATIBILITY`, and a `dprintf` on
`apollo_kbd_device::set_mode` recorded **zero hits** across a full boot, login
and count burst. The mouse ports are never sampled; `read_mouse()` is dead code
at runtime, so nothing downstream of it — pacing, gain, re-latching — can
matter.

**The unlock, read out of `rcv_complete()`:** Domain/OS must send the keyboard
the two bytes `0xFF 0x01` to reach `KBD_MODE_1_KEYSTATE` (`0xFF 0x00` goes back
to compatibility; the ID query `0xFF 0x12 0x21` does not change the mode).
Once in mode 1, `read_mouse()` self-promotes to
`KBD_MODE_2_RELATIVE_CURSOR_CONTROL` on the first motion — so reaching mode 1 is
the entire unlock.

**Exact next step:** the DM's own pointer initialisation is the natural sender
and never runs on this disk — the DM prints
`(CMDF) user_data/startup_dm.191 - name not found` on every boot. From a shell
pad, `ld /com | grep -i mou`, `ld /sys/dm`, `ld /domain_examples` to find a
shipped `startup_dm.191` template or a `/com` mouse-enable command; if the guest
has no such command, the fallback is a MAME patch. Budget a boot (~2–3 min)
before the first experiment, or start from the golden.

The station ships keyboard-only meanwhile, exactly as `apple2e` does, and the
DM is a keyboard desktop anyway.

### 7. The Apollo driver registers no save state at all

`grep -c 'save_item\|save_pointer' src/mame/apollo/*.cpp` is **0** in every
file. A stock `SAVEST`/`LOADST` therefore restores the CPU, RAM and the
emulated clock (the heartbeat `mtime` genuinely rewinds — 1708.501 → 1687.925)
but leaves the graphics device's image memory untouched. On a machine whose
desktop repaints only on demand, that means **the previous visitor's screen
simply stays on the glass after a reset**, which is exactly the failure a
checkpoint exists to prevent. The wave's answer is
`patches/mame-apollo-savestate.patch`.

**The general lesson:** "the driver registers state" is not something to infer
from a driver's flags — it is one `grep` away, and on any new host-native
station it should be run *before* the checkpoint is designed.

## Driving this guest

- Boot to the `login:` bar takes ~110–190 s; then `user`↵, `-apollo-`↵ and the
  DM appears ~30 s later. Wait on the framebuffer, never on a guess.
- Tools live in `/data/vms/sandbox/domainos/tools/` and
  `/data/vms/sandbox/domainos-finish/tools/`: `shm2png.py`, `shmwait.py`
  (fb-wait for drawshm mappings), `fbdiff.py` (changed-pixel bounding box —
  this is how you SEE something move), `ktype2.py` (types through ctlsock,
  deriving the char map from the keymap; `--gap=0.10` is required),
  `kpress.py` (named keys).
- **DM keys**, which ARE the interaction on a pointerless DM: `F1` = the Apollo
  CMD/SHELL key → the bottom `Command:` bar, where `cp /com/sh` makes a shell
  pad, `cp /com/pst` a process-display pad and `wp` pops a window; `F11` =
  ABORT → input back to the shell pad; `F6` = LINE DEL. Home/End/MENU/the
  numpad/F2–F5/F9/F10 move, grow, pop, close and reprompt — they will rearrange
  a scene you were about to bake.
- ctlsock commands take a sequence prefix (`1 STAT`). The binary **ignores
  SIGTERM**; kill by pidfile with SIGKILL after a `/proc/<pid>/exe` check.

## Still open

1. **Pointer** — §6 above, with the exact next step.
2. **The guest clock reads 1981-12-26** (§2). Cosmetic, visible in the process
   display. Fixable by choosing the date when CALENDAR is answered during the
   tile build, which nobody has tried.
3. **Retronet** — the 3C505 is in the device set and Domain/OS has TCP/IP, but
   the tap NIC is not wired and there is no era browser for this platform. The
   web plane is a research question, not a task; the IM plane is n/a. Rule 15:
   no `rn-tapnet.sh` is committed for this station.
4. **`tiles/domainos.sh`** is written end-to-end but its build and
   CALENDAR-compose steps have not been run from scratch in one pass; the ROM
   staging step has.
