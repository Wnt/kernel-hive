# macOS on Proxmox VE 9.2 (no-GPU Xeon-D) — historical install and recreate notes

Host: `192.0.2.10` (Supermicro, Xeon D-2146NT / Skylake-D, **no GPU**), single
ZFS pool `data` (83.5 GiB, shared). Companion script: `scripts/provision/pve-macos-vm.sh`.

## Current status (2026-07-14)

The macOS VM and its VNC/WebSocket bridge were permanently deleted on
2026-07-14. The SPA tile is now a showcase poster with no live backend.
`scripts/provision/pve-macos-vm.sh` remains the proven optional recreation path if a live
macOS guest is wanted again.

Everything below is the historical build record and recreation recipe; VMID 925
references describe the deleted guest or an explicit future recreation.

## Historical verdict (2026-07-04) — SOLO RUN, VMID 925: **BOOTED DESKTOP ACHIEVED** ✅

**A fully booted macOS Sequoia (15) desktop with a local admin ran as VMID
925.** It was end-to-end, screenshot-verified via a fully scriptable VNC-driven flow:
OpenCore → Recovery → Disk Utility (erase APFS "Macintosh HD") → Reinstall macOS
Sequoia (working `en0`/DHCP/internet) → multi-reboot install (OpenCore
auto-selects the installer entry each reboot) → first boot → Setup Assistant
(renders and is drivable) → **logged-in Finder desktop**.

Delivered state before deletion (snapshotted `data/vm-925-disk-*@golden-desktop`):
- Local admin **`admin`** / password `<REDACTED-see-private-notes>` — `uid=501`, in group `80(admin)`,
  `sudo` verified.
- **Auto-login enabled** (`sysadminctl -autologin set -userName admin ...`) →
  boots straight to the desktop.
- Final on-disk footprint ~14.5 GiB; pool `data` at 64%.

The recipe WORKS; the only thing that ever stopped earlier attempts was **pool
space**, now solved (see reclamation section).

### The two fixes vs. the earlier fan-out recipe
1. **Drop `-cpu Skylake-Server-v4` from `--args`.** The old script appended it,
   which overrides `--cpu host` and black-screens the kernel (MP-rendezvous
   spinlock). Rely on `--cpu host` only. This was THE blocker for the GUI.
2. **Use Sequoia, and manage the tiny 83.5 GiB pool aggressively** (destroy dead
   attempts, `discard=on` on the target, wipe host-side between attempts).

### Earlier fan-out verdict (superseded, kept for context)
The 4-way fan-out reached "install writing to disk" but no booted desktop, and
pinned the blockers below.

**Closest / recommended path = OSX-KVM OpenCore + Sonoma recovery (fan-out approach
"prebuilt-image", VMID 923).** It ran, screenshot-verified, all the way to a REAL
macOS install **actively writing to the target disk** — booted OpenCore, rendered a
fully-drivable Recovery, erased the disk to APFS in Disk Utility, brought up
networking, launched Reinstall, and reached the progress bar. It stopped for **one
reason only: not enough free pool space** for the ~24 GiB transient install peak on
the shared box. That path is now encoded in `scripts/provision/pve-macos-vm.sh`. On a box with
>= ~25 GiB dedicated free space it should run through to Setup Assistant unchanged.

**The single remaining blocker to a finished install: ~25 GiB of dedicated free pool
space.** Everything upstream of it is solved and scripted.

---

## THE key discovery: Tahoe vs. everything else

macOS **Tahoe (26) black-screens on QEMU's unaccelerated `vmware`-VGA**. WindowServer
starts (the mouse cursor renders and can move) but it **never composites** the
Recovery / Disk-Utility / Setup-Assistant windows — no GPU-less Metal path exists for
26's UI. Because the GUI never draws, the target disk is never written. **This is
exactly where the prior 6h agent and three of the four fan-out approaches died.**

macOS **Sonoma / Sequoia / Monterey** via the version-agnostic **OSX-KVM** OpenCore
DO render and ARE fully drivable on this same no-GPU box. **=> Use Sonoma, not Tahoe.**

> An earlier note claimed the Tahoe *Recovery* GUI rendered with
> `Skylake-Server-v4 + vga vmware + 4 cores`; the later fan-out could not reproduce a
> usable Tahoe GUI (cursor-only, no compositing) and additionally hit dead HID input.
> Treat Tahoe-on-this-box as **not viable**; the reliable path is OSX-KVM + Sonoma.

---

