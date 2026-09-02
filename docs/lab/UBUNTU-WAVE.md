# Ubuntu 4.10 Warty Warthog integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, pcgeos 6/14/18): integrate **Ubuntu 4.10
Warty Warthog** — the first Ubuntu (October 2004), GNOME 2.8, Debian lineage — as a
fully featured Tier-1 host-native station. Branch `ubuntu` is the ledger; every
stream branches from it. Media is the official **live CD**, so there is no install:
the CD is the OS, and the golden vmstate lives in an otherwise empty qcow2.

## Proven in the spine (coordinator, alone)

- `warty-release-live-i386.iso` from `http://old-releases.ubuntu.com/releases/4.10/`,
  **674152448 bytes**, sha256
  `189746859b539c37d978b107589610aa49a7415f7c089d22667867a918591013`
  (`/data/assets-staging/ubuntu/MANIFEST.sha256`; copied to
  `/data/gallery-guests/Ubuntu/warty-release-live-i386.iso`).
- Boots unattended past isolinux to usplash, then the GNOME 2.8 desktop (user
  `ubuntu`, brown "Human" theme, Applications/Computer menus, cdrom + ramdisk icons,
  bottom panel) in ~90 s under KVM. Frame: `/data/vms/sandbox/ubuntu/smoke/minimal/fb.png`.
- **The wall, raced on 3 rigs:** with `-device AC97` + ACPI on, the live boot hangs
  at ~12 % of the usplash bar (2 rigs: `-cpu host` and `-cpu Nehalem,kvm=off`, 150 s
  no framebuffer change). `-machine pc-i440fx-11.0,acpi=off` with **no audio device**
  boots. The split (AC97 alone vs ACPI alone) is untested — not needed to ship.
- X comes up at **640x480** (XFree86 vesa, no DDC). The golden stream's job is
  1024x768 (below); 640x480 is the fallback and still a valid station.
- Dark-launched at `/os/ubuntu` from rig `/data/vms/sandbox/ubuntu/smoke/`
  (`launch.sh`, QMP at `smoke/minimal/qmp.sock`; `run-daemon.sh` restarts the daemon).

## Allocation ledger (claimed on labhost by session `ubuntu`)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `ubuntu` |
| slot / UDP / VMID label | **183 / 54183 / 183** (176–182 belong to the concurrent waves: netbsd14, openbsd, freebsd411, pcbsd, suse64, redhat62, debian22 — hands off) |
| render orders | as scaffolded from redstar2: signal 74 · stationsManifest 72 · binding 79 · golden 72 · actionMap 44 · bringUp 79 (group 6) · build row 72 |
| upstream | Ubuntu 4.10 live CD, old-releases.ubuntu.com (the bytes above; the builder pins the sha256) |
| builder output | `/data/gallery-guests/Ubuntu/warty-release-live-i386.iso` + `/data/gallery-guests/Ubuntu/ubuntu.qcow2` (empty 1G qcow2, the vmstate carrier; pristine = no snapshot) |
| station dir | `/data/vms/streamhost/stations/ubuntu/` — QMP, reset-hmp, pid; the disk stays under gallery-guests like redstar2 |
| device set (verbatim launcher `streamhost/stations/ubuntu/qemu-streamhost.sh`) | `qemu-system-x86_64 -nodefaults -enable-kvm -machine pc-i440fx-11.0,acpi=off -cpu host -m 512 -smp 1 -rtc base=localtime -drive ubuntu.qcow2 ide index=0 -drive ISO ide index=2 cdrom readonly -boot order=d -vga std -usb -device usb-tablet -display dbus,p2p=on` — **no NIC, no audio** |
| pointer | `usb-tablet`; Linux 2.6.8 `mousedev` turns it into PS/2-style deltas scaled to `mousedev.xres/yres` = 1024x768 by default, so 1:1 needs X at 1024x768 AND no X acceleration (`xset m 1 1`, captured inside the golden) |
| screen | shipped **640x480** (std VGA, vesa, no DDC) — the golden stream's 1024x768 attempt was not reached inside its time budget (below) |
| reset | `loadvm golden`, fixture in `station.env.fixture` |

## Streams (each: `scripts/dev/wt.sh new <name> --from ubuntu`, commit on its branch, push, 4-minute stop)

