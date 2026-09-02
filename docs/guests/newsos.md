# newsos — Sony NEWS-OS 4.1R on an NWS-3260 (host-native MAME)

**Status 2026-08-18: LISTED.** `streamhost@newsos` is live and published (slot
148 / UDP 54148): keyboard fixed, `labctl exec` (serialcsh_e) and the `demo`
login working, hero + exhibition notes + a Sony NEWS hardware gallery in place.
Still open: pointer plane (open-loop only), golden/idle-pause (no save state in
the driver).

## What it is

Sony's NEWS (Network Engineering Workstation) line — Japan's BSD workstation
family, 1987–1990s. NEWS-OS 4 is 4.3BSD-derived with X11R4 and Sony's own
NEWS Desk on top. The **NWS-3260** (1991) is the portable of the MIPS
generation: R3000A @ 20 MHz, 16 MB, a **1120×780 monochrome LCD**, HLE
keyboard/mouse (`news_hid`), am79c90 Ethernet, CXD1185 SCSI.

## Why this machine, not the nws5000x the candidate doc named

[`docs/lab/research/candidate-newsos.md`](../lab/research/candidate-newsos.md)
planned NEWS-OS 4.2.1aRD on MAME `nws5000x`, whose driver has **no local
framebuffer** (confirmed against `news_r4k.cpp` in 0.250 and master: the
DSC-39 XB card is a TODO; the desktop only exists over XDMCP), which would
have needed an Xvfb+XDMCP capture and a brand-new XTEST input path. MAME's
`nws3260` (`news_r3k.cpp`, Patrick Mackinlay) is `MACHINE_NO_SOUND` only,
paints a real LCD framebuffer (`news_lcdfb`), and its keyboard is a normal
ioport matrix — i.e. exactly the shape the nine converted MAME stations
already ship (drawshm frames + ctlsock keys). Direct framebuffer capture is
the lab's host-native rule; the 3260 satisfies it and the 5000X cannot.
Neither driver has `MACHINE_SUPPORTS_SAVE`, so both would be reset=relaunch.

The OS is therefore **NEWS-OS 4.1R** (`nwf_672rb`, the NWS-3000-series MO
kit): the 4.2.1aRD CD is "usable only on NWS-5000 series" per its softlist
entry and briceonk's notes.

## Emulator

