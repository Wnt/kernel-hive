# sunos414 guest — SunOS 4.1.4 / OpenWindows on a SPARCstation 5

Status: **bring-up in progress** (Tier 1, hidden candidate; dark-launched at
`/os/sunos414` from the sandbox rig so the install is watchable live).
Research brief: [`../lab/research/candidate-sunos414.md`](../lab/research/candidate-sunos414.md).

## Identity and source

- Public ID / station directory: `sunos414`
- Reserved slot / UDP port: `147` / `54147` (claimed on the box, `kh-claim udp 54147`)
- Archetype: `sparc-pizzabox`
- OS: SunOS 4.1.4 (Solaris 1.1.2), SPARC (sun4m kernel), 1994. Licence class:
  **contested-commercial** (Sun/Oracle; preservation copy). Media stays on the
  box, never in the repo.
- Media: `sunos_4.1.4_install.iso` from fsck.technology
  (`software/Sun Microsystems/SunOS Install Media/SunOS 4.1.4 SPARC (CD)/`),
  378 178 080 bytes, sha256
  `6088d836cf582128cdd69661c4b62399fbd6f4db9b817188b2d1509cebbb5f48`
  (md5 `9638a1e88711946f95cb171437ac37a3`). Sector 0 carries the Sun disk label
  "CD-ROM Disc for SunOS Installation cyl 2048 alt 0 hd 1 sec 640".

## Build and device set

- Emulator: `qemu-system-sparc` 11.0.2, kernel-hive fork (`github.com/Wnt/qemu`
  @ `kernel-hive`), built like macos753/hpuxvue into **`/opt/qemu-sparc`**
  (pve-qemu ships no sparc target). Firmware = the fork's own
  `openbios-sparc32`; nothing to source.
