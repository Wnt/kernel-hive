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
- Display: **`-vga cg3`** — SunOS 4.1.4 has no driver for QEMU's default TCX.
- Storage: SCSI target 0 = 4 GB qcow2 system disk, SCSI target 2 = install CD.
- NIC: `lance` + slirp user net.
- Input: relative pointer only (Sun serial mouse); `SH_INPUT_BACKEND=dbus-rel`.
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

**Keyboard-in-X: known limitation (SKIP).** Even with the console tty, xnews
grabs the mouse but not the keyboard under QEMU sun4m: keystrokes reach the
guest kernel (escc channel A make/break codes are correct) but are not
delivered to X clients. Keyboard works at the console and via `labctl exec`.
Candidate fixes for a follow-up: how xnews takes `/dev/kbd` from the console
(KIOCSDIRECT), or a QEMU escc keyboard tweak. The exhibit is mouse-driven and
does not depend on it.

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