`scripts/build-guests/emulators/native.d/newsos.sh` →
`build-mame-native.sh newsos`: MAME 0.289 subtarget `newsos`,
`SOURCES=src/mame/sony/news_r3k.cpp`, base patches (ctlsock, drawshm,
kiosk-no-ui) **plus `mame-irix-skip-warnings.patch`** and
**`mame-news-hid-kbd-order.patch`** (the keyboard fix, below): `idrom.bin` is a
`BAD_DUMP` in MAME and its "ROM NEEDS REDUMP" panel is a *modal* wait that
`skip_warnings` alone does not cover — without the patch MAME sits in
`display_startup_screens` forever (found 2026-08-18: black frame, no ctlsock
heartbeat, gdb stack). `NATIVE_GEOM=1120x780` (the LCD's raster, streamed
1:1). Gate: 863,507 lit pixels (the LCD's white page) at 15 emulated seconds.

Binary/roms during bring-up: `/data/vms/sandbox/newsos/build/mame-native/`;
production: `/data/vms/streamhost/assets/newsos/mame-native/{newsos,roms/}`.

## ROMs and media (sourced 2026-08-18; hashes verified against MAME's pins)

| what | where | hash |
|---|---|---|
| `nws3260.zip` (mpu-16 ver 2.0A ic64, 051_aa.ic109, 052_aa.ic110, idrom.bin) | archive.org item `mame-0.250-roms-split_202212`, `MAME 0.250 ROMs (split)/nws3260.zip` (same bytes in `mame-roms-non-merged`) | md5 ec8fe868944b6ec9c5fd4191c95d2383; all four sha1s match `-listxml` |
| `nwf_672rb_mo.chd` — NEWS-OS 4.1R Version Up Kit, MO image | archive.org item `nwf_672rb` | md5 be5b4c8fe82e988ed2ec1ddcd0dc3556 |
| `nwf_672rb_installation_program.img` (floppy) | same item | sha1 ed9499211ccf133570defa136199f331a38368f5 (softlist `install`) |
| `nwf_672rb_format_program.img` (floppy, unused — unsupported by the driver) | same item | sha1 64ff03dace6e8b91569bef6f2f8855fa59c39abe |
| `hd1307.img.gz` — blank, pre-labelled 1.3 GB disk image | `briceonk/news-os` `src/news-inst/blank-images/` | 1388496896 bytes unpacked |
| fallback, unused: `nws5000x.zip`, `nwf_683rd1.chd` (4.2.1aRD CD) | `mame-0.250-roms-split_202212`, item `nwf_683rd1` | md5 7688edcc…, 546247f8… |

Staged raw blobs: `/data/assets-staging/newsos/` (ROMs, sha1-matched by
`stage-romset.py`); media in `/data/vms/sandbox/newsos/media/` during
bring-up. Nothing under `roms/`, `media/` or a disk image is ever committed.

## Install recipe (as driven, 2026-08-18 — briceonk's `nws3260-mame.md` shape)

MAME args for the install: `-scsi:4 harddisk -hard1 hd1307.img -hard2
nwf_672rb_mo.chd -flop nwf_672rb_installation_program.img` (a second
"harddisk" at SCSI 4 stands in for the MO drive; the system disk is SCSI 0).

1. `NEWS>` `bo fh()copy/i` → "NEWS-OS 4.1 Install Program (news3200)".
2. `Install from:` delete `tape`, type `mo`; MO SCSI channel `4`; onto `hd`,
   channel `0`; "Tahoe disklabel is already set, use this" → `y`. Miniroot
   copies (24576 sectors), primary boot installs, miniroot kernel boots
   (`NEWS-OS Release 4.1R #0`).
3. Installer TUI: `a` Installation → `c` MO disk → `y` (sd04) → language
   `f` US_English → timezone `c` EUROPE, `d` FINLAND → date `y` →
   `/usr` local `y` → packages `0 1 2 4 5 6 b s u x y` (network, X11-core,
   X11-appl, X11-font, NEWS Desk, sys, man, games, sound, sample, 3D =
   97,844 kB of the 105,672 kB default layout, so no partition resize) →
   `y` → network `n` (no TAP in the rig) → display manager **Yes** (X at
   boot) → `y`. newfs runs, then the package copy.
4. Per the driver's known issue, the kernel's reboot does not work: after
   "Install Complete" hard-restart MAME (relaunch), then `bo` from the
   ROM monitor (Automatic Boot DIP for the station); first boot fscks.
   `root`, no password. `sxdm` is the graphical login on the LCD.

Driver: `nkey.py post "text\n"` / `key <field>` / `shot` on the box
(`/data/vms/sandbox/newsos/rig/`) — speaks the ctlsock protocol directly
(`<seq> KEY 1|0 <port> <field>`, `SHOT <abs path>`), the browser stays a
read-only monitor. Keymap: `scripts/dev/mame-keymap.py <ctl.sock> --tags ":"`
→ `streamhost/stations/newsos/newsos.keymap` (78 keys; unmatched: keypad,
Nfer/Xfer, Help/Clear — irrelevant to the exhibit).

## Runtime shape

Row: `registry/stations/newsos.json` (dragon32's host-native shape:
`SH_CAPTURE=shm`, `SH_INPUT_BACKEND=mamesock`, launcher
`stations/mame-native/x11-runtime.sh`, `resetMode=relaunch`, `snapshot:null`).
Fixture: `streamhost/stations/newsos/station.env.fixture`
(`MAME_NATIVE_ARGS=-hard1 …/newsos-disk.img -cfg_directory …/cfg -serial0 pty`,
`MAME_NATIVE_SKIP_WARNINGS=1`, `MAME_CTL_PTR_PORTS=:hid`,
`SH_IDLE_PAUSE_SECS=60`). The `-serial0 pty` line carries the exec channel
(below). The disk is a **writable raw image** (not a CHD +
diff — a mid-boot relaunch left the CHD diff dirty and corrupted the next
boot, 2026-08-18): it persists across relaunches like a real workstation's
disk, and NEWS-OS's own boot-time `fsck -p` repairs any unclean stop. The
shipped cfg sets the **SW2:5 Automatic Boot DIP** (DIPs live only in MAME's
cfg) so a cold `reset=relaunch` power-cycles straight to sxdm; `rc.local`
re-arms `/fastboot` so the reboot skips fsck (~90-120 s to login). Bring-up rig (until the
unit takes over): `/data/vms/sandbox/newsos/rig/newsos-rig.sh start|stop|
status|daemon` — MAME + a borrowed released daemon from `stream.env`, overlay
via `darklaunch-station.py publish newsos --rig … --entry entry.json`;
`install-phase` marker file selects the install media args.

## Pointer

Bound via the base ctlsock module (`MAME_CTL_PTR_PORTS=:hid`; the NEWS HLE
mouse uses MAME's default `mouse_{buttons,x_axis,y_axis}` port names, so no
ptr-tags patch). No hardware cursor, so MOVEA degrades to open-loop dead
reckoning — made 1:1 by `-a 1 -t 1` on the X server (in `/etc/sxdm/Xservers`;
`xset m 1 1` covers a running session too). **Binding the pointer freezes the
ROM monitor's `bo`** (measured 2026-08-18): the daemon's connect-time homing
slam reaches the guest before the OS driver attaches, so drive the ROM
monitor with the daemon detached, or let Automatic Boot skip the monitor
entirely (the shipped config). The sxsession menus are press-and-hold
(DOWN1, drag, UP1); proven by opening Application → Terminal Emulator.

## Keyboard (`news_hid` ordering + fast-typing)

`mame-news-hid-kbd-order.patch` — without it, typed Shifted characters come out
unshifted (`The`→`the`, `#`→`3`, `$HOME`→`$hOME`). MAME's `news_hid` HLE
keyboard is a `device_matrix_keyboard_interface` that scans 8 rows round-robin
and reports scancodes in **row order**, not the order edges were applied. The
ctlsock path presses Shift and the character in the *same* sweep; L-Shift sits
in a later row than most letters, so the character's row is scanned (and
latched, unshifted) first. The patch buffers a scan sweep's key edges and
flushes them in a safe order — modifier-makes → char-makes → char-breaks →
modifier-breaks — and deepens the key FIFO 8→256 so a burst can't silently
drop. Chosen from three independent bring-up attempts (2026-08-18); re-validated
byte-exact (`echo The_Quick-Brown.Fox JUMPED 42 over ok-123` types and echoes
exactly).

