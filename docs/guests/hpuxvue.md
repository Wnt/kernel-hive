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
- Pointer: `SH_CURSOR_SCALE=1.0`, click/drag/wheel and keyboard modifiers left
  to the operator's browser eyeball (`reset.mouse` = UNVERIFIED on purpose).
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
