# MASTER-REPRODUCE — rebuild the whole lab on the real NVMe box, fast

_Single ordered runbook. Each phase names the exact script/command and marks what is
**automated** vs **interactive**. The design intent is: **rebuild every live streamhost
guest from its upstream or explicitly supplied source media** — each has a
self-contained `scripts/build-guests/tiles/<key>.sh` that obtains its source, drives the
install automation, injects the era software, and framebuffer-verifies the GUI
(Phase 4). No image backups required. The old `zfs send` image-restore is retained
below only as a **historical migration shortcut**; its source box no longer exists._

> **2026-07-15 execution result:** the rebuilt host is **`labhost`
> (`labhost.lan`)**, IP **192.0.2.10**. The NVMe migration completed through
> verification, and Phase 2's pool/dataset/storage setup ran via
> `scripts/provision/pve-zfs-pool.sh` exactly as documented, unmodified.

Companion docs (read for the *why* behind each step):
`docs/lab/REMOTE-PROVISIONING-NOTES.md` (bare-metal
gotchas), and the per-guest notes in `docs/guests/<os>.md`.

**Standing rules:** always fetch **latest-stable** tools/ISOs; **PXE/HTTP** installs,
never baked ISOs; **zvols, never qcow2-on-ZFS**; the gallery/tiles sit behind the
**edge passkey** only (no WAN exposure).

Legend:  🟢 automated (one command)   🟡 interactive / needs a human   ⚙️ config choice

---

## Phase map (run top-to-bottom)

| # | Phase | Script / command | Mode |
|---|-------|------------------|------|
| 0 | HW acceptance / burn-in | `scripts/provision/hw-acceptance.sh` | 🟢 + 🟡 (memtest, BMC) |
| 1 | PXE/HTTP Proxmox install | `scripts/provision/` Range server + iPXE/answer templates | 🟡 |
| 2 | ZFS pool + datasets + storages | `scripts/provision/pve-zfs-pool.sh` | 🟢 |
| 3 | Streamhost daemon build (gallery CT retired) | repo at `/data/vms/streamhost` + `cargo build --release` | 🟢 |
| 4 | **Build every production streamhost tile (PRIMARY; roster from `registry/tiles/`)** | `scripts/build-guests/build-all.sh` | 🟢 (default public-media set plus SDK/licensed-media opt-ins; some guests need a one-time click) |
| 4′ | _Historical shortcut (NOT the plan):_ copy prebuilt images off the pre-wipe host | `scripts/provision/preserve-guest-images.sh --all` | archival; source retired |
| 5 | Wire the registry production roster as streamhost tiles + serve plane (parity-gated by `scripts/dev/verify-emit.sh`) | `streamhost/tiles-manifest.sh` → `streamhost/bring-up-all.sh` (+ `scripts/serve/`) | 🟢 |
| 6 | Optional standalone Win11 + macOS VM recreations (SPA exhibits stay posters) | `scripts/provision/pve-win11-vm.sh` / `pve-macos-vm.sh` | 🟢 / 🟡 |
| 7 | Post-install hygiene | inline below | ⚙️ |
| 9 | **Perf rollout — DONE** (TCG→KVM + audio-buffer knob) | baked into the Phase-4 builders + Phase-5 tile launchers; results doc retired (see git history) | 🟢 (already in Phases 4–5) |

