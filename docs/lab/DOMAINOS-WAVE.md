# domainos wave — Apollo DN3500, Domain/OS SR10.4.1 (the Display Manager desktop)

Operator ask (2026-09-09): add four distinctive graphical-desktop stations from
the Virtual OS Museum extraction in one fast-path wave (sculpt, medley, lisa,
domainos). This is Domain/OS. **STOPPED by operator order 2026-09-10 00:15 UTC+3**
before landing — this file is the handoff. Nothing is deployed; the station is
not on main; the claims are still held (see §Claims).

Apollo's Domain/OS on a DN3500 runs the **Display Manager** (DM): a
pane-and-transcript desktop with no overlapping-window manager, unlike anything
in the lineup. Host-native on the MAME `dn3500` driver (rule 13), the same path
as `apple2e`/`samcoupe`/`atari800xl`; `samcoupe` is the `--like` shape sibling.

## Where it stands (all proven on the framebuffer)

**The Display Manager desktop was reached, on the shipping ctlsock/shm rig
path**, minutes before the stop order — frame
`/data/vms/sandbox/domainos/rig3/s4-desktop.png`: the `pad0000` window with
"Apollo Domain/OS Version SR10.4.1" and the DM `Command:` bar, after logging in
as `user` / `-apollo-` through the daemon's keymap. No golden was baked (the
stop came first). Everything a resumer needs is below; the whole recipe from a
cold rig to that frame is about four minutes of emulated time.

## The three walls, in the order they fell

### 1. MAME 0.289 (the fleet pin) cannot boot this machine in Normal mode — use 0.276

Every Normal-mode boot on the 0.289 build was BLACK forever (all four
front-panel LEDs lit), on the shipping binary, on a pristine unpatched 0.289
build, with mono/4-plane/8-plane graphics, with the 3C505 removed, with and
without the kiosk env, for 220 s. Service mode works on 0.289 (MD `>` prompt).
Stock `/usr/games/mame` 0.276 on labhost boots Normal mode fine.

Pinned by sampling the 68030's PC with a Lua autoboot: it spins at
0x67a2–0x67b2 with A0 = 0x10400 (the SIO), a send-and-compare loop polling SIO
status with a 65535-iteration timeout and retrying forever — the ROM's
KEYBOARD self-test (Service mode skips the self-tests, hence the asymmetry).
The keyboard VERBOSE trace showed the host byte never reaches the keyboard on
0.289; with the DUART transmitter hunks reverted the keyboard received 0xff and
echoed, but channel A still never completed a receive. Bisected by whole-file
and hunk swaps (all still black): diserial.cpp 0.276, the DUART receiver
condition, the DUART transmitter TxRDY/`m_tx_enabled`/`write_CR` hunks. Not
finished — the regression is somewhere else in 0.276→0.289 (68030 core or
another device). **Not pursued further: the fix that works is building the
station binary from `mame0276`.**