- Machine: `-M SS-5 -m 256`, TCG only (no KVM for SPARC-on-x86).
- Display: **`-vga cg3`**. Not for the reason this line used to give: SunOS
  4.1.4 *does* have a TCX driver and QEMU's TCX works. The real reason is in
  ["Why not TCX"](#why-not-tcx) below.
- Storage: SCSI target 0 = 4 GB qcow2 system disk, SCSI target 2 = install CD.
- NIC: `lance` + slirp user net.
- Input: buttons and keys on the Sun serial mouse/keyboard through QEMU's
  D-Bus path; pointer MOTION absolute through the guest's own X server
  (`SH_INPUT_BACKEND=x11warp`). See ["The pointer is absolute, through the
  guest's X server"](#the-pointer-is-absolute-through-the-guests-x-server).
- Builder: `scripts/build-guests/tiles/sunos414.sh` (TODO after the golden)

## Install log (2026-08-18)

Rig: `/data/vms/sandbox/sunos414/rig/` — `launch.sh [cd|mini|hd]` (restarts the
borrowed daemon), `t.sh <wait> "text\n" | --keys …` (QMP typing + screendump),
`shot.sh`, `daemon.sh`. Every step below was verified on the framebuffer.

1. **The fsck.technology "ISO" is a raw 2352-byte/sector BIN** (sync + MSF
   header per sector; 160790 × 2352 = 378 178 080). OpenBIOS found no boot
   block on it. Stripped to 2048-byte sectors → `sunos414.iso` (329 297 920 B, sha256 `7b9b092a63bf5dde9f09eea25614c6da58e5c065758a8c24b96be1574bcaa0c8`);
   sector 0 then carries a valid Sun label (magic `dabe`): a = whole disc,
   b–f = five 16 MB per-architecture boot/miniroot partitions.
2. `-m 256` → kernel dies with `Trap 0x29 (Data Access Error)` right after
   load. **`-m 64` boots** (`mem = 49020K` reported). Not retried higher.
3. SCSI IDs must be Sun's: system disk **target 3 = `sd0`**, CD **target 6 =
   `sr0`** (the GENERIC/MUNIX kernel hard-wires both). Explicit
   `-device scsi-hd/scsi-cd` with `scsi-id=`, not `if=scsi,unit=`.
4. **CD needs 512-byte blocks**: SunOS's `sr` driver reads 512-byte blocks and
   QEMU's default 2048 gives `esp0: data transfer overrun` + `sr0: SCSI
   transport failed` while extracting the miniroot. Fix:
   `-device scsi-cd,…,physical_block_size=512`. OpenBIOS still boots it
   (`boot cdrom:d` = the sun4m MUNIX kernel).
5. `format`: type 13 `SUN2.1G` (2733/19/80), table a=/ 100 cyl (76 MB),
   b=swap 130 cyl (99 MB), g=/usr 2503 cyl (1.9 GB), h=0. `label`, `quit`.
6. MUNIX "install SunOS mini-root" → miniroot copied to `sd0b`. Reboot lands
   back at OpenBIOS (`-prom-env boot-device` is ignored — it boots
   `disk:a`/`cdrom:d`); type
   `boot /iommu/sbus/espdma/esp/sd@3,0:b -sw`. **The `-w` matters**: without
   it the miniroot's root is read-only (its `rc.boot` is only `loadkeys -e`,
   nothing remounts) and `suninstall` dies with
   `/etc/install/suninstall.log: cannot open file for append`.
7. `suninstall` → Custom, TZ `EET`, host `sunos414` standalone, `le0`
   10.0.2.15, NIS none, no auto-reboot; disk form "use existing" label,
   a → `/`, g → `/usr`, preserve n; software from `sr0` local, choice **all**
   (`sunos 4.1.4 sun4m media`). Form UI: `x` selects, RET ends a text field,
   `^F`/`^B` move; the trailing `[y/n]?` prompt only takes input once the
   cursor is past the last field.
8. **`Versatec` cannot be extracted from this disc** (`/usr/etc/install/tar/
   export/exec/sun4_sunos_4_1_4/versatec: cannot extract file`, then an
   endless "mount volume 1" loop). Both fsck.technology copies are
   byte-identical, so it is the press, not the transfer. Ctrl-C, re-run
   `suninstall` (host/disk data survive as `+`), software → edit existing
   release → choice **own choice** → answer `y` to every category except
   `Versatec` (a plotter driver nobody misses). Everything else re-extracts.
9. Station dir on the box created by `box-deploy --apply` (launcher) +
   `station.env`/`ROLLBACK.md` from a scratch emit of
   `streamhost/scripts/streamhost-station.sh` with the row's `emitArgs`
   (`registry/local.env` supplies the real IPs) + `labctl gen`. The unit is
   left stopped while the sandbox rig owns UDP 54147; the switch happens when
   the installed disk moves into the station dir.

## Desktop, autologin, and the input fix

Golden fixture: the **OpenWindows 3** desktop on SunOS 4.1.4, logged in as the
**unprivileged `guest` user** (uid 100, home `/export/home/guest`, `sunos414%`
csh prompt) — cmdtool console, File Manager, and the "Introducing Your Sun
Desktop" Help Viewer on the cg3 at 1024x768x8. `resetMode: loadvm`, snapshot
`golden`; restore is instant and the guest starts frozen (`-S`) until the first
visitor.

**Autologin → desktop.** The guest logs in on the console (getty → login →
`~/.login`), and on `/dev/console` its `.login` execs
`/usr/openwin/bin/gallery-session` (a wrapper that `exec`s `openwin -noauth`).
`.Xdefaults` sets `OpenWindows.SetInput: followmouse`. Because the golden
captures the already-logged-in session, the unit never cold-boots — so the
console-login path only has to work once, at bake time.

**The input fix (why openwin MUST run from a console login).** xnews only grabs
the keyboard + mouse when it owns the **console controlling terminal**
(`ps` shows `TT=co`). Started any other way — from `rc.local`, or `su ... <
/dev/console` — xnews comes up with `TT=?` and gets **no input at all** (the
cursor never moves; the escc mouse/keyboard bytes reach the kernel but never
reach X). SunOS 4.1.4's `login` has no `-f`, so OS-level autologin via ttytab
is not used; the golden-of-a-logged-in-session sidesteps it entirely.

**Mouse: PASS.** Motion, buttons and the OPEN LOOK workspace menu are
framebuffer-proven (2026-08-18) and survive the loadvm restore. The Sun serial
mouse is relative-only; `SH_CURSOR_SCALE=1.0` pending an operator eyeball.

**Keyboard-in-X: PASS (was a false alarm).** Two competing agents chased this
(one on the SunOS side, one patching QEMU's escc). The escc angle was decisively
ruled out — every keystroke emits a correct Sun make/break scancode and the guest
kernel reads it; the emulator is blameless. **Root cause: the OpenWindows input-
focus model.** The golden had shipped `OpenWindows.SetInput: followmouse`, under
which keyboard focus follows the pointer — keys only reach a window while the
pointer physically sits over it. Every "dead keyboard" test had the pointer on
the root/backdrop, on a menu, or typed into the special cmdtool CONSOLE. The fix
is `OpenWindows.SetInput: select` (click-to-focus) in guest's `~/.Xdefaults`:
click a window and it keeps focus with the pointer anywhere — the intuitive model
for visitors. Framebuffer-proven: click a shelltool, move the pointer off it,
type `whoami` → `guest`. The golden was re-baked with select; keyboard also works
at the console and via `labctl exec`.

Applying it needs a re-bake, not just the file: olwm reads SetInput at session
start and the golden captures the running xnews, so the integration is: set
`select` in `/export/home/guest/.Xdefaults`, restart openwin (re-login guest at
the console so olwm re-reads it), then recapture the checkpoint with
`ssh lab 'checkpoint-guard recapture sunos414'` — never hand-typed snapshot verbs
([`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md)).

