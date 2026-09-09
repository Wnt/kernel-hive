# domainos wave — Apollo DN3500, Domain/OS SR10.4.1 (the Display Manager desktop)

Operator ask (2026-09-09): add four distinctive graphical-desktop stations from
the Virtual OS Museum extraction in one fast-path wave — Genode Sculpt, Interlisp
Medley, Apollo Domain/OS and Apple Lisa. This is Domain/OS.

Apollo's Domain/OS on a DN3500 workstation runs the **Display Manager** (DM): a
pane-and-transcript desktop with no overlapping-window manager, unlike anything
in the lineup. Host-native on the MAME `dn3500` driver (rule 13), the same path
as `apple2e`/`samcoupe`/`atari800xl`; `samcoupe` is the `--like` shape sibling.

## Status: INFRASTRUCTURE BUILT, GOLDEN OPEN

The station is **not live**. It boots Domain/OS to the kernel and hard-halts at
the boot ROM's 14-day CALENDAR check; the DM desktop (the actual exhibit) is not
yet reachable unattended. Everything up to that halt is built and proven. Do not
`station-land` this until the OPEN item below is closed — a visitor would see a
boot-ROM halt, not a desktop.

## Ledger (from `wave.sh alloc domainos --retronet --x11warp`, session `domainos`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| domainos | domainos | 192 / 54192 / 192 | :92 (127.0.0.1:6092) | 10.99.0.40 / `domainosrn0` / `DOMAINOSRN-IN` / UIN 19200 |

| Fact | Value | Measured by |
|---|---|---|
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Driver / machine | `dn3500` — src/mame/apollo/apollo.cpp (DN_FLAGS=0, registers state) | spine, stock 0.276 `-listxml` on labhost |
| Device set | isa1=wdc (OMTI 8621 ESDI+floppy; winchester1=`-disk1 .awd`), isa2=ctape (Archive SC-499), isa3=3c505 (3Com EtherLink Plus, Domain/OS 802.3) — all driver defaults, set explicitly | spine, stock 0.276 `-listslots`/`-listmedia` |
| Published surface / view | 1024x768 via the layout view **"XGA Screen (1024x768)"** (bare raster); the DEFAULT view is 1024x844 (raster + a function-key legend strip) — `-view xga` short name is NOT accepted, the full name is required | native stream, MEASURED 2026-09-09 (snapshot 1024x844 default vs 1024x768 xga) |
| Boot ROMs | `3500_boot_12191_7.bin` (65536, sha256 `7f1028f9…`); the `3c505` sub-set: `0729-12_a.3h`, `0729-62_a.3f`, `3000_3c505_010728-00.bin`, `3com.9h`, `apollo.9h`. `3c505-nw.bin` has NO GOOD DUMP KNOWN (expected miss, `romset dn3500 is best available`). Origin **bitsavers.org/bits/Apollo/firmware** (curl needs a UA; 403 without) | build stream, hashes below |
| Winchester image | `domain_os_10.4.1.awd`, **348 701 760 bytes**, sha256 `9f9ae29c56e456e2520d9107ea2fc30eb8f0dae2d46f6475cc7aa3a92db1f917`. Domain/OS SR10.4.1, kernel dated March 1 1994. Provided-by `andrew_warkentin` per the VOM `INFO`; VOM redistributes it under CC BY-NC-SA — treat that author's distribution as the origin (the underlying OS is Apollo/HP; not committed, gallery is private) | spine, `sha256sum` on the staged copy |
| Credentials | login `user`, password `-apollo-` (VOM `PASSWD`); default node ID 12345 | VOM `PASSWD` |
| Keyboard | Apollo **serial** keyboard, 1200 baud 8E1 (apollo_kbd.cpp), NOT a CPU-scanned matrix — so `MAME_CTL_KEY_EXCL` does not apply. KEYDUMP → `domainos.keymap` (81 keys). Mouse is a 3-button device on the same keyboard port | native stream |

## Streams

Only the spine + native/golden work ran (this is a coordinator fork, not a full
fan-out). `build`, `spa` (museum/poster prose), and `docs/guests/domainos.md`
are scaffolded-only and carry TODO markers.

## What is BUILT and PROVEN (framebuffer)

- **Native binary** `build-mame-native.sh domainos` → `native.d/domainos.sh`
  (SUBTARGET=domainos, SOURCES=src/mame/apollo/apollo.cpp). Boot gate + drawshm
  gate PASS (36960 lit px on the self-test transcript, 64+1024x768x4 mapping).
- **Boots Domain/OS to the kernel**: self-test transcript → "Domain/OS
  kernel(7), revision 10.4.1, March 1, 1994" (framebuffer, both service and
  normal mode).
- **Keyboard echoes on the framebuffer**: driving the ioport fields via Lua
  `set_value`, the MD prompt echoed `EX` in **uppercase** (Shift+letter) and
  executed it. Return is the field MAME names "Unnamed Key" with mask
  0x20000000 / token KEYCODE_ENTER.

