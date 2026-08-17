# ninefront — 9front (Plan 9 fork), station notes

- Station: `ninefront` (VMID 96), q35/`-cpu host`, 1920x1080 `-vga std`, intel-hda,
  disk `/data/gallery-guests/9front/9front-11554.amd64.qcow2` (internal `golden`
  checkpoint; launcher boots `-loadvm golden`, savevm persists — no `-snapshot`).
- Boots unattended to rio (auto user glenda). The production `golden` is captured
  only after rio is fully settled, with acme, stats, catclock, and a focused rc
  terminal visible; `loadvm golden` does not resume the cold-boot path.

## Pointer: SH_POINTER=warpd (absolute, agent-backed) — since 2026-07-12

9front runs a PS/2 relative mouse at the QEMU device level, but the kernel's
devmouse accepts true absolute injection: writing `A x y buttons msec` to
`/dev/mousein` warps the cursor full-screen (absmousetrack). The in-guest agent
`/amd64/bin/warpd` (source `streamhost/guest-agents/ninefront/warpd.c`, built
in-guest with 6c/6l) listens on `tcp!*!7777`, translating the daemon's M/P/R/B
protocol 1:1 — including real button presses (menus, drags, wheel), so no
`SH_WARPD_BUTTONS=qemu` hybrid is needed.

Since 2026-07-26 the agent does **guest-side latest-wins move coalescing**
(mirrors win9x/win311): `emit()` reopens `/dev/mousein` per event, so replaying
every queued `M` under a sustained pen-hover chain made the guest fall behind
and the cursor rubber-band ever farther. `serve()` now pends only the newest
`M`, flushing it before any non-move verb (Q/P/R/B) and once per `read()` chunk,
so guest apply is capped to ~1 move/cycle and the cursor snaps to the latest
position. Framebuffer-verified on a sandbox clone and the live checkpoint: a 18 s
sustained sweep left the cursor tracking the commanded x to within the cursor
hotspot offset (flat, no growth) and settling on the final point in ~0.01 s;
the pre-coalescing agent lagged 80–400 px during the sweep and took 6–15 s to
drain after input stopped.

Wiring:

- hostfwd on the existing user netdev: `127.0.0.1:57793 -> guest :7777`
  (backend property — device set unchanged, `loadvm golden` matches).
- `station.env`: `SH_POINTER=warpd`, `SH_WARPD_ADDR=127.0.0.1:57793`.
- Autostart: `/cfg/cirno/termrc` (net up via `ip/ipconfig` + `ndb/cs`, then
  `bind -a '#m' /dev` and a retry loop around `warpd`). The bind + retry are
  REQUIRED: `/dev/mousein` is not bound into /dev yet when termrc sources the
  cfg hook, so a bare `warpd &` sysfatals at boot. Agent log:
  `/cfg/cirno/warpd.log` (in-guest).
- Captured into BOTH the seed disk and the checkpoint. The settled
  framebuffer is explicitly paused before `savevm golden`, matching the
  boot-video poster and making the seam deterministic.
  Pre-agent disk backup:
  `/data/gallery-guests/9front/9front-11554.amd64.qcow2.pre-agent`.

Verified by framebuffer screendumps: cursor tracks `M x y` 1:1 at (60,60),
(970,710), (512,384) after cold boot, and after `loadvm golden` restore;
`P 3/R 3` opens and operates the rio button-3 menu.

## Guest facts / driving

- Network: SLIRP via virtio-net; in-guest `ip/ipconfig` (DHCP 10.0.2.15) +
  `ndb/cs`; fetch from labhost with `hget http://10.0.2.2:<port>/...`.
  The captured termrc now brings the net up at every cold boot.
- Typing: `labctl type/key/sh` (QMP send-key) lands in the focused rio window.
- Long command output is clipped by the small rio terminal window — prefer
  short, single-line queries (`grep -n`, `ls | ...`).