> **Phase 9 (perf) is not a separate run** — its outputs are already carried by the Phase-4
> `build-guests/tiles/*.sh` (per-OS `-enable-kvm`/`ACCEL=kvm` + the Win9x recipe) and the Phase-5
> per-tile launchers (`qemu-streamhost.sh`, emitted from `streamhost/tiles-manifest.sh`, which
> carries each tile's `-enable-kvm -cpu host` + audio wiring). A fresh Phase 4→5 run reproduces
> the tuned (KVM) gallery directly. In the neko era the same tuning lived in the
> `gallery-integrate-all.sh` manifest rows + the gallery-wide `launch-qemu.sh` audio/KVM plumbing
> (neko-era, deleted in the 2026-07 restructure — git history). The before→after measurement and
> per-tile deltas lived in `docs/perf-rollout-results.md` (neko-era doc, likewise retired —
> recover from git history if needed).

This file covers the **host + guests + gallery** fast path. Offsite backups
(sanoid + restic) are a later, separate step — see the NVMe migration plan's
Phase 7 checklist.

---

## Phase 0 — Hardware acceptance (USED box: BEFORE trusting it) 🟡

```bash
# from the freshly-netbooted rescue env or the just-installed host:
scripts/provision/hw-acceptance.sh
```
7 gated phases: BMC/SEL audit + **rotate the default ADMIN password**, memtest86+ ≥4
passes (🟡 via IPMI virtual media — no network output, read Pass/Errors off the KVM),
prove ECC active via `skx_edac`, nested-virt check, CPU soak (throttle/MCE=0), SMART +
fio + NVMe thermals + etcd-fsync<10 ms on the PLP drive, iperf3 per NIC, power, final SEL.
**Do not proceed past any HARD FAIL.** Firmware is already latest (BIOS 2.2 / BMC
01.74.13 — do NOT reflash). Historical pre-wipe result: memtest 1 pass / 0 errors.

---

## Phase 1 — PXE/HTTP Proxmox VE 9.2 install 🟡

**No baked ISO** (user preference). Netboot the installer via the proven iPXE-via-Redfish
chain, fetch a Proxmox **answer file** over HTTP. Full mechanics in
`REMOTE-PROVISIONING-NOTES.md` ("The netboot direction" + "iPXE netboot — BUILT & WORKING").

1. Create a private serve directory and run
   `scripts/provision/isoserver.py <serve-dir>` (defaults to `0.0.0.0:58080`). It is
   HTTP/1.1, advertises `Accept-Ranges: bytes` on HEAD, serves byte ranges, and accepts
   Proxmox's answer-file POST. Stock `python3 -m http.server` FAILS the BMC HEAD.
2. Mount the tiny generic **iPXE** ISO via Redfish virtual media
   (`/redfish/v1/Managers/1/VirtualMedia/CD1`), **`mc watchdog off`**, boot override
   **`UsbCd` / `UEFI` / `Once`**, `power reset`. iPXE `chain`s to the HTTP
   `boot.ipxe` rendered from `scripts/provision/boot.ipxe.tmpl`.
3. Point the Proxmox auto-installer at an HTTP **answer file**:
   render `scripts/provision/pve-answer.toml.tmpl`, validate it, then use
   `proxmox-auto-install-assistant prepare-iso --fetch-from http --url …
   --pxe-loader ipxe --output …`. The assistant emits the PXE kernel/initrd/prepared-ISO
   set consumed by the chain template. Edit the served answer per tweak; the complete
   preparation and Redfish commands are in `scripts/provision/README.md`. **Create the
   `--output` directory first**; the assistant does not create it. During the real
   migration, these artifacts were prepared on the old Linux host and pulled to the Mac.
4. Install **PVE 9.2**, **ext4 + LVM on the Kingston DC2000B (PLP)** — the durability tier
   (reserved for future non-gallery workloads).
   The executed answer used keyboard `fi`, FQDN `labhost.lan`,
   `lvm.swapsize=8`, `lvm.maxroot=32`, `lvm.maxvz=0`, disk filter
   `ID_SERIAL_SHORT=EXAMPLE0000000000` (replace with your own drive's serial, e.g. from
   `smartctl -i`), and NIC filter `*020000000001`.
5. ⚙️ **BIOS:** enable **Above 4G Decoding** (+ Resizable BAR) & a large MMIO High Base —
   the historical pre-wipe host logged `failed to assign` PCI BARs (SR-IOV VF MMIO); verify
   `dmesg | grep -i "failed to assign"` is empty post-install.
6. **Nested virt:** `echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf;
   modprobe -r kvm_intel; modprobe kvm_intel` → confirm
   `/sys/module/kvm_intel/parameters/nested` = Y. (Also `options kvm ignore_msrs=Y` in
   `/etc/modprobe.d/kvm.conf` now — macOS needs it in Phase 6.)
7. **Pin NIC names, then rewrite networking yourself.**
   `pve-network-interface-pinning` produces `nicN` names and does not rewrite
   `/etc/network/interfaces`. Keep `interfaces.pre-pinning`, run the tool, then update
   the bridge port manually. This box's uplink is `nic3`, MAC `02:00:00:00:00:01`.

Automated bits: the netboot chain + answer file make this near-hands-off after the one
Redfish mount; the **memtest** and **watching the KVM** are the interactive parts.

---

## Phase 2 — ZFS bulk pool + datasets + storages 🟢

```bash
# on the host (prefer a by-id device path so the pool survives renumbering):
DEV=/dev/disk/by-id/nvme-WD_BLACK_SN7100_1TB_xxxx scripts/provision/pve-zfs-pool.sh
```
Creates pool `data` on the **WD SN7100** (`ashift=12`, **lz4** pool-wide — the
architecture pick for the no-PLP bulk drive; the historical pre-wipe pool used **zstd** only to squeeze
its tiny 83.5 G pool), `atime=off xattr=sa dnodesize=auto`, **caps ARC at 16 GiB**
(persistent + live — the pre-wipe host had a wrong inherited 4 G cap), installs a weekly
`zpool trim` timer, creates the datasets `vms` / `isos` (1M/zstd-1) / `backups` (zstd-3) /
`pvcs` / **`gallery-guests`** (zstd — where Phase 4 lands the images), and registers the
PVE storages **`data`** (zfspool: images+rootdir) and **`isos`** (dir). Idempotent; will
not destroy an existing pool. ⚙️ Override `COMPRESSION=`, `ARC_MAX_GIB=`, `DEV=` as needed.

**Execution result (2026-07-15):** this script ran exactly as shown, worked
unmodified, and created the Phase-2 pool, datasets, ARC/trim configuration, and PVE
storages.

---

## Phase 3 — Streamhost daemon build (the gallery CT is retired) 🟢

**The gallery no longer runs inside an LXC.** Guests are host-level QEMU processes
captured and streamed by the Rust `streamhost` daemon (one `streamhost@<tile>` systemd
unit per tile) — there is no Docker/neko CT to provision. The neko-era deploys
`scripts/pve-osgallery-deploy.sh` and `scripts/pve-osgallery-hardened.sh` (neko-era,
deleted in the 2026-07 restructure — git history) are superseded; the validated
least-privilege KVM-in-LXC findings they encoded are preserved for reference in
`docs/lab/REMOTE-PROVISIONING-NOTES.md` ("HARDENED nested-KVM-in-LXC").

What Phase 3 is now: mirror the repo's `streamhost/` tree to the host at
`/data/vms/streamhost/` and build the daemon there. (The serve plane is NOT in
that tree — its canonical source is the repo's `scripts/serve/`, copied to the
host in Phase 5.)

```bash
# on the host (repo checkout under /data/vms/streamhost/build/):
cd /data/vms/streamhost/build/streamhost/streamhost
nice -n15 cargo build --release
install -m 0755 ../target/release/streamhost \
  /data/vms/streamhost/build/target/release/streamhost  # binary shared by all tiles
```

**Build prerequisite:** the x264-sys crate runs bindgen, which needs libclang on
the box — `apt install libclang1-19 libclang-common-19-dev` (also observed on the
historical pre-wipe host 2026-07-14). If the build can't find it, set
`LIBCLANG_PATH=/usr/lib/llvm-19/lib`.
Install the matching formatter component as part of the Rust setup:
`source /root/.cargo/env && rustup component add rustfmt`.

See `streamhost/README.md` for the daemon architecture and
`scripts/dev/build-deploy.sh` for the routine rsync+build+restart workflow from the
workstation. The checked-in versioned unit is applied only through the supervised
`scripts/dev/migrate-to-versioned.sh` procedure documented in
`streamhost/deploy/VERSIONED-INSTALL.md`; never copy it over the live legacy unit
ad hoc. Tile wiring itself is Phase 5.

---

## Phase 4 — Build every live streamhost guest (THE PRIMARY PATH) 🟢

This is the point of the whole kit: **reproducible install scripts, not image backups.**
Each guest has a self-contained `scripts/build-guests/tiles/<key>.sh` that, on a fresh host with
the Phase-2 infra, does the whole thing END TO END once any gated source is supplied:
obtain the upstream ISO/image → create the disk → drive the install automation (answer
file / autounattend / QEMU-monitor sendkeys / VNC taps / offline hive+FAT edits) → inject the era software →
land the bootable artifact in `/data/gallery-guests/<DIR>/` → framebuffer-verify the GUI.
Public sources are fetched from their canonical URLs; gated sources are the explicitly
staged exceptions listed below.

```bash
# on the host (or over SSH to it), after Phase 2:
export WATCOM=/root/watcom WATCOM_ROOT=/root/watcom
export PATH="$WATCOM/binl:$PATH"
scripts/build-guests/build-all.sh                 # build all 25 tiles needing no staged media
scripts/build-guests/build-all.sh --list          # the manifest: dir / class / est-time / automation
scripts/build-guests/build-all.sh --only 9front   # rebuild just one (any class)
scripts/build-guests/build-all.sh --class fast    # just the cheap live-ISO exotics
SFOS_VDI=/media/SailfishOS.vdi \
  scripts/build-guests/build-all.sh --with-media  # add the two-stage Sailfish build
XP_ISO_LOCAL=/isos/xp.iso SOL10_ISO=/isos/sol10.iso \
  scripts/build-guests/build-all.sh --include-licensed   # add WinXP + Solaris
FORCE=1 scripts/build-guests/build-all.sh --only win95     # force a rebuild of one guest
```
OpenWatcom 1.9 lives at **`/root/watcom`** on `labhost`; it arrived inside
`/root` in `oldbox-final.tgz`. The obsolete `/opt/watcom` path never existed.
The explicit environment above overrides legacy builder defaults.

The orchestrator runs the per-guest scripts in a cheap-first order (live exotics →
retro Win/DOS → heavy compiles/installs), times each, continues past failures (unless
`--fail-fast`), and prints a pass/fail summary. It **never** kills anything or touches
CT 110 or the deleted Win11/macOS VMIDs — each per-guest script owns its own namespaced run
dir, unique VNC/monitor sockets, and pidfile/monitor-`quit`-only teardown. Every script
is idempotent (`FORCE=1` to rebuild, `--skip-verify` to skip the boot test). See the
**Automation coverage** table below for what's hands-off vs. what has a one-time click.

> **Staged media is skipped by default and reported in the summary.** Sailfish needs an
> emulator VDI/archive obtained through the Sailfish SDK/account flow; stage it and pass
> `--with-media` (plus `SFOS_VDI=` or `SFOS_EMULATOR_URL=`). WinXP and Solaris 10 CDE
> need user-supplied licensed ISOs; pass `--include-licensed` plus their environment
> variables. An explicit `--only <key>` opts that key in without either aggregate flag.

### Phase 4′ — HISTORICAL shortcut: copy prebuilt images (NOT the plan)

**This is not the reproduce path — Phase 4 (full rebuild from the builders) is.**
This shortcut was available only while the pre-wipe source host existed. It is no
longer runnable after the 2026-07-15 cutover and is kept solely to explain the old
migration option; Phase 4 remains the source of truth for every guest.

```bash
# DO NOT RUN: historical shape only; the source no longer exists:
SSH_KEY=~/lab_key SRC=root@<oldbox> DST=root@<newbox> \
  scripts/provision/preserve-guest-images.sh --all           # gallery guest dataset
#   ... --gallery                                   # just the Kernel Hive guest dataset
```
`zfs send | zfs recv` copies `data/gallery-guests` (including child
`.../postmarketOS`); `--vms` can additionally copy a selected VM's zvols and
`qm config` only when that VM still exists on the source. Source read-only bar transient
snapshots; running VMs untouched
(`PRESHUTDOWN=1` for a guaranteed-clean copy). `--rsync-gallery` for a non-ZFS target;
`--dry-run` previews; incrementals via the kept `@migrate-*` snapshot.
VM 900 (Win11, deleted 2026-07-08) and VM 925 (macOS, deleted 2026-07-14) are
not available as copy shortcuts. Their `pve-*.sh` scripts are optional standalone
recreate paths; recreating a VM does not turn its SPA showcase poster into a live tile.

After restore, on DST:
```bash
zfs list data/gallery-guests            # -> mounted at /data/gallery-guests
```

### Automation coverage — per production tile (Phase 4 builders)

Across its default and media opt-in modes, `build-all.sh` sequences a builder for
**every production tile in the canonical registry**
(key↔tile mapping where they differ: `9front`→ninefront, `win98`→win98se,
`msdos-win1`→msdoswin1, `android-x86`→android, `amigaos`→osId aros;
`sailfishos` needs BOTH stages; the 4 bridge tiles share the `bridge-base`
prerequisite). Status legend: **hands-off** = builds to a verified GUI with
zero human input · **one-time-click** = a single one-time in-guest
click/calibration · **licensed-ISO** = fully scripted once you supply the
copyright/SSO-gated source.

| Tile (build key) | Status | Residual manual step | Est. build |
|---|---|---|---|
| alpine (`alpine`) | ✅ hands-off *(proven full path)* | none — upstream ISO → `/data/isos/Alpine.iso` | ~2–3 m |
| tinycore (`tinycore`) | ✅ hands-off *(proven full path)* | none — upstream ISO → `/data/isos/TinyCore.iso` | ~2–3 m |
| reactos (`reactos`) | ✅ hands-off | none — live ISO fetch, FB-verified to desktop | ~3–5 m |
| toaruos (`toaruos`) | ✅ hands-off *(proven live)* | none — live ISO | ~3 m |
| haiku (`haiku`) | ✅ hands-off *(proven full path)* | none — `haiku-install.sh` runs the ISO stage, installs `haiku-persist.qcow2`, provisions sshd/gallery key, applies the fixture, and proves `savevm`→dirty→`loadvm` | ~6–10 m |
| amigaos / AROS (`amigaos`) | ✅ hands-off | none — latest AROS pc-i386 boot ISO, FB-verified | ~3–5 m |
| helenos (`helenos`) | ✅ hands-off *(proven live)* | none — live ISO auto-boots to compositor | ~3 m |
| kolibrios (`kolibrios`) | ✅ hands-off | none — live CD, self-lands on GUI | ~2–3 m |
| ninefront (`9front`) | ✅ hands-off | none — plan9.ini suppresses every prompt → rio | ~5–8 m |
| android (`android-x86`) | 🟡 one-time-click | installer keystrokes + 8 SetupWizard tap coords weren't persisted → nudge on first run (screenshot-gated) | ~20–40 m |
| solariscde (`solaris-cde`) 🔒 | licensed-ISO | supply OTN ISO (`SOL10_ISO=`) **and** `INSTALL_GUEST=1` for a supervised first install; post-install→CDE tail fully automated | ~40–60 m |
| win2000 (`win2000`) | ✅ hands-off | 🟡 *runtime* only: per-boot "Found New Hardware" → Cancel. Era SW best-effort | ~15–30 m |
| winxp (`winxp`) 🔒 | licensed-ISO | supply XP ISO (`XP_ISO_LOCAL=`/`XP_ISO_URL=`); then fully unattended | ~30–50 m |
| win311 (`win311`) | ✅ hands-off | none — patched AUTOEXEC boots straight to Program Manager | ~10 m |
| win95 (`win95`) | 🟡 one-time-click | first-boot PnP click-through (one-time, in-guest). Netscape skipped if no mirror | ~15–25 m |
| win98se (`win98`) | 🟡 one-time-click | worst-case one "Browse to C:\WINDOWS\OPTIONS\CABS" click (usually self-completes). GTA1 staged | ~15–25 m |
| freedos (`freedos`) | ✅ hands-off | 🟡 *runtime* only: Arachne's 1st-run VESA mode click (CTMOUSE loaded). Wolf3D staged/broken (non-fatal) | ~10–15 m |
| msdoswin1 (`msdos-win1`) | ✅ hands-off | none — genuine from-floppy DOS 6.22 build + Win 1.01 SETUP, all archive.org-fetched | ~10–15 m |
| os2warp (`os2warp`) | ✅ hands-off | none — archive.org prebuilt Warp 4 + scripted first-boot taming (TCG) | ~20–30 m |
| qnx (`qnx`) | ✅ hands-off | none — archive.org LiveCD; Photon first-run flow driven scripted, FB-proofed | ~5–10 m |
| sailfishos (`sailfishos` + `sailfishos-gui`) | SDK-media opt-in; then hands-off | obtain the emulator VDI/archive through the Sailfish SDK/account flow, set `SFOS_VDI=` or `SFOS_EMULATOR_URL=`, and pass `--with-media`; the two scripted stages then run in order | ~35–70 m |
| templeos (`templeos`) | ✅ hands-off | none — upstream ISO fetch + checksum + FB-verify | ~2–3 m |
| serenityos (`serenityos`) | ✅ hands-off | none, but **heavy**: from-git toolchain+OS compile in a privileged `nesting=1` LXC (CTID 112) | ~20–60 m |
| postmarketos (`postmarketos`) | ✅ hands-off *(live-verified)* | none — `postmarketos-fixture.sh` runs the raw-image builder, converts/provisions qcow2+OVMF vars, types PIN 147147, and bakes `golden` | ~12–25 m |
| — bridge base (`bridge-base`) | ✅ hands-off | none — shared read-only kiosk base (VICE+hatari+cap32 + bare-X); build **once** before the four bridge tiles | ~20–30 m |
| c64 (`c64`) | ✅ hands-off | none — thin overlay on `bridge-base`; VICE x64sc auto-boots the GEOS 2.0 deskTop → golden bake | ~3–5 m |
| atarist (`atarist`) | ✅ hands-off | none — thin overlay; hatari auto-boots EmuTOS → GEM desktop → golden bake | ~3–5 m |
| apple2 (`apple2`) | ✅ hands-off | none — thin overlay; LinApple auto-boots Apple GEOS → golden bake | ~3–5 m |
| amiga (`amiga`) | ✅ hands-off | none — thin overlay; FS-UAE auto-boots Kickstart 1.3 + Workbench 1.3 → golden bake | ~3–5 m |

🔒 = `licensed` class, skipped unless `--include-licensed`. The production roster
and its current total come from `registry/tiles/` (`python3
scripts/tiles-registry.py count`); `build-all.sh` reports any media-gated rows it
skips. Approximate default serial time is **3–4.5 h**.

#### Emulator-bridge tiles (the reusable "captured-Linux" bridge)

The four home-computer tiles (`c64`, `atarist`, `apple2`, `amiga`) are **not** native
QEMU guests — each is a **captured Debian 12 kiosk** running a period emulator
full-screen, so streamhost captures the Linux framebuffer + AC97 audio exactly like
every other tile. They share ONE read-only base image (`bridge-base.sh` →
`/data/vms/bridge/bridge-base.qcow2`, carrying VICE(x64sc)+hatari+cap32 + a bare-X
kiosk); each tile is a thin `overlay.qcow2` on that base with an INTERNAL `golden`
snapshot (`-loadvm golden` = boot straight to the desktop). Build order therefore is
**`bridge-base` first, then the four tiles** (already encoded in `DEFAULT_ORDER`).
The reusable pattern — base build, kiosk launcher gotchas (true-drive, no real
fullscreen, the AC97-modal trap, the x64sc-needs-a-tty segfault), the bridge device
set (ide overlay + e1000 hostfwd + conditional `-loadvm golden`), and the golden-fixture
`tile.env` stanza — is documented in **`streamhost/docs/BRIDGE.md`** and
**`docs/guests/c64.md`** (the reference tile).

The SPA also has showcase posters outside the live production roster. Run
`python3 scripts/tiles-registry.py count` for the current split (currently 30
production tiles and 3 posters: Win11, RISC OS, and macOS). VM 900 was deleted
on 2026-07-08 and VM 925 on 2026-07-14;
RISC OS lost its RPCEmu/neko transport when that plane was retired. The Win11 and
macOS `pve-*.sh` scripts remain optional VM recreation paths (Phase 6), not live-tile
integration paths.

---

## Phase 5 — Wire every live guest as a streamhost tile + serve plane 🟢

The neko/docker-compose integrator `scripts/gallery-integrate-all.sh` — which itself
superseded `retro-guests-add.sh` + `exotic-guests-add.sh` — is gone (neko-era, deleted
in the 2026-07 restructure — git history). Tiles are now wired natively on the host by
the streamhost kit:

```bash
# on the host (root), streamhost tree at /data/vms/streamhost (Phase 3), guests built (Phase 4):
cd /data/vms/streamhost
bash tiles-manifest.sh --install     # emit every tile's per-tile files (tile.env,
                                     # qemu-streamhost.sh, ROLLBACK.md) + drop streamhost@.service
rsync -a <repo>/scripts/serve/ /data/vms/streamhost/serve/
                                     # serve plane files — canonical source is the repo's
                                     # scripts/serve/ (NOT in the streamhost/ tree);
                                     # bring-up-all.sh step 0 fails loud without them
bash bring-up-all.sh                 # ordered boot: launch each tile's QEMU (pidfile),
                                     # wait for its QMP socket, start streamhost@<tile>,
                                     # then start the HTTPS serve plane
```

- **Patched QEMU (prerequisite for Phase 5).** Tiles run on the box's
  `pve-qemu-kvm` (11.0.2-1, apt-held). It is patched from source by
  `scripts/provision/build-pve-qemu-fastpoll.sh`, which appends the streamhost quilt
  patches after the final numbered pve patch: fast-poll `pve/0047`
  (`SH_DBUS_UPDATE_MS` display capture), serial-Sphinx `pve/0048`, and the
  `gallery-hid-pci` device `pve/0049` (`streamhost/qemu-patches/0003-gallery-hid-device.patch`;
  PCI `1b36:0015`, class `ff00`). The gallery-hid device is REQUIRED to launch
  and `-loadvm golden` the `solariscde` tile (its golden carries the
  `gallery-hid-pci` VMState); it is an optional, `CONFIG_GALLERY_HID`-guarded
  device that is inert for every other tile, so the one rebuilt binary serves
  the whole fleet. Build the `.deb`, stage the stock same-version `.deb` as
  rollback, `dpkg -i` the patched deb, then relaunch tiles per
  `streamhost/qemu-patches/README.md` (running QEMUs keep the old binary until
  relaunch).
- **`streamhost/tiles-manifest.sh`** is generated from the production entries in
  the canonical registry; it invokes `streamhost/scripts/streamhost-tile.sh` per tile to emit
  `/data/vms/streamhost/tiles/<tile>/`. It does NOT start anything. **Every tile now
  emits completely — no hand-patched launchers remain**: generic tiles are generated
  from flags; the golden-fixture / bridge / state-disk tiles install VERBATIM
  launchers tracked at `streamhost/tiles/<tile>/qemu-streamhost.sh` (+ their
  golden-fixture `tile.env.fixture` stanzas). The postmarketos writable
  `OVMF_VARS.qcow2` seed is performed by the manifest itself post-emit; serenityos's
  per-boot overlay create lives inside its (verbatim) launcher.
- **The other three SPA exhibits are posters, not missing manifest rows.** Win11,
  RISC OS, and macOS use the SPA `showcase` transport and make no connection attempt.
  Recreating VM 900 or 925 alone does not add a streamhost transport.
- **Parity gate: `scripts/dev/verify-emit.sh`** — emits the registry production roster into a scratch
  dir on the box (`/tmp`, never live paths) and byte-diffs each `tile.env` +
  `qemu-streamhost.sh` against `/data/vms/streamhost/tiles/<tile>/`, with a
  justified whitelist (`scripts/dev/verify-emit-allow.diffpatterns`) for intentional
  deltas. Run it after ANY change to the manifest/emitter/tracked launchers; every
  production row must report PASS or PASS*.
  On a fresh pinned rebuild, run it directly on the box as
  `bash scripts/dev/verify-emit.sh --local --pin-machine`.
- **Machine-type pinning:** `labhost` was emitted with pinning **ON** —
  `SH_PIN_MACHINE=1 bash bring-up-all.sh` (or `tiles-manifest.sh --pin-machine`) —
  so every launcher carries `pc-i440fx-11.0`/`pc-q35-11.0` explicitly (identical
  resolution on today's QEMU 11.0.x) and the new goldens
  survive a future QEMU alias retarget (savevm/loadvm needs an exact device-set
  match).
- **`streamhost/bring-up-all.sh`** does the full ordered boot (light guests first) and
  finally starts the serve plane. Guest images must already exist under
  `/data/gallery-guests/` (Phase 4), plus the two LiveCD ISOs at their canonical
  paths `/data/isos/Alpine.iso` + `/data/isos/TinyCore.iso` (the pre-2026-07-14
  live launchers pointed at retired CT110/spikeA paths; the emitted ones use
  `/data/isos/`).
- **Serve plane: `scripts/serve/`** (mirrored to `/data/vms/streamhost/serve/` above) —
  `osgallery-https-server.py` serves the SPA bundle + `tiles.json` signaling over HTTPS
  on **:8443**. Before running `gen-local-ca.sh`, restore the gitignored
  `scripts/serve/pki/rootCA.key` (mode 600) together with its fingerprint-matched
  `rootCA.pem`; the script then reuses that root and issues a fresh leaf. Do not create
  a new root when clients already trust the carried one. Install the systemd
  supervisor so the server auto-starts on boot:
  `ssh lab 'bash /data/vms/streamhost/serve/install-https-service.sh'` (enables
  `osgallery-https.service`); thereafter restart via `restart-https.sh` or
  `systemctl restart osgallery-https.service` (see `scripts/serve/README.md`).
  The SPA bundle is built from `spa/` and deployed into the webroot.
- Afterwards, regenerate the labctl capability matrix: `ssh lab 'labctl gen'`.

Guest-level notes that survive the neko→streamhost cutover: **XP is deduped to
`WinXPpro/`** (canonical: autologon→Administrator desktop, IE8, ZDoom+Doom, D: =
retro-software.iso; the `WinXP/` and `WinXP-usermedia/` dirs are contested duplicates —
dispose after verifying the tile points at WinXPpro). **SerenityOS** boots a per-run
writable qcow2 overlay over the read-only golden `_disk_image` (its Ext2FS root must be
writable or the kernel panics) — its launcher recreates the overlay itself on every
launch. **postmarketOS** is UEFI (OVMF pflash) — the manifest seeds the writable
`OVMF_VARS.qcow2` varstore once (qemu-img convert of `OVMF_VARS_4M.fd`; the launcher
attaches it `format=qcow2`). **Sailfish IS wired now** (`sailfishos` tile, bochs-drm KMS GUI
image from `scripts/build-guests/tiles/sailfishos-gui.sh`) — the old "renders black in plain
QEMU" blocker belonged to the deleted VirtualBox builder path. The four
**emulator-bridge home computers (c64, atarist, apple2, amiga)** are captured-Linux
bridge tiles — see `streamhost/docs/BRIDGE.md`.

Gallery: `https://<box>:8443/` (the neko-era `http://<edge>:8080/gallery-guests.html`
landing page is gone).

---

## Phase 6 — Optional standalone Windows 11 + macOS VM recreations

These recipes recreate standalone lab VMs only. **Win11, RISC OS, and macOS remain
SPA showcase posters** until a new live transport is implemented; none is part of the
registry-generated production streamhost manifest.

- **Windows 11 (900)** — VM 900 was **deleted on 2026-07-08**. To recreate the
  standalone VM from scratch:
  ```bash
  SSH_KEY=~/lab_key STORAGE=data scripts/provision/pve-win11-vm.sh
  ```
  Hands-off autounattend install (q35 + OVMF + Secure Boot + TPM 2.0 + VirtIO; injects
  ENTER to defeat the OVMF CD prompt; polls the guest agent). There is no current RDP
  bridge or SPA binding to it; the Win11 exhibit stays a poster after recreation.
- **macOS Sequoia (925)** — VM 925 was **deleted on 2026-07-14**. The script remains
  a proven optional standalone recreate path:
  ```bash
  VMID=925 OSVER=sequoia scripts/provision/pve-macos-vm.sh create
  VMID=925 scripts/provision/pve-macos-vm.sh shot 20        # framebuffer check
  ```
  There is no current VNC/WebSocket or streamhost binding; the macOS exhibit stays a
  poster after recreation.
  (Historical: the Tahoe experiments on VMs 920–923 hit a Recovery-Assistant HID
  blocker; they were superseded by the proven Sequoia recipe.)

---

## Phase 7 — Post-install hygiene ⚙️

- **Kill the "No valid subscription" nag** + switch apt to **pve-no-subscription** (deb822)
  — see `scripts/provision/README.md` for the exact `sed`/sources.
- **Swap/zram cushion** (the pre-wipe host had 0 B swap) and confirm the **ARC cap** took
  (`cat /sys/module/zfs/parameters/zfs_arc_max` → 16 GiB) — Phase 2 sets both.
- **`lm-sensors`** (`sensors-detect`, load `coretemp` + NVMe thermal) — the pre-wipe host was
  flying blind on temps.
- ⚙️ **Untrusted-guest posture** (the gallery boots arbitrary ISOs): decide L1TF/MDS — SMT
  off or `kvm-intel.vmentry_l1d_flush=always` vs. accepting single-tenant lab risk.
- Watch **EDAC** once RAM is loaded: `journalctl -k | grep -i edac` (climbing *correctable*
  = early bad-DIMM signal).
- **UPS**: single PSU + no PLP on the bulk drive + no RAID → a clean shutdown is the main
  corruption defence. Buy the ~700 VA UPS.
- Then stand up **sanoid + restic → UpCloud fi-hel1** for offsite backups (see the NVMe
  migration plan's Phase 7 checklist).

---

## Gaps / still-manual (be honest)

**How close to one-command reproduce?** The **host + gallery** path is essentially
**four commands** — `pve-zfs-pool.sh` → `build-guests/build-all.sh` →
`streamhost/tiles-manifest.sh --install` → `streamhost/bring-up-all.sh` (plus the
one-time `cargo build --release` of the daemon, Phase 3). The neko-era chain
(`pve-osgallery-hardened.sh` → `gallery-integrate-all.sh` ×2 around one CT reboot) is
gone (neko-era, deleted).
For the full production roster, stage the external-media sources and add
`--with-media --include-licensed`; without them the build runs only the default
public-media subset.
The **primary** Phase-4 path (`build-all.sh`) needs no pre-wipe source host: it fetches public
sources and clearly skips inputs that must be staged. The `preserve-guest-images.sh`
copy (Phase 4′) was only a historical shortcut and is no longer available; deleted
VMs 900 and 925 could not be copied even then. It is NOT zero-touch end-to-end; these
steps still need a human:

1. **Phase 1 bare-metal install is interactive.** The Redfish iPXE mount, `mc watchdog
   off`, watching the HTML KVM, and **memtest** (no network output) all need eyes/hands.
   Everything after "Proxmox is installed + SSH-reachable" is scripted.
2. **Phase-5 emit is complete — the golden bake sources are now vendored too.**
   All registry production tiles emit from `tiles-manifest.sh` (verbatim tracked launchers for the
   fixture/bridge/state-disk tiles; the postmarketos varstore seed is in the manifest;
   serenityos's overlay create is in its launcher) and `scripts/dev/verify-emit.sh`
   proves byte-parity with live. The seven formerly box-only bake drivers are now at
   `streamhost/tiles/{alpine,kolibrios,solariscde,templeos,tinycore,win95,win98se}/golden-bake.sh`
   with their tile-local QMP/setup auxiliaries; postmarketOS's two fixture helpers are
   vendored beside its launcher and wired by `scripts/build-guests/tiles/postmarketos-fixture.sh`.
   Haiku's formerly manual persistent install is `scripts/build-guests/tiles/haiku-install.sh`
   (on-box proven through sshd/key persistence and dirty→`loadvm golden` restoration).
   The remaining curated first boots use these helpers/builders rather than unrecorded
   box state; Sailfish SDK media and licensed images still require their supplied
   sources as noted above.

   **Mandatory bootstrap order for android/freedos/ninefront:** their normal launchers
   contain unconditional `-loadvm golden`, so QEMU refuses a truly fresh disk before a
   snapshot exists. (1) build the disk; (2) launch the launcher's exact device set once
   with only `-loadvm golden` omitted; (3) reach/curate the fixture and issue QMP HMP
   `savevm golden`; (4) stop that bootstrap QEMU through its pidfile/QMP, then use the
   tracked normal launcher unchanged. Do not add a temporary device while baking—the
   saved VM state must match normal boots. All conditional-golden launchers may simply
   cold-boot normally for their first bake.
   (The old "one CT reboot to activate the bind-mount" gap died with the neko CT.)
3. **macOS has an optional VM recipe, not a live SPA path**:
   `scripts/provision/pve-macos-vm.sh` builds/drives a standalone Sequoia VM 925 headless
   (Phase 6), but the deleted VM and bridge mean the SPA exhibit remains a poster.
   Historical blocker for the
   record: on the Tahoe/macOS-26 experiments (VMs 920–923, destroyed) **HID input into
   the Recovery Assistant did not register** (OpenCore `USBPorts.kext`
   port-map vs QEMU `qemu-xhci`; four fixes tried — `docs/guests/macos.md` §6).
   macOS remains **very
   laggy** (no Metal/GPU) — fine for headless build/CI, not interactive Simulator work; and
   the **iOS Simulator stays on a Mac** regardless.
4. **postmarketOS tile host prep and bake are now one runnable path**:
   `scripts/build-guests/tiles/postmarketos-fixture.sh` runs the existing upstream-image
   builder, converts `pmos-phosh.img` to the live qcow2, invokes the vendored offline
   provisioner, boots/unlocks phosh, and saves `golden`. It is UEFI (OVMF pflash); the
   writable **`OVMF_VARS.qcow2`** varstore is seeded by `tiles-manifest.sh` post-emit
   (idempotent safety net in `bring-up-all.sh` step 3). Root MUST be **AHCI/NVMe**
   (no `virtio_blk` in the initramfs). Unlock PIN **147147**. The live tile boots the
   qcow2 disk (`pmos-phosh.qcow2`, golden-fixture, no snapshot=on) — the builder's
   raw `pmos-phosh.img` is the pristine source it was converted from.
5. **Solaris 10 CDE** has **no dtlogin autologin** — the tile launcher must auto-type
   `root<CR>solaris<CR>` ~90 s after boot, or it sits at the greeter (default session is
   already CDE). License: Oracle OTN dev license — free to use in this private collection
   (personal use behind edge auth); just don't re-distribute the copyrighted ISO via the
   GitHub repo.
6. **FreeDOS Arachne** first-run needs **one mouse click** to pick a video mode (CTMOUSE is
   loaded); could be pre-seeded for true zero-click.
7. **Windows 11 and RISC OS are showcase posters.** VM 900 was deleted on
   2026-07-08 and its RDP bridge is gone; `qm start 900` is therefore not a valid
   gallery step. `scripts/provision/pve-win11-vm.sh` can recreate a standalone VM, but does not
   supply a SPA transport. RISC OS likewise has no streamhost tile after its RPCEmu/neko
   path was retired.
8. **Sailfish OS is wired but its source media is gated.** The `sailfishos` streamhost
   tile uses the bochs-drm KMS GUI image from `scripts/build-guests/tiles/sailfishos-gui.sh`;
   the old "renders black in plain QEMU / VirtualBox-GPU-locked" blocker belonged to
   the retired VBox builder. A fresh build still requires an emulator VDI/archive from
   the Sailfish SDK/account flow, so the default orchestrator skips both stages until
   `--with-media` is passed.
   **SerenityOS is wired too** — built from source, boots a per-run writable qcow2
   overlay over the read-only golden `_disk_image` (its Ext2FS root must be writable, or
   the kernel panics at `StorageManagement::create_first_vfs_root_context`). Do NOT boot the
   golden image read-write: a hard kill mid-write corrupts the ext2 superblock.
9. **On-box-only builds — NOW REPRODUCED as repo scripts.** These guests were originally
   built with ad-hoc **on-box helper scripts** under `/data/gallery-guests/<OS>/`. That
   ad-hoc work has since been **distilled into self-contained repo reproducers** under
   `scripts/build-guests/` (Phase 4) — **Win 3.11, Win 95, Win 98 SE, Win 2000, WinXPpro,
   FreeDOS 1.3, 9front, Solaris 10 CDE, Android-x86 9, postmarketOS**, plus the exotics
   (KolibriOS, ToaruOS, HelenOS, SerenityOS). So retiring the pre-wipe host did not lose
   them — a fresh host rebuilds each from source via `build-all.sh`. The residual
   caveats per guest are in the **Automation coverage** table (Phase 4): the genuine
   one-time human touches are win95/win98 first-boot PnP, android-x86 coordinate
   calibration, obtaining Sailfish SDK emulator media, and supplying the WinXP/Solaris
   licensed ISOs. `preserve-guest-images.sh` (Phase 4′) is retained only as a historical
   record of the now-ended copy window.

**BMC/CMOS status (from provisioning):** the BMC ADMIN password was rotated in-band
on 2026-07-15 and is recorded privately in `docs/gallery-credentials.md` under `## BMC`;
the dead CMOS battery was replaced during the NVMe install. Firmware is EOL-latest
(don't reflash).
