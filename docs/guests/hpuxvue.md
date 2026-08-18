# hpuxvue guest — HP-UX 10.20 with HP VUE (HP 9000/778, PA-RISC)

Status: **INSTALLED — HP VUE desktop reached 2026-08-18 02:45, dark-launched** (production, `listing=hidden`, slot 144 /
UDP 54144). `/os/hpuxvue` streams the installer live; nothing is baked yet.
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
| NIC | `tulip` on user-mode net |
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
  `set_parms`**: standalone (no network), hostname `hpuxvue`, TZ EET, no root
  password, no font server. Then **`vuelogin`** (HP greeter) → root → **HP VUE
  3.0 desktop**: front panel, six workspaces, Helpview welcome, File Manager.
- Pointer: guest gain measured 50 units → 96 px on both axes = plain X
  acceleration (2×, threshold 4), i.e. `xset m 1 1` gives 1:1 and
  `SH_CURSOR_SCALE=1.0` is right. QMP `mouse_move`/`mouse_button` clicks
  Motif buttons reliably.

## Golden, input, and rollback

- Reset mode: `restart` during install (re-runs the launcher only when QEMU is
  not live). Becomes `loadvm golden` once baked; `SH_IDLE_PAUSE_SECS` 0 → 60
  at the same time.
- Pointer gain, click/drag proof, keyboard modifiers: TODO after install.
- Known post-install steps (catalog): copy `/etc/nsswitch.files` →
  `/etc/nsswitch.conf` or the login manager hangs; grow filesystems with
  `lvextend`+`extendfs`.
- Credentials reference only: `guest/hpuxvue`.
- Rollback: `systemctl stop streamhost@hpuxvue`; the install disk is a single
  station-local qcow2 — delete it and the launcher re-creates an empty one.