- Clean shutdown for recaptures: `fshalt` (syncs cwfs and exits QEMU).
- sysname is `cirno` (9front default, set in /rc/bin/termrc before the
  /cfg/$sysname/termrc hook fires).

## Checkpoint rebuild and scene

Run `nice -n15 scripts/build-guests/tiles/9front.sh` on labhost. The builder starts
from the pinned official release, installs warpd, cold-boots the exact production
device set at `VGASIZE` (default `1920x1080x32`, set in `plan9.ini`), and lays
this deterministic rio composition on top of stock `riostart`'s tiny top-left
`stats` + boot term:

    window -r 20 130 1250 1050 acme
    window -r 1268 130 1900 430 stats
    window -r 1268 442 1900 770 games/catclock
    window -r 1268 782 1900 1050

acme fills the left ~64%; stats/load, catclock, and a focused rc terminal stack
the right column. The last window is an interactive rc terminal and therefore
owns keyboard focus. The builder gates the real 1920×1080 framebuffer, parks the
pointer at `PARK_X,PARK_Y` (`1580,916`) via warpd, issues QMP `stop`, saves the
paused `golden`, resumes, and proves both the lively frame and `Q 1580 916 -> K`
after `loadvm`. To re-res the station, edit `VGASIZE` + `FIXTURE_COMMAND` (and, if
the aspect changes, the scene sample points) in `scripts/build-guests/tiles/9front.sh`.
Do not move the checkpoint back to the former early-boot point; that deliberately
imposed a post-reset rio/network delay.

### 1920×1080 resolution bump (2026-07-27)

Raised from 1024×768 → **1920×1080** (full-era-correct 16:9). 9front's
`monitor=vesa` path negotiates 1920×1080×32 straight from QEMU 11's std-vga
VGABIOS mode list — no device-set change (`-vga std` unchanged, `loadvm golden`
still matches). The mode is set at cold boot from `plan9.ini vgasize`, so the
re-res is a **cold-boot recapture** (not a `loadvm`): patch `plan9.ini`, cold boot,
re-lay-out the scene at the new geometry, `delvm`/`savevm golden`. Built ON TOP
of the current coalescing seed disk (the `/amd64/bin/warpd` binary is untouched
— the latest-wins move-coalescing agent is preserved and re-verified live: an
1200-move sustained sweep drained in ~0.04s with the cursor snapping flat to the
final point and zero trailing). Validated clone-first under
`/data/vms/sandbox/ninefront-res1080/` (killed via `clone-guard`).

The official disk also includes mothra, abaco, and the full `/bin/games`
collection. The checkpoint keeps the uncluttered four-window composition above; the
other programs remain immediately launchable from the focused terminal.

## Boot-video replay

The `scripts/coldboot/bootrec-tiles.conf` arm copies the external qcow2 and moves
hostfwd `57793` to `58793`. Its clone-only `ninefront-record-driver.sh` waits for
rio from framebuffer truth, recreates the same four-window scene, and then lets
the normal recorder pause/save/verify seam invariant run. Publish with
`postprocess-boot.sh`, `trim-boot.sh`, and `gen-boot-manifest.sh` as documented in
`scripts/coldboot/README.md`.

Re-record on labhost (the `bootrec-tap` companion binary must be built first — it
is a `[[bin]]` in the streamhost crate; the compiled binary lands in the WORKSPACE
target dir, i.e. `/data/vms/streamhost/target/release/bootrec-tap`, NOT under the
member crate):

