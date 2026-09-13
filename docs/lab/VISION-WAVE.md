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

| Field                  | Value                                                                                                                                                                                                                  |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| slot / UDP port / VMID | 194 / 54194 / 194                                                                                                                                                                                                      |
| x11warp display        | `:94` (loopback `127.0.0.1:6094`) — allocated; unused unless the winner is an X11-captured sandbox                                                                                                                     |
| retronet               | **none** — skipped on purpose: Visi On has no TCP/IP stack (PC-DOS 2.00, 1983)                                                                                                                                         |
| ICQ UIN                | none                                                                                                                                                                                                                   |
| sibling (`--like`)     | see §Race verdict                                                                                                                                                                                                      |
| render orders          | as scaffolded by `stations-registry.py new` — never hand-edited                                                                                                                                                        |
| device set             | IBM 5160 XT: 8088 @ 4.77 MHz, 640 KB, CGA, two 360 KB floppies, 10 MB XT fixed disk (306/4/17), serial card on COM1 carrying a Mouse Systems-protocol serial mouse (the "VisiCorp mouse Model M1"), 83-key XT keyboard |
| media                  | see `scripts/build-guests/tiles/vision.sh` (URL + sha256 + byte size per file); staged by the `vision-media` agent under `/data/assets-staging/vision/`                                                                |

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

| Theory                                                           | Runner | Where                                 | Result                                                                                                             | Frame                                                     |
| ---------------------------------------------------------------- | ------ | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------- |
| A. MAME `ibm5160` host-native (fleet tier, `--like samcoupe`)    | sonnet | `/data/vms/sandbox/vision/race/mame/` | **LOST** — BIOS and PC-DOS 2.00 boot to `C:\>` and the keyboard works over the ctlsock, but Visi On is unreachable | `/data/vms/sandbox/vision/race/mame/frames/`              |
| B. PCE `pce-ibmpc` in systemd-nspawn (VOM-proven, `--like lisa`) | sonnet | `/data/vms/sandbox/vision/race/pce/`  | **WON** — Visi On desktop on the framebuffer 20 minutes in                                                         | `/data/vms/sandbox/vision/race/pce/frames/24-desktop.png` |

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
keeps the protection _and_ is writable — the one format that satisfies both the
key-disk check and PCE's write-back on eject. That single capability decided the
race. PCE is a stock X11 host application, so the station runs it inside a
systemd-nspawn container under the operator's host-application rule.

`/data/vms/sandbox/vision/race/mame/` is kept as provenance. Runner A also built
`psi` and `pce-img` for Linux from the pinned tarball under
`race/mame/pce-build/`; `pce-img convert -i hd0.pbi -o hd0.img` yields a raw
306x4x17 image if a raw disk is ever wanted.

## The station

|               |                                                                                                                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| launcher      | `streamhost/stations/vision/x11-runtime.sh` + `vision-inner.sh` (the lisa/medley contained shape)                                                                                                                     |
| tile builder  | `scripts/build-guests/tiles/vision.sh` — `--fetch` / `--unpack` / `--rootfs` / `--compose`                                                                                                                            |
| rootfs        | `debootstrap --variant=minbase trixie` + X and build packages, PCE compiled inside it into `/opt/pce`, whole tree uid-shifted once to 2162688                                                                         |
| root geometry | **1280x800** — PCE draws CGA 640x200 at `scale = 2` with its 4/3 aspect correction, which is exactly 1280x800, so the Xvfb root **IS** the PCE window: root coordinates are window coordinates, no crop and no offset |
| reset         | `relaunch` — PCE's ibmpc has no save state. Every launch copies `hd0.pbi`, `VOAPP1.psi` and `VOAPP2.psi` fresh from `assets/vision/disk` into the writable `work/` bind and cold-boots the 5160                       |

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
   — _not_ as a host path the way lisa's LisaEm does, because PCE lives inside
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

| Stage       | Result                                                                                                                                                                                                                                         | Wall clock                 |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| `--fetch`   | all 9 sources already staged by the media agent, hash-verified, `MANIFEST.sha256` rewritten                                                                                                                                                    | 1.4 s                      |
| `--unpack`  | 10 TransCopy disks, 2 PC-DOS images, PCE ROMs + `hd0.pbi`, MAME ROMs; every size assertion passed                                                                                                                                              | 12.8 s                     |
| `--rootfs`  | `debootstrap --variant=minbase trixie`, runtime+build packages, PCE built from the pinned tarball into `/opt/pce`, uid-shifted once to 2162688                                                                                                 | 3m46.7s (root, on labhost) |
| `--compose` | 10 `.TC` disks converted to `.psi` with the freshly-built `psi`; `hd0.pbi` staged from the proven race rig's installed disk (provenance: `race/pce/work/hd0.pbi`, made by hand per §Installing Visi On on 2026-09-13); `pce.cfg` + ROMs staged | 1.4 s                      |

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

Audit below is from **this station's own launcher**, re-run on the LAUNCHER
FINAL pass against the production assets (`/data/vms/streamhost/assets/vision`),
payload pid 1775392 (the pce-ibmpc host pid from the pidfile), 2026-09-13T08:04Z.
The production rootfs is `--variant=minbase` and carries neither `procps` nor
`iproute2`, so the process list and the interface list are read from `/proc`
inside the container instead of from `ps -e` / `ip link` — same facts, one fewer
package in a sandbox that does not need it.

