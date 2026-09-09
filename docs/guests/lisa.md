# Apple Lisa — Lisa Office System 3.1 — gallery station notes

Status: **LIVE, host-native, SANDBOXED** since 2026-09-09 — LisaEm 2.0.0
running inside a systemd-nspawn container on labhost, the daemon capturing a
pinned 720x498 Xvfb whose root is the aspect-corrected Lisa screen. Wave
record: [`../lab/LISA-WAVE.md`](../lab/LISA-WAVE.md).

**Guest:** an emulated **Apple Lisa 2** (Motorola 68000 at 5 MHz, 1 MB RAM,
boot ROM rev H of 24 February 1984, a 5 MB ProFile on the motherboard parallel
port, no expansion cards) booting **Lisa Office System 3.1** — Apple's last
Lisa release — from a ProFile image that carries the seven Lisa tools
(LisaWrite, LisaDraw, LisaCalc, LisaGraph, LisaList, LisaProject, LisaTerminal)
plus the Clock and Calculator desk accessories. No network of any kind: a 1984
Lisa has no TCP/IP, so there is no retronet web plane and no IM client; the
retronet reservation `10.99.0.41` is held only as the plane's uniqueness
ledger.

> Lineup position: after `alto` and `star` (Xerox) and before `macos`
> (Macintosh). It is the document-centric desktop between them — the one the
> Macintosh simplified.

## Identity and source

- Public ID / tile directory: `lisa`
- Reserved slot / UDP port / VMID: `193` / `54193` / `193`; Xvfb display `:93`
- Archetype: `beige-tower-crt`; scene tuple `pizzaBoxB,compactA,keyboardA,paramMouseC`
- Media (staged under `/data/vms/sandbox/lisa/media/`, hash-verified, **never
  committed**; the builder `scripts/build-guests/tiles/lisa.sh --fetch`
  re-creates all of it):
  - `LisaEm-2.0.0-2026.01.25-Linux_x86_64.AppImage` — 5 343 736 B, sha256
    `a9dc5674fbbb0174920b21e8b8a6c543074e239f205af1cdd61ca17628e2ade8`, from
    github.com/arcanebyte/lisaem release 2.0.0 (Ray Arachelian, GPL-2.0).
  - `lisa2.zip` (MAME 0.264 romset) — 30 822 B, sha256
    `3f324d5f041c8f1e70210bf278b4d963550730e75c4fcd24214f4b16bbce3034`, from
    archive.org item `mame-0.264-roms-non-merged`. The rev H halves
    `341-0175-h` (high, CRC adfd4516) and `341-0176-h` (low, CRC 546d6603) are
    byte-interleaved into LisaEm's 16 384-byte `lisaboot-revH.rom`, sha256
    `4eb245a5a133a202cb07757a7430437a996d91acddfba2c1a3b787e8b5b9d8f5`.
  - `LisaEM_LOS3.1with7LisaApps.zip` — 5 131 254 B, sha256
    `3536d79794b121614015b95705e9f63767a7c37cfb82a307f5c397ab4a563aad`, from
    archive.org item
    `apple-lisa-profile-hd-disk-images-for-lisaem-and-idle-lisa-office-system-3.1-lis`;
    inside, the 10 350 676-byte DC42 ProFile image (sha256
    `bbc97e82d544050c156057fd80e28a7f66a8e24429e7ed28442fe9d62b84e2ae`) that is
    the station's golden disk, unmodified.
  - `los-3.1-en.zip` — 1 195 960 B, sha256
    `7cc3b9e1b62ae49ec3e520be915383c63c9516d638570a70599c3e2e798a57f3`, from
    archive.org item `los-3.1-en`: the five 419 284-byte DC42 install floppies,
    staged for provenance and a from-scratch rebuild.
- License class: preservation-source, copyrighted (Apple). Private exhibit
  only; never redistribute the bits. LisaEm itself is GPL-2.0.

## Emulator decision

**LisaEm 2.0.0**, the upstream Linux AppImage, extracted and run as a plain
X11 application. The alternative, MAME's `lisa2` driver (present in labhost's
MAME 0.276), is dead by inspection: `-listslots`/`-listmedia lisa2` expose two
Sony floppy drives and no ProFile, and the Office System installs and boots
only from a ProFile. Not raced.

LisaEm has no headless mode, no shm frame export and no control socket, so
this station is the x11-capture shape (`SH_CAPTURE=x11`,
`SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`) like `amix` — but with no
guest X server and no warp: LisaEm maps the host X pointer 1:1 onto the Lisa
mouse, so absolute XTEST motion in root coordinates IS the Lisa pointer.

## Pinned machine (LisaEm config template, `assets/lisa/lisaem.conf.template`)

