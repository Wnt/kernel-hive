# hpuxvue guest — HP-UX 10.20 with HP VUE (HP 9000/778, PA-RISC)

Status: **LISTED — golden checkpoint baked 2026-08-18 03:57** (production, slot 144 /
UDP 54144). `/os/hpuxvue` restores the VUE desktop from the `golden` snapshot in the station-local disk; the guest starts frozen until the first visitor.
Research note: [`docs/lab/research/candidate-hpux.md`](../lab/research/candidate-hpux.md).

## Identity and source

- Public ID / station directory: `hpuxvue`
- Archetype: `sparc-pizzabox` (scene: `pizzaBoxA|crtE`)
- Target: **HP-UX 10.20 with HP VUE 3.0 chosen at the login screen** — the
  operator's call: the hall has enough CDE; VUE (what CDE was built from) is
  the exhibit. VUE is gone in 11.x, so 10.20 is the ceiling.
- Media: see [`ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md) — HP-UX 10.20
  Install/Core OS (June 1996 press, `hpux-1020-iso`), Applications, Patches
  2002, and the **July 1997 ACE Install/Core disc for B/C/J class**
  (`B3782-10178`). Contested-commercial; never committed, archived in the
  media cache.

## Emulator and device set

| | |
|---|---|
| Emulator | `qemu-system-hppa` 11.0.2, kernel-hive fork (`github.com/Wnt/qemu` @ `kernel-hive`), built like macos753 into **`/opt/qemu-hppa`** (pve-qemu ships no hppa target). Firmware = the SeaBIOS-hppa `hppa-firmware.img` that build installs; nothing to source. |
| Machine | `-M B160L` (HP 9000/778 Visualize B160L, PA-7300LC), `-smp 1 -m 512`, `-accel tcg,thread=multi -d nochain` (the known-good HP-UX recipe) |
| Display | built-in **Artist** framebuffer, 1280x1024x8, `-display dbus,p2p=on` — hard ceiling, do not raise |
| Disk | `if=scsi,bus=0,index=6` 4000M qcow2 (`hpuxvue-golden.qcow2` in the station dir) |
| CD | `if=scsi,bus=0,index=2` `assets/hpuxvue/disc1.iso`, `-boot d` during install |
| NIC | `tulip` on a **real bridged tap** (`hpuxrn0` on `vmbr-rn`), per-station MAC from `RN_HPUXVUE_MAC`; HP-UX claims it with `btlan3` as `lan0`. See [`retronet/WEB-STATION-hpuxvue.md`](../lab/retronet/WEB-STATION-hpuxvue.md) |
| Pointer | LASI PS/2, **relative** (`dbus-rel`); `SH_CURSOR_SCALE=1.0` unmeasured |
| Audio | none |

Launcher: `streamhost/stations/hpuxvue/qemu-streamhost.sh` picks the shape from
what exists (golden snapshot → `-loadvm golden -S`; `INSTALLED` marker → boot
disk; else boot CD). The device set is identical in all three.

## Install log

- 2026-08-18 00:27 — first boot: SeaBIOS-hppa boots the June-1996 Install/Core
  CD, HP-UX B.10.20 install kernel comes up on the Artist ITE console at
  1280x1024, capture + keyboard (QMP `sendkey`) proven on the framebuffer.
  **"There were no disk devices found during the scan"** — twice. The disk IS
  attached (QMP `info qtree`: `scsi-hd` id 6 on the `lsi53c895a` at Dino
  PCI 00:00.0). Diagnosis: the 1996 install kernel predates the B/C/J-class
  workstations and has no 53c8xx PCI SCSI driver — the firmware read the CD,
  the kernel cannot see the bus. Confirmed by Helge Deller on qemu-discuss
  (2020-09): the emulated B160L has a PCI 53c895a where the real one has a
  LASI 53c710, and older install kernels only claim the latter.
- 00:37 — the July-1997 **ACE B/C/J-class disc** (`B3782-10178`) boots the SAME
  June-1996 install kernel (`install/init $Revision: 5.30G`) and fails the same
  way; `-smp 4` also fails ("Processor 1..3 did not start") — back to 1 vCPU.
- **00:44 — WORKS: the 10.20 Install/Core CD from archive.org `hpux_20200510`
  (`cd1.iso`, 508 MB, md5 `54f0d43ce09d7e6c8450e59b9409c1c1`) — a later press
  whose `install/init` is `$Revision: 10.3`, the revision the qemu-discuss
  thread names as the one that finds disks.** Disk seen at `8/0/0/0.6.0`
  (QEMUHARDDISK, 4000 MB). Keyboard language 61 `PS2_DIN_US_English`.
  Whole-system config: Standard LVM; **Software Selection = "VUE Runtime
  Environment"** (the list offers VUE / CDE / Minimal / Minimal+networking —
  the open question is answered: VUE is on the media and selectable);
  "Load 10.20 Networking ACE" = True (the sanctioned way; the SD-UX warning
  is about hand-picking bundle B6378xx, which we do not); no SD-UX
  interaction. FS sizes enlarged up front to dodge the LVM-growth gotcha:
  / 300, /stand 48, swap 512, /home 100, /opt 700, /tmp 100, /usr 1000,
  /var 480 (756 MB spare in vg00). Then unattended: LVM + swinstall.
- 01:05–01:45 — swinstall loaded 246 filesets (VUE.VUE-RUN etc.), configured
  ("/etc/inittab modified to start HP VUE at system startup"). The
  post-install "user specified script" from the media (HP's, not ours) then
  ran a second `swinstall -x match_target=true -s <CD>` for the ACE bundles and
  **hung for 40+ min at "Beginning Execution"** with zero disk I/O (loopback
  RPC to swagentd was already failing: "Connection request rejected
  (dce / rpc)"). Ctrl-C ended swinstall cleanly; the following `swlist` hung
  the same way and ignored Ctrl-C. Forced reboot from disk.
- **The interrupted finale never built the kernel**: `/stand` had ioconfig,
  bootconf, system, kernrel but no `vmunix` (ISL: "Cannot find /stand/vmunix"),
  and no `/stand/rootconf`. Fix, from the CD's Support Media shell
  ("Run a Recovery Shell"): the RAM fs has ~200 KB free so no LVM tool loads;
  instead `mount /dev/dsk/c0t6d0s1lvm /ROOT` (the boot LV is addressable as
  the s1lvm section without LVM), write `/ROOT/rootconf` = `deadbeef` +
  root-LV start + size in 1 K blocks read from the disk's LIF `LABEL`
  (host: `qemu-io -r -c "read -v 0xd0800 512"`; here 0x0008cb60 / 0x0004b000,
  i.e. `/` at PE 140, 300 MB), then Recovery MENU → **d. Replace only the
  kernel** installs the media's generic `vmunix` (7.4 MB) onto the boot LV.
- 02:25 — boots from disk on that kernel; manual `fsck -y` of lvol6/7/8 at
  the bcheckrc prompt (dirty from the forced reset); Ctrl-D → **X11 first-boot
  `set_parms`**: answered **standalone (no network)** at install time, hostname
  `hpuxvue`, TZ EET, no root password, no font server. *(That standalone answer
  was undone on 2026-08-23 when the station joined the retronet — the
  networking section below is the current truth.)* Then **`vuelogin`** (HP greeter) → root → **HP VUE
  3.0 desktop**: front panel, six workspaces, Helpview welcome, File Manager.
- Pointer: guest gain measured 50 units → 96 px on both axes = plain X
  acceleration (2×, threshold 4), i.e. `xset m 1 1` gives 1:1 and
  `SH_CURSOR_SCALE=1.0` is right. QMP `mouse_move`/`mouse_button` clicks
  Motif buttons reliably.

## Networking — on the retronet since 2026-08-23

The station is on the retronet **web** plane. Full as-built:
[`docs/lab/retronet/WEB-STATION-hpuxvue.md`](../lab/retronet/WEB-STATION-hpuxvue.md).

- The `tulip` is a **real bridged NIC**: backend `-netdev tap,ifname=hpuxrn0`
  on `vmbr-rn`, sharing L2 with the retronet gateway CT `10.99.0.2`. The
  `-device` is unchanged apart from the per-station `mac=`, which is read from
  gitignored `registry/local.env` (`RN_HPUXVUE_MAC`).
- HP-UX claims the card with **`btlan3`** (the PCI 100Base-TX driver) as
  **`lan0`** at hardware path `8/0/1/0`.
- Address **`10.99.0.20/24`**, DNS `10.99.0.2`, **no default gateway** — the
  routing table has exactly `lo0` and `10.99`. It is **static**, not DHCP: the
  base-1996 `/usr/lbin/dhcpclient` cannot enumerate the 1997 `btlan3` driver's
  DLPI PPA (`get_ppa_info: Failed to locate lan0 in ppa info`) and never sends a
  packet; the usual fix is a `PHNE_*` patch, which cannot be installed because
  SD-UX is broken on this guest. The address is the one the retronet DHCP server
  reserves for this MAC, so the reservation stays valid and unused.
- Containment is proven: gateway reachable, `spacejam.com` resolves to the
  gateway, labhost `10.99.0.1` 100 % loss (the `HPUXRN-IN` guard chain),
  `1.1.1.1` *Network is unreachable*.
- **`/etc/rc.config.d/netconf.prern`** is the pre-retronet copy of the config.

## Golden, input, and rollback

- Reset mode: `loadvm golden` (baked 03:57 with QMP `savevm`; 98.5 MiB
  vmstate; restore proven framebuffer-identical bar the front-panel clock, and
  the guest is live afterwards). `SH_IDLE_PAUSE_SECS=60`, launcher starts the
  guest `-S` at the checkpoint.
- Baked into the guest: `/.vue/sessionetc` = `xset m 1 1` (pointer 1:1);
  `/etc/vue/config/sys.resources` `Vuesession*saverTimeout: 0` and
  `lockTimeout: 0`; `/etc/vue/config/Xconfig` `Vuelogin*autoLogin: root`
  (unverified on a cold boot — the checkpoint restores a logged-in desktop);
  hostname `hpuxvue`, TZ EET, root without password (recorded in the gitignored
  credential stores as `guest/hpuxvue`).
- Kernel is the media's generic recovery `vmunix` (works; `mk_kernel` from
  `/stand/system` never ran — optional future tidy-up, keep a copy first).
- Catalog gotchas checked: there is NO `/etc/nsswitch.*` on 10.20 (that fix is
  11.x); LVM growth stays `lvextend`+`extendfs` (756 MB spare in vg00).
- Pointer: a **closed loop over the Artist hardware cursor** since 2026-08-30.
  See "The pointer is a closed loop" below.
- Exec channel: none over the network, but there **is** a working serial
  console now. QEMU's `-serial` is the guest's *second* RS-232C port
  (`ioscan -fnC tty`: `8/0/63`→`tty0p0`, `8/16/4`→**`tty1p0`**), and
  `/etc/inittab` carries `s1:234:respawn:/usr/sbin/getty -h tty1p0 9600`, so
  `serial.sock` in the station dir gives a root shell (no password;
  `/etc/profile` asks for `TERM` — answer `dumb`). Wiring `labctl exec` to it is
  a small separate job. Two traps: the line editor mangles command lines past
  ~70 characters, and the QEMU serial socket serves **one client at a time**, so
  connect momentarily and never hold it.
- Automation path for a future builder: HP's install runs a config from the
  CD's INSTALLFS (`post_load_cmd`/`post_config_cmd` hooks — the "user
  specified script" seen on camera is HP's own); patching that config is the
  scripted-install route instead of driving the TUI.
- Credentials reference only: `guest/hpuxvue`.
- Rollback: `systemctl stop streamhost@hpuxvue`; the install disk is a single
  station-local qcow2 — delete it and the launcher re-creates an empty one.


## The pointer is a closed loop (2026-08-30)

The B160L has no absolute pointer device — LASI PS/2, relative only, no USB, no
tablet — so this station spent its first fortnight on the daemon's dead-reckoning
`dbus-rel` bridge. It no longer does. HP-UX 10.20's X server drives the Artist
framebuffer's **hardware cursor**, which means the guest continuously publishes
its own idea of the pointer position into the Artist `CURSOR_POS` / `CURSOR_CTRL`
registers. That is a sensor, so the control loop closes *inside QEMU*: the engine
in `hw/display/artist.c` (patch
`streamhost/qemu-patches/0008-artist-closed-loop-pointer.patch`) reads the
guest's own position back, takes the error against the daemon's absolute target,
and injects one bounded step of relative counts per window until it converges.

`absolute: true` on this station is therefore **earned by measurement**, not
provided by a device. The daemon states targets over the `artistptr/1` dialect on
`ptr.sock` and reckons nothing.

Why this station was the cheapest of its wave: `artist_get_cursor_pos()` already
did the register→pixel decode in upstream QEMU, the back-porch term it depends on
is forced to a constant by `artist.c` itself, `cursor_pos`/`cursor_cntrl` were
already in `vmstate_artist`, and hppa B160L has exactly one graphics path. So
there was **no adapter swap, no new migration state and no golden re-bake** — the
2026-08-24 golden still restores unchanged.

**Measured facts** (sandbox clone, never the live station):

| thing | value | how |
|---|---|---|
| hotspot, VUE arrow | `(2,1)` | top-left **and** bottom-right screen clamps, agreeing exactly, both with proof-of-motion |
| gain | ~1.9 px per injected count | see the `xset` note below; only a step sizer |
| convergence | 8–15 windows, 0 give-ups | `STAT` counters at 7 targets |
| accuracy | 7/7 targets at `--tol 1` | three independent observers, below |

### Read the position through `artist_get_cursor_pos()`, never the raw registers

`CURSOR_CTRL`'s low nibbles (`(&0xf0)>>4`, `&0x0f`) are an **offset** that the
accessor subtracts to reach the drawn sprite origin. They are *not* a hotspot.
A loop closed on a private decode of `CURSOR_POS` lands every target a constant
8 px to the left — and the raw register and the framebuffer still agree with each
other **exactly**, `err +0,+0`, at every target. This is worth internalising
beyond this station: *two observers agreeing is not proof*. Only the **commanded
target** is the third observer that separates "self-consistent" from "correct",
which is why every proof run here reports all three.

### `xset m 1 1` is NOT in effect on the current golden — a live-fleet caveat

The old open-loop configuration carried `SH_CURSOR_SCALE=1.0`, justified by
`/.vue/sessionetc` running `xset m 1 1` at session start (measured 2026-08-18:
50 units → 50 px). **Measured again 2026-08-30 on the 2026-08-24 re-baked golden:
50 units → ~96 px, i.e. ~1.9x — X's default acceleration is back and the `xset`
that the 1.0 depended on is not taking effect on this login path.** The re-bake
silently invalidated the open-loop assumption, so the station shipped a pointer
that overshot by ~2x on every dead-reckoned move.

The closed loop makes this irrelevant — gain only sizes the engine's steps, and
accuracy comes from the register readback, so a wrong gain costs convergence
windows and never accuracy. It is recorded here because it is a **live-fleet
inaccuracy that predates and is independent of this work**: any station still on
`dbus-rel` whose scale was calibrated before a golden re-bake may have the same
problem, and a re-bake is not currently required to re-measure it.

### Traps this port had to solve (none transfer from aix432 or irix)

- **"Pinned" must be verified, not inferred.** Under TCG the guest consumes PS/2
  packets on its own schedule, so three windows can elapse with motion still
  queued and a naive homing step concludes on a mid-flight reading — recording an
  impossible hotspot and reporting it as exact. Homing requires proof of
  **motion** *and* proof of **place** (within one sprite of the corner, the only
  place it can be if pinned), and every path that records a hotspot bounds it to
  the sprite. It reports `hot_exact=0` over `STAT` when it cannot establish the
  value rather than asserting a default.
- **A reconnecting session usually finds the pointer already parked in the
  corner**, where stillness is indistinguishable from a wedge. Homing therefore
  kicks *outward* first so the subsequent stillness means something.
- **Bounded in-flight gate.** Never issue a step while the previous one is
  unconsumed, bounded at 6 windows or a screen clamp wedges the loop forever.
  Without it: give-ups and 9–35 px misses.
- **Settle before declaring convergence.** A target can look reached while counts
  are still queued; those counts then carry the pointer past it, usually into a
  clamp it cannot return from.

### Idle-pause is the common path here, not an edge case

The engine's window timer is `QEMU_CLOCK_VIRTUAL`, so it does not tick while the
guest is stopped — and this station starts `-loadvm golden -S` **and**
idle-auto-pauses after `SH_IDLE_PAUSE_SECS=60`. A returning visitor therefore
always meets a paused guest. `MOVEA` acks on *accept* rather than on convergence
precisely so a pause cannot stall the daemon's ack pipeline. Verified: `STAT`
answers while paused (reporting `running=0`), `MOVEA` acks in 40 ms while paused,
and the loop converges on the commanded target after `cont` with zero give-ups
and exact framebuffer agreement.

### Proof (rule 9)

Seven targets — desktop background, both screen edges, a File Manager icon, the
Mosaic title bar, a front-panel button and the Toolboxes frame — commanded
through the engine, each checked by three independent observers (commanded
target; the engine's own `STAT` sensor plus measured hotspot;
`scripts/dev/cursor-locate.py` on a QMP screendump, which sees only pixels).
**7/7 within `--tol 1`, zero give-ups, `hot_exact=1`.** Plus a click at the VUE
front panel that switched workspace One→Two and repainted 88.4% of the screen,
and the same again after a pause/resume cycle.

### Debugging

Arm the three traces together and turn them off after: `SH_ARTISTCTL_TRACE`
(daemon wire), `PTR_TRACE` and `PTR_TRACE_POS` (engine windows and readings, via
the launcher's `-global artist.ptr-trace*`). `STAT` over `ptr.sock` reports
reading, hotspot and whether it was *measured*, home state, target, gain, queue
depth, re-aims, give-ups and the guest runstate.

**Single injector (binding).** While the control socket is connected the engine
owns the guest pointer: no rel bridge, no QMP `input-send-event`, no `labctl`
pointer helper. Two injectors and the loop reads motion it did not cause.

## The keyboard is NOT broken: it is a FOCUS trap in the baked scene

Opened 2026-08-31 while verifying the restore-re-arm fix, and CLOSED the same
day. The earlier heading here said "the keyboard does not reach this guest" and
called it a second independent fault. **That was wrong, and this is the
correction.** There is one real fault (the pointer freeze, fixed) and one
usability trap that imitates a second one.

**What the trap is.** The golden bakes **Mosaic** as the focused window — VUE
paints the focused title bar pink and the rest cyan, and Mosaic's is pink in the
checkpoint. This VUE session moves keyboard focus only on a **title-bar/frame**
click, not on a client-area click. So a visitor clicks a File Manager icon (it
visibly selects — the click is working), types, and sees nothing: the keys are
going to Mosaic, which does nothing visible with bare letters or arrows. It
reads exactly like a dead keyboard.

**Proof that the keyboard is fine** (clone, this station's own golden, same
device set):

- click the File Manager's TITLE BAR -> 61731 changed pixels, and the title bars
  swap: Mosaic pink -> cyan (sampled at (300,15): `[253,130,130]` -> `[122,202,197]`).
  Focus has moved.
- arrow keys immediately after -> **976 changed pixels**, the icon selection
  moves. The keyboard works.
- the same arrow keys BEFORE the title-bar click -> 0 pixels.

**And the keys were never the problem end-to-end.** With `SH_INPUT_TELEMETRY=1`
armed, a browser typing `khive` produced matching `[key-tel dbus] recv` **and**
`sent` pairs for `0x25 0x23 0x17 0x2f 0x12` — correct XT set1 codes, delivered
to QEMU within ~3 ms. Browser -> daemon -> D-Bus is healthy. (Telemetry is off
again; it is diagnostic only and logs every visitor keystroke to journald.)

**What is still open, and it is the PRE-EXISTING one.** Through the real SPA the
title-bar click does **not** land on the live station — Mosaic stays pink — while
the identical click lands on the clone. The title bar abuts the window frame,
which is the region named by the standing finding *"hpuxvue: engine cannot hold
the pointer on resize borders"*. So today a visitor cannot perform the one
gesture that would give them the keyboard. Client-area clicks land normally
(1359 px, an icon selects), so this is specific to the frame region.

**Two ways out, neither taken here** (a recapture needs the operator's word, and
hpuxvue's only rollback on record is still the 2026-08-24 one):

1. Re-bake the golden with the File Manager focused, or with dtwm's focus policy
   set to pointer (focus-follows-mouse), so no frame click is needed at all.
   Cheapest for the visitor; costs a checkpoint.
2. Fix the resize-border hold in the engine, which the standing finding wants
   anyway and which would also restore drag-on-frame. **Attempted 2026-08-31 and
   NOT deployed** — the premise did not survive measurement (the engine holds the
   title bar perfectly: one reading over 17 s, `giveups=0`, and the sprite does
   not even change there), and the obvious fix made things worse (a 425 px miss).
   The measurements and what a working fix must do are in
   [`../lab/HPUXVUE-CURSOR-REGISTER-POINTER.md`](../lab/HPUXVUE-CURSOR-REGISTER-POINTER.md).

**And a caution about the click itself.** Some harness runs lose the title-bar
click 0/5 or 0/6 with the engine demonstrably innocent — `aiming=0`,
`giveups=0`, the reading on target, and the trace showing `edge btn1 DOWN/UP
applied` for the very click that had no effect. Other runs, including an
interleaved control, land 6/6 on the title bar and 6/6 in the client area. The
variable is NOT: click position (a five-point y-sweep failed together), approach
direction (five start points failed together), startup vs mid-session restore,
a stale held button (a leading bare `UP1` does not help), hotspot drift (there is
none), or an idle gap (20 s still lands 4/4). It is unexplained. Measure a rate
over repeated trials before believing any single click result on this station —
one anecdote either way will mislead you.

Do not file this as a keyboard regression again. The check that settles it in
one step is the title-bar colour at (300,15): pink means Mosaic still owns the
keyboard and your keys are going there.


## BLOCKED: the focus-policy re-bake cannot be executed, and why that matters

Attempted 2026-08-31, authorised, **not done**. The plan was to set vuewm's
`keyboardFocusPolicy` to `pointer` (focus-follows-mouse) so no frame click is
needed to hand the visitor the keyboard, then recapture. It is blocked on the
setting, not on the recapture: there is no working route to change vuewm's
configuration inside this guest.

Routes tried, all dead ends:

| route | outcome |
|---|---|
| serial getty (`tty1p0`) | a shell WAS alive (`echo` returned `KHTEST_1019`), then stopped executing mid-session; input still echoes, no prompt, and **no getty respawn** |
| VUE Style Manager (front panel) | the Window button accepts the click and turns to an hourglass — then nothing renders, watched for **7+ minutes** |
| Toolboxes -> General | the cell selects (37565 px) but never opens, single or double click |
| File Manager `File` / `Actions` menus | **do not post**, even press-and-HOLD (Motif menus post on press) |
| Mosaic URL field | unresponsive, **0/5** clicks |
| retronet exec | this station has no exec channel (documented) |
| offline edit of the disk image | HP-UX HFS/VxFS is not mountable on the Linux host |

**The finding that outgrew the task.** Those rows are not six unrelated
annoyances. With a positive control on BOTH sides in the same session — a File
Manager icon click measuring **1363 px before and 1359 px after** — the two menu
presses in between measured **107 px** (the label highlight only) and **0 px**.
So the instrument was working throughout and *the menus genuinely do not post*.

Everything that fails needs an X **pointer grab** (menus post under a grab,
drawer/toolbox panels open under one, and a window-manager frame click takes
one). Everything that works — selecting an icon in a client area — needs no
grab. That is a coherent hypothesis and it is bigger than a focus policy: it
would also explain why the title-bar click is intermittent while client-area
clicks are 6/6. It is UNPROVEN; what is proven is the pattern above.

**Do not re-attempt the focus-policy re-bake before settling that.** If grabs are
broken, focus-follows-mouse removes the need for the one gesture that needs a
grab, so it may still be the right fix — but it cannot be *applied* until
something inside the guest can run a command.

**The cheapest unblock** is the one the retronet write-up already names as "a
small, separate piece of work": wire `labctl exec` to the serial getty. That
gives a command channel that does not depend on the GUI, and every route above
failed for want of exactly that.