That patch handles Shift-vs-character ordering *within* one sweep, but not two
different characters that overlap across sweeps: a scanned matrix reads each row
once per ~6.7 ms sweep, so at fast browser speed the makes of two rolled-over
keys still emit in **row order** (fast `root` → `roto`) and a key whose whole
press+release falls between two samples of its row is dropped (`asd` → `ad`).
The cure is **`MAME_CTL_KEY_EXCL`** in the fixture: it serialises non-modifier
keys so only one is ever down, and the guest scans each alone, in order. It
matches a **case-sensitive** substring of the port tag, and the NEWS rows are
`:hid:ROW0..` — so the value must be **`:ROW`**. It was mistakenly `:row`
(lowercase), which matched nothing and silently left EXCL off; slow one-key
typing hid it. Fixed 2026-08-18 with `EXCL=:ROW` and 40/40 ms hold/gap
(~12 chars/s), validated byte-exact under a fast burst.

## labctl exec + the demo login

**Non-root desktop.** The install has a passwordless **`demo`** guest (uid 300,
`/usr/people/demo`, `/bin/csh`); at the sxdm greeter type `demo` (no password)
→ the sxsession NEWS Desk desktop as `Username: demo`. Root (`root`, no
password) stays available for operators. There is **no autologin**: NEWS-OS
4.1R `login` has no `-f`, `getty` ignores the `al` capability, and an
`/etc/init` wrapper around `login`/`su` fails without a getty's tty setup — so
the demo login is manual, by design. (`news` uid 6 is the system Usenet user —
unrelated; the guest is `demo`.)