## The pointer is absolute, through the guest's X server

The SS-5 has no absolute input device and its framebuffer has no hardware
cursor, so neither of the fleet's two existing absolute mechanisms applies: no
tablet to write to, and nothing to close a control loop on. The third mechanism,
and the only one in the fleet that reaches a guest over the guest's own network
stack, is the guest's X server itself:

- **Actuator**: `XWarpPointer(src=None, dst=root, 0,0,0,0, x, y)` puts the
  pointer on an absolute root coordinate, and OpenWindows repaints immediately —
  no nudge needed to make the move visible.
- **Sensor**: `XQueryPointer(root)` reads the guest's OWN idea of where the
  pointer is. That is what earns `absolute: true`; it is a measurement, not an
  assertion about a device.

`xnews` runs with `-noauth` and listens on TCP `*:6000`. The launcher publishes
it as a **loopback-only** SLIRP forward, `127.0.0.1:6047 -> 10.0.2.15:6000`, so
the daemon sees display `127.0.0.1:47` (`SH_X11WARP_DISPLAY`). SLIRP forwards
are host-side state, not vmstate, so this is re-added at every start exactly like
the telnet exec forward — **the device set does not change and the golden does
not move.**

**Exposure.** The guest has exactly two interfaces, `le0` (SLIRP `10.0.2.15`) and
`lo0`; there is no retronet tap on this station. So `*:6000` inside the guest is
reachable only from SLIRP's own `10.0.2.2` and, through the loopback forward,
from the host. Access control is left **on** and the grant is scoped to that one
peer: `xhost +10.0.2.2`, never `xhost +`. The guest's `/etc/hosts` must name the
peer (`10.0.2.2 slirphost`) first — xnews resolves NAMES for its access list, and
without the entry every connection is refused with the misleading `Internal error
during connection authorization check`, which is a reverse-lookup failure, not an
authorization decision.

**Both of those live in the golden, not in a startup step.** They were baked with
`checkpoint-guard recapture`, so a restore already has them and the pointer has no
per-restore dependency to fail. Restore-proven on a sandbox clone before anything
retired: a fresh restore of the *old* golden refuses the X connection outright,
and a fresh restore of the baked one answers the handshake and warps to all seven
proof targets with nothing having run in between — no bootstrap, no exec channel,
no login.

What the launcher still carries is a **check, not a configure step**. It probes
the forward from the host with a bare X11 connection-setup handshake — 12 bytes
out, and the first byte of the reply is success or refusal — and logs
`x11warp ok: the golden carries the X access state` to `x11warp-bootstrap.log`.
It verifies from the host on purpose: every telnet login into this guest writes a
`ROOT LOGIN` line into the cmdtool CONSOLE the visitor is looking at, and a check
must not dirty the exhibit it checks. If the state is absent it shouts
(`x11warp STALE GOLDEN`, naming the recapture command), repairs over the exec
channel, and shouts again that the checkpoint needs recapturing. That path exists
only for the window where a deployed launcher meets a golden baked before this
change; it is a workaround with a siren on it, not the design. Both branches are
proven — against the baked golden it logs `ok` with no guest login at all, and
against the old golden it logs `STALE GOLDEN`, repairs, and logs
`repaired at runtime -- RECAPTURE THE CHECKPOINT`.