```
PAYLOAD PID=1775392  exe=/opt/pce/bin/pce-ibmpc
--- namespaces (all six must differ) ---
pid  host=pid:[4026531836]       payload=pid:[4026536986]
mnt  host=mnt:[4026531832]       payload=mnt:[4026536983]
net  host=net:[4026531833]       payload=net:[4026536987]
user host=user:[4026531837]      payload=user:[4026536982]
ipc  host=ipc:[4026531839]       payload=ipc:[4026536985]
uts  host=uts:[4026531838]       payload=uts:[4026536984]
--- status ---
Uid:	2162688	2162688	2162688	2162688
CapEff:	0000000015808dff
NoNewPrivs:	1
--- processes in the container (/proc, no procps in a minbase rootfs) ---
     1 (sd-stubinit)
     2 /bin/bash /work/inner.sh
     5 Xvfb :94 -screen 0 1280x800x24 -nolisten tcp -noreset -ac
    14 /opt/pce/bin/pce-ibmpc -c /work/pce.cfg
--- interfaces (/proc/net/dev) ---
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets ...
    lo:       0       0    0    0    0     0          0         0        0       0 ...
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

| Proof                                                                                                                                                                       | Verdict                                                     | Frame                                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------- |
| Cold boot: the 5160 posts and PC-DOS 2.00 reaches `C:\>` with AUTOEXEC run (`PROMPT $P$G`, `PATH C:\;C:\DOS`)                                                               | **PASS**                                                    | `/data/vms/sandbox/vision/frames/01-station-launch.png`          |
| Visi On 1.0 starts and the copy-protection check on the VOAPP1 key disk passes — the Applications Manager splash, `COPYRIGHT 1983 VISICORP / VERSION 1.0`                   | **PASS**                                                    | `/data/vms/sandbox/vision/frames/02-station-vision-desktop.png`  |
| Keyboard: `VISION` typed over XTEST at 120 ms/char is received without a dropped or doubled character (it is what launched Visi On above)                                   | **PASS**                                                    | same frame                                                       |
| Sandbox audit from the running station                                                                                                                                      | **PASS**                                                    | §Sandbox above                                                   |
| The Visi On desktop itself — Services window on Archives, the `start install remove Printing` menu line, the HELP/CLOSE/OPEN/FULL/FRAME/OPTIONS/TRANSFER/STOP command strip | **PASS on the race rig**, not yet from the station launcher | `/data/vms/sandbox/vision/frames/00-live-desktop.png` (the hero) |
| Pointer: two-target readback                                                                                                                                                | **FAIL — OPEN**, see §Pointer                               | —                                                                |

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

| Theory                                                                                 | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A — patch PCE's x11 terminal to forward motion with no grab** (`race/ptrA/`)         | **CLOSEST.** A 2-hunk patch (`/data/vms/sandbox/vision/race/ptrA/pce-x11-nograb.patch`) applies cleanly to the pristine tarball, builds clean, and changes behaviour: Visi On advanced past the calibration splash into the Services desktop with no click and no grab, which pristine PCE cannot do. But the readback is over-driven — absolute XTEST jumps drove the guest cursor to the right edge and pinned it there. NOT a proven pointer.              |
| **B — drive the mouse through the serial port instead of the terminal** (`race/ptrB/`) | **PLUMBING PROVEN, pointer not.** `serial { driver = "pty:symlink=/work/com1.pty" }` initialises (`char-pty: /dev/pts/0`), PCE holds the master and the symlink is the slave, so host-written bytes land on the guest's COM1 RX. PCE's own encoder at `char-mouse.c:132-148` is ground truth for the Mouse Systems framing (byte0 `0x80` + active-low buttons, dy negated, two dx/dy samples per packet). No byte writer was built and no frame was captured. |
| B2 — re-assert the grab from PCE's monitor                                             | **DEAD as documented.** `emu.term.grab` appears in the monitor's `hm` help but has no entry in `pc_set_msg`'s `set_msg_list[]` (`msg.c:298-318`), and `trm_set_msg_trm` (`terminal.c:201-218`) exact-matches only `term.escape`/`term.screenshot`. Unrelated but real and useful: `emu.serport.driver` / `emu.serport.file` DO work, so serial 0's driver can be hot-swapped at runtime.                                                                      |

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
identical inverted pattern reproduces at _every_ position over that
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

## LAUNCHER FINAL pass (Claude Opus 5, 2026-09-13, ~07:30-09:00Z)

The station now reaches the Visi On 1.0 splash **on the first attempt of a cold
launch, with nobody at the keyboard**. Two real bring-up bugs behind that, both
fixed at the root; the pointer is unchanged and still OPEN.

### 1. The auto-type: why every "settled screen" test was doomed

Three settle heuristics have now typed `VISION` into a screen that was not the
prompt. The measurement that ends the argument, taken on this station on
2026-09-13 with 45 one-second `xwd` captures at the prompt:

> **The C:\\> prompt produces exactly TWO distinct frames, alternating forever**
> (half-period ~2.5 s). It is the PC-DOS cursor blinking.

So a settle test cannot work in either direction: it fires on the _static_ POST
screen and it can _never_ fire on the prompt. Every previous version of
`fb_settle` was measuring the wrong property of the right screen.

But blink alone is not enough either, and the log of the first fixed launch says
why in its own words — the 5160's POST screen **also** blinks:

```
08:02:08 blink seen but ink=0 is outside the prompt band — not the prompt yet
08:02:10 blink seen but ink=0 is outside the prompt band — not the prompt yet
08:02:12 blink seen but ink=0 is outside the prompt band — not the prompt yet
08:02:15 blink seen but ink=2 is outside the prompt band — not the prompt yet
08:02:18 blinking text screen, ink=45 — this is the C:\> prompt
08:02:18 attempt 1: typing VISION
08:02:20 Visi On started (ink=524)
```

The second signal is **ink**: the fraction of non-black subpixels in the X root,
x10000. Every screen this boot passes through is an order of magnitude from its
neighbours, so "which screen is this" is a measurement rather than a guess:

| Screen                                                       | ink       |
| ------------------------------------------------------------ | --------- |
| POST / memory count (blinking cursor on black)               | 0-2       |
| PC-DOS 2.00 `C:\>` prompt                                    | **39-45** |
| the prompt with `VISION` typed on it                         | 47-52     |
| Visi On Applications Manager splash (`Calibrate the mouse.`) | **524**   |
| the Visi On desktop (Services window)                        | 4570      |

`vision-inner.sh`'s `wait_dos_prompt` therefore requires BOTH: the frame
alternating a-b-a-b-a between exactly two states (four consecutive changes — a
one-shot transition between two static screens cannot fake it) AND both states
carrying ink in the prompt band (25..120). It measures ink with `python3` on the
raw `xwd` bytes, because the minbase rootfs carries `x11-apps` for `xwd` and no
ImageMagick.

And because no screen test deserves to be trusted alone, the whole thing is a
**retry loop closed on the ink measurement**: after typing, it watches for ink to
cross 200; if the splash has not appeared within 20 s the keystrokes went
somewhere else and it waits for the prompt and types again, up to five times.
Typing `VISION` at a DOS prompt that is already busy is harmless — worst case a
`Bad command` line and another attempt. Measured cold launch: prompt found at
**15 s**, splash at **17 s**, first attempt, no retry needed.

`fb_settle` survives, but only for use _after_ Visi On has started, where the
screen genuinely does go static. It is never used to find the prompt.

### 2. The relaunch bug: nspawn's leftover unix-export mount

`reset = relaunch` on this station, so the second launch is the common case —
and it died, every time:

```
vision[vision]: the sandbox died at launch — tail of pce.log:
Mount point '/run/systemd/nspawn/unix-export/vision-vision' exists already, refusing.
```

`systemd-nspawn` mounts a per-machine tmpfs under
`/run/systemd/nspawn/unix-export/<machine>` and refuses to start if one is
already there. Its teardown is **asynchronous**: it lands a beat after the
container's pids are gone, so `reap_previous` returns true while the mount is
still up, and the relaunch loses the race with the launch it just killed.
`x11-runtime.sh` now waits up to 10 s for that path to disappear after reaping
and then clears it by force (`umount` + `rmdir`), failing loudly if it will not
go.

**Do not rename `$MACHINE`.** A cosmetic rename of the nspawn machine from
`vision-vision` to `kh-vision` was tried in the same pass and every container
under the new name was SIGTERMed within seconds of starting ("Trying to halt
container"), three times running, while `vision-vision` containers under
otherwise identical launches survived indefinitely. Something on the box reaps
`kh-*` machines it does not recognise. The rename was reverted; whatever the
sweeper is, it is not this station's to fight, and the name is cosmetic.

### 3. The pointer on the station launcher: still OPEN, one theory eliminated

`vision-inner.sh` now runs `calibrate_pointer` after the splash — an incremental
walk of `xdotool mousemove --sync` steps (incremental because the no-grab patch
reads the DELTA between successive MotionNotify events and spends the first
seeding its reference). On the clean cold launch above the walk completed and the
framebuffer **did not change at all**: ink stayed at 524 across the whole walk and
for 60 s after it, and the arrow stayed exactly where the splash drew it at
window (640,415). This reproduces the FINISH pass's result on a fresh rootfs and
a fresh boot.

**The "the rebuilt binary is not the patched one" theory is dead.** The
production binary carries the patch's own function-local static as a symbol:

```
$ nm /data/vms/streamhost/assets/vision/rootfs/opt/pce/bin/pce-ibmpc | grep have_pos
00000000000b6e20 b have_pos.1          # the patched no-grab motion handler
$ nm /data/vms/sandbox/vision/race/pce/rootfs/opt/pce/bin/pce-ibmpc | grep have_pos
                                        # (nothing — the pristine build)
