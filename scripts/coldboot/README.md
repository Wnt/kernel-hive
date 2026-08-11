# coldboot — boot-video capture tooling

Box-side tooling that records a tile's **cold power-on** to a scrub-optimised MP4
whose **last frame is byte-identical to the golden's first live frame**, so the SPA's
recorded-video → live-stream handoff is invisible (the §1.1 invariant). The working
spec was never committed as a doc — this README plus the `record-boot.sh` header
comment ARE the surviving definition; the `§`/`P1a…P2b` labels below are that spec's
internal numbering, kept for cross-reference. Everything here is a **standalone
sidecar** — no `streamhost` daemon change, so it is unaffected by the shared-binary
redeploys of `scripts/dev/build-deploy.sh`.

> Sibling lifecycle tooling — all vendored here 2026-07-14 as byte-copies of the live
> install — makes the **amiga** bridge tile cold-boot FS-UAE *per visit*; the
> boot-video tooling records that same power-on **once**:
> `amiga-coldboot-watch.sh` (box: `/usr/local/bin/`, journal-driven session watcher,
> unit in `streamhost/deploy/amiga-coldboot-watch.service`), `amiga-emu` (kiosk:
> `/usr/local/bin/amiga-emu`, boot/stop flag), `amiga-launch-coldboot.sh` (kiosk:
> `/etc/bridge/launch.sh` supervisor variant — replaces the plain launcher that
> `scripts/build-guests/tiles/amiga.sh` bakes), `install-amiga-coldboot.sh` (installer).

## Files

| file | role |
|------|------|
| `bootrec-lib.sh`        | sourced helpers: QMP/HMP client, `screendump`, ffmpeg-SSIM change-fraction, kill-by-pidfile — kills + destructive HMP route through `clone-guard` (fail-closed; never touches a live tile — see `docs/lab/clone-guard.md`) |
| `bootrec-tiles.conf`    | **per-tile data** (canvas res, audio, detect tier/thresholds, hostfwd/fixed ports, tile-local/external disks, boot kind and optional boot driver); compare its `case` arms with the canonical production roster (`python3 scripts/stations-registry.py count`) when adding a tile |
| `record-boot.sh`        | **P1a+P1c** — clone-launch, dbus tap → ffmpeg, detect, freeze → poster → `savevm golden` → verify |
| `detect-interactive.sh` | **P1b** — 3-tier "interactive reached" detector (framebuffer-stability / reference-region / fixed timer) |
| `postprocess-boot.sh`   | **P2a** — `boot.mp4` re-encode (§6.1) + `sprite.jpg` (§6.2) + `thumbs.vtt` (§6.3) + `durationMs` |
| `trim-boot.sh`          | **P2a′** — trim the dead trailing-static tail (audio+video aware, seam-invariant-gated); re-runs `postprocess-boot.sh` for the new duration |
| `gen-boot-manifest.sh`  | **P2b** — rsync staging → `$WEBROOT/boot/<id>/` + aggregate `boot.json` → `$WEBROOT/boot/index.json` (§4) |
| `*-zero-input-prep.md`  | prep/ready-state notes for 27 arms (the existing amiga bridge lifecycle is documented in this README); automated LiveCD/greeter input is documented where a disk-baked zero-input path is unavailable |
| `*-record-driver.sh`    | clone-only automated input for unavoidable boot blockers (Alpine tty login, QNX LiveCD flow, TempleOS questions, postmarketOS greeter); never used against live QMP |
| `docs/history/os2warp-promote-notes.md` (archived) | os2warp promotion notes (clone-validated → live transplant record) |
| `solaris-prep`          | solaris prep payload used by its zero-input-prep flow |

## The dbus tap (`SH_DBUS_TAP`) — the one box-only companion

Tapping QEMU's **p2p D-Bus** display+audio needs `SCM_RIGHTS` fd-passing + zbus — it
cannot be done in bash and cannot be exercised off-box. It is the **exact mechanism the
daemon already ships**: `streamhost/streamhost/src/capture.rs` `connect()` (BGRA scanout,
`:621-660`) + `audio.rs` `register()` (s16le PCM, `:139-200`). Build a ~120-line `[[bin]]`
in that crate (`bootrec-tap`) whose `main()`:

1. `capture::connect(<qmp.sock>)`; per frame, **letterbox/scale the scanout to a CONSTANT
   `<WxH>` canvas** and write BGRA to the video fifo, **paced to `<fps>`** (duplicate the
   last frame between damage). Constant size + rate is what lets the downstream
   `ffmpeg -f rawvideo` avoid the mid-boot SPS/resolution change (spec §2.3).
2. `audio::register(...)`; write s16le PCM to the audio fifo (**open+close it even when the
   tile has an audiodev but no card**, else ffmpeg blocks on the missing writer).

Contract (any producer honouring it works — e.g. a synthetic BGRA generator to exercise
the ffmpeg/detect/bake plumbing off-box, mirroring `amiga-coldboot-watch.sh`'s `SH_FEED_CMD`):

```
$SH_DBUS_TAP <qmp.sock> <video.fifo> <audio.fifo|""> <WxH> <fps> <arate> <ach>
  # constant-size BGRA @ <fps> to video.fifo; s16le PCM to audio.fifo ("" => skip);
  # exit cleanly on SIGTERM (close fifos => ffmpeg EOF).
```

## Flow: record → bake → post → publish (per tile, on the box)

```bash
ssh lab
export SH_DBUS_TAP=/data/vms/streamhost/streamhost/target/release/bootrec-tap
export WEBROOT=<the SPA webroot the https server uses>   # os.environ["WEBROOT"]

# 0. PREVIEW — writes the clone launcher, launches nothing. INSPECT the rewritten
#    device set (must match live exactly, or loadvm golden will fail).
scripts/coldboot/record-boot.sh amiga --dry-run

# 1. RECORD + BAKE (P1a+P1c). Clone under /data/vms/soltest/, killed only by pidfile.
#    vmstate tiles: cold-launch (no loadvm) → detect → stop → poster → savevm golden
#                   (on the PAUSED state) → verify (loadvm → SSIM vs poster ≥ 0.999).
#    bridge tiles : loadvm the kiosk golden → ssh the in-kiosk emu cold-boot → record;
#                   NO savevm/verify (the emulator cold-boots per visit).
scripts/coldboot/record-boot.sh amiga

# 2. POST-PROCESS (P2a): sprite.jpg + thumbs.vtt + durationMs.
scripts/coldboot/postprocess-boot.sh amiga

# 2b. (optional) TRIM the dead trailing-static tail (P2a'). Operates on a boot-rec DIR,
#     backs up boot.mp4.orig, cuts at max(videoSettle, audioEnd)+1.2s while KEEPING the
#     original's final GOP verbatim (last frame stays byte-identical to the golden — a
#     hard md5 gate refuses to overwrite otherwise; the boot chime is never cut), then
#     regenerates sprite/vtt/durationMs. Idempotent (always recomputes from boot.mp4.orig).
scripts/coldboot/trim-boot.sh /data/vms/streamhost/boot-rec/amiga

# 3. PUBLISH (P2b): rsync assets into WEBROOT + rebuild /boot/index.json.
scripts/coldboot/gen-boot-manifest.sh amiga
```

Staging (not served, not git): `/data/vms/streamhost/boot-rec/<id>/`.
Served (rsynced by step 3): `$WEBROOT/boot/<id>/{boot.mp4,poster.jpg,sprite.jpg,thumbs.vtt}`
plus `$WEBROOT/boot/index.json`.

## Detection tiers (`bootrec-tiles.conf`, spec §2.7)

- **Tier 1 — framebuffer-stability** (default; static desktops): cf = `1 − SSIM(prev,cur)`
  stays `< BR_CF_THRESHOLD` for `BR_SETTLE_MS`.
- **Tier 2 — reference-region match** (animating desktops — kolibrios/templeos/CDE clock):
  `SSIM(crop, BR_REF_PNG) ≥ 0.985` for `BR_REF_MATCH_K` frames. Maintain the reference PNG
  alongside the golden.
- **Tier 3 — fixed timer** (unpredictable boots — amiga ≈ 60–75 s to Workbench), optional
  Tier-2 confirm. All tiers are bounded by `BR_MAX_MS`.

## Device-set / golden safety (AGENTS.md hard rules)

- The clone launcher is a **byte copy** of the live `qemu-streamhost.sh` with **only**
  paths (→ clone dir), `-name`, the guest **hostfwd port**, and (vmstate) `-loadvm golden`
  rewritten. **No `-device`/`-audiodev` is added or removed** — `loadvm golden` requires an
  exact device match; adding a device would poison the snapshot.
- Clones live under `/data/vms/soltest/`; the launcher's `savevm` writes the **copied**
  disk, never live. VMs are killed **only by pidfile**.
- `BR_EXTERNAL_DISKS` covers writable qcow2 files outside the tile directory: each is
  copied into the namespace and its absolute launcher path is rewritten before launch.
  `BR_PORT_REWRITES` similarly moves fixed monitor/post-launch ports off the live port.
- `restart` arms (toaruos, sailfishos, serenityos) have no usable vmstate store; they
  freeze a poster but skip savevm/loadvm. Require an independent fresh-boot poster
  comparison before promotion.
- `record-boot.sh` bakes + verifies the invariant **on the clone**. Promoting the validated
  golden + `boot.mp4` onto the live tile is a **separate supervised transplant** (or re-run
  during a real bake window) — this tooling never mutates a live tile.

## Server change (spec §2.9, outside this tooling) — LANDED

`scripts/serve/osgallery-https-server.py` already carries it: `.mp4`/`.m4v`/`.webm`/
`.vtt`/`.m4s` are in the MIME table (`:216-217`) and `/boot/` is in the reserved-prefix
guard (`:510`) so a missing asset 404s (exposes bake skew) instead of returning
`index.html`. The static path is also single-range Range-capable for `<video>` scrubbing.

## Steps that require a live box (first amiga run — supervise)

Nothing here runs off-box (no live tile, no dbus). On the box, in order:
1. Build `bootrec-tap` from `capture.rs`+`audio.rs` and export `SH_DBUS_TAP` (once).
2. `record-boot.sh amiga --dry-run` → eyeball the rewritten clone launcher device set.
3. `record-boot.sh amiga` → watch `/data/vms/soltest/bootrec-amiga-*/{launch,ffmpeg,tap}.log`
   and the framebuffer; confirm t0 non-black, Workbench reached, `boot.mp4` non-empty.
4. `postprocess-boot.sh amiga`, then `gen-boot-manifest.sh amiga`.

## Regenerating every tile's boot video from a fresh build (state 2026-07-14)

One-time on a fresh box: build the tap (`cd /data/vms/streamhost/build &&
cargo build --release --bin bootrec-tap`; the crate ships `src/bin/bootrec-tap.rs`)
and `export SH_DBUS_TAP=/data/vms/streamhost/build/target/release/bootrec-tap`,
`export WEBROOT=/data/vms/streamhost/serve/webroot`. Then per tile:
`record-boot.sh <tile>` → `postprocess-boot.sh <tile>` →
(optional) `trim-boot.sh /data/vms/streamhost/boot-rec/<tile>` →
`gen-boot-manifest.sh <tile>`. Everything is scripted — no hand-run ffmpeg
steps exist outside these scripts (live `/boot/*/boot.mp4` probe: H.264 High
yuv420p 30 fps + AAC, keyint 15 — exactly the §6.1 encode).

`arm status` is deliberately evidence-scoped: **existing** predates this coverage
pass, **proven-new** completed record → postprocess → trim in a namespaced clone and
passed framebuffer/ffprobe gates, and **authored-untested** passed live-launcher
`--dry-run` rewriting but has not been cold-recorded. Published assets were read-only.

| tile | arm status | prep / ready-state notes | published `/boot/` | capture note |
|------|------------|--------------------------|--------------------|--------------|
| alpine | **proven-new** | `alpine-zero-input-prep.md` | no | automated passwordless tty login; 20.416 s trimmed proof |
| tinycore | **authored-untested** | `tinycore-zero-input-prep.md` | no | LiveCD → FLWM; review natural desktop vs old RAM fixture |
| reactos | **existing** | `reactos-zero-input-prep.md` | no | known immutable-LiveCD dialogs and external-store caveat; not promote-ready |
| toaruos | **authored-untested** | `toaruos-zero-input-prep.md` | no | restart kind; remastered ISO is golden |
| haiku | **existing** | `haiku-zero-input-prep.md` | **live** | Tier 2 Deskbar crop |
| aros | **authored-untested** | `aros-zero-input-prep.md` | no | AROS LiveCD → Wanderer |
| helenos | **authored-untested** | `helenos-zero-input-prep.md` | no | LiveCD → compositor; review old RAM-only terminal fixture |
| kolibrios | **authored-untested** | `kolibrios-zero-input-prep.md` | no | LiveCD → desktop; array-form loadvm rewrite covered |
| ninefront | **proven-new** | `ninefront-zero-input-prep.md` + record driver | **live** | external disk + hostfwd rewrite; lively rio fixture |
| android | **authored-untested** | `android-zero-input-prep.md` | no | external disk copy; reject lock/setup UI |
| solaris | **existing** | `solaris-zero-input-prep.md` + `solaris-prep/` | **live** | video-only (`hasAudio: false`) |
| win2000 | **existing** | `win2000-zero-input-prep.md` | **live** | Tier 2 Notepad crop |
| winxp | **existing** | `winxp-zero-input-prep.md` | **live** | Tier 2 Start-button crop |
| win311 | **authored-untested** | `win311-zero-input-prep.md` | no | both tile-local disks copied |
| win95 | **existing** | `win95-zero-input-prep.md` + `win95-clean/` | **live** | clean-desktop promotion pipeline |
| win98se | **existing** | `win98se-zero-input-prep.md` | **live** | Tier 3 (50 s), two staged disks |
| freedos | **proven-new** | `freedos-zero-input-prep.md` | no | external disk proof; 6.477 s trimmed |
| msdoswin1 | **authored-untested** | `msdoswin1-zero-input-prep.md` | no | suppresses post-launch loadvm helper |
| os2warp | **existing** | `os2warp-zero-input-prep.md` + promote notes | **live** | Tier 2 left-icon crop |
| qnx | **authored-untested** | `qnx-zero-input-prep.md` | no | automated LiveCD driver; requires `QNX_RECORD_PASSWORD` |
| sailfishos | **authored-untested** | `sailfishos-zero-input-prep.md` | no | restart kind; current live shot is boot text, hard publish blocker |
| templeos | **authored-untested** | `templeos-zero-input-prep.md` | no | automated two-question driver; video-only |
| serenityos | **authored-untested** | `serenityos-zero-input-prep.md` | no | restart kind; current live shot is black, hard publish blocker |
| postmarketos | **authored-untested** | `postmarketos-zero-input-prep.md` | no | disk+UEFI varstore copies; requires `POSTMARKETOS_RECORD_PIN` |
| c64 | **proven-new** | `c64-zero-input-prep.md` | no | VICE/GEOS bridge proof; 78.587 s trimmed |
| atarist | **authored-untested** | `atarist-zero-input-prep.md` | no | Hatari/EmuTOS bridge; 1024×768 kiosk canvas |
| apple2 | **authored-untested** | `apple2-zero-input-prep.md` | no | LinApple/GEOS bridge; watchdog stopped during cold start |
| amiga | **existing** | (bridge lifecycle documented above) | **live** | Tier 3 (75 s), per-visit FS-UAE cold boot |

Representative new-arm evidence (all under one disposable `repro-bootvideo-arms-*`
namespace, final assets never published):

| tile | framebuffer/seam gate | trim gate | final ffprobe |
|------|------------------------|-----------|---------------|
| alpine | root shell ready; poster == post-loadvm frame, SSIM 1.000000 | 31.900→20.416 s; final MD5 preserved | 1280×800 H.264 High/yuv420p 30/1, keyframes 0.5 s, AAC-LC |
| freedos | complete games menu; poster/loadvm SSIM 0.999594 (caret) | 11.960→6.477 s; final MD5 preserved | 720×400 H.264 High/yuv420p 30/1, keyframes 0.5 s, AAC-LC |
| c64 | GEOS System window ready (visually inspected) | 100.560→78.587 s; final MD5 preserved | 1024×768 H.264 High/yuv420p 30/1, keyframes 0.5 s, AAC-LC |
| ninefront | acme + stats + catclock + focused term; poster/loadvm SSIM 1.000000 | 34.660→31.183 s; MD5 `370587372846cf749aebe732c0c7fce8` preserved | 1024×768 H.264 High/yuv420p 30/1, AAC-LC |

Serving needs no extra config: `gen-boot-manifest.sh` rebuilds
`$WEBROOT/boot/index.json` from every published tile's `boot.json`, and the
https server already MIME-types + Range-serves `/boot/`.