### Recapturing this station's checkpoint

The two config steps must be applied, and the console cleared, in **one** telnet
session — `login` writes its `ROOT LOGIN` line before your command runs, so
clearing last leaves the console clean:

```sh
labctl exec sunos414 "grep slirphost /etc/hosts > /dev/null || echo 10.0.2.2 slirphost >> /etc/hosts ; env DISPLAY=:0 /usr/openwin/bin/xhost +10.0.2.2 > /dev/null ; env TERM=sun /usr/ucb/clear > /dev/console"
ssh lab 'checkpoint-guard recapture sunos414'
```

Measured on a sandbox clone: the resulting checkpoint's **first frame** differs
from the old one by 1105 px **inside the cmdtool console pane and 0 px
everywhere else** — and the console difference is text being REMOVED. The scene
is strictly cleaner than before, since the old golden also carried a stray
`sv_xv_sel_svc: Unable to remove …` line that goes with it.

**A frame-diff trap on this station, found the hard way.** Comparing a restored
frame against a stored one can show the Help Viewer's mouse illustration
changing colour (black ↔ lavender) with nothing else different. That is not a
regression and not something a recapture bakes: it is 8-bit PseudoColor
**colormap focus** — the window under the pointer gets its colormap installed —
so simply warping the pointer over the Help Viewer changes those pixels. Park the
pointer identically in both frames before concluding anything from a diff, and
capture a checkpoint with the pointer where you want the colormap to be.

**Buttons and keys do NOT ride this channel.** This server has no XTEST
extension — `ListExtensions` answers exactly `MIT-SHM`, `Multi-Buffering`,
`SHAPE`, `SUN_ALLPLANES`, `SUN_DGA`, `SunWindowGrabber`, `XInputDeviceEvents` —
so nothing can be synthesised through X but pointer position. Edges stay on the
D-Bus PS/2 path. Two channels with independent latency is precisely the hazard
that turns a click into a drag (press-at-A / motion / release-at-B; on aix432 it
was reported as "the keyboard stopped working in Netscape"), so the sink
**confirms** each warp with `XQueryPointer` before an edge is released. A
verified restate, not a sequenced one — an unconfirmed sequence works on a fast
day and drags on a slow one.

**The caveat, stated plainly.** This pointer exists only while the guest's X
server does. A hardware-cursor or guest-RAM sensor keeps working at the console,
during boot, at a login prompt and after the window system dies; this one does
not. **And there is no fallback** — an earlier draft of this page said there was,
which was wrong. `apply_move_abs` (input.rs) returns immediately after
`router.try_move(...)` whenever a router exists, so on this station the D-Bus
relative path is never reached: if the sink rejects with `BackendDown` the move is
DROPPED and counted, and the pointer simply stops moving until the X server is
back. STAT states this rather than leaving it to be inferred from a rising
counter: `on-backend-down=motion-stops`.

### Do NOT add a relative fallback here

It is the obvious improvement and it is forbidden, so the reason is written down
where someone about to add it will read it.