```

`nm | grep have_pos` on the two builds is a one-line check that the shipped PCE
is the patched one, and the production asset passes it. `pce.cfg` in the
production assets likewise carries `mouse_div_x = 2` / `mouse_div_y = 4`.

So the difference between the vision-ptr rig (where `xdotool mousemove` moved the
guest arrow) and the station launcher (where it does not) is **not the binary and
not the config**. What is left, untested, and in priority order:

1. the walk runs INSIDE the container while the rig's ran from the host — same
   display either way, but a different X client with a different connection;
2. XTEST motion generates no `MotionNotify` at all if the pointer is already at
   the requested coordinate (the walk's first `mousemove 640 400` may be a no-op,
   and the patch discards the first real event as its seed, so the first TWO
   steps can vanish);
3. the rig may have had a button press first, which stock PCE needs and the
   patched build may still need to arm something.

The cheap test for (1) and (2) is one command against a running station:
`ssh lab 'DISPLAY=:94 xdotool mousemove --sync 100 100 mousemove --sync 900 600'`
then a frame — a single large two-step move, from the host, with no click.

### 4. The readback, and why `cursor-locate.py` does not apply here

Recorded so nobody spends another pass on it: Visi On's arrow is an **XOR
cursor** — it inverts what is under it rather than blitting fixed pixels, proven
by the FINISH pass's two learned templates having identical masks and different
RGB payloads. `scripts/dev/cursor-locate.py` matches a hard-edged sprite with
content-independent pixels and returns AMBIGUOUS at every coordinate over a
uniform background, and no parameter changes that. **The two-target readback for
this station is a bounding-box diff of the changed region between two captures at
well-separated positions**, as the vision-ptr rig did, and the operator validates
by eye — that is the standing rule for an eyeballable check. The wave doc says
this rather than leaving a future pass to rediscover it.

### 5. Listing verdict

`listing.state` stays **hidden**. The station cold-boots, reaches the Visi On 1.0
splash unattended and deterministically, and is sandboxed to the contract — but a
visitor's pointer does nothing, and the desktop behind the calibration screen is
not reachable from the station launcher. `pointerRel` is `false` (the generator
refuses `true` with the `x11test` backend, §FINISH+LANDING pass); the declared
method is `x11test` + `SH_X11TEST_ABS=1`, which is correct for the geometry and
unproven end to end on the station.

## LISTING pass (Claude Opus 5, 2026-09-13, ~11:00-12:35Z)

Sandbox `/data/vms/sandbox/vision-list`, branch `vision-list`. Every measurement
below is from a **copy** of the deployed launcher — `SH_STATION=visionc194`,
`VISION_BASE=/data/vms/sandbox/vision-list/copyA`, `VISION_ASSETS` the real
`/data/vms/streamhost/assets/vision` bound read-only, display `:194` — never on
the live unit (rule 4). The live `streamhost@vision` and its `pce-ibmpc`
(pid 1952397) were left alone throughout.

### 1. The calibration walk DOES reach the desktop — twice, unattended

§LAUNCHER FINAL pass 3 recorded the walk completing with the framebuffer
unchanged at ink 524. **That no longer reproduces.** Two consecutive cold
launches of the copy, both unattended, both ending on the Visi On desktop:

| Launch                    | Xvfb up  | `C:\>` prompt | splash (ink 524) | desktop (ink **3427**) |
| ------------------------- | -------- | ------------- | ---------------- | ---------------------- |
| first                     | 11:04:56 | 11:05:11      | 11:05:13         | 11:06:33               |
| second (`relaunch` path)  | 11:29:56 | 11:30:00      | 11:30:03         | 11:31:23               |

97 s and 87 s from Xvfb to the desktop. The live unit's own log carries the same
three lines from its landing launch (`calibration walk done, ink=3427` at
08:18:03), so the deployed station reached the desktop too. **Ink 3427, not the
4570 of §1's table** — the desktop with the arrow parked where the walk leaves
it. Treat 3427 as the desktop's measured ink on this launcher.

**Relaunch proof.** The second launch above is `x11-runtime.sh` re-run over a
live container: it reaped the previous nspawn + `pce-ibmpc`, cleared the
`unix-export` mount and cold-booted again with no intervention. Wall clock for
the launcher script itself: **3 m 0.5 s** (`time` on the whole invocation),
of which the reap is the slow part — long enough that a caller with a 2-minute
timeout will kill the launcher mid-reap and leave an orphaned `pce-ibmpc`
(observed once; cleaned up by exe). Worth a look, not a blocker.

### 2. Pointer scale: exactly 1.000 window px per XTEST px, both axes

Two-target readback on the desktop, `xdotool mousemove --sync` from the host,
2 s settle, `import -window root`, arrow located by the changed-region diff:

| XTEST move            | arrow centroid            | delta         | px per XTEST px |
| --------------------- | ------------------------- | ------------- | --------------- |
| (300,200) → (800,200) | (300.5,257.5) → (800.5,257.5) | **+500.0 x** | **1.000**       |
| (800,200) → (800,600) | (800.5,257.5) → (800.5,657.5) | **+400.0 y** | **1.000**       |

and four consecutive +100 px X steps, each landing exactly +100.0
(700.5 → 800.5 → 900.5 → 1000.5 → 1100.5). Frames
`/data/vms/sandbox/vision-list/frames/{p0-300x200,p1-800x200,p2-800x600,s-000,s-x1..s-x4}.png`.
`mouse_div_x=2 / mouse_div_y=4` is confirmed correct, and the §Pointer
derivation of the identity mapping holds.

### 3. …but the mapping is RELATIVE, it drifts, and it WEDGES — so the station stays hidden

Three measurements, in order, that together close the listing question:

1. **The offset is not constant.** On the first boot XTEST (300,200) put the
   arrow's bbox origin at (290,240); on the second boot XTEST (240,140) put it
   at (230,160). Same launcher, same assets — a different offset, because Visi
   On owns its own cursor and sees only Mouse Systems *deltas*. There is no
   absolute correspondence to declare.
2. **It wedges at an edge and never comes back.** After ~15 moves, some of which
   drove the arrow into the bottom command strip and past the bottom of the
   screen, the arrow pinned at bbox (1276,792) — the bottom-right corner — and
   **no** subsequent motion moved it again: not absolute XTEST
   (`mousemove --sync 640 400`, `740 500`), not relative XTEST
   (`mousemove_relative 100 0`, `0 100`). Frames `z-abs1/z-abs2/z-rel1/z-rel2.png`
   are pixel-identical to each other and to `r-home.png`. This is the same
   symptom §Pointer's theory A called "over-driven and pinned to the edge"; it
   is reachable by an ordinary visitor in under a minute.
3. **The daemon's own recovery cannot fix it.** `SH_X11TEST_ABS=1` sends true
   absolute XTEST and nothing else (`x11_input.rs:283`); dropping it selects the
   reckoner path, whose `HOME_DELTA = -8192` slam exists precisely to re-home a
   relative guest after a clamp. Simulated exactly — 41 chunks of
   `mousemove_relative -200 -200`, then the target as chunked deltas
   (`/data/vms/sandbox/vision-list/reckon.sh`) — and the guest arrow did not move
   at all (`r-home` → `r-400x300` → `r-home2` → `r-900x500`: *no change*, four
   frames, all identical). The reason is structural: **once the host X pointer
   clamps at (0,0) the X server emits no further MotionNotify**, so only the
   first ~600 px of the 8192-px slam is ever delivered to PCE. The homing slam
   is a no-op on an Xvfb root this size, and neither `SH_X11TEST_ABS=1` nor
   `SH_X11TEST_ABS=0` has a recovery path for this station.
4. **Closed-loop aiming does not converge either.** Three iterations of
   locate-then-correct with `cursor-locate-cv.py` (below) on a fresh boot:
   a correction of (-140,+170) XTEST moved the arrow (-62,+131); the next,
   (-78,+39), moved it (-6,**-42**) — the wrong way on Y. So the 1.000 factor
   of §2 holds for clean, well-separated moves in mid-screen and *not* in
   general; something (packet-rate clamping on the 1200-baud Mouse Systems
   link, or Visi On's own cursor handling near a window edge) is eating and
   inverting deltas.

**Listing verdict: `listing.state` stays hidden, and the reason has changed.**
It is no longer "the desktop is not reachable" — the launcher reaches it every
time, unattended. It is that a visitor's pointer works for a few seconds, then
sticks in a corner with no way back, and no setting in the fixture or the
daemon recovers it. The registry row is unchanged by this pass.

### 4. The tool the operator asked for: `scripts/dev/cursor-locate-cv.py`

OpenCV, in a venv on `/data` (`/data/vms/sandbox/vision-list/cv-venv`, built on
labhost; nothing was installed into any system python). Verbs `learn` / `find` /
`check` / `react`, same CLI shape as `cursor-locate.py`, which stays the default
for hard-edged sprites.

It solves the XOR-cursor readback that §"4. The readback" says `cursor-locate.py`
cannot do. Note that the obvious method does **not** work here and the file says
so: matching the learned mask against a Laplacian/Canny edge image, or against
the frame and its inverse, is swamped by Visi On's dithered background (peaks
300+ px away, scores 0.02-0.39 with no separation). What works is a
**consistency cost**: un-invert the hypothesised sprite region and require it to
agree with the same columns both above *and* below the sprite's own height — a
wrong hypothesis conflicts with real page content in at least one direction.
Unique global minimum on every test frame.

Acceptance against this pass's frames, ground truth from the bbox diff:

```
learn s-000.png s-x1.png      -> learned a 22x36 mask
find  s-x2.png -> origin=(890,596)  centroid=(901.0,614.0)  score=1.0000 FOUND
find  s-x3.png -> origin=(990,596)  centroid=(1001.0,614.0) score=1.0000 FOUND
find  s-x4.png -> origin=(1090,596) centroid=(1101.0,614.0) score=1.0000 FOUND
find  s-y5.png -> origin=(1090,692) centroid=(1101.0,710.0) score=0.0303 FOUND
check ... --expect 900.5,613.5 / 1000.5,613.5 / 1100.5,613.5 / 1100.5,709.5
      -> OK err=(+0.5,+0.5) on all four