## Two reusable fixes this wave produced (land these regardless of the golden)

1. **`scripts/stations_registry/scaffold.py`** — `new --like <host-native
   sibling>` refused with "sibling 'samcoupe' is missing
   streamhost/stations/samcoupe/x11-runtime.sh". A mame-native/fsuae-native/
   vice-native sibling names a SHARED launcher under
   `streamhost/stations/<engine>/`, not one in its own dir. Fixed: detect the
   shared launcher, keep the new station pointing at it, copy nothing. The
   `lisa` wave (also MAME) needs this.
2. **`scripts/build-guests/patches/mame-ctlsock-field-token.patch`** +
   **`scripts/dev/mame-keymap.py`** — MAME gives Backspace, Tab AND Return the
   generic name "Unnamed Key" on the Apollo keyboard, so the ctlsock KEY verb's
   name-only field lookup sent **Backspace for every Enter** (proven with the
   apollo_kbd `LOG1` trace: `EX`+Enter reprinted the MD banner instead of
   executing). The patch lets a KEY field spec carry its default token
   (`Unnamed Key#KEYCODE_ENTER`); the keymap generator now emits `name#TOKEN`
   whenever a name is shared inside one port. No save items change (signature
   intact). Reusable for any MAME driver with unnamed keys.

## OPEN — the Display Manager golden (the blocker)

**Wall: the boot ROM 14-day CALENDAR halt.** In normal mode Domain/OS boots to
the kernel and then prints "More than 14 days have elapsed since the last
shutdown. Switch to service mode, press reset and run CALENDAR." and HALTS. Plain
Returns do not advance it (proven, 220 s wait). The disk was last shut down circa
its 1994 build; the emulated RTC is host time (2026).

- **The RTC math does not reach 1994.** `apollo_m.cpp` MACHINE_RESET adjusts the
  2-digit year: with host year 26, "30 Years Ago" (default ON) → 96 (1996); "25
  Years Ago" needs year<25. 1996 is still 2 years > 14 days after the 1994
  shutdown, so the halt persists. There is no config path to 1994 from host
  2026.
- **The fix is to run CALENDAR once** (the VOM README and the halt message both
  say so — "updating the time won't actually change anything persistently", it
  just clears the check by updating the disk's last-shutdown reference). Then
  reboot → boots to the DM. Since the exhibit ships a SAVESTATE golden captured
  AT the DM, running CALENDAR once on the rig, reaching the DM and `SAVEST` is
  sufficient; the mutated disk ships as the station disk.
- **Why it is not done: the Apollo serial keyboard drops programmatic input at
  the MD prompt.** Lua `set_value` echoed some characters but dropped most of a
  multi-char command; the ctlsock KEY and natural-keyboard POST paths echoed
  nothing at the MD prompt after the rig had been up a while. The keyboard is a
  1200-baud serial link the boot ROM services in "compatibility mode"; input is
  only reliable once Domain/OS itself initialises the keyboard for the DM — the
  exact place we cannot reach until CALENDAR has run. This is a
  chicken-and-egg timing wall.

**Next step (for a dedicated golden stream, ~1–2 h):** race these on
`rig-clone.sh` clones, first DM-frame wins:
1. Type `EX CALENDAR` at the MD prompt inside the NARROW window right after the
   self-test finishes (the keyboard link is freshest then), one char at a time
   with a screendump-verify-and-retry loop per character (the MD echoes at a
   fixed row); then `W`, Returns through the prompts, `Y`. Reboot normal → DM →
   `SAVEST golden`, flip `MAME_NATIVE_CHECKPOINT=1`, stage `sta/dn3500/golden.sta`.
2. Seed the RTC / disk directly: find the disk's stored last-shutdown field (or
   the mc146818 nvram year register) and pre-write it so the 14-day check passes
   with no typing. `apollo_rtc_r/w(9)` is the year register; the nvram lives in
   `nvram/dn3500/`.
3. Investigate whether a stock host MAME with a keyboard-enabled window can run
   CALENDAR interactively once, then reuse that mutated `.awd` as the shipped
   disk (the golden is then a normal-mode boot to DM with no halt).

Once the DM is up: prove the mouse (the open-loop pointer stack is compiled in,
apple2e's), pick the rest state (a shell pad + a process-display pad), measure
keyboard pacing at the DM, and write museum/spa prose + `docs/guests/domainos.md`
from real DM screenshots.

## Teardown

Sandbox rigs and clones under `/data/vms/sandbox/domainos/*` (rig, smoke*, race-*,
boot-*, cal-*, norm-*, luaecho*, dbg*, BUILD-native-domainos). The kh-claim
allocations (slot/port/vmid/display/retronet 192, 10.99.0.40) stay held under
session `domainos` until the station lands or the wave is abandoned.
