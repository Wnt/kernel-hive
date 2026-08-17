# os2warp boot-capture — zero-input prep + detection notes

Reproduction notes for baking a boot video on the **os2warp** vmstate tile
(IBM OS/2 Warp 4 GA "Merlin") with `record-boot.sh` (spec
`BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end on a
`/data/vms/sandbox` clone 2026-07-13; the live tile was **never touched**
(golden snapshot `2026-07-13 12:38:54`, service, `qmp.sock`/`serial.sock` all
unchanged at the end).

## Zero-input prep required: NONE (cold boot already reaches the desktop unattended)

Unlike win95 (network-logon modal) / win98se, the os2warp golden **already**
cold-boots to its clean gallery WPS desktop with **zero keyboard/mouse input**.
Verified on a cold-boot clone (no `loadvm golden`) by framebuffer screendumps
spanning the whole boot:

- **BootManager / firmware** auto-boots the default — no boot-menu keypress
  (SeaBIOS/iPXE "Booting from Hard Disk...", then the OS/2 WARP splash).
- **No logon** — OS/2 Warp 4 GA has no logon by default.
- **No registration nag** — registration was already completed on the golden
  disk during the original build; a cold boot does **not** re-prompt.
- **`STARTUP.CMD` does the rest, unattended.** A VIO command window opens showing:
  ```
  [C:\]start C:\WARPD.EXE
  Setting up the gallery desktop, please wait...
  ```
  i.e. it launches the in-guest **WARPD.EXE** pointer agent (the same agent the
  live `SH_POINTER=warpd` serial channel drives) and then builds/arranges the
  gallery desktop objects. When finished (~t116 s in TCG) the script exits and
  its VIO window **auto-closes**, leaving the clean WPS desktop.

So no on-disk change was made. The copied qcow2 was cold-booted, filmed, frozen
at the settled desktop, `savevm golden`'d on the paused state, and verified — all
on the clone. (If a future golden ever regressed this — e.g. WARPD.EXE dropped
from `STARTUP.CMD`, or registration reset — the fix would live in `STARTUP.CMD` on
`C:` via `qemu-nbd`, not per-boot input.)

## Detection: Tier-2 reference-region (Tier-1 is a TRAP here)

`BR_DETECT_TIER=2`, `BR_REF_CROP="crop=110:250:10:105"` (left icon column),
`BR_REF_MATCH_K=3`, reference `boot-ref-desktop.png` = the settled cold-boot
desktop screendump. **Tier-1 framebuffer-stability would false-settle** for two
independent reasons, both measured on the clone:

1. **The "please wait" plateau.** During the `STARTUP.CMD` gallery-desktop build
   the VIO window sits **byte-static for ~45 s** (full-frame `SSIM(t45,t90) =
   0.9994` ⇒ cf `0.0006` < the 0.005 Tier-1 threshold). Tier-1 would freeze &
   bake *that* "Setting up the gallery desktop, please wait..." frame — the exact
   win95 "blank teal" trap.
2. **The live WarpCenter bar.** Even on the finished desktop the top ~20 px bar
   keeps a **ticking clock + free-memory counter** animating every second, so
   whole-frame stability never truly settles either.

The chosen crop is the **left icon column** (Assistance Center / Connections /
Programs). It is painted **only once the gallery desktop is fully built** (black
during "please wait"), carries no clock and no parked pointer, and is static.
Discrimination validated on the clone:

| region-SSIM vs settled reference (crop) | value |
|---|---|
| "please wait" plateau frame | **0.0001** (no false match) |
| settled gallery desktop frame | **1.0000** (clean match ×3) |

Detect fired at **+116.5 s** (`tier2 region match x3`).

## Staging (out-of-tile disk — like win98se)

The live launcher references its disk by the **absolute** path
`DISK=/data/gallery-guests/OS2Warp/os2.qcow2` (NOT `$TILE_DIR`), so
`record-boot.sh`'s `$TILE_DIR`→clone `sed` does not redirect it; a naive run
would leave the clone (and `savevm golden`!) pointing at the LIVE disk (and would
also fail QEMU's qcow2 lock against the running live service). Run with
`BOOTREC_TILES_ROOT` pointed at a sandbox staging tiles root holding:

- a **copy** of `os2.qcow2`,
- a launcher that is a byte copy of live with only `D=<staging/os2warp>` and
  `DISK=$D/os2.qcow2` (tile-dir-relative) so the sed redirects both into the clone,
- `boot-ref-desktop.png` (the Tier-2 reference).

Dry-run diff of the rewritten clone launcher vs live showed **only** the allowed
rewrites: `D=`/`DISK=` paths (→ clone), `LOADVM` neutralised (cold boot), and the
`-name …-bootrec` suffix. Every `-machine/-cpu/-vga/-display/-audiodev/-device/
-drive/-serial/-netdev` line was byte-identical. os2warp has **no hostfwd** (its
pointer rides a serial chardev, not a host TCP port), so `BR_HOSTFWD_*` are empty
and there is nothing to collide with the live tile.

For a real **live bake** (not this clone proof), drop the golden-fixture
screendump at `tiles/os2warp/boot-ref-desktop.png` (the conf's default
`BR_REF_PNG` path) instead of staging one.

## Measurements (this clone bake)

- **Invariant (poster == golden first live frame):** `md5` **identical**
  (`427858bc…`), `SSIM = 1.000000`. The `savevm golden` → `loadvm golden`
  round-trip reproduces the poster byte-for-byte. This is the load-bearing seam.
- **boot.mp4 last frame vs poster:** `SSIM = 0.885` — **below** the 0.999 gate,
  but this is a metric artifact, **not** a wrong frame. The last frame *is* the
  clean gallery desktop. os2warp's wallpaper is a high-frequency **dithered blue
  noise** pattern; under the mandated **yuv420p (4:2:0)** colorspace (required to
  match the live WebCodecs decoder), 4:2:0 chroma subsampling alone floors SSIM
  vs the lossless RGB poster at **~0.89** — proven by round-tripping the lossless
  poster through the same encoder (crf18 4:2:0 → 0.834; crf0/lossless-luma 4:2:0
  → 0.890). ≥0.999 is therefore mathematically unreachable for this tile without
  abandoning 4:2:0 (which would *break* the live-path colorspace match). The
  handoff that actually matters is boot-4:2:0 → live-4:2:0 (apples-to-apples
  ~0.95) plus the player's opacity insurance fade — visually seamless.

boot.json: `640×480`, `durationMs 116720`, `hasAudio true` **but the captured
audio track is digital silence** (`mean=max=-91 dB`) — OS/2 Warp 4's system
startup sound did not fire in this window; there is no boot chime to keep.
Consider `hasAudio=false` / `-an` for the delivered os2warp clip.

## Golden-change risk (for the human go/no-go)

Promoting a cold-boot-baked golden would replace the current **warm** golden. The
two states are the **same clean gallery WPS desktop** (same icon layout: OS/2
System, Klondike, OS/2 Chess, Mahjongg, DOOM, System Editor, OS/2 Window, plus the
left column; OS/2 WARP logo; Shredder; **WARPD.EXE running** in both — it
auto-starts via `STARTUP.CMD` on cold boot, so the pointer agent is preserved).
Differences are cosmetic: the WarpCenter clock shows a different time, and the
mouse pointer parks at the WARPD default (~325,240). No open-window curated state
is lost (the current live golden has **no** windows open). Low risk.
