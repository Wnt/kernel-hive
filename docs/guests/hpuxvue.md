# hpuxvue guest — HP-UX 10.20 with HP VUE (HP 9000/778, PA-RISC)

Status: **INSTALL PHASE, dark-launched** (production, `listing=hidden`, slot 144 /
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
  the kernel cannot see the bus. Fix in flight: swap disc1 for the July-1997
  **ACE Install/Core disc for B/C/J class** (`B3782-10178`).

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