- `ROMFILE=` rev H boot ROM; `ioromver=a8`; `MemoryKB=1024`; `cheatromtests=1`
  (LisaEm skips the ROM's slow self-tests); `hle=1`.
- `[parallelport] parallelport=PROFILE path=` the launch's fresh copy of the
  golden image; the three card slots empty.
- Command line: `-s-` (no skin) `-z 1.0` `-o-` (video top-left) `-p` (power on)
  `-c <conf>`.

## Sandbox (the operator's host-application rule, 2026-09-09)

LisaEm's menus and GTK dialogs are host user interface, so it runs inside a
`systemd-nspawn` container started by `streamhost/stations/lisa/x11-runtime.sh`:
private PID, mount, network (only `lo`) and user namespace (host uid range
200000..265535, so "root" inside is unprivileged on the host); a read-only
rootfs skeleton (`assets/lisa/rootfs`) with the host's `/usr`, `/etc/fonts`,
`/etc/ld.so.cache` and `/etc/alternatives` bound in read-only and the asset
directory at its own path (so `/proc/<pid>/exe` reads as the host path and the
daemon's `SH_IDLE_PAUSE_PROC_MATCH=assets/lisa/lisaem` still matches);
capabilities dropped and `@mount` syscalls filtered exactly as the `medley`
sandbox does; writable only `work/` (this launch's ProFile copy, LisaEm's
config, logs) and `x11/` (the Xvfb socket directory, bound to the container's
`/tmp/.X11-unix`). The host symlinks `/tmp/.X11-unix/X93` to that socket so the
daemon's `DISPLAY=:93` reaches the sandboxed server. `lisa-inner.sh` is PID 2
inside: Xvfb, LisaEm, window placement, the boot click.

Proven on the rig (2026-09-09): inside the container `id` is uid 0 mapped to
host 200000, `ip link` shows only `lo`, `/proc` lists five processes, `/data`
and `/etc/shadow` do not exist; from the host LisaEm runs as uid 200000 with
exe `/data/vms/streamhost/assets/lisa/lisaem/usr/local/bin/lisaem`.

## Geometry (measured, `docs/lab/LISA-WAVE.md`)

- Skinless LisaEm draws the aspect-corrected **720x498** Lisa video (the real
  Lisa's 720x364 frame buffer has 1.5:1 pixels) inside a 1020x720 frame with
  a GTK menubar above and a status bar below.
- A `gtk.css` in the station's own `XDG_CONFIG_HOME` collapses the menubar to
  2 px; the window is resized to 720 wide (video at x=0) and moved to
  y=-42 (2 px of menubar + a 40 px band LisaEm keeps under it); Xvfb is
  720x498, so the captured root is exactly the Lisa screen. **Only a negative
  Y move is safe** — a negative X offset made GDK drop every button event while
  motion still worked.
- LisaEm's own menus are the collapsed strip above the root: unreachable by
  pointer, reachable by keyboard accelerators only — which is why the sandbox
  exists.

## Boot and reset

The rev H ROM stops at its `STARTUP FROM` menu (floppy / ProFile) because the
PRAM has no default boot device. `lisa-inner.sh` clicks the ProFile icon at
(55,93) four seconds after launch; LOS 3.1 shows its "Wait" splash and reaches
the desktop **~120-150 s** later at the emulated 5 MHz (the LOS Preferences
window's "Select Defaults" panel has a "Start Up From: Profile" checkbox that
would write the PRAM and remove the click — OPEN). `SH_RESET_MODE=relaunch`:
the launcher kills the container (nspawn pid, verified through
`/proc/<pid>/exe`), copies `disk/lisa-profile.dc42.golden` fresh and cold-boots.
LisaEm has no save state. The golden is the pristine archive.org image;
nothing is baked from a running session, so a reset returns exactly the
desktop LOS wrote at its last clean shutdown.

## Input

- Pointer: **absolute**. `SH_X11TEST_ABS=1` moves the host X pointer to root
  coordinates that are Lisa pixels; the Lisa's own arrow lands on the
  commanded pixel (proven on the ROM menu icon, the Preferences icon and its
  check boxes, the Disk icon and folder icons). Buttons over XTEST with
  `SH_BTN_MIN_HOLD_MS=150`: xdotool's instant press/release never registered
  on LisaEm, a 150 ms hold did every time. A double-click is two such presses
  ~70 ms apart (opened Preferences and the Disk window).
- Keyboard: XTEST keys into LisaEm (the display's US layout), pacing 40/40.
  Typing proof in a LisaWrite document: see the wave record's proofs table.

## Rest state

The Office System desktop as the pristine image boots it: grey stipple
desktop, the Desk / File/Print / Edit / Housekeeping menu bar, Preferences,
Wastebasket and Clipboard icons along the bottom, the ProFile "Disk" icon at
the bottom right. Double-clicking Disk opens the folders for the seven tools
and the desk accessories; each tool folder holds the tool and its stationery
pad — tear a sheet off the pad to make a document.

## Checkpoint

None (LisaEm has no save state). Golden = `disk/lisa-profile.dc42.golden`
(sha256 above) + the LisaEm 2.0.0 AppImage + `assets/lisa/lisaem.conf.template`
+ the rev H ROM: ONE combination (rule 6). `bootrec-tiles.conf` is not armed
for this station (no vmstate; `resetMode=relaunch`).

## Known gaps / OPEN

- PRAM default boot device (removes the launcher's click): set "Start Up From:
  Profile" in LOS Preferences → Select Defaults, power the Lisa off cleanly so
  LisaEm writes the `[pram]` block, and ship that block in the config template.
- Standby: the fixture freezes LisaEm (SIGSTOP) 200 s after launch when no
  viewer is connected; the first session wakes it. LOS's own clock will be
  wrong after a long freeze — cosmetic.
- No audio (`SH_AUDIO=off`): the Lisa's beeper is not exhibited.
- Type-in demo: none yet; a LisaWrite document must be open first.
