# PC-BSD 1.5.1 integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, PC/GEOS 18 min): integrate **PC-BSD 1.5.1
"Edison"** (FreeBSD 6.3-RELEASE + KDE 3.5.8, i386, 23 April 2008 — the last
PC-BSD release before iXsystems' 7.x) as a fully featured Tier-1 host-native
station `pcbsd`. Branch `pcbsd` is the ledger; every stream branches from it.
Concurrent waves on the box: netbsd14 (176), openbsd (177), freebsd411 (178) —
this wave was allocated **179** by the coordination session; landing on main is
serialized through it ("ready to land pcbsd" → "go pcbsd").

## Proven in the spine (coordinator, alone)

- Media: archive.org item `pcbsd-1.5.1-x-86-cd-1`, file `PCBSD1.5.1-x86-CD1.iso`,
  **688930816 bytes**, sha256 in `/data/assets-staging/pcbsd/MANIFEST.sha256`
  (labhost path). CD1 alone installs the base system + KDE; CD2 was optional PBIs.
- Smoke boot on the reactos device set (`pc-i440fx-11.0`, KVM, `-cpu host`,
  1024 MB, `-vga std`, IDE disk + IDE cdrom, AC97 dbus audio, usb-tablet):
  X.org came up at 1024x768 at 26 s, the Qt installer ("Select Language and
  Keyboard") at ~35 s after power-on. Frame: `/data/vms/sandbox/pcbsd/smoke/frame2.png`
  (shipped as the placeholder hero).
- Dark-launched at `/os/pcbsd` via `smoke-rig.sh pcbsd --like reactos --slot 179`
  (rig `/data/vms/sandbox/pcbsd/smoke/`, `run-daemon.sh` restarts the daemon
  after every guest relaunch).

## Allocation ledger (claimed on labhost by session `pcbsd`)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `pcbsd` |
| slot / UDP / VMID label | 179 / 54179 / 179 (allocated by the coordination session; X11 warp forward, if ever needed, 127.0.0.1:6079 = display :79) |
| render orders | as assigned by `stations-registry.py new --like reactos` (duplicates with sibling waves are fixed in THIS entry at landing, then regenerate) |
| upstream | archive.org `pcbsd-1.5.1-x-86-cd-1` / `PCBSD1.5.1-x86-CD1.iso` (688930816 bytes; the builder pins the sha256 from MANIFEST.sha256) |
| builder output | `/data/gallery-guests/PCBSD/pcbsd.iso` (pinned CD1) + `pcbsd.qcow2` (installed, pristine, no golden) — install is GUI, so the builder is `automation: assisted` |
| station dir | `/data/vms/streamhost/stations/pcbsd/` — `disk.qcow2` = the ONLY block device, carries the `golden` vmstate; no cdrom at runtime |
| device set | `pc-i440fx-11.0`, KVM, `-cpu host`, 1024 MB, 1 vCPU, `-vga std`, IDE disk index 0, AC97 + dbus audiodev, PS/2 relative mouse only (usb-tablet dropped: inert in FreeBSD 6.3 X); **no NIC** |
| screen | 1024x768 (X.org 7.3 vesa on the Bochs VGA) |
| guest accounts | root / `kernelhive`; user `visitor` / `kernelhive`, KDM autologin (credentialsRef `guest/pcbsd`) |
| pointer | **`rel` (PS/2)** — measured by the golden stream: the usb-tablet is inert in FreeBSD 6.3 X (installer and KDE); PS/2 relative moves with X acceleration ≈3.5 px/unit under KDE, ≈2 px/unit in the installer. The tablet was dropped from the device set (the validator forbids an inert absolute device next to a `rel` method) and the golden re-baked without it |

## Streams (each: `scripts/dev/wt.sh new <name> --from pcbsd`, commit on its branch, push, 4-minute stop)

| Stream | Model | Deliverables |
|---|---|---|
| `golden` (runs on the smoke rig, not a worktree) | Fable | drive the installer, reboot without cdrom, KDE first-run + autologin + no screensaver, `savevm golden`, one `loadvm` proof, stage `disk.qcow2` into the station dir; reports pointer transport, VM_SIZE/VM_CLOCK, time to desktop |
| `pcbsd-build` | sonnet-low | `scripts/build-guests/tiles/pcbsd.sh` (fetch CD1 from archive.org, verify sha256, stage `pcbsd.iso`, create `pcbsd.qcow2` 8G and print the assisted-install instructions — do not attempt to automate the GUI), `check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` row |
| `pcbsd-spa` | Fable | `registry/posters/pcbsd.md` in the museum's voice, hero from a real KDE frame when the rig shows one (else the installer frame), `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa` polish (drop the `TODO(spa)` prefixes), a `demoProgram` typed into the focused editor |
| `pcbsd-docs` (after golden reports) | sonnet-low | `docs/guests/pcbsd.md` incl. §Checkpoint from golden's report, `docs/GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index |

## Reserved to the coordinator

Merging, "ready to land" → `git push origin HEAD:main` from this sandbox worktree,
`box-deploy.sh --apply`, `smoke-rig.sh pcbsd --down`, `station-up.sh pcbsd`,
SPA build/deploy, final framebuffer acceptance, teardown of stream sandboxes.

## Golden stream report (measured)

- Install: installer wizard driven over QMP with PS/2 relative moves (driver
  `/data/vms/sandbox/pcbsd/smoke/drv.py`); copy phase ~4.5 min; whole-disk ad0,
  default KDE components; installer sets KDM autologin itself.
- First boot: one-time Display Settings wizard (vesa 1024x768x24 autodetected —
  "Apply" test fails, "Skip" keeps the working default); no Kpersonalizer; KTip
  and Konsole tips unchecked; `~/.kde/Autostart/noblank.sh` (`xset s off -dpms`),
  kdesktoprc ScreenSaver disabled. No xorg.conf written.
- Golden: VM_SIZE 388 MiB, VM_CLOCK 0:11:40, one loadvm proven pixel-identical.
  Fixture = clean desktop, Konsole focused at an empty `%` prompt, pointer at (450,680).
- Shared with the freebsd411 wave: PC-BSD's own X + KDM autologin need nothing
  hand-written; the usb-tablet route is dead on FreeBSD ≤6 — plan for `rel`.

## Measured milestones

Filled at landing from `scripts/dev/session-timeline.py`.