## The four fan-out approaches — how far each got

| VMID | approach | furthest point reached | why it stopped |
|------|----------|------------------------|----------------|
| **923** | **prebuilt-image (OSX-KVM + Sonoma)** | **Real install WRITING to disk** (OpenCore renders, Recovery fully drivable, disk erased to APFS, en0+DHCP up, Reinstall progress bar) | **Shared pool space** — ~24 GiB transient peak wouldn't fit. Method sound. |
| 922 | startosinstall | Full boot to launchd userspace via **`-cpu host`**; single-user **root shell**; proved scriptable **disk write** (`dd` 52 MB to target, ZFS grew) | (1) installer is a 38 MB **stub, no SharedSupport** payload; (2) **no en0** (bundled OpenCore has no network kext); (3) Tahoe GUI won't composite. |
| 924 | vnc-ocr | Tahoe graphical **boot logo + progress bar**, then black desktop w/ live cursor | Tahoe **WindowServer spins 300-400% forever**, never draws Recovery UI on vmware-VGA. Found the `-v` verbose-console hang + scripted fix. |
| 921 | monitor-input | (report incomplete — VM still running at handoff) | n/a — see cleanup below. |

Reusable sub-findings from the dead ends:
- **`-cpu host` fixes an MP-rendezvous spinlock** the emulated `Skylake-Server-v4`
  triggers on this Xeon-D at 2/4 cores (922). Kept in the script's PVE `--cpu host`;
  the applesmc `-cpu Skylake-Server-v4` in `--args` is what the guest actually sees.
- **Cores must be a power of 2** (2/4/8). Non-power-of-2 (e.g. 6) hangs boot.
- **NIC `e1000-82545em` gives NO `en0`** on modern macOS (922 + 923 both confirmed).
  **`vmxnet3`** brings `en0` up with DHCP + working internet. This is mandatory for
  the Reinstall download.
- **OpenCore verbose `-v` boot-arg can freeze the recovery on a text console** (924).
  The OSX-KVM OpenCore used by 923 does not have this problem; if you hit it, mount
  the ESP and `sed -i 's/ -v//' EFI/OC/config.plist`.
- **fetch-macOS `-s high-sierra` no longer yields an older OS** — Apple serves the
  latest recovery for the injected board-id, so you can't shrink the footprint that
  way. Sonoma is the OSX-KVM "RECOMMENDED" target and renders well.

---

## The validated pipeline (what `scripts/provision/pve-macos-vm.sh` does)

1. Reuse the existing OSX-KVM checkout at
   `/data/gallery-guests/macos-prebuilt-image/OSX-KVM` (has `OpenCore/OpenCore.qcow2`
   + `fetch-macOS-v2.py`), or clone it. **No re-download of the existing /data/isos.**
2. `fetch-macOS-v2.py -s sonoma` -> `BaseSystem.dmg` -> `dmg2img` -> `BaseSystem.img`.
3. `qm create` q35/OVMF/applesmc, **`vmxnet3`** NIC, **`vga vmware`**, MacPro7,1
   SMBIOS, `--cpu host`, applesmc `--args` (with the Skylake-Server-v4 flags).
4. Import OpenCore (ide0) + recovery (ide2), add a blank **48 GiB sparse** virtio0
   target, boot order `ide0;ide2;virtio0`.
5. Boot; set VNC password via QMP; `socat`-bridge the PVE VNC unix socket to a
   **unique** TCP port; drive with `vncdo` (`move/click/type/key/capture`).
6. Disk Utility: erase target -> APFS "Macintosh HD". Reinstall macOS -> Continue ->
   Agree -> pick disk -> install runs (downloads ~14 GiB, writes ~24 GiB peak).
7. On completion it self-reboots into Setup Assistant -> create the local admin.

**Drive everything by real framebuffer screenshots, never logs** — the prior agent's
core mistake was trusting monitors/logs over pixels. Menu coordinates drift between
point releases; re-verify each step with a `capture` before the next blind send.

### Creating the local admin (Setup Assistant)
Either drive the wizard (Country -> Continue; skip Migration/AppleID/analytics/Siri;
type name + short name + password) with the same `vnc move/type/key` primitives, or
bypass it headless on the installed volume:
```
dscl . -create /Users/admin ; dscl . -passwd /Users/admin '<pw>'
dscl . -append /Groups/admin GroupMembership admin
touch /var/db/.AppleSetupDone
```

---

## Reclaiming a stale/failed install (the pool-pressure trap) — 2026-07-04