| Stream | Model | Deliverables |
|---|---|---|
| `ubuntu-build` | sonnet-low | `scripts/build-guests/tiles/ubuntu.sh` (fetch ISO to `/data/assets-staging/ubuntu`, verify the sha256 above, `qemu-img create -f qcow2 ubuntu.qcow2 1G`, install both to `/data/gallery-guests/Ubuntu/` atomically, framebuffer-verify the desktop with fb-wait.py using the exact launcher device set); RUN it; `scripts/build-guests/check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` row (append own rows only) |
| `ubuntu-golden` | sonnet | on a sandbox clone with the exact launcher device set: get X to 1024x768 (edit `/etc/X11/XF86Config-4` Modes in the live session, restart X) or fall back to 640x480; `xset m 1 1`, screensaver off; bake `golden` via HMP `savevm golden` into `ubuntu.qcow2`; one `loadvm` restore proof; one abs-pointer proof (QMP `input-send-event` abs to a corner, screendump); stage the result at `/data/gallery-guests/Ubuntu/ubuntu.qcow2`; `scripts/coldboot/bootrec-tiles.conf` arm (replace `scripts/coldboot/ubuntu-bootrec-arm.sh`); fill the TODO(golden) facts in `station.env.fixture` comments and correct the ledger's screen row |
| `ubuntu-spa` | Fable | `registry/posters/ubuntu.md` (Origins, Significance, What you're looking at) + a better hero from real frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`; `museum`/`spa` polish; `demoProgram` only if one keyboard-driven demo makes sense (Alt+F2 → `gedit` → type) |
| `ubuntu-docs` (after golden reports) | sonnet-low | `docs/guests/ubuntu.md` prose + §Checkpoint from golden's report, `docs/GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index |

## Reserved to the coordinator

Merging to `main`, "ready to land ubuntu" → "go" from the six-wave coordinator
(memory `station-waves-2026-09-03-coordination`), `git push origin main`,
`scripts/dev/box-deploy.sh --apply`, `scripts/dev/station-up.sh ubuntu`, the SPA
build/deploy, `smoke-rig.sh ubuntu --down`, and the final framebuffer acceptance.

## Golden (stream `ubuntu-golden`)

Baked on `/data/vms/sandbox/ubuntu-golden/bake/` (empty 1G qcow2, exact launcher
device set, first boot **without** `-loadvm`/`-S`):

- Reached the GNOME 2.8 desktop unattended in ~90 s (`fb-wait.py --settle 15`
  settled at 89.5 s). Login user is **`warty`**, not `ubuntu` (the ledger's
  earlier assumption was wrong — corrected here and in `station.env.fixture`
  / `registry/stations/ubuntu.json`).
- **1024x768 was not attempted.** The stream's clock ran out reaching the
  desktop and doing the pointer/bake/restore proof inside its time budget;
  per the brief, ship **640x480** rather than spend more time on the resize.
  A future stream can pick this up: `/etc/X11/XF86Config-4`'s `Modes` line
  under a terminal opened via Alt+F2 → `gnome-terminal`, then
  Ctrl-Alt-Backspace to restart X.
- Idle prep in a terminal: `xset m 1 1; xset s off; gnome-screensaver-command
  -d 2>/dev/null; exit` — screen returned to the clean idle desktop
  (`/data/vms/sandbox/ubuntu-golden/bake/probe4.png`).
- **Abs-pointer proof did NOT show a clean 1:1 mapping.** QMP
  `input-send-event` abs move to (16383,16383) (screen-fraction ~0.5) landed
  with the cursor **not visible on the desktop** — a date tooltip appeared
  over the top-right panel clock instead, meaning the cursor over-shot far
  right/up of centre. A subsequent move to (0,0) landed the cursor at
  **screen pixel ~(130,390)**, not the top-left corner. This is consistent
  with the ledger's own prediction: Linux 2.6.8 `mousedev` scales the USB
  tablet's 0..32767 absolute range to `mousedev.xres/yres` = **1024x768 by
  default**, while X is running at 640x480 — so the mapping is NOT 1:1 at
  this resolution and the two probes also read as position-dependent
  (second move landed near, not at, the target), suggesting mousedev may be
  applying its own relative/hysteresis smoothing on top of the scale
  mismatch rather than a pure affine transform. Not investigated further —
  out of budget. A follow-up stream should either get X to 1024x768 (the
  scale mismatch disappears per the ledger's own note) or recalibrate
  `mousedev.xres`/`yres` for 640x480 explicitly.
- Frames: `/data/vms/sandbox/ubuntu-golden/bake/desktop.png` (initial
  desktop), `probe4.png` (idle prep done), `abs_center2.png` /
  `abs_tl.png` (pointer probes), `restore.png` (post-`loadvm` proof).
- Baked `savevm golden` via the `reset-hmp.sock` HMP socket:
  **VM_SIZE = 255 MiB, VM_CLOCK = 0000:05:55.667** (`qemu-img snapshot -l`).
- **Restore-proven**: killed the bake clone by pidfile, relaunched with
  `-loadvm golden -S`, QMP `cont`, `fb-wait.py --settle 3 --timeout 30`
  landed in 3.3 s on the identical idle desktop (same cursor position,
  same icons, same clock) — `restore.png`.
- Staged: `/data/gallery-guests/Ubuntu/ubuntu.qcow2` (the `ubuntu-build`
  stream's pristine empty carrier was moved aside to
  `ubuntu.qcow2.bak-pre-golden` first).
- `scripts/coldboot/bootrec-tiles.conf` armed with a `ubuntu)` case (modeled
  on `redstar2`: `BR_BOOT_KIND=vmstate`, external writable disk only — the
  live-CD ISO is read-only and stays at its live path, not cloned);
  `scripts/coldboot/ubuntu-bootrec-arm.sh` scaffold removed.

## Measured milestones

TODO(coordinator): from `scripts/dev/session-timeline.py` after landing.