**`labctl exec newsos "<cmd>"`** (`exec_kind serialcsh_e`). MAME runs a getty on
the guest's `/dev/tty00`, exposed to the host as a pty by `-serial0 pty` (the
`on` entry for `tty00` in `/etc/ttys`). `streamhost/guest-agents/newsos/newsosexec.py`
scrapes that pty straight out of MAME's fd table — the irix transport, **no
pump** — takes an exclusive `serial.lock`, logs in as passwordless root, and
runs the command with tru64's sentinel-framed capture, returning byte-exact
stdout and the guest's own exit code. Two NEWS specifics: the login shell is
`/bin/csh` and there is **no ksh**, so the client does `exec /bin/sh`; and
`/bin/sh`'s default PATH is too thin, so it sets
`PATH=/bin:/usr/bin:/usr/ucb:/etc:/usr/etc` (this BSD has no `uname`/`id`;
`whoami`/`w` live in `/usr/ucb`). Deployed to the box as `/root/newsosexec.py`
via the `newsos-exec` `box-sync-pairs` entry; dispatched from
`scripts/labctl.d/guest.py`. The getty is fresh on every cold boot (validated
no-HUP), which is all this station ever does — reset = relaunch, no savestate.

## Open

- **Pointer**: `news_hid` exposes `mouse_x_axis`/`mouse_y_axis`/buttons and
  ctlsock reports "MOVEA unsupported (no cursor items)" — the relative
  axis path (`mame-ctlsock-ptr-tags.patch`, irix's shape) is the next step
  once X is up; until then the exhibit is keyboard-only.
- Golden: none possible (no save state); "checkpoint" = the installed disk
  + Automatic Boot DIP + `/fastboot`. Standby (`SH_IDLE_PAUSE_SECS=60`) is ON
  since 2026-09-02, with `MAME_NATIVE_STANDBY_DELAY_S=200`: the launcher's
  SIGSTOP is unconditional after that delay, so it must stay comfortably past
  the ~90-120 s boot or it freezes a half-painted console. It was held OFF for
  the dark launch and was not turned back on when the station went
  `lifecycle=production` — unwatched MAME pinned a full core around the clock
  until the flip. `SH_IDLE_PAUSE_SECS` gates BOTH the launcher's one-shot
  freeze and the daemon's steady-state pauser, so `0` meant no auto-pause at
  all even though `SH_IDLE_PAUSE_PIDFILE`/`_PROC_MATCH` were correct. The two
  arms keep SEPARATE clocks, and newsos is the one station where they cross:
  the daemon's pauser fires `SH_IDLE_PAUSE_SECS` after daemon start regardless
  of `MAME_NATIVE_STANDBY_DELAY_S`, so on the first restart after the flip it
  froze the guest at 27 s of emulated time — a boot console. Hence
  `SH_IDLE_PAUSE_WARMUP_SECS=240`, above the launcher's 200 s, so the launcher
  freezes the settled login and the daemon inherits an already-paused guest.
- Hero photo: placeholder is the live LCD frame; a real NWS-3260 photo
  (Commons) is the operator's pick.
- Sound: driver has none.