On this 83.5 GiB pool the biggest operational hazard is a **half-written install**
left on the target zvol. Two hard-won rules:

1. **Never "resume" a half-written install by re-running Reinstall on a non-empty
   target.** The installer counts the stale `macOS Install Data` (~28 GiB) as
   occupied and then demands *an additional ~16 GiB it cannot get* ("not enough
   free space to upgrade the OS"). It will not reuse the staged payload.
2. **Wipe host-side, don't TRIM-in-guest.** A thin zvol does NOT shrink just
   because you erase the APFS volume unless `discard=on` is set AND the guest
   issues UNMAP. The fastest, most reliable reclaim is to destroy+recreate the
   zvol from the Proxmox host (VM stopped):
   ```
   qm stop 925
   qm set 925 --delete virtio0
   zfs destroy data/vm-925-disk-3            # frees the ~26 GiB instantly
   qm set 925 --virtio0 data:48,discard=on,cache=unsafe
   qm set 925 --boot order='ide0;ide2;virtio0'
   ```
   Then boot Recovery, erase the fresh disk to APFS, and install **clean in one
   pass** with a healthy pool. Always create virtio0 with `discard=on` so future
   Disk-Utility erases can reclaim blocks too.

## Disk-space math (the actual blocker)

- Pool `data` = 83.5 GiB; 85% cap ≈ 71 GiB usable.
- Reinstall **downloads ~14 GiB AND writes the OS while the payload is still present**
  => **~24 GiB transient peak** on the target zvol (a finished install settles ~20 GiB).
- The script **aborts** unless the pool is < 85% AND has >= 25 GiB free, and you should
  run a `zfs`/`zpool` watchdog that `qm stop`s the VM if the pool crosses ~83%
  (a validated `watchdog.sh` is in `/data/gallery-guests/macos-prebuilt-image/`).
- To free space on the shared box before a run: **destroy the old stuck VM 920**
  (see below) and confirm no other agent VMs are live.

---

## Disk reclamation status (2026-07-04)

Checked host state after the fan-out:

- **Failed approaches cleaned up correctly** — no leftover zvols for VMID **922, 923,
  924**. `zfs list -t volume` shows only `vm-900-*`, `vm-920-*`, `vm-921-*`.
- Work dirs remain under `/data/gallery-guests/` (scripts + proof screenshots only,
  a few MB): `macos-prebuilt-image` (KEEP — has the validated `reproduce-macos.sh`,
  `vnc.sh`, `watchdog.sh`, and the reusable `OSX-KVM/` checkout), `macos-startosinstall`,
  `macos-vnc-ocr`, `macos-monitor-input`. Safe to keep; delete the latter three if
  space is ever tight.
- **VM 921 (`macos-mon921`, "monitor-input" approach) was still RUNNING** at handoff
  and its report was incomplete — it belongs to another concurrent agent. **Not
  touched.** If it is confirmed abandoned, `qm stop 921 && qm destroy 921 --purge`
  reclaims ~1.3 GiB (its `vm-921-disk-3` recovery img) + RAM.
- **VM 920 (`macos-tahoe`) — the old stuck VM — should be DESTROYED.** It is the prior
  6h dead-end (Tahoe, black-screen, disk never written), still running and holding
  8 GiB RAM. Its zvols are small (~1.3 GiB total). Reclaim with:
  ```
  qm stop 920 && qm destroy 920 --purge
  ```
  (Left running here only because the task scoped VM 920 as out-of-bounds to touch;
  flag it to the operator to destroy — it frees RAM and a boot slot for a real run.)

> **Historical 2026-07-04 snapshot.** VMs 920 and 921 no longer existed; the only
> qm VM then was **925**. That VM was subsequently deleted on 2026-07-14.

Untouched, in-use *(at the time)*: VM 900 (win11, 18.7 GiB — since deleted),
CT 110 (osgallery), CT 112 (serenity-build).

---

## Honest caveats

- **No GPU = no Metal.** Even a successful Sonoma install is **software-rendered and
  laggy**; fine for headless/CI over VNC, not for interactive Simulator work. (Tahoe's
  UI won't render at all — that's the whole reason to use Sonoma here.)
- **Coordinates are brittle** — the `do_drive` clicks are 1280x800-specific and drift
  across point releases. The robust variant is to reach Utilities > Terminal and use
  `diskutil eraseDisk APFS Macintosh GPT diskN` + a scripted reinstall instead of
  pixel-clicking Disk Utility.
