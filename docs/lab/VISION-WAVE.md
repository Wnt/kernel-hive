# VisiCorp Visi On 1.0 integration wave — 2026-09-13

Visi On (VisiCorp, released December 1983) is the first integrated graphical
desktop shipped for the IBM PC: overlapping windows, a mouse, a "Services"
window that installs and launches Visi On Calc/Word/Graph, all on an 8088 with
CGA a year before the Macintosh. Part of the five-station wave of 2026-09-13
(`vision`, `oberon`, `fmtowns`, `magiccap`, `perq`; common contract in the
coordinator's `WAVE-COMMON.md`). Branch `vision`.

The Virtual OS Museum (reference only, CC BY-NC-SA — facts read, nothing
copied) runs it under PCE as an IBM 5160 XT; that is theory B below. The fleet
tier would be MAME's `ibm5160` host-native (theory A). Per rule 14 the two were
raced from minute 0, one `sonnet` runner each, on their own dirs under
`/data/vms/sandbox/vision/race/<theory>/`.

## Ledger — from `wave.sh alloc vision --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 194 / 54194 / 194 |
| x11warp display | `:94` (loopback `127.0.0.1:6094`) — allocated; unused unless the winner is an X11-captured sandbox |
| retronet | **none** — skipped on purpose: Visi On has no TCP/IP stack (PC-DOS 2.00, 1983) |
| ICQ UIN | none |
| sibling (`--like`) | see §Race verdict |
| render orders | as scaffolded by `stations-registry.py new` — never hand-edited |
| device set | IBM 5160 XT: 8088 @ 4.77 MHz, 640 KB, CGA, two 360 KB floppies, 10 MB XT fixed disk (306/4/17), serial card on COM1 carrying a Mouse Systems-protocol serial mouse (the "VisiCorp mouse Model M1"), 83-key XT keyboard |
| media | see `scripts/build-guests/tiles/vision.sh` (URL + sha256 + byte size per file); staged by the `vision-media` agent under `/data/assets-staging/vision/` |

### Facts that shape the station (from the VOM readme + the 0.289 source, verified)

- Visi On needs PC-DOS 2.00 on a FAT16 10 MB hard disk, 640 KB, CGA and the
  serial mouse. It drives the 8250 itself: **no DOS mouse driver**.
- Copy protection: `VOAPP1` (Application Manager disk 1) is the **key disk** and
  must be in A: whenever Visi On starts. The disks ship as TransCopy `.tc`
  flux-ish images; PCE reads `.tc` but cannot write it, its `psi` tool
  converts to `.psi` which keeps the protection.
- Install, once: at `C:\>` type exactly `A:VINSTALL`, choose VisiCorp mouse
  Model M1 on COM1, swap to disk 2 when asked, put disk 1 back; then `VISION`.
- Visi On is unreliable on faster CPUs — the emulated machine stays XT-class
  (PCE `cpu.speed` multiplier is the only throttle knob worth touching).
- MAME `ibm5160` (0.289, `src/mame/pc/ibmpc.cpp`): slots default to
  `isa1 cga`, `isa2 com`, `isa3 fdc_xt`, `isa4 hdc`; the `hdc` card carries
  its own `wdbios.rom`; the rs232 option `msystems_mouse` is the Mouse
  Systems HLE mouse (`src/devices/bus/rs232/rs232.cpp`).
- PCE (VOM's shape, rewritten): `system { model = "5160" boot = 128 }` boots
  C: directly so the key disk can stay in A:; `serial { driver =
  "mouse:protocol=msys" }` on 0x3f8/IRQ4; `terminal { driver = "x11" }`.

## Race — rule 14

| Theory | Runner | Where | Result | Frame |
|---|---|---|---|---|
| A. MAME `ibm5160` host-native (fleet tier, `--like samcoupe`) | sonnet | `/data/vms/sandbox/vision/race/mame/` | **LOST** — BIOS and PC-DOS 2.00 boot to `C:\>` and the keyboard works over the ctlsock, but Visi On is unreachable | `/data/vms/sandbox/vision/race/mame/frames/` |
| B. PCE `pce-ibmpc` in systemd-nspawn (VOM-proven, `--like lisa`) | sonnet | `/data/vms/sandbox/vision/race/pce/` | **WON** — Visi On desktop on the framebuffer 20 minutes in | `/data/vms/sandbox/vision/race/pce/frames/24-desktop.png` |

### Race verdict — PCE, and the reason is the copy protection

MAME lost on the key disk, not on the machine. Its `ibm5160` boots PC-DOS 2.00
fine with `-isa1 cga -isa2 com -isa3 fdc_xt -isa4 hdc -isa2:com:serport0
msystems_mouse` (romsets `ibm5160` + `isa_hdc` + `kb_pcxt83`), and the keyboard
was proven through the ctlsock. But the VisiCorp disks are protected with
**variable sectors per track (9-16/track) and no data address mark**, MAME has
no TransCopy or PSI loader, and both raw and IMD conversions of `VOAPP1.TC` are
rejected by the drive. There is no route to Visi On on MAME without a flux
image MAME will accept (HFE is the thing to try if anyone revisits this).

PCE reads TransCopy directly and its `psi` tool converts `.TC` to `.psi`, which
keeps the protection *and* is writable — the one format that satisfies both the
key-disk check and PCE's write-back on eject. That single capability decided the
race. PCE is a stock X11 host application, so the station runs it inside a
systemd-nspawn container under the operator's host-application rule.

`/data/vms/sandbox/vision/race/mame/` is kept as provenance. Runner A also built
`psi` and `pce-img` for Linux from the pinned tarball under
`race/mame/pce-build/`; `pce-img convert -i hd0.pbi -o hd0.img` yields a raw
306x4x17 image if a raw disk is ever wanted.

## The station

| | |
|---|---|
| launcher | `streamhost/stations/vision/x11-runtime.sh` + `vision-inner.sh` (the lisa/medley contained shape) |
| tile builder | `scripts/build-guests/tiles/vision.sh` — `--fetch` / `--unpack` / `--rootfs` / `--compose` |
| rootfs | `debootstrap --variant=minbase trixie` + X and build packages, PCE compiled inside it into `/opt/pce`, whole tree uid-shifted once to 2162688 |
| root geometry | **1280x800** — PCE draws CGA 640x200 at `scale = 2` with its 4/3 aspect correction, which is exactly 1280x800, so the Xvfb root **IS** the PCE window: root coordinates are window coordinates, no crop and no offset |
| reset | `relaunch` — PCE's ibmpc has no save state. Every launch copies `hd0.pbi`, `VOAPP1.psi` and `VOAPP2.psi` fresh from `assets/vision/disk` into the writable `work/` bind and cold-boots the 5160 |

### Traps (each one cost time)

1. **PCE starts STOPPED at its monitor prompt.** `pce-ibmpc` comes up at
   CS:IP = F000:FFF0 with `type 'h' for help` and executes nothing until the
   monitor is told `g`. A launcher that skips this waits forever for a DOS
   prompt that is never coming. `vision-inner.sh` writes `g` to the monitor FIFO
   before it does anything else.
2. **`--bind-ro` on the media breaks the guest.** PCE writes `.psi` floppies back
   on eject and Visi On writes to C:; a read-only media bind makes the guest see
   a dead drive. Every disk image lives in the ONE writable `work/` bind.
3. **The host X symlink must point at the socket FILE**, `x11/X<n>`, not at the
   directory. A directory symlink silently leaves the daemon with no display.
4. **`/proc/<pid>/exe` reads as the CONTAINER path here**, `/opt/pce/bin/pce-ibmpc`
   — *not* as a host path the way lisa's LisaEm does, because PCE lives inside
   the rootfs rather than in a bound-in assets dir. A bare path match would
   therefore match any other PCE on the box, so the launcher matches the exe AND
   requires the process to be a descendant of this launch's nspawn pid.
   `SH_IDLE_PAUSE_PROC_MATCH` is `/opt/pce/bin/pce-ibmpc` for the same reason.
5. **A naive "screen settled" check fires on the blank POST screen.** The 5160
   spends its first seconds in memory count with nothing on the CGA, two samples
   match, and the launcher types `VISION` into the BIOS. Measured on this
   station's first launch: PC-DOS reached `C:\>` perfectly and the keystrokes had
   already been thrown away. `fb_settle` now requires the screen to have CHANGED
   from t=0 first, and then to hold across three consecutive samples.
6. **The rootfs needs `x11-apps`.** `vision-inner.sh` polls the framebuffer with
   `xwd` rather than sleeping a guessed number of seconds, and a race runner lost
   its whole proof window on 2026-09-13 to a rootfs that had no `xwd` and no
   `convert`.

### Installing Visi On (how `hd0.pbi` was made, and how to remake it)

`hd0.pbi` is the PCE XT bundle's own 10 MB PC-DOS 2.00 image (hampa.ch, inside
`pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip`, hashed in the tile builder) with
Visi On 1.0 installed onto it once, by hand, on the race rig of 2026-09-13. The
builder stages that image rather than replaying the install, because VINSTALL is
an interactive full-screen installer with a mid-run disk swap. To rebuild it from
the hashed inputs:

1. Convert the TransCopy disks: `psi -i VOAPP1.TC -o VOAPP1.psi` (and `VOAPP2`).
2. Boot the 5160 with the stock `hd0.pbi` in 0x80, `VOAPP1.psi` in A:,
   `VOAPP2.psi` in B:, and `g` at the monitor.
3. At `C:\>` type `A:VINSTALL`.
4. Answer the installer: VisiCorp mouse **Model M1**, on **COM1**; acknowledge the
   write-protect prompt with a space; let it copy.
5. When it asks for disk 2, swap through the PCE monitor FIFO:
   `di 0 /work/VOAPP2.psi`. When it asks for disk 1 back: `di 0 /work/VOAPP1.psi`.
   (The monitor writes the `.psi` back on each eject — this is why the images are
   in the writable bind.)
6. `VISION` at `C:\>` to confirm, then keep the resulting `hd0.pbi`.

## Builder — `scripts/build-guests/tiles/vision.sh` run end to end

Run by the BUILD+PUBLISH stream (Claude Sonnet 5), into a throwaway output —
`STAGE=/data/assets-staging/vision OUT=/data/vms/sandbox/vision-build/out
MEDIA=$OUT/media DISK=$OUT/disk ROOTFS=$OUT/rootfs UID_BASE=2162688
INSTALLED_HD=/data/vms/sandbox/vision/race/pce/work/hd0.pbi` — never touching
the previously-proven race rig or the real `/data/vms/streamhost/assets/vision`
until every stage had passed:

| Stage | Result | Wall clock |
|---|---|---|
| `--fetch` | all 9 sources already staged by the media agent, hash-verified, `MANIFEST.sha256` rewritten | 1.4 s |
| `--unpack` | 10 TransCopy disks, 2 PC-DOS images, PCE ROMs + `hd0.pbi`, MAME ROMs; every size assertion passed | 12.8 s |
| `--rootfs` | `debootstrap --variant=minbase trixie`, runtime+build packages, PCE built from the pinned tarball into `/opt/pce`, uid-shifted once to 2162688 | 3m46.7s (root, on labhost) |
| `--compose` | 10 `.TC` disks converted to `.psi` with the freshly-built `psi`; `hd0.pbi` staged from the proven race rig's installed disk (provenance: `race/pce/work/hd0.pbi`, made by hand per §Installing Visi On on 2026-09-13); `pce.cfg` + ROMs staged | 1.4 s |

**One builder bug fixed at the root.** `do_rootfs`'s `./configure` line passed
`--enable-x11` and `--disable-sdl`, neither of which exists in PCE's autoconf
script (confirmed by extracting the pinned tarball and reading
`configure --help`: X11 is `--with-x`, SDL is `--without-sdl`; the bogus names
only ever produced two silent `configure: WARNING: unrecognized options`
lines and worked by accident because X11 auto-detects against `libx11-dev` and
SDL auto-detects absent with no SDL dev package installed). Fixed to
`--enable-ibmpc --with-x --without-sdl --enable-char-pty`; re-run and
`shellcheck`/`shfmt -d` both clean on the changed file.

**Boot proof of the throwaway output itself** was queued behind the wave's
one-`pce-ibmpc`-at-a-time rule (the `vision-ptr` stream was mid-flight on its
own rig at `/data/vms/sandbox/vision-ptr/`, investigating the pointer) rather
than raced or killed. See §Publish for whether it landed before this stream's
own stop; if not, the exact next command is
`VISION_ASSETS=/data/vms/sandbox/vision-build/out VISION_BASE=/data/vms/sandbox/vision-build/proof SH_STATION=vision SH_X11_DISPLAY=:195 streamhost/stations/vision/x11-runtime.sh`
once `pgrep -f '^/opt/pce/bin/pce-ibmpc '` on labhost is empty.

The `--rootfs` and `--compose` stages are proven by their own exit codes and
output-shape assertions (the builder's own `verify`/size checks on every
staged file, `[ -x .../pce-ibmpc ]`, `[ -x .../psi ]`, the `.psi`/`hd0.pbi`
existence and size checks in `--compose`); the framebuffer proof of the
throwaway output is the one piece still gated on the shared PCE slot.

## Sandbox

**Verdict: host application, full nspawn contract.** PCE is a stock X11
application — it opens a window and reads X input, with no headless mode and no
shm export — so it is not a fleet-QEMU or fleet-MAME tier station. It runs inside
a systemd-nspawn container with private PID, mount, network, IPC, UTS and user
namespaces, `--volatile=overlay` over a read-only debootstrap rootfs,
`--private-network` (lo only), the wave's capability drop list,
`--no-new-privileges=yes` and `--system-call-filter=~@mount`. Nothing of labhost
is bound in except this station's own assets, read-only; the one writable bind is
the station's `work/`. The container's uid 0 is host uid **2162688**.

The nspawn line is in `streamhost/stations/vision/x11-runtime.sh`.

Audit below is from **this station's own launcher**, not from the race rig:
`SH_STATION=vision SH_X11_DISPLAY=:94 VISION_BASE=/data/vms/sandbox/vision/stationtest ./x11-runtime.sh`,
payload pid 3687162 (the pce-ibmpc host pid from the pidfile), 2026-09-13T06:29Z.

```
PAYLOAD PID=3687162  exe=/opt/pce/bin/pce-ibmpc
--- namespaces (all six must differ) ---
pid  host=pid:[4026531836]  payload=pid:[4026536834]
mnt  host=mnt:[4026531832]  payload=mnt:[4026536831]
net  host=net:[4026531833]  payload=net:[4026536835]
user host=user:[4026531837] payload=user:[4026536830]
ipc  host=ipc:[4026531839]  payload=ipc:[4026536833]
uts  host=uts:[4026531838]  payload=uts:[4026536832]
--- status ---
Uid:	2162688	2162688	2162688	2162688
CapEff:	0000000015808dff
NoNewPrivs:	1
--- ps -e ---
    PID TTY          TIME CMD
      1 ?        00:00:00 (sd-stubinit)
      2 ?        00:00:00 bash
      5 ?        00:00:00 Xvfb
     14 ?        00:00:02 pce-ibmpc
     46 ?        00:00:00 ps
--- ip link ---
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
--- ls /dev ---
char  core  fd  full  fuse  mqueue  net  null  ptmx  pts  random  shm
stderr  stdin  stdout  tty  urandom  zero
--- mount attempt (must fail) ---
mount: /mnt: permission denied.
rc=32
```

All six namespaces differ from the host's. The payload runs as host uid 2162688
with `NoNewPrivs: 1`. Only the nspawn init stub, the inner script, Xvfb and
pce-ibmpc exist in the container's PID namespace. The only interface is `lo`.
`/dev` is nspawn's minimal set — no disks, no host devices. Mounting a tmpfs as
the container's own root, with `CAP_SYS_ADMIN` dropped from the bounding set,
is refused.

## Proofs (framebuffer only — rule 9)

From **this station's own launcher**, not the race rig:

| Proof | Verdict | Frame |
|---|---|---|
| Cold boot: the 5160 posts and PC-DOS 2.00 reaches `C:\>` with AUTOEXEC run (`PROMPT $P$G`, `PATH C:\;C:\DOS`) | **PASS** | `/data/vms/sandbox/vision/frames/01-station-launch.png` |
| Visi On 1.0 starts and the copy-protection check on the VOAPP1 key disk passes — the Applications Manager splash, `COPYRIGHT 1983 VISICORP / VERSION 1.0` | **PASS** | `/data/vms/sandbox/vision/frames/02-station-vision-desktop.png` |
| Keyboard: `VISION` typed over XTEST at 120 ms/char is received without a dropped or doubled character (it is what launched Visi On above) | **PASS** | same frame |
| Sandbox audit from the running station | **PASS** | §Sandbox above |
| The Visi On desktop itself — Services window on Archives, the `start install remove Printing` menu line, the HELP/CLOSE/OPEN/FULL/FRAME/OPTIONS/TRANSFER/STOP command strip | **PASS on the race rig**, not yet from the station launcher | `/data/vms/sandbox/vision/frames/00-live-desktop.png` (the hero) |
| Pointer: two-target readback | **FAIL — OPEN**, see §Pointer | — |

The gap between the last two rows is one thing, and it is the pointer: Visi On
stops at **"Calibrate the mouse. See the Setup Guide for detailed instructions."**
and does not reach the desktop until the mouse has been moved. The race rig got
past it by taking an X pointer grab by hand. So on this station the pointer is not
a refinement — it is what stands between the splash and the desktop.

## Pointer — OPEN, and it is the blocker

**The mechanism.** PCE's x11 terminal converts host pointer movement into Mouse
Systems packets on the emulated 8250, and Visi On drives that 8250 itself (there
is no DOS mouse driver anywhere in this station). But `xt_event_motion()` in
`src/drivers/video/x11.c` opens with `if (xt->grab == 0) { return; }` — with no X
pointer grab, every motion event is dropped. When grabbed it accumulates
`x_root` deltas and warps the pointer back to screen centre each event, which is
what makes the grab necessary in the first place and what fights XTEST.
`xt_event_button_press()` likewise swallows the first click to take a grab. A
headless Xvfb station cannot hold a grab the way a person at a keyboard can.

Raced per rule 14, two `sonnet` runners, 20 minutes each.

| Theory | Result |
|---|---|
| **A — patch PCE's x11 terminal to forward motion with no grab** (`race/ptrA/`) | **CLOSEST.** A 2-hunk patch (`/data/vms/sandbox/vision/race/ptrA/pce-x11-nograb.patch`) applies cleanly to the pristine tarball, builds clean, and changes behaviour: Visi On advanced past the calibration splash into the Services desktop with no click and no grab, which pristine PCE cannot do. But the readback is over-driven — absolute XTEST jumps drove the guest cursor to the right edge and pinned it there. NOT a proven pointer. |
| **B — drive the mouse through the serial port instead of the terminal** (`race/ptrB/`) | **PLUMBING PROVEN, pointer not.** `serial { driver = "pty:symlink=/work/com1.pty" }` initialises (`char-pty: /dev/pts/0`), PCE holds the master and the symlink is the slave, so host-written bytes land on the guest's COM1 RX. PCE's own encoder at `char-mouse.c:132-148` is ground truth for the Mouse Systems framing (byte0 `0x80` + active-low buttons, dy negated, two dx/dy samples per packet). No byte writer was built and no frame was captured. |
| B2 — re-assert the grab from PCE's monitor | **DEAD as documented.** `emu.term.grab` appears in the monitor's `hm` help but has no entry in `pc_set_msg`'s `set_msg_list[]` (`msg.c:298-318`), and `trm_set_msg_trm` (`terminal.c:201-218`) exact-matches only `term.escape`/`term.screenshot`. Unrelated but real and useful: `emu.serport.driver` / `emu.serport.file` DO work, so serial 0's driver can be hot-swapped at runtime. |

**Resolved 2026-09-13 (Sonnet, `vision-ptr` branch/sandbox).** Theory A's
amplification was NOT the `scale = 2` mismatch alone — PCE's aspect correction
at `scale = 2` on 640x200 CGA is asymmetric. Walking `trm_get_scale()`
(`src/drivers/video/terminal.c`) by hand for a 640x200 source against
`min_w=512 min_h=384` and `aspect_x/y=4/3`: `f` stays 1 (640 already exceeds
`min_w`), so `*fx=*fy=trm->scale=2` before aspect correction; the aspect loop
then stretches ONLY the Y factor (`while ((h2+h) <= maxh) *fy += 1`) from 2 to
4 to hit 4:3 on a non-square CGA pixel, while `*fx` stays 2. **`fx=2, fy=4`,
not `2,2`** — the window is 1280x800 (`2*640`, `4*200`), confirming the wave
doc's own "1280x800 = scale 2 with 4/3 aspect correction" note was right about
the window size and silently wrong about the factor being uniform.

`terminal { mouse_div_x=2 mouse_div_y=4 }` (not `2,2`) undoes exactly this:
`trm_set_mouse()` in `terminal.c` divides the patch's raw window-pixel deltas
by `mouse_div_x/y` before handing them to the emulated 8250, and PCE's own
renderer then blits the CGA framebuffer back up by the SAME `fx,fy` factors —
so dividing then re-scaling by the same numbers cancels to the identity
mapping **1 XTEST window pixel of motion == 1 window pixel of visible guest
cursor motion**, on both axes independently (they need not match each other,
and here they don't: 2 vs 4).

Rerun on a rig (`/data/vms/sandbox/vision-ptr/rig/`, race ptrA's already-built
patched binary at `race/ptrA/work/pce-ibmpc`, race pce's pristine post-install
disk set, display `:194`):

- Cold boot to `C:\>`, `VISION` typed, calibration splash reached (cursor
  centred at window (640,415) — `rig/frame-02.png`).
- A sequence of incremental XTEST absolute moves (`xdotool mousemove`, ~8
  steps) advanced Visi On PAST calibration and onto the full desktop — Services
  window open on Archives, `start install remove Printing` menu line, the
  HELP/CLOSE/OPEN/FULL/FRAME/OPTIONS/TRANSFER/STOP command strip —
  **`rig/target2.png`**, matching the race rig's original hero frame.
- Two isolated single-step deltas, each read back by diffing consecutive `xwd`
  captures (bounding box of changed pixels, not yet `cursor-locate.py`'s exact
  sprite match — see caveat below): a 100-px XTEST **X** delta (window
  521→621) moved the visible arrow ~100-104 window px (`rig/vptr-A.png` →
  `rig/vptr-B.png`); a 100-px XTEST **Y** delta (window 311→411) moved it
  ~100-119 window px (`rig/vptr-C.png` → `rig/vptr-D.png`, sprite bbox height
  subtracted). Both are consistent with the derived 1:1 identity mapping
  within the precision of a bounding-box estimate; sign was consistently
  positive (right/down XTEST motion moved the arrow right/down).

**Verdict: PROVEN DIRECTIONALLY, not yet to `cursor-locate.py` precision.**
The theory holds — no over-drive, no pinning to an edge, the desktop is
reachable by pointer alone — but the two-target readback in the brief means an
exact centroid match via `cursor-locate.py`'s learned sprite template, and this
pass only had time for a coarse bbox diff. **Next**: `cursor-locate.py learn`
on `rig/vptr-A.png`/`rig/vptr-B.png` (only the cursor moved, so it can learn
the sprite unattended), then `find` on two fresh, well-separated targets and
compute `px per unit / offset / sign` exactly. Until that runs,
`listing.state` stays **hidden** — this pass gets it out of "over-driven and
pinned to the edge" and into "one measurement pass from proven", not further.

**Registry method.** The station's fixture already declares
`SH_X11TEST_ABS=1 SH_X11TEST_BUTTONS=xtest SH_X11TEST_KEYS=1` (the `x11test`
backend in absolute mode) — this is the same shape as `lisa`
(`SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`: "the root is the Lisa video,
LisaEm maps the host pointer 1:1 onto the Lisa mouse"), not `amix`'s continuous
`x11warp` loop into a guest-owned X server (Visi On's mouse is emulated 8250
hardware, not a guest X server to warp inside). With `mouse_div_x=2
mouse_div_y=4` the identity mapping derived above makes this true for vision
the same way it's true for lisa: no code change needed beyond what already
ships, `x11test` + `SH_X11TEST_ABS=1` is the correct declared method and needs
no new backend or registry variant.

The patch is committed at
`scripts/build-guests/patches/vision/pce-x11-nograb.patch` and wired into
`scripts/build-guests/tiles/vision.sh`'s `--rootfs` stage (`patch -p1` before
`./configure`); `write_pce_cfg()`'s `terminal{}` block now pins
`mouse_div_x=2 mouse_div_y=4` with the derivation in a comment. Neither the
tile builder's `--rootfs` nor `--compose` has been run end-to-end against this
patch (still true per the OPEN items below) — this pass proved the theory on
the RACE rootfs with the already-built `ptrA` binary bind-mounted over the
pristine one, not on a rebuilt production rootfs.

## Keyboard

XTEST through the fleet `x11test` backend, into the sandboxed display. Proven:
`VISION` typed at **120 ms hold / 120 ms gap** launched Visi On with no dropped or
doubled character, on the race rig and again on the station launcher.

`SH_KEY_MIN_HOLD_MS=120` / `SH_KEY_MIN_GAP_MS=120` is therefore what ships, and it
is **not a measured floor** — nobody bisected downward, so the real minimum may be
much lower. Say so rather than implying 120/120 was chosen.

## Publish — `/os/vision` dark-launch, QUEUED (not yet started)

Prepared by the BUILD+PUBLISH stream but **not yet started**, in observance of
the wave's "one `pce-ibmpc` at a time, coordinate by waiting, never by killing
theirs" rule: at the time this stream hit its own stop, `vision-ptr`'s own rig
(`/data/vms/sandbox/vision-ptr/`, nspawn `--machine=vision-ptr-rig`,
`pce-ibmpc pid 4138822`) had been running continuously for 7+ minutes
investigating the pointer, and `ps -eo pid,args | grep pce-ibmpc` never went
empty during this stream's 60-minute window.

`smoke-rig.sh` was read and, like `fmtowns` and `oberon`, is the wrong tool for
a contained x11 station by construction (it assumes a QMP socket at step 0).
The documented route (`docs/lab/FMTOWNS-WAVE.md` §Publish) is
`darklaunch-station.py publish` against the STATION'S OWN rig dir, since for a
sandboxed-x11 station "the rig IS the station dir" the same way it is for
MAME-native. Everything up to actually starting `pce-ibmpc` is done:

1. **Real assets staged** at `/data/vms/streamhost/assets/vision` — `rsync`'d
   from this stream's own proven builder output
   (`/data/vms/sandbox/vision-build/out/{rootfs,disk,rom,pce.cfg}`, §Builder),
   not from the race rig's hand-built copy. `rootfs` 545 M, uid base 2162688
   throughout (`ls -la` shows the shifted ownership).
2. **`station.env` emitted** for real, via
   `bash streamhost/stations-manifest.sh --only vision --pin-machine` run from
   this stream's own sandbox checkout (not `/data/kernel-hive`, which is not
   yet at a deployed rev carrying `vision` — `station-up.sh` needs that and so
   could not be used pre-merge). Wrote
   `/data/vms/streamhost/stations/vision/{station.env,x11-runtime.sh,ROLLBACK.md}`;
   `SH_HOST_IP`/`SH_ADVERTISE_HOST` came out as the real `192.168.1.126` from
   `registry/local.env`, not the repo's scrubbed placeholder.
3. **Binary symlink created**:
   `/usr/local/lib/streamhost/stations/vision/current` → the same
   `streamhost-ccdc999d28a9df0af200cc19b5c0ee0c89c42323` binary `lisa` runs
   (no code change on this branch touches the daemon, so any fleet binary
   already on the box is correct).
4. **The manifest-entry trap, avoided.** `darklaunch-station.py`'s `--like`
   copies the sibling's row with `dict(sibling)` and only overrides
   `id`/`displayName`/`order`/`listed`/`signalEndpoint` — every other field
   (`accent`, `archetypeId`, `arch`, `blurb`, `eraSoftware`, `notes`, …) would
   stay **lisa's**, the exact trap the oberon lead hit. Built vision's own
   entry instead, from `registry/stations/vision.json`'s own `museum`/`spa`
   blocks, at `/data/vms/sandbox/vision-build/vision-entry.json`, for
   `darklaunch-station.py publish vision --rig /data/vms/streamhost/stations/vision --entry /data/vms/sandbox/vision-build/vision-entry.json`.

**Exact next commands, once `ssh lab "pgrep -f '^/opt/pce/bin/pce-ibmpc '"` is
empty:**

```
ssh lab 'systemctl start streamhost@vision && systemctl is-active streamhost@vision'
ssh lab 'ss -lunp | grep 54194'                                    # UDP listening
python3 scripts/dev/darklaunch-station.py publish vision \
  --rig /data/vms/streamhost/stations/vision \
  --entry /data/vms/sandbox/vision-build/vision-entry.json          # run ON the box
curl -sk https://<box>:8443/os/vision -o /dev/null -w '%{http_code}\n'
python3 scripts/dev/fb-wait.py --settle 3 vision                    # or: labctl shot vision
```

Withdraw with `scripts/dev/darklaunch-station.py withdraw vision`, then
`systemctl stop streamhost@vision` — leave the station RUNNING for the
operator otherwise, per the brief ("leave only the dark launch up").

## FINISH+LANDING pass (Claude Sonnet 5, 2026-09-13, ~06:52-08:10Z)

Merged `origin/vision-ptr` and `origin/vision-build` (clean octopus merge, no
conflicts). Did NOT merge `origin/vision-spa` wholesale — it branched before
the scene-table sharding and before oberon/fmtowns landed, so a full merge
would have reverted both; ported only its museum-voice poster prose into
`registry/posters/vision.md` (was still the scaffold placeholder) by hand,
updated to the measured scene (Services window on Archives, the
HELP/CLOSE/OPEN/FULL/FRAME/OPTIONS/TRANSFER/STOP strip).

Two correctness bugs the brief's assumptions did not anticipate, found by
running the real thing rather than trusting the prior streams' reports:

1. **`spa.pointerRel: true` is wrong, not right.** `stations-registry.py
   generate` refuses it: the `x11test` backend + `pointerRel=true` lets a
   type=4 DIRECT relative pointer record bypass the router entirely (two
   injectors, neither aware of the other — see the validator's own message).
   The vision-spa draft's own conditional applies now that the identity
   mapping is proven: `pointerRel: false`, documented in `museum.notes`.
2. **`machineIdentity.3.ts` had `kit: 'office80'`**, not a valid `StationKit`
   (`'office90'` is) — vitest never checks the enum, only `npx tsc -b` catches
   it. Fixed.

**Then three real bring-up bugs, found by actually running the builder and the
launcher against production assets** (the previous streams' "run end to end"
passes used throwaway output dirs and never exercised this path):

3. `tiles/vision.sh`'s patch path resolved to
   `scripts/build-guests/tiles/patches/vision/...`; the patch is committed one
   level up at `scripts/build-guests/patches/vision/...`. Every real
   `--rootfs` run died immediately with "missing pointer patch". Fixed
   (`$SCRIPT_DIR/../patches/...`).
4. The script's arg handling is a plain `case "$1" in`, not a flag loop —
   `--rootfs --compose` silently runs only `--rootfs`. Each stage needs its
   own invocation. Not changed (out of scope for this pass); noted here so the
   next person doesn't lose time to it.
5. **`do_compose` staged `rom/`, `disk/` and `$OUT` itself under root's ambient
   umask** (0700/0400 on labhost's non-interactive ssh shells), not the
   0755/0644 every sibling station's `assets/` tree uses. The container reads
   `$OUT` read-only as host uid 2162688, never as real root, so an unreadable
   bind mount silently yielded PCE's `*** loading failed` on all three ROMs at
   the monitor prompt — the station never booted past `type 'h' for help'`
   until this was found. Fixed with an explicit `chmod -R a+rX` at the end of
   `do_compose`; applied live to the real assets (no rebuild needed) and
   verified — the 5160 now boots, PC-DOS 2.00 reaches `C:\>`
   (`frames/proof-01-boot.png`), `VISION` typed reaches the copy-protected
   splash (`frames/proof-04-splash.png`, calibration cursor visible).

**A sixth bug, not yet fixed: `vision-inner.sh`'s `fb_settle` still fires too
early.** Trap #5 above claims this was fixed, but on this pass's fresh launch
the log shows `screen settled` 4 seconds after `g` and `VISION` typed
immediately after — into a screen that had not yet run AUTOEXEC.BAT. The
keystrokes evaporated (measured: the C:\> prompt sat untouched at
`frames/proof-02-now.png`, taken 3 minutes later, with no `VISION` text on it
at all) while DOS finished booting on its own underneath. Typing `VISION`
**by hand** over the same XTEST path (`xdotool type --window <id> --delay 120
VISION`) worked cleanly and reached the splash immediately
(`frames/proof-03-typed.png` → `frames/proof-04-splash.png`), so the keyboard
path itself is fine — only the launcher's own auto-type timing is broken
again. **Next: replace the "changed-then-held" heuristic with something that
recognizes the actual C:\> prompt bytes** (e.g. wait for the `PATH` line
AUTOEXEC prints, which is content the launcher already controls), not another
guessed threshold.

**Pointer two-target readback: attempted, NOT resolved, and the reason is now
understood.** Converted the vision-ptr rig's `vptr-A/B/C/D` frames to PPM and
ran `cursor-locate.py learn` — it found two well-formed 18x40 sprite templates
(272/720 opaque pixels each, not degenerate) but `find` returned `AMBIGUOUS`
matches at effectively every coordinate in the frame (a 24.7 MB match list).
Diffing the two learned templates' RGB payloads at identical mask geometry
showed why: **the same mask (identical shape, same opaque-pixel positions)
carries DIFFERENT colours between the old-position and new-position capture.**
That is the signature of an **XOR/inverting cursor**, not a fixed-colour
sprite — PCE's arrow inverts whatever is underneath it rather than blitting
constant pixels, so over the desktop's large uniform-white background the
identical inverted pattern reproduces at *every* position over that
background, and `cursor-locate.py`'s exact-match premise (a hard-edged sprite
with fixed, content-independent pixels) does not hold for this cursor. A
follow-up attempt to move it further with `xdotool mousemove --sync` (four
incremental absolute moves toward the lower-right, then a click) produced NO
visible motion at all on the calibration screen
(`frames/proof-05-afterptr.png` is pixel-identical to `proof-04-splash.png`)
in the time this pass had left to look into it — unlike the vision-ptr rig's
own successful moves, which is itself worth investigating (a stale window
focus? the click consuming the first motion event the way stock PCE's
`xt_event_button_press` does, per the mechanism section above?). **Pointer
stays OPEN. `listing.state` stays hidden — this pass narrows the puzzle
(the XOR-cursor readback problem is now a specific, falsifiable claim rather
than "cursor-locate.py fails"), it does not close it.**

`/os/vision` dark-launch was **not published this pass** — the remaining
budget went to the bring-up bugs above (a broken boot blocks everything
downstream of it, including the framebuffer proof of any publish) rather than
publishing a station that only reaches the calibration splash. §Publish's
exact commands are unchanged and still the next step once the pointer or an
explicit decision to publish hidden-behind-splash is made.

## OPEN items

| Item | Next command |
|---|---|
| **Pointer** — desktop reached once by the race rig with a hand-driven grab, XOR-cursor readback problem now understood (see above), not yet solved | investigate why `xdotool mousemove --sync` produced no motion on this pass's live rig; if solved, `cursor-locate.py` needs an XOR-aware match mode (compare against `frame XOR sprite-shape`, not fixed RGB) or a `--hotspot`-anchored `check` against the commanded position instead of a blind `find` |
| `vision-inner.sh`'s `fb_settle` fires on an intermediate screen, not the true `C:\>` prompt — the auto-typed `VISION` is lost | replace the "changed then held" heuristic with a content match on the `PATH` line AUTOEXEC prints |
| The Visi On **desktop** has not been reached from the station launcher itself (only the splash, and only by hand-typing over the broken auto-type) | follows the two items above |
| `/os/vision` dark-launch prepared (real assets, `station.env`, binary symlink, entry JSON) but not started | see §Publish; blocked behind the pointer/fb_settle items, not behind the one-`pce-ibmpc`-at-a-time rule (that rig is torn down) |
| `spa/src/scene/assembliesByTile.ts` line count | 24 lines on this branch — the 600-line cap this doc previously flagged was a pre-shard measurement; `origin/main` has already sharded the scene tables (`.1.ts`/`.2.ts`/`.3.ts`), so this is resolved by the merge-main step, not by this stream |

## Measured timeline

| Milestone | Wall clock (UTC) | Minute |
|---|---|---|
| `wave.sh alloc` | 2026-09-13T05:13:46Z | 0 |
| race B: Visi On desktop on the framebuffer | 2026-09-13T05:33Z | 20 |
| replacement lead (Opus) resumes the stack | 2026-09-13T06:05Z | 51 |
| station launcher cold-boots PC-DOS 2.00 to `C:\>` | 2026-09-13T06:29Z | 75 |
| station launcher reaches the Visi On 1.0 splash (key disk accepted) | 2026-09-13T06:30Z | 76 |

## Teardown

| Resource | Released | Check |
|---|---|---|
| race runner A's MAME (pid 1462964) | yes | `readlink /proc/1462964/exe` returns nothing |
| race runner ptrA's container, Xvfb :195 and its `/tmp/.X11-unix/X195` symlink | yes, by the runner | runner verified by exact pid |
| race runner ptrB's container, Xvfb :196, plus one orphaned pce-ibmpc | yes, by the runner | runner verified absent from `ps` |
| the winning race rig — nspawn 2591998 / pce-ibmpc 2592146, Xvfb :194 | yes | `readlink /proc/2591998/exe` and `/proc/2592146/exe` both return nothing |
| this station's test launch — nspawn 3686893 / pce-ibmpc 3687162, Xvfb :94 | yes | same check on both pids returns nothing |
| a second run of the losing MAME theory (pid 3540488) | yes | `readlink /proc/3540488/exe` returns nothing |
| X socket symlinks `/tmp/.X11-unix/X94` and `X194` | yes | both `No such file or directory` |

Everything was killed by `/proc/<pid>/exe`, never `pkill -f`. Final sweep: no
process on the box has an exe under `race/mame`, `stationtest`, `sandbox/vision`
or any `pce` path. labhost 1-minute load went 55 → 31 across the teardown.

Kept on disk as provenance, costing nothing: `race/mame/` (including the `psi`
and `pce-img` Linux builds), `race/pce/` (the winning rig's media, rootfs and the
installed `hd0.pbi`), `race/ptrA/` (the no-grab patch) and `race/ptrB/` (the
proven pty serial config). The Visi On *desktop* frame that the race rig reached
is preserved at `/data/vms/sandbox/vision/frames/00-live-desktop.png` and is the
station's hero.