A fallback is **a second motion path**, and a second motion path silently
invalidates this sink's `VerifiedWarp` discharge (see
[`../lab/INPUT-DEBUGGING.md`](../lab/INPUT-DEBUGGING.md#a-confirmed-position-is-not-a-held-one--the-general-property)).
The armed confirm→inject→done window excludes a concurrent motion **only**
because motion reaches this guest through exactly one path. Add a second one and
the window still arms, the readback still confirms, every counter still reads
healthy — and clicks start landing somewhere else, occasionally. Nothing errors
and no test fails.

Weigh the two failure modes honestly: a pointer that visibly stops is a failure a
visitor can see and an operator can diagnose in seconds. A click that lands in the
wrong place now and then, on a station reporting itself healthy, is the failure
this whole wave exists to avoid. **The worse-looking behaviour is the safer one.**

If a fallback is ever genuinely wanted, it would have to engage only when the
sink is down **and** no edge is armed, with an explicit handoff between the two
movers rather than two of them live at once — and the drain of QEMU's Sun mouse
accumulator (below) becomes its problem. That is a constrained design someone
would have to build deliberately; it is not a TODO, and it is not a small change.
For an exhibit whose entire content *is* OpenWindows that is an acceptable trade,
but it is a real difference from the other absolute stations.

### Framebuffer proof (rule 9), 2026-08-30

Three observers at every target — what was COMMANDED, what `XQueryPointer`
returned, and where `scripts/dev/cursor-locate.py` found the sprite — because a
sensor agreeing with the framebuffer is not the same claim as the pointer being
where it was aimed. Hotspot **measured**, not guessed: two `learn` frames put the
sprite origin at (299,549) for a commanded (300,550) and (449,699) for a
commanded (450,700), so the hotspot is (1,1) and the sprite is 18x18.

| commanded | XQueryPointer | cursor-locate `--tol 1 --hotspot 1,1` |
|---|---|---|
| 300,550 | 300,550 | OK err +0,+0 |
| 450,700 | 450,700 | OK err +0,+0 |
| **300,133** | 300,133 | OK err +0,+0 — File Manager TITLE BAR |
| 700,300 | 700,300 | OK err +0,+0 |
| 60,40 | 60,40 | OK err +0,+0 |
| **1,500** | 1,500 | OK err +0,+0 — left screen edge |
| 1006,700 | 1006,700 | OK err +0,+0 |

At the hard clamp (0,500) the sensor confirms 0,500 and the sprite is visibly
there with its left column clipped (changed-pixel bbox x 0-16, y 499-516 =
pointer minus the (1,1) hotspot, cut at the frame). `cursor-locate` answers
NOTFOUND, correctly: it is an exact masked matcher and a clipped sprite is not
the sprite. That is a tool limitation at a clamp, not a pointer error, and it is
recorded rather than hidden by loosening `--tol`.

**Click that visibly repaints**: warp to (400,600) on the root, confirm the
readback, then press button 3 on the D-Bus PS/2 path. The OPEN LOOK Workspace
menu pops with its top-left corner at (397,564) — 24 662 changed pixels anchored
on the pointer. The X button mask reads 256 during the press, at (400,600), so
the guest saw the edge at the warped position.

### The Sun mouse accumulator: a 127-pixel trap on the FALLBACK path

QEMU's Sun mouse keeps a dx/dy **accumulator** and drains it only 127 at a time
(`sunmouse_sync` in `hw/char/escc.c` clamps to +/-127, emits that, and subtracts
it). A large relative injection therefore leaves a residue that bleeds 127 px
into **every subsequent event, including a button-only one**. Measured: after
big relative test injections, a warp to (723,649) followed by press and release
walked the pointer to (596,522) and then (469,395) — exactly -127,-127 per edge,
*through* a confirmed warp. On a fresh `loadvm golden` restore with no relative
motion ever injected, the same warp/press/release holds (723,649) throughout.

Under `x11warp` this cannot arise: the sink never sends relative motion. It
matters wherever relative motion IS injected on this station — a `labctl`
pointer helper, a QMP `mouse_move`, or a future rollback to `dbus-rel` — since
the residue outlives whoever left it. It is not reachable from the x11warp
daemon path itself, which has no relative channel at all. Note that zero-valued
relative events are dropped by QEMU and do NOT drain it; a residue needs real
+/-1 events, one sync each.

### Two measurements the old relative pointer was quietly wrong about

Found while calibrating, and true of the station as it shipped before this
change:

- **The emulated Sun mouse's Y axis is INVERTED** relative to QEMU relative
  input: a positive `dy` in `input-send-event` moves the guest pointer **up**.
- **OpenWindows ships pointer acceleration `2/1` with threshold `15`**
  (`xset q`), so guest pixels per injected count are neither 1 nor constant.

Together those mean the previous `dbus-rel` pointer was neither 1:1 nor
sign-aligned, independently of anything in this change. Both are moot under
`x11warp`, which never reckons a delta.

### Why not TCX

The launcher used to say "SunOS 4.1.4 has no driver for QEMU's TCX". That is
**false**, and it was rejected on the strength of it for months. Measured
2026-08-30 by cold-booting a sandbox copy of the golden disk with `-vga tcx`:

```
SUNW,tcx0 at  SBus slot 3 0x800000 and  ... pri 9 (sbus level 5)
tcx0: revision 0, screen 1024x768
```

SunOS attaches it (`@(#)tcx.c 1.48 94/08/22 SMI` is in `/vmunix`), boots to
multiuser, and brings up the full OpenWindows desktop at the same 1024x768.

TCX was attractive because QEMU's `hw/display/tcx.c` models a **complete**
hardware cursor — `cursx`/`cursy` at THC `0x8fc`, a 32x32 `cursmask`/`cursbits`
sprite, and `tcx_draw_cursor32` indexes the surface at `p[cursx]` directly, so
the register IS the sprite origin with **no bias to calibrate**. It was rejected
on two measurements instead:

1. **The guest never writes the cursor registers.** With OpenWindows running,
   gdb against the live QEMU shows `cursx == cursy == 0xf000` — the `tcx_reset`
   "off screen" value — and `cursmask`/`cursbits` all zero. Only `thcmisc` is
   ever written (`0x80000400`). There is no sensor here, only a modelled one.
2. **The TCX session is input-dead under QEMU.** Injected relative motion and a
   right-click on the root window change **zero** framebuffer pixels, and xnews
   starts `vkbd` there. Even with a working cursor the exhibit would not be
   usable.

So TCX would have cost an adapter swap, a golden re-bake **and** emulator input
work, to buy a sensor that does not track.

**A note for whoever does inherit `tcx.c`**: `cursx`/`cursy` are **not** in
`vmstate_tcx` (version 4 carries height/width/depth, the palette and the DAC
index only). A TCX golden therefore restores with the cursor off-screen at
`0xf000`, and any convergence test that concludes on "the reading stopped
changing" would read *converged* forever without the guest having moved a pixel.
A quiescent sensor is not a converged sensor.

**And cg3, the framebuffer this station actually runs, has no cursor at all** —
`hw/display/cg3.c` models a Bt458 palette plus five FBC registers (`CTRL`,
`STATUS`, `CURSTART`, `CUREND`, `VCTRL`, the last three pure scratch). There is
no position, no sprite and no enable bit anywhere in the file. That is a
source-level fact, not an inference from behaviour.

## labctl exec (telnet_unix_e)

`labctl exec sunos414 "<cmd>"` returns real captured stdout+stderr and the
guest's exit code. SunOS 4.1.4 predates ssh, so the channel is the guest's own
**in.telnetd** (inetd runs it; root has no password on a fresh suninstall):

- client `streamhost/guest-agents/sunos414/sunexec.py` → deployed to
  `/root/sunexec.py` (box-sync-pairs `sunos414-sunexec`). It logs in, quiets the
  line, and brackets each command with unique START/END markers (immune to csh
  prompt echo), so `false`→1, `test -f /vmunix`→0 come back correctly.
- labctl dispatch: `telnet_unix_e` branch in `scripts/labctl.d/guest.py`.
- transport: QEMU SLIRP. The guest is `10.0.2.15`; the launcher re-adds
  `hostfwd_add tcp:127.0.0.1:5947-10.0.2.15:23` on every start (SLIRP forwards
  are host-side, not in the loadvm snapshot — same reason alpine re-adds its ssh
  forward). Declaration: `exec_kind=telnet_unix_e`, `exec_port=5947`,
  `exec_user=root`.
- **Liveness**: needs the guest booted to multiuser (inetd up). That is instant
  once the loadvm golden restores the running system; at the bare OpenBIOS
  prompt there is no telnetd yet. Proven 2026-08-18 against the running bring-up
  guest: `labctl exec sunos414 "uname -a"` → `SunOS sunos414 4.1.4 2 sun4m`.

## Golden, input, and rollback

- Reset mode and fixture: TODO
- Pointer/click/drag/wheel/keyboard proof: TODO
- Credentials reference only (never values): `guest/sunos414`
- Rollback plan: TODO