The 0.276 tree with the full fleet patch stack is built and works:
`/data/vms/sandbox/BUILD-native-domainos276/mame` (binary copied to
`/data/vms/sandbox/domainos/domainos-0276`). Ports needed on 0.276, all done in
that tree and NOT yet turned into patch files:
- `scripts/src/osd/modules.lua`: the two `ctlsock/ctlsock.{cpp,h}` source
  lines after `netdev/taptun.cpp` (the ctlsock patch's hunk context differs);
- `src/emu/render.cpp`: `#include <cstdlib>` (kiosk patch hunk 1);
- `src/osd/modules/render/drawshm.cpp`: `std::atomic_ref` (C++20) replaced by
  `__atomic_load_n`/`__atomic_store_n` on the seq word (0.276 builds C++17);
- the ctlsock patch's `src/emu/save.cpp` hunk (a diagnostic message only)
  skipped — 0.276's `validate_header` has a different signature;
- ptr-tags, move-step-cap, open-loop-gain, home-drain, count-carry,
  field-token, irix-skip-warnings all apply cleanly.
A resumer should make this a proper per-station pin: `build-mame-native.sh`
hard-codes `MAME_TAG=mame0289`; it needs a stanza override (tag + base sha +
an "0276" patch variant set), or a second builder. This deviates from the
fleet pin deliberately and only for this station.

### 2. The boot ROM's 14-day CALENDAR halt — cleared by running CALENDAR once

"More than 14 days have elapsed since the last shutdown. Switch to service
mode, press reset and run CALENDAR." halts the kernel; plain Returns do not
advance it. The RTC cannot be made to satisfy it: the volume's last recorded
time is **2002/07/31 19:59:06 MDT** (CALENDAR printed it), the MAME "N years
ago" offsets reach only 1996/1999 from a 2026 host, and an RTC patch pinning
2011-08-19 (decoded from the volume-label timestamps, which turned out to be
write times, not the reference) was read by Domain/OS as 1981/12/26 — the OS
windows the two-digit year — and still halted. Frames:
`/data/vms/sandbox/domainos/b-0276/snap/dn3500/0000.png` (1994 patch),
`b-0276b/…` (2011 patch), `norm-wait/…`, `norm-ret/…`.

**What works: run CALENDAR once in Service mode and answer it.** Then a Normal
boot of the SAME disk goes through to the DM (frames
`/data/vms/sandbox/domainos/postcal/snap/dn3500/000{3,8}.png`: HP splash,
"Apollo Phase II Environment Revision 10.4", "Loading Init", then the login
bar). The post-CALENDAR disk is
`/data/vms/sandbox/domainos/cal276b/disk.awd` (with its `nvram/`) — **this is
the station disk**; the pristine copy stays at
`/data/vms/sandbox/domainos/media/domainos.awd`.

The RTC patch (`/data/vms/sandbox/domainos/race/rtcpatch/mame-apollo-fixed-date.patch`,
the 1994 variant) is applied in the 0.289 tree `BUILD-native-domainos/mame`
(source edit in place, binary `…/mame/domainos`, original at
`/tmp/apollo_m.cpp.orig` on labhost) and, as the 2011 variant, in the 0.276
tree. It is harmless but not sufficient; keep or drop it. The other two raced
runners: libfaketime stalls MAME (monotonic clock) — dead theory; "type
CALENDAR" was the one that worked once the keyboard was understood (below).

### 3. The Apollo keyboard at the MD prompt — press Return first

Programmatic typing at the MD `>` prompt dropped most characters or all of
them. Cause: **the MD does baud recognition on the first Return** (the
driver's own `apollo_sio::read` comment says so). Press Return two or three
times (the `MD7C REV 8.00` banner appears), THEN type; after that every
character lands, at 0.25 s hold / 0.35 s gap. Frames:
`/data/vms/sandbox/domainos/cal276b/snap/dn3500/000{0..6}.png`.

Second keyboard fact: MAME names Backspace, Tab and Return all "Unnamed Key"
on this driver, so the daemon's name-only KEY lookup sent Backspace for every
Enter. Fixed by `mame-ctlsock-field-token.patch` + the keymap generator
(`Unnamed Key#KEYCODE_ENTER`), committed on branch `domainos`.

## The recipe that reaches the desktop (resume here)

Rig launcher that produces frames (the bare binary WITHOUT `skip_warnings 1`
in `ui.ini` sits paused on the 3C505 "no good dump" warning panel until a
keypress — that is why the raced runners saw black; not the daemon):
`/data/vms/sandbox/domainos/rig3/run.sh` — `-video shm`, `MAME_SHM_PATH`,
`MAME_CTL_SOCK`, `MAME_NO_UI=1`, `-view "Screen 0 Standard (4:3)"` (the
default view is 1024x844 with a key-legend strip; the layout's own
"XGA Screen (1024x768)" name is NOT honoured by the shm target, the
Screen 0 view is), `-isa1 wdc -isa2 ctape -isa3 3c505 -disk1 <awd>`,
`ui.ini` = `skip_warnings 1`, cfg `apollo_config` mask 1 value 1 (Normal;
0 = Service).

1. Service mode, stock-style Lua or ctlsock: wait ~32 s for `>`, Return ×3,
   `EX CALENDAR`↵ (wait 25 s), `W`↵, `N`↵ (keep the time zone), `Y`↵ at
   "Is the calendar correct?" → "Done." (`cal276b/t.lua` does exactly this.)
   Keep the resulting `disk.awd` + `nvram/`.
2. Normal mode with that disk: login bar in ~90 s (`shmwait.py --settle 25`),
   then through ctlsock with `rig3/domainos.keymap`: `user`↵, `-apollo-`↵ →
   the DM with `pad0000` in ~30 s.
3. Then (not done): pick the rest state (a shell pad — Shift-F1 opens one —
   plus the copyright pad), `PAUSE`, `SAVEST golden`, relaunch fresh with
   `-state golden`, diff; flip `MAME_NATIVE_CHECKPOINT=1`, stage
   `sta/dn3500/golden.sta` and the post-CALENDAR disk under
   `/data/vms/streamhost/assets/domainos/`; prove the mouse (apple2e's
   open-loop stack is compiled in: `MAME_CTL_PTR_TAGS=:kbd:mouse1,:kbd:mouse2,:kbd:mouse3`,
   `MAME_CTL_BTN_NAMES="Left mouse button,Right mouse button,Center mouse button"`,
   `MAME_CTL_PTR_MOD=256`) or take the lisa/sculpt readback route; measure
   typing at the DM; museum/spa prose from real frames; then `station-land.sh`.

Tools written for this wave (in `/data/vms/sandbox/domainos/tools/`):
`shm2png.py`, `shmwait.py` (fb-wait for drawshm mappings), `ktype.py`
(types through ctlsock KEY with a keymap), `rtcvariant.py`, `duarttx.py`.

## Ledger (from `wave.sh alloc domainos --retronet --x11warp`, session `domainos`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| domainos | domainos | 192 / 54192 / 192 | :92 (127.0.0.1:6092) | 10.99.0.40 / `domainosrn0` / `DOMAINOSRN-IN` / UIN 19200 |

| Fact | Value | Measured by |
|---|---|---|
| MAME | **must be `mame0276` for this station** (see wall 1); fleet pin 0289 hangs Normal mode | this wave, PC sampling + bisect |
| Driver / machine | `dn3500` — src/mame/apollo/apollo.cpp (DN_FLAGS=0) | spine |
| Device set | isa1=wdc (OMTI 8621; `-disk1 .awd`), isa2=ctape, isa3=3c505 — driver defaults, set explicitly | spine, stock 0.276 `-listslots` |
| Published surface | 1024x768 via `-view "Screen 0 Standard (4:3)"` (bare raster, aspect-corrected) | native stream, measured |
| Boot ROMs | `3500_boot_12191_7.bin` (sha256 `7f1028f9…`) + the `3c505` set (`0729-12_a.3h`, `0729-62_a.3f`, `3000_3c505_010728-00.bin`, `3com.9h`, `apollo.9h`); `3c505-nw.bin` has no good dump (expected). Origin **bitsavers.org/bits/Apollo/firmware** (needs a UA header) | build stream |
| Winchester image | `domain_os_10.4.1.awd`, 348 701 760 bytes, sha256 `9f9ae29c56e456e2520d9107ea2fc30eb8f0dae2d46f6475cc7aa3a92db1f917`; SR10.4.1, volume last recorded 2002-07-31; Provided-by `andrew_warkentin` (VOM); not committed, gallery is private | spine |
| Credentials | `user` / `-apollo-` (proven at the DM login bar) | this wave |
| Keyboard | Apollo serial keyboard, 1200 baud 8E1 — NOT a scanned matrix, `MAME_CTL_KEY_EXCL` does not apply; keymap `rig3/domainos.keymap` (81 keys, token-pinned Return/Backspace/Tab) | native stream |

## Reusable fixes (committed on branch `domainos`, commit e93fe11 and later)

1. `scripts/stations_registry/scaffold.py` — `new --like <host-native sibling>`
   no longer fails on the shared `streamhost/stations/<engine>/x11-runtime.sh`.
2. `scripts/build-guests/patches/mame-ctlsock-field-token.patch` +
   `scripts/dev/mame-keymap.py` — `name#KEYCODE_TOKEN` field specs.
3. Playbook wall rows worth adding: the startup warning panel pauses a bare
   MAME until a keypress (`skip_warnings 1` in `ui.ini` + the skip-warnings
   patch); `-view` must name a view the shm target honours; the Apollo MD
   needs Return before typing; a fleet-pin regression is bisected by sampling
   the PC in Lua before touching patches.

## Claims still held (deliberately — the numbers stay reserved)

Session `domainos` holds slot 192, port 54192, vmid 192, display :92 (loopback
6092), rnip 10.99.0.40, tap `domainosrn0`, chain `DOMAINOSRN-IN`, uin 19200,
sandbox `domainos`. Release all of it with
`ssh lab 'kh-claim release-session domainos'` (or `scripts/dev/wt.sh rm
domainos` for the sandbox) only when the station is abandoned. The station
entry is on the branch only, `rn-tapnet.sh` was never generated or committed
(rule 15), nothing is listed.

## Teardown at the stop (2026-09-10 00:1x)

Killed by pid after an `/proc/<pid>/exe` check: the rig3 emulator (pid
1329580, `/data/vms/sandbox/domainos/domainos-0276`); earlier rigs (4008173,
3935122, 3729062, 592550) likewise. No `make` was running. Sweep of
`/proc/*/exe` for `domainos`/`BUILD-native-domainos`: none remaining. Build
trees, binaries, race dirs and frames left in place under
`/data/vms/sandbox/domainos/` and `/data/vms/sandbox/BUILD-native-domainos{,276}/`.