```sh
ssh lab
cd /data/vms/streamhost/streamhost && cargo build --release --bin bootrec-tap
export SH_DBUS_TAP=/data/vms/streamhost/target/release/bootrec-tap
export WEBROOT=/data/vms/streamhost/serve/webroot
# clear any stale boot.mp4.orig FIRST when re-recording at a NEW resolution:
# trim-boot.sh reuses an existing boot.mp4.orig as its seam reference, so a leftover
# orig from the prior resolution would trim+republish the OLD clip (verified footgun).
rm -rf /data/vms/streamhost/boot-rec/ninefront
scripts/coldboot/record-boot.sh      ninefront                            # clone → record → savevm → verify
scripts/coldboot/postprocess-boot.sh ninefront                            # sprite.jpg + thumbs.vtt + durationMs
scripts/coldboot/trim-boot.sh /data/vms/streamhost/boot-rec/ninefront     # trim trailing static (seam-gated; takes the staging DIR)
scripts/coldboot/gen-boot-manifest.sh ninefront                           # publish + update /boot/index.json
```

Re-recorded at **1920×1080** on 2026-07-27 (seams with the 1920×1080 checkpoint):

- record clone: cold boot → four-window rio scene laid out → warpd pointer-park
  at `1580,916`; pause/`savevm golden`/verify `SSIM(golden-first-frame,poster)=
  1.000000` (≥ 0.999 gate); 27.2 s recorded, trimmed to 22.72 s with final-frame
  MD5 `b1c7ab2f4e5a839ec419b5e298a2de3a` preserved; H.264 High/yuv420p 1920×1080
  at 30 fps plus AAC-LC;
- live seam (boot.mp4 last frame vs `labctl reset ninefront` → `loadvm golden`
  first frame, both 1920×1080): full-frame SSIM `0.9978`; static regions
  essentially identical — acme body `0.99992`, rio floor `0.99971`, cursor-park
  `0.99999`. The only divergence is in the intrinsically-live widgets that cannot
  match between two independent capture instants: `games/catclock` `0.9916` and the
  `stats`/load graph `0.9887`;
- served: `/boot/index.json` `ninefront` entry is `width:1920 height:1080
  durationMs:22720`, HTTPS full probe `200` / range probe `206` (video/mp4);
  poster/sprite/thumbs `200`.
- The superseded 1024×768 boot-video (recorded 2026-07-15, trimmed 31.183 s,
  final-frame MD5 `370587372846cf749aebe732c0c7fce8`) is backed up under
  `/data/vms/streamhost/serve/webroot/boot/ninefront.bak-1024x768-<ts>/` and
  `/data/vms/streamhost/boot-rec/ninefront.bak-1024x768-<ts>/`.

Promotion rollback:

- **pre-1080 checkpoint (the exact 1024×768 coalescing checkpoint, before the 2026-07-27
  resolution bump; fastest rollback to 1024×768 keeping the coalescing agent):**
  `/data/gallery-guests/9front/9front-11554.amd64.qcow2.bak-res1024-20260727T075014Z`
  (SHA-256 `38895a49d10a06544b0d257d09b8642c4e446506e0fe8ac9def689277a664f00`);
- pre-coalescing checkpoint (before the 2026-07-26 latest-wins agent swap; the
  fastest rollback to the per-event-replay agent):
  `/data/gallery-guests/9front/9front-11554.amd64.qcow2.pre-coalesce-20260726T220402Z`
  (SHA-256 `a92cc0a73c7ac8a45804c7a979a89781f043dd81939b1aacad7f1a661fd9cd72`);
- prior disk:
  `/data/gallery-guests/9front/9front-11554.amd64.qcow2.pre-instant-apps-20260715T234357Z`
  (SHA-256 `fb2112cd64edf1e9a29ef6528fd0870f9e3efdd677e8b5a91024cf3345802662`);
- promoted disk SHA-256 before the first live launch (runtime qcow2 writes
  subsequently change the whole-file digest):
  `7b4fe1b27d7121118487be88e0e96be7fea218863c563d788d14fa277a89684c`;
- rollback by stopping `streamhost@ninefront`, terminating only the PID in
  `tiles/ninefront/qemu.pid` if it remains, copying the prior disk over the live
  path, then starting the service and running `labctl reset ninefront`.
