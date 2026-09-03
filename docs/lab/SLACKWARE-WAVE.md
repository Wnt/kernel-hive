# Slackware 3.4 integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, pcgeos 18 min): integrate **Slackware 3.4**
(October 1997 — Linux 2.0.30, XFree86 3.3.1, the fvwm95 desktop) as a fully
featured Tier-1 host-native station. Branch `slackware` is the ledger; every
stream branches from it. Coordination: this wave is one of nine on the box
(memory `station-waves-2026-09-03-coordination`); main landings are serialized
through the coordinator session ("ready to land" → "go" → "landed").

## Proven in the spine (coordinator, alone)

- **Media**: `https://mirrors.slackware.com/slackware/slackware-3.4/` (a mirrorbrain
  redirector — fetch with `curl -L`). Staged on labhost under
  `/data/assets-staging/slackware/`: `kernels/bare.i/zImage` (**461067 bytes**,
  sha256 `a8e56f9556f1cf50a4146524c2302ab17a7c6bf757de96a55b2a38d821126acd`),
  `rootdsks/color.gz` (609325), `bootdsks.144/bare.i` (601088 — authentic size per
  FILELIST.TXT), and the `slakware/{a*,ap*,x*,xap*,y*}` package directories
  (**54251183 bytes** of .tgz). `MANIFEST.sha256` there lists all 128 files.
- **Root filesystem composed HOST-SIDE, no interactive setup**:
  `scripts/build-guests/tiles/slackware/compose.sh` (proven; runs on labhost as
  root in ~12 s). Slackware packages are plain tarballs relative to `/`; each
  `install/doinst.sh` is written to run with cwd = the install root using relative
  paths, so it runs under the host `sh` with `ldconfig`/`depmod`/`chroot` neutered.
  65 packages: `a` ADD+REC minus gpm (it would grab the mouse from X), scsi, pcmcia,
  loadlin, umsprogs, ibcs2, scsimods; `ap` manpgs sudo joe bc diff sc zsh ash jpeg mc
  vim; `x` fvwm fvwmicns x331bin/cfg/doc/fnts/lib/man/svga/vg16/fscl xlock xpm;
  `xap` fvwm95 libgr xv xfm xpaint xgames; `y` bsdgames.
  Traps found: `var/adm` becomes a symlink (records go to `var/log/packages`);
  libc5-era Slackware leaves the **soname links to ldconfig** (`libc.so.5`,
  `ld-linux.so.1`) — without them init cannot even load, and the kernel sits silent
  after "VFS: Mounted root"; a.out libs make `readelf` fail (pipefail).
  Disk: 400 MiB raw, one bootable partition at sector 63, `mke2fs -E revision=0,offset=32256 -d`
  (kernel 2.0 mounts nothing newer than rev 0), then `qemu-img convert` → qcow2.
- **Boot loader**: the 1997 LILO on the `bare.i` floppy wedges at `LI` under
  SeaBIOS (KVM: `KVM internal error. Suberror: 1`; TCG: same `LI`), and QEMU's
  `-kernel` loader hangs this zImage before "Uncompressing Linux". What works:
  a **GRUB2 rescue ISO** (`grub-mkrescue`, `linux16 /zImage root=/dev/hda1 ro`),
  attached read-only as the secondary-master CD, `-boot d`. Kernel boots under KVM
  `-cpu host` and under TCG `-cpu pentium2`; the station ships KVM.
- **X**: XF86_SVGA on `-vga cirrus` (CL-GD5446, `Chipset "clgd5446"`, VideoRam 4096),
  1024x768. Text did not paint at depth 8 or 16 until `Option "no_bitblt"`
  (raced 4 configs on clones: depth 8 accel ✗, depth 16 noaccel ✗ (X never came
  up), depth 16 no_bitblt ✓, depth 8 noaccel ✓). `Option "sw_cursor"` too. Shared
  with the netbsd14 wave (same symptom, same fix).
- **Pointer**: Microsoft serial mouse on ttyS0 (`-chardev msmouse -serial chardev:ms0`);
  PS/2 is a module in bare.i (`CONFIG_PSMOUSE=m`). `xset m 1 1` in `.xinitrc`.
- **Session**: `/root/.xinitrc` = xset s off / -dpms / m 1 1, xterm 80x24 at +48+40,
  xclock top-right, `exec fvwm95-2`; `~/.fvwm2rc95` copied from
  `/var/X11R6/lib/fvwm95-2/system.fvwm2rc95` (without it fvwm95 runs with a bare
  builtin look). `rc.local` runs `startx` on every boot, so a cold boot lands on the
  desktop with root logged in (empty password in passwd + shadow).
- Smoke rig: `/data/vms/sandbox/slackware/smoke/` (`launch-smoke.sh`, `run-daemon.sh`),
  dark-launched at `/os/slackware` on slot 184. Pristine composed disk:
  `/data/vms/sandbox/slackware/build/disk.qcow2` (+ `disk.raw`, never booted).
  Frames: `smoke/fb10.png` = the fvwm95 desktop (the hero).