react s-x2.png s-x3.png --ignore-bbox 880,590,1020,640
      -> changed_pixels=0 NO REACTION      (cursor-only change, correctly ignored)
```

`scripts/dev/fb-diff-bbox.py` ships alongside it as the 60-second version: diff
two frames, report the changed bbox, `--split` separates the old and new cursor
clusters along whichever axis has the wider gap. It is what produced the ground
truth above.

### 5. Click proof — NOT obtained

The click itself was never delivered to a known target: the aim loop of §3.4 did
not converge, so `mousedown 1 / mouseup 1` fired at an unknown arrow position and
`react` reported `changed_pixels=0`. No click proof exists for this station. It
is downstream of the pointer, not independent of it.

### 6. What the next pass should do

The pointer is not a calibration problem any more; it is a **delivery** problem
in PCE's patched `xt_event_motion()`. Two concrete leads, in order:

1. **Instrument the patch.** Build a copy of `pce-x11-nograb.patch` that logs
   every accepted delta and every packet handed to `trm_set_mouse()`, run the
   §3.2 wedge sequence and read where the deltas stop — at the X event, at the
   `mouse_div` truncation, or in the 8250 encoder. That distinguishes "PCE stops
   forwarding" from "Visi On stops consuming" in one run, and everything else
   depends on which it is.
2. **Theory B, now worth building** (§Pointer): PCE's `char-pty` serial driver is
   already proven to initialise, and `char-mouse.c:132-148` is ground truth for
   the Mouse Systems framing. A host-side byte writer on `/work/com1.pty` bypasses
   the X terminal, the grab, `mouse_div` and the patch entirely — a ~40-line
   script, and if it drives the arrow it is also the station's shipping pointer
   path (an `SH_INPUT_BACKEND` that writes deltas to a fifo, sibling to
   `x11warp`). No byte writer was ever built; that is the cheapest untried thing
   on this station.

Do **not** spend another pass on absolute-vs-relative fixture flags. Both were
measured this pass and neither recovers a wedged cursor.

## POINTER DELIVERY pass (Claude Opus 5, 2026-09-13, ~14:20-15:40Z)

**The wedge is a protocol bug in PCE's Mouse Systems encoder, and it is fixed.**
One clamp per axis. The arrow now tracks XTEST absolutely across a 31-move
sequence that includes every screen edge, both bottom corners and the command
strip, and a click opens a real Visi On window.

Sandbox `/data/vms/sandbox/vision-deliver`, branch `vision-deliver`. Every
measurement is from a **copy** of the deployed launcher (`SH_STATION=visionc194`,
`VISION_BASE=/data/vms/sandbox/vision-deliver/copyA`, the real
`/data/vms/streamhost/assets/vision` bound read-only, display `:194`). The live
`streamhost@vision` and its `pce-ibmpc` (pid 1952397) were never touched.

### 1. The instrumented build said the delivery path is perfect

An instrumented PCE (`PCE_MOUSE_LOG=<file>`, log lines at the patched
`xt_event_motion()`, at `trm_set_mouse()`, at `chr_mouse_set_drv()`, at every
emitted Mouse Systems pair and at every `chr_mouse_read()`) was built from the
`ptrA` tree and bind-mounted over `/opt/pce/bin/pce-ibmpc` in a copy of the
station. Its log during the wedge sequence is unambiguous:

```
MOVE 10 -> 800,200
X_MOTION evt=(800,200) delta=(500,0) but=0
TRM_SET_MOUSE scaled=(250,0) rem=(0,0) but=0
CHR_SET_DRV in=(250,0) acc=(250,0) but=0->0
MSYS_PKT pair=0 emit=(127,0) residual=(123,0) hdr_but=0
MSYS_PKT pair=1 emit=(123,0) residual=(0,0) hdr_but=0
```

Every X delta reaches the encoder; `mouse_div_x=2 / mouse_div_y=4` divides
exactly; **the chunking the coordinator's theory suspected already exists and
already works** — `chr_mouse_get_val()` clamps each component to ±127 and
*subtracts what it emitted from the accumulator*, so a 500-px move becomes
127 + 123 in the two pairs of one packet and nothing wraps and nothing is lost.
Not one `MSYS_PKT_DROP` (buffer full) line appeared in the whole run. **PCE does
not stop forwarding. Visi On stops consuming.**

### 2. Why Visi On stops consuming: the delta bytes alias the sync byte

A Mouse Systems packet is `1000 0LMR` followed by two signed 8-bit `(dx, dy)`
pairs. The sync byte is therefore **0x80..0x87** — and a *signed delta byte* can
be exactly that: `dx` in `-127..-121` encodes as `0x81..0x87`, and PCE's wire
`dy` byte (it writes `~v + 1`, i.e. `-dy`) does the same for `dy` in `121..127`.
Visi On 1.0's built-in 8250 driver resynchronises on that pattern, so any packet
carrying such a delta is thrown away.

PCE's chunker emits **exactly -127** for the first chunk of any leftward move
longer than 127 guest units. So every large LEFTWARD move was silently lost and
every large RIGHTWARD move landed. The arrow ratcheted right and could never come
back — that is the whole of §LISTING pass 3's "wedge", and it also explains its
two puzzles: why Y kept working (`dy` never reached ±121 in those runs) and why
closed-loop corrections came back non-linear (a correction was delivered or
eaten depending purely on whether its first chunk was -127).

Measured correlation over the 31-move sequence, before the fix — the four moves
that produced **no framebuffer change at all** are exactly the four whose
emitted `dx` byte landed in `0x81..0x87`:

| move | requested | emitted pairs | alias byte | framebuffer |
| ---- | --------- | ------------- | ---------- | ----------- |
| 8    | 900,300 → 640,400 | (-127,25) (-3,0) | **0x81** | **no change** |
| 9    | → 300,200 | (-127,-50) (-43,0) | **0x81** | **no change** |
| 10   | → 800,200 | (127,0) (123,0) | — | moved +500 px |
| 26   | → 200,600 | (-127,50) (-93,0) | **0x81** | **no change** |
| 29   | → 400,200 | (-127,0) (-123,0) | **0x81 0x85** | **no change** |

From move 15 the arrow sat at bbox x = 1270..1279 and only ever moved in Y again.

### 3. The fix: clamp one unit short of the alias range

`scripts/build-guests/patches/vision/pce-msys-sync-alias.patch` —
`chr_mouse_get_val (&drv->dx, **-120**, 127)` and
`chr_mouse_get_val (&drv->dy, -127, **120**)`. The residual stays in the
accumulator and rides the next packet, so a long move costs one extra 5-byte
packet and lands in the same place. Wired into `tiles/vision.sh --rootfs` after
the no-grab patch; both apply `-p1` to the pinned tarball (dry-run verified).

**Re-run of the identical 31-move wedge sequence on a fresh cold launch of the
same copy, with the fixed binary** (`/data/vms/sandbox/vision-deliver/frames/`,
`wedge.sh` is the script):

- **31 of 31 moves produce motion.** The single exception is move 14, a 15-px
  nudge at a cursor already clamped against the bottom of the screen.
- **The arrow tracks the requested absolute XTEST coordinate at every move**,
  corners included: XTEST `(0,0)` → arrow bbox origin `(0,0)`; `(640,0)` →
  `(630,4)`; `(0,400)` → `(0,404)`; `(900,600)` → `(890,596)`; `(1279,795)` →
  the bottom-right. Scale stays 1.000 px per XTEST px on both axes.
- **It recovers from every edge**, including the bottom command strip and both
  bottom corners, and is still controllable at move 31. No wedge.

### 4. Click proof

Two clicks through plain XTEST on the same run, each at a named target:

| action | frames | reaction |
| ------ | ------ | -------- |
| `mousemove 60 778` (HELP in the command strip) + `click 1` | `frames/c0-aim.png` → `frames/c1-click.png` | changed bbox `(0,712)-(1279,795)`, 1280x84 — Visi On prints **"Select what you need help with."** |
| `mousemove 320 778` (OPEN) + `click 1`, then `mousemove 110 340` (Archives) + `click 1` | `frames/d0-open.png` → `frames/d1-archives.png` | changed bbox `(0,160)-(1279,799)` — a **Help window opens**, titled `Help`, with the OPEN help text and its own `overview see back contents quit.` command line |

So the station now answers a pointer the way a visitor would use it: aim at a
word, press the button, get a window.

### 5. What ships

The **XTEST path**, unchanged in shape: `SH_INPUT_BACKEND=x11test`,
`SH_X11TEST_ABS=1`, `pointerRel: false`, `mouse_div_x=2 / mouse_div_y=4`. No new
transport, no new backend, no daemon change — only the two PCE patches in the
rootfs. `listing.state` is **removed**: the station is listed.

### 6. Theory B, raced and NOT shipped

Per rule 14 a `sonnet` runner built the pty byte writer (§LISTING pass 6.2) on
display `:195` at the same time. It works: `serial { driver =
"pty:symlink=/work/com1.pty" }` plus a Mouse Systems encoder run inside the
container's namespaces moved the arrow and survived a 34-move edge sequence. It
is **not** what ships — it needs a new transport, a writer process inside the
container and a pacing/drain fix, and its own click proof failed — whereas the
one-clamp fix makes the path the station already declares correct. Kept as
provenance on branch `origin/vision-ptyb` (`movemouse.py` + the `pce.cfg` serial
swap); nothing from it is on `vision-deliver`.


## POINTER 1:1 pass (Claude Opus 5, 2026-09-13, ~14:40-16:00Z)

**The sync-alias clamp made every delta land. It did not make the guest cursor
and the host pointer agree on where they are.** One corner slam does, and with it
the station meets the wave's 1:1 bar: five targets, two laps, **0 px error on all
ten**, plus a click that opens a window.

Rig: a copy of the deployed launcher (`SH_STATION=visionc294`,
`VISION_BASE=/data/vms/sandbox/vision-ptr2/copyA`, the real
`/data/vms/streamhost/assets/vision` bound read-only, display `:294`, claim
`display/294`). The live `streamhost@vision` was never touched.

### 1. The deployed binary really does carry the clamp

`objdump -d` of `/data/vms/streamhost/assets/vision/rootfs/opt/pce/bin/pce-ibmpc`
over `chr_mouse_add_packet` shows `$0xffffff88` (-120) and `$0x78` (120) in the
msys branch, alongside the untouched `$0xffffff81 / $0x7f` (-127/127) of the
other protocols. The fix of §POINTER DELIVERY is on the box, not just in git.

### 2. The residual error was an OFFSET, not a scale, and it is 40 px

Straight out of the launcher's own `calibrate_pointer` walk, with the host
pointer parked at XTEST (140,140), the guest arrow's 22x36 sprite sat at bbox
origin (130,180) — hotspot (140,**180**). Scale was already perfect; the station
was 40 px out in Y and would have been some other number on the next boot,
because Visi On owns its cursor and sees only Mouse Systems *deltas*. Equal
deltas preserve an offset forever; §LISTING pass 3.1 saw the same thing and
called it "there is no absolute correspondence to declare".

### 3. A clamp removes what a delta cannot: the corner slam

Two REAL absolute moves — `mousemove 1279 799`, then `mousemove 0 0`. The second
delivers a delta of (-1279,-799), larger than any possible guest cursor
coordinate, so the guest arrow bottoms out at ITS (0,0) in the same instant the
host pointer bottoms out at its own. Measured, frames `h1-br/h2-tl/h3-40/h4-140`:

| step | host XTEST | guest sprite bbox origin | hotspot error |
| ---- | ---------- | ------------------------ | ------------- |
| after the calibration walk | (140,140) | (130,180) | (0,**+40**) |
| slam bottom-right | (1279,799) | (1276,792) — clamped | — |
| slam top-left | (0,0) | (0,0) — clamped | **(0,0)** |
| then | (40,40) | (30,40) | (0,0) |
| then | (140,40) | (130,40) | (0,0) |

It has to be two absolute moves and not a relative overshoot: a clamped X pointer
emits no further `MotionNotify`, which is exactly why the daemon's own
`HOME_DELTA = -8192` slam was a no-op here (§LISTING pass 3.3).

This is now `home_pointer()` in `streamhost/stations/vision/vision-inner.sh`,
run once after `calibrate_pointer`, parking the pointer at the screen centre.

### 4. The proof: five targets, two laps, 0 px

Targets on the published 1280x800 surface, returning to the centre between each
(so lap 2 is a genuine re-approach, not a continuation). Readback is
`scripts/dev/fb-diff-bbox.py --split`, which reports the EXACT 22x36 sprite bbox
rather than an estimate. Sprite geometry from §3: hotspot = bbox origin + (10,0),
centroid = hotspot + (0.5,17.5).

| target | lap 1 sprite bbox | lap 2 sprite bbox | hotspot error, both laps |
| ------ | ----------------- | ----------------- | ------------------------ |
| (20,20)     | (10,20)   | (10,20)   | **0,0** |
| (1240,20)   | (1230,20) | (1230,20) | **0,0** |
| (20,760)    | (10,760)  | (10,760)  | **0,0** |
| (1240,760)  | (1230,760)| (1230,760)| **0,0** |
| (640,400)   | (630,400) | (630,400) | **0,0** |

Both laps are **byte-identical** frames (`cmp`), so there is no drift at all
between them, and this run is on the RESET PATH: a cold relaunch of the launcher
whose `vision-inner.sh` does the homing itself, with no hand-driven slam
anywhere. Frames `/data/vms/sandbox/vision-ptr2/final/L{1,2}-<x>-<y>.png`.
At (20,760) the sprite's own cluster merges with the HELP button's repaint (Visi
On reacts to the hover), so that row's bbox is the merged region; the position is
confirmed by the lap-1/lap-2 byte-identity and by the click proof below.

`scripts/dev/cursor-locate-cv.py check` agrees on the centre target —
`centroid=(641.0,418.0) want=(640.5,417.5) err=(+0.5,+0.5) score=1.0000` — and
reports **AMBIGUOUS (score 0.0154, second 0.0154, an exact tie)** on the four
corner targets. That is a real limitation of the tool worth writing down: its
XOR-consistency cost compares a hypothesised sprite region against the same
columns ±36 rows away, and Visi On's background is a *periodic* fine dither, so
over a large uniform patch of it every candidate position ties. Use it where the
cursor sits on or near real content; use `fb-diff-bbox.py --split` (or `learn`'s
own two-frame differencing) where it sits on open desktop. A `--near X,Y` search
window would fix it and is the obvious next 10 lines in that file.

### 5. Click proof

`mousemove 60 778` (HELP in the command strip) + `click 1`:
`cursor-locate-cv.py react` reports `changed_pixels=30418 bbox=(0,712,1279,795)
REACTED`, and the frame reads **"Select what you need help with."** above the
command strip. Frames `/data/vms/sandbox/vision-ptr2/final/c{0-aim,1-click}.png`.

### 6. What changed

One file: `vision-inner.sh` gains `home_pointer()`. No daemon change, no new
backend, no device-set change, no new patch. `SH_INPUT_BACKEND=x11test`,
`SH_X11TEST_ABS=1`, `pointerRel: false`, `mouse_div_x=2 / mouse_div_y=4` all
stand. Registry `reset.mouse` now carries the numbers above instead of "OPEN".

### 7. `labctl reset vision` did not come back — two causes, both fixed

The coordinator's measurement agent reported that a live `labctl reset vision`
cold-boots PCE and leaves the visitor on the "Calibrate the mouse." splash, frame
unchanged 90 s after the call. Reproduced on the rig, and it is two independent
things, neither of them the pointer:

1. **The container ignored the first SIGTERM.** `systemd-nspawn
   --kill-signal=SIGTERM` delivers SIGTERM to pid 2 — `bash /work/inner.sh`,
   blocked in `wait "$PCEPID"`. Bash defers a signal until `wait` returns, so the
   container logged *"Trying to halt container. Send SIGTERM again to trigger
   immediate termination"* and stayed up. Measured: **8 minutes** with no new
   container, and the old frame still on the wire the whole time. `vision-inner.sh`
   now installs `trap term_handler TERM INT` before the wait, forwards SIGTERM to
   PCE, and retries the `wait` (a trap makes `wait` return >128).
2. **`reap_previous` was O(every process on labhost), 40 times over.**
   `station_emu_pids()` readlink()ed `/proc/<pid>/exe` for every pid on the box to
   find the container's PCE, and the reap ladder calls it up to 40 times; on a
   labhost running 100+ guests that is minutes of pure scanning. It now checks the
   pid the launcher itself recorded first (O(1), still verified by exe *and*
   descent — rule 5 intact), and returns empty immediately when the nspawn pid is
   gone, because PCE lives in that nspawn's PID namespace and cannot outlive it.
   The full scan stays as the fallback.

The 90 s observation window was also simply too short even for a healthy
relaunch: a cold 5160 boot to `C:\>` is ~25 s, `VISION` types in 3 s, the splash
wait is 30 s, and the calibration walk is ~50 s — the desktop arrives about two
minutes after the container starts. That is the number below, and it is why the
coordinator is right that a CRIU checkpoint of the container payload is the only
route to the operator's <2 s bar. **Do not read this pass as "reset is now fast";
read it as "reset now completes, deterministically, and here is the number."**

Measured relaunches, each proved on the framebuffer by ink (the Services/Archives
desktop is ~467 000 lit pixels of 1 024 000; the splash is ~72 000):

| relaunch | launcher returns | desktop on the framebuffer |
| -------- | ---------------- | -------------------------- |
| see the measured table in the landing commit | | |

**`labctl facts vision`'s "could not resolve a boot disk" is cosmetic and not
this bug**: `labctl facts lisa` and `labctl facts perq` print the identical
warning. It means only "this station has no QEMU `-drive` to parse", which is
true of every host-native x11 station.


## OPEN items

| Item | Next command |
| ---- | ------------ |
| ~~Pointer~~ — **CLOSED and 1:1**: the sync-alias clamp (§POINTER DELIVERY) plus `home_pointer()`'s corner slam (§POINTER 1:1 pass) — five targets, two laps, 0 px error on all ten, click opens a window | — |
| The launcher's `relaunch` reap takes ~3 min and can hang indefinitely: nspawn's SIGTERM reaches `bash inner.sh` blocked in `wait`, which defers it (§POINTER 1:1 pass 7). Observed 8 min with no new container | add `trap 'kill -TERM $PCEPID' TERM` around the `wait` in `vision-inner.sh`, then re-time `x11-runtime.sh` |
| `SH_KEY_MIN_HOLD_MS=120` / `SH_KEY_MIN_GAP_MS=120` was never bisected downward — it is what worked first, not a measured floor | bisect on a copy |
| `/os/vision` dark-launch prepared (real assets, `station.env`, binary symlink, entry JSON) but never started | §Publish — now moot if the station lists |

## Measured timeline

| Milestone                                                           | Wall clock (UTC)     | Minute |
| ------------------------------------------------------------------- | -------------------- | ------ |
| `wave.sh alloc`                                                     | 2026-09-13T05:13:46Z | 0      |
| race B: Visi On desktop on the framebuffer                          | 2026-09-13T05:33Z    | 20     |
| replacement lead (Opus) resumes the stack                           | 2026-09-13T06:05Z    | 51     |
| station launcher cold-boots PC-DOS 2.00 to `C:\>`                   | 2026-09-13T06:29Z    | 75     |
| station launcher reaches the Visi On 1.0 splash (key disk accepted) | 2026-09-13T06:30Z    | 76     |

## Teardown

| Resource                                                                      | Released           | Check                                                                    |
| ----------------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------ |
| race runner A's MAME (pid 1462964)                                            | yes                | `readlink /proc/1462964/exe` returns nothing                             |
| race runner ptrA's container, Xvfb :195 and its `/tmp/.X11-unix/X195` symlink | yes, by the runner | runner verified by exact pid                                             |
| race runner ptrB's container, Xvfb :196, plus one orphaned pce-ibmpc          | yes, by the runner | runner verified absent from `ps`                                         |
| the winning race rig — nspawn 2591998 / pce-ibmpc 2592146, Xvfb :194          | yes                | `readlink /proc/2591998/exe` and `/proc/2592146/exe` both return nothing |
| this station's test launch — nspawn 3686893 / pce-ibmpc 3687162, Xvfb :94     | yes                | same check on both pids returns nothing                                  |
| a second run of the losing MAME theory (pid 3540488)                          | yes                | `readlink /proc/3540488/exe` returns nothing                             |
| X socket symlinks `/tmp/.X11-unix/X94` and `X194`                             | yes                | both `No such file or directory`                                         |

Everything was killed by `/proc/<pid>/exe`, never `pkill -f`. Final sweep: no
process on the box has an exe under `race/mame`, `stationtest`, `sandbox/vision`
or any `pce` path. labhost 1-minute load went 55 → 31 across the teardown.

Kept on disk as provenance, costing nothing: `race/mame/` (including the `psi`
and `pce-img` Linux builds), `race/pce/` (the winning rig's media, rootfs and the
installed `hd0.pbi`), `race/ptrA/` (the no-grab patch) and `race/ptrB/` (the
proven pty serial config). The Visi On _desktop_ frame that the race rig reached
is preserved at `/data/vms/sandbox/vision/frames/00-live-desktop.png` and is the
station's hero.
