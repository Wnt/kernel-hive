# haiku boot-capture — zero-input prep + detection notes

Reproduction notes for baking a boot video on the **haiku** vmstate tile with
`record-boot.sh` (spec `BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end
on a `/data/vms/soltest` clone 2026-07-13; **the live tile was never touched**
(service `active`, `qmp.sock` unchanged, golden snapshot still the original
ID 1 / 719 MiB / 2026-07-08 throughout).

## Zero-input prep: NONE required (disk unchanged)

Unlike win95, **no in-guest / on-disk prep was applied** — the clone's copied
`haiku-persist.qcow2` was recorded byte-for-byte as cloned. A cold power-on
(no `loadvm golden`) reaches the interactive Haiku desktop with **zero keyboard/
mouse input**, because:

- Haiku boots straight to the desktop — **no login**, no first-boot/Welcome
  dialog on the installed disk (GOLDEN-MANIFEST.md).
- BFS is journalled: the crash-consistent copy of the (continuously-running)
  live qcow2 **replays its journal automatically** — no fsck/ScanDisk-style
  prompt (the win95 dirty-shutdown blocker has no Haiku equivalent here).
- The golden's determinism tweaks are **on-disk** settings
  (`~/config/settings/deskbar/{clock_settings,replicants,settings}`,
  `ScreenSaver_settings`, `Terminal/Default`) so they persist to the cold boot:
  clock HIDDEN, ProcessController replicant REMOVED, screensaver+DPMS OFF. The
  settled cold-boot desktop is therefore **byte-static** (screendumps
  md5-identical across t14s..t44s) — no idle animation.

Cold-boot timeline (2 s screendumps, investigation clone):
`SeaBIOS ~t2s → Haiku boot SPLASH ~t6s → screen clears to BLACK ~t8-10s →
desktop paints → byte-static desktop from ~t14s`. `record-boot.sh` (Tier-2)
settled at **+18.3 s**.

### The one difference vs the live golden: no Terminal (see GOLDEN-CHANGE RISK)

The live golden ends on a **focused Terminal at an empty `~>` prompt** (the
curated input-reactive surface), opened *live* by `fixture-tweaks.sh`
(`/system/apps/Terminal &`). Haiku does **not** restore apps across a reboot, so
a cold boot reaches the **bare desktop with no Terminal**. Promoting this boot
video therefore changes the live on-connect frame from *Terminal-open* to
*bare clean desktop* — a supervised go/no-go, not part of this clone proof.

## Detection: Tier-1 FALSE-SETTLES on the boot splash → use Tier-2

**Tier-1 framebuffer-stability must NOT be used for haiku.** Measured on the
clone: the Haiku boot **splash** (black screen, HAIKU logo, a row of boot-stage
icons that light up one by one) advances with a per-frame cf of only
**~0.0008–0.0014 — below the 0.005 Tier-1 threshold** — so the detector treats
the still-animating splash as "stable" and settles at **+6.7 s, baking the BOOT
SPLASH, not the desktop** (poster == splash; confirmed by screendump). The clip
that run was 7.9 s and never reached the desktop.

**Tier-2 reference-region** fixes it. SSIM a crop of the **top-right Deskbar**
(leaf logo + header) against a settled-desktop reference:

    BR_REF_CROP="crop=135:60:1145:0"

That region is **pure black during the splash** and only paints once the desktop
is up. Measured discrimination:

| frame                | region-SSIM vs reference |
|----------------------|--------------------------|
| boot splash (~t6s)   | 0.000001                 |
| black transition     | 0.000001                 |
| desktop mid-paint    | 0.330582                 |
| settled desktop      | 1.000000 (×3 → settle)   |

K=3 @1 s poll ⇒ 3 s of confirmed desktop. Result: settled at **+18.3 s on the
real desktop**, `region-ssim 1.0 ×3`.

### Reference PNG — staged, NOT written into the live tile dir

The `haiku` arm resolves `BR_REF_PNG` via an override hook:

    BR_REF_PNG="${HAIKU_BOOT_REF:-${BOOTREC_TILES_ROOT:-/data/vms/streamhost/stations}/haiku/boot-ref-desktop.png}"

- **Clone proof (this run):** `export HAIKU_BOOT_REF=<staged settled-desktop
  screendump>` so nothing is written under the live tile dir. Here it was
  `/data/vms/streamhost/boot-rec/haiku/boot-ref-desktop.png` (a screendump of the
  settled cold-boot desktop from an investigation clone).
- **Live bake (future, supervised):** drop the golden fixture screendump at the
  default tile-dir path under the same name (matches the win95 convention).

## Invariant result (clone, framebuffer truth)

`poster == screendump(loadvm golden)` **SSIM 1.000000 (md5-identical,
`276b17d4a576a359bda570c0ce219a92`)**; the poster also matches the staged
settled-desktop reference at SSIM 1.000000. boot.mp4 last decoded frame vs poster
**SSIM 0.999391** (H.264/yuv420p residual only). Clip **20.6 s**, **1280×720**,
H.264 (+ AAC track), `goldenSha 3a2bd090…`.

## Audio: track present but SILENT (no boot chime)

`-device intel-hda -device hda-output` is in the device set, so the tap opens an
audio stream and `boot.json` carries `hasAudio: true`. But the captured PCM is
**digital silence — `max_volume -91.0 dB`**: this Haiku golden emits **no startup
chime**. (First Tier-1 run froze at +6.7 s before the HDA codec initialised →
0 bytes PCM; the Tier-2 run reached the desktop and streamed 1.13 MB of PCM, all
≈ −91 dB.) A human may prefer to set `hasAudio: false`, or enable the Haiku
"Startup" system sound before a live bake if a chime is wanted.

## Reproduce

```bash
ssh lab
export SH_DBUS_TAP=/data/vms/bootrec-build-a97055/target/release/bootrec-tap
export HAIKU_BOOT_REF=/data/vms/streamhost/boot-rec/haiku/boot-ref-desktop.png
cd /data/subvol-950-disk-0/home/<user>/osgallery
scripts/coldboot/record-boot.sh haiku --dry-run   # eyeball the clone device set
scripts/coldboot/record-boot.sh haiku             # Tier-2 → freeze → savevm(clone) → verify
scripts/coldboot/postprocess-boot.sh haiku        # sprite.jpg + thumbs.vtt + durationMs
# gen-boot-manifest.sh / live promotion are SEPARATE supervised steps (not run here).
```

> The `record-boot.sh` dry-run prints
> `WARN: loadvm neutralise did not match` for haiku. This is a **benign no-op**:
> the haiku launcher has **no** `-loadvm golden` line (unlike win95) — it
> cold-boots by design and the streamhost daemon does the `loadvm golden` at
> connect (`SH_RESET_MODE=loadvm`). There is nothing to neutralise; the clone
> cold-boots correctly and the device set is byte-identical to live.

## LIVE promotion (2026-07-13, supervised — DONE, Terminal → bare desktop)

The discovery run above proved feasibility and committed this prep, but cleaned up
its clone, so its validated golden was gone. This run **re-baked a fresh matched
clip+golden on a new clone and promoted it live**, gated and reversible. The
authorised golden change is **focused-Terminal → bare clean desktop** (the cold
boot never restores the live `fixture-tweaks.sh` Terminal). No disk prep: the clone
boots to the desktop byte-unchanged.

### Re-bake + validate on the clone (live untouched)
`record-boot.sh haiku` (Tier-2, `HAIKU_BOOT_REF` = the preserved settled-desktop
reference from the discovery run): settled on the real desktop at **+18.33 s**
(`region-ssim 1.0 ×3`), `savevm golden` on the paused clone, `loadvm golden` →
screendump → **SSIM(golden-first-frame, poster) = 1.000000** ("INVARIANT OK").
`postprocess-boot.sh haiku` → clip **22.23 s**, **1280×720**, H.264+AAC,
`hasAudio: true`, `goldenSha 140a2057…`.

**M1 seam invariant (md5-identical, the gate):** an independent relaunch +
`loadvm golden` screendump, the tool's own `verify.png`, and the freeze-frame
`poster.png` are all the same PPM — **md5 `97724d2d1a1cb5aab03e4f93e93f7e28`**.
`poster == screendump(loadvm golden)` bit-for-bit. Clone framebuffer = bare Haiku
desktop (HAIKU wallpaper, Deskbar leaf+Tracker, icons; **no Terminal**).

### Live promotion (gated, reversible)
- **Backup:** live golden `haiku-persist.qcow2` (pre-swap md5
  `6a48ee5bf63426168bb300594b755cab`) → `haiku-persist.qcow2.bak-terminal-golden-20260713-224708`.
  Rollback: `systemctl stop streamhost@haiku; kill $(cat …/qemu.pid);
  cp --reflink=auto …bak-terminal-golden-20260713-224708 …/haiku-persist.qcow2;
  …/qemu-streamhost.sh; systemctl start streamhost@haiku`.
- **Swap:** stop daemon → kill live QEMU by pidfile → `cp` the validated clone
  golden onto the live path (device set byte-identical — dry-run verified: only
  paths / `-name` / hostfwd 5807→6807 rewritten, no `-device` change) → relaunch
  the live launcher (cold-boot; daemon does `loadvm golden` at connect). New live
  golden md5 `bb64812b4aaceeb7362e85e744bf367c`, single `golden` snapshot
  (ID 1 / 692 MiB / 2026-07-13 22:44).
- **Framebuffer gate (money shot):** `labctl reset haiku` (loadvm golden) +
  `labctl shot haiku` → bare clean Haiku desktop matching the clip end, **no
  Terminal, no error/login/wizard/greeter**. Guest interactive
  (`labctl exec haiku "uname -a"` → `Haiku shredder … hrev57937+113 x86_64`).
- **Publish:** `gen-boot-manifest.sh haiku` rsynced the fresh assets to
  `$WEBROOT/boot/haiku/` and merged `/boot/index.json` (amiga + win95 preserved →
  3 tiles). Verified live: `/boot/haiku/boot.mp4` → **206 `video/mp4`**
  (Content-Range …/1001584); index has amiga+win95+haiku; poster/sprite/vtt 200.

The SPA `▶Boot` badge/registry flag is wired separately (SPA agent); this work only
re-baked the golden and served the assets. NOTE: `station.env` `SH_FIXTURE_DESC` still
describes the *focused-Terminal* fixture — now stale (bare desktop); left unchanged
(purely descriptive, no behavioral effect) for a human to refresh.