## Allocation ledger (claimed on labhost by session `slackware` via smoke-rig.sh)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `slackware` |
| slot / UDP / VMID label | 184 / 54184 / 184 (assigned by the wave coordinator; X warp :84/6084 reserved, unused) |
| render orders | as assigned by `stations-registry.py new --like tinycore` (see the entry) |
| upstream | Slackware 3.4 tree on mirrors.slackware.com (immutable release, 1997-10-05) |
| builder output | `/data/gallery-guests/Slackware/slackware.qcow2` (pristine, no golden) + `grub-boot.iso` |
| station dir | `/data/vms/streamhost/stations/slackware/` — `disk.qcow2` carries the `golden` vmstate; `grub-boot.iso` read-only |
| device set | `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 32 MB, 1 vCPU, `-vga cirrus`, sb16 + pcspk → dbus audiodev, msmouse on ttyS0, ide disk + ide cdrom index 2, `-boot d` |
| screen | 1024x768x16 |
| pointer | relative, dbus-rel, scale 1.0 |

## Streams (each: `scripts/dev/wt.sh new slackware-<stream> --from slackware`, commit on its branch, push, 4-minute stop)

| Stream | Model | Deliverables |
|---|---|---|
| `slackware-build` | sonnet-low | `scripts/build-guests/tiles/slackware.sh`: pinned `curl -L` fetch of the file list, SHA-256 check against the ledger manifest, run `compose.sh`, build `grub-boot.iso`, framebuffer-verify the desktop, output to `/data/gallery-guests/Slackware/`; RUN it; `check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` rows (append-only) |
| `slackware-golden` | sonnet | bake `golden` on a sandbox clone from `build/disk.qcow2` with the exact launcher; one `loadvm` restore proof; stage `disk.qcow2` + `grub-boot.iso` into the station dir; `scripts/coldboot/bootrec-tiles.conf` arm (replace the scaffold `slackware-bootrec-arm.sh`); pointer/keyboard truth into the fixture comments + report |
| `slackware-spa` | Fable | `registry/posters/slackware.md` + hero polish + extra frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts` (append-only), `museum`/`spa` polish, a keyboard `demoProgram` typed into the xterm |
| `slackware-docs` | sonnet-low, after golden | `docs/guests/slackware.md` prose + §Checkpoint from golden's report, `docs/GUEST-TIERS.md`, release notes JSON, `docs/README.md` index (append-only) |

## Reserved to the coordinator

Merging to `main`, `git push`, `scripts/dev/box-deploy.sh --apply`,
`scripts/dev/station-up.sh slackware`, the SPA build/deploy, withdrawing the
smoke overlay, and the final framebuffer acceptance — all after the coordinator
session's "go slackware".

## Measured run (session-timeline.py on the coordinator transcript, UTC)

| Milestone | Clock | From the ask |
|---|---|---|
| Operator's message | 23:00:49 | 0 |
| Smoke rig published at `/os/slackware` (viewable) | 23:22 | **21 min** |
| Ledger pushed, 4 streams launched | 23:34 | 33 min |
| Streams merged, "ready to land" | 23:41 | 40 min |
| main pushed (gate green, after conflict-marker + shfmt fixes) | 23:45 | 45 min |
| Station live (`station-up`, labctl gen PASS) | 23:48 | 47 min |
| SPA deployed, proofs done (fully featured) | 23:49 | **48 min** |

Split over the 50-minute span: coordinator model time 58 %, tools 35 %, waiting on
agents 6 %. Not a record against pcgeos (18 min): this guest had no install media
and no known-good boot path, so minutes 5–22 went to four walls raced in sequence —
LILO `LI`, `-kernel` hang, the missing soname links, the cirrus BitBLT — each
costing one compose+boot cycle (~1.5 min). Sinks worth fixing next time: the quiet
`git merge -q origin/main` hid conflict markers that the gate then caught (3 min);
`stations-registry.py new --like` copies the sibling's `operator.labctl.dir/qmp`
(one extra push+deploy); the four X-config race should have started the moment the
first blank xterm appeared instead of after two serial theories.

## Phase 2 — absolute pointer via x11warp (2026-09-03, coordinator alone, ~35 min)

Operator: "pointer-based graphical OSes need absolute cursor positioning before
they are considered fully integrated." Route as netbsd14's: the daemon warps the
pointer inside the guest X server over a slirp forward. What it took, all in
`compose.sh`: the `tcpip` package from n6, a static `rc.inet1` (10.0.2.15/24, gw
10.0.2.2), `rc.inet2` emptied, `modprobe ne io=0x300` in `rc.modules` (the
`bare.i` kernel ships `ne.o` as a module — no kernel swap), `xhost +10.0.2.2` in
`.xinitrc`; launcher: `-netdev user,id=n0,hostfwd=tcp:127.0.0.1:6084-10.0.2.15:6000
-device ne2k_isa,netdev=n0`. Proof: `xwarp.py` (raw X11 WarpPointer+QueryPointer;
xdotool segfaults on XFree86 3.3) warps to (100,700) and (900,100) with exact
readback and the cursor visible on the framebuffer at both; new golden baked with
the pointer parked at (1020,760), restore frame pixel-identical, warps exact after
restore. Traps: an absolute-symlink append (`cat >> etc/rc.d/…`) on the host is
safe here (regular file), but the site-config patch anchored on a line `shfmt` had
already reformatted (`>etc/HOSTNAME`) and silently applied nothing — check the
composed tree for your marker before booting. Fixture keys: `SH_INPUT_BACKEND=x11warp`,
`SH_X11WARP_DISPLAY=127.0.0.1:84`; registry pointer `x11-warp-absolute`, abs.

## Open follow-ups

- ~~Absolute pointer~~ — landed in phase 2 below.
- Playbook §0 cited `/data/vms/streamhost/serve/qmp-type.py`; fixed in this wave to
  `scripts/dev/qmp-type.py` (`--qmp` or `--station`).
- `pgrep -x qemu-system-x86_64` matches nothing (15-char comm limit); prune by
  `/proc/<pid>/cwd` with `pgrep qemu-system`.
