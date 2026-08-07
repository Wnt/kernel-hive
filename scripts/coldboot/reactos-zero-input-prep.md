# reactos — zero-input boot prep notes (boot-video record)

Companion to `win95-zero-input-prep.md`. Records what a boot-video capture of the
**reactos** tile requires, what was rehearsed on a clone 2026-07-13, and why the
result is **NOT promote-ready**. All work was clone-only (`/data/vms/soltest/`);
the live tile/golden/service were never touched.

## What reactos actually is (the thing that breaks the standard flow)

reactos is a **diskless ReactOS 0.4.14 LiveCD** tile:

- The launcher boots the ISO (`-cdrom .../ReactOS.iso -boot d`) and **does not boot
  the qcow2**. `/data/reactos-golden/reactos-golden.qcow2` is *only* a `savevm golden`
  store (RAM+device snapshot). There is **no writable OS disk**.
- Reset in production is a **live QMP `loadvm golden`** by the daemon
  (`GOLDEN_RESET_MODE=loadvm`); the launcher itself has **no `-loadvm`** line and
  already cold-boots on every launch.
- Golden desktop resolution is **800×600** (`/data/reactos-golden/base.ppm` = `P6 800 600`).

### Consequence 1 — the §3.2 disk-baked zero-input prep has NO surface

The per-OS zero-input prep in the spec bakes registry/config into the **boot disk**.
Here the boot medium is an **immutable LiveCD** and the qcow2 is never read during
boot, so there is nothing to bake into. A cold boot runs the stock LiveCD GUI, which
is **not zero-input**:

```
SeaBIOS → FreeLdr menu (auto-boots "LiveCD" after ~4s, OK)
        → driver-load screen (grey ReactOS list, OK)
        → "Please wait… Installing devices…" PnP progress dialog  (transient)
        → "ReactOS LiveCD" LANGUAGE / KEYBOARD dialog  [Next] [Cancel]  ← MODAL, no timeout
        → "Run ReactOS Live CD" chooser                              ← MODAL, no timeout
        → bare desktop
```

Both modal dialogs are **click-gated with no timeout**. Zero input parks forever at
the Language dialog (verified: clone framebuffer identical at +40s and +55s). The
curated live golden was built by a human clicking both dialogs, then opening Notepad
and hiding the clock (`/data/reactos-golden/build-golden.md`).

### Consequence 2 — the detector false-settles before the desktop

The record rehearsal ran the actual **Tier-1** (framebuffer-stability) detector. It
**false-settled at +23.0 s on the "Installing devices…" progress dialog** (the bar
stalled long enough for `cf<0.005` for 3 s). Poster = that PnP dialog, not a desktop.
Even a correct settle would only ever reach the Language dialog with zero input.

### Consequence 3 — record-boot.sh is UNSAFE for reactos as written

`record-boot.sh` copies `BR_DISKS` from `$TILE_DIR/$d` and its launcher-rewrite sed
only redirects `$TILE_DIR` → clone dir. reactos's golden lives at
`/data/reactos-golden/` (hard-coded `GDIR=`), **outside** `$TILE_DIR`, so it is **not
redirected**: an automated run would attach and `savevm`-overwrite the **LIVE golden**.
`--dry-run` confirms line 30 still reads `-drive file=$GDIR/reactos-golden.qcow2` with
`GDIR=/data/reactos-golden`. The tool needs an **external-golden-store override**
(e.g. `BR_GOLDEN_STORE` copied into the clone + a `GDIR=` rewrite) before it can
record reactos safely.

## The safe clone rehearsal (2026-07-13)

Hand-rolled a safe clone: copied the golden qcow2 into the clone dir and rewrote
`GDIR` + tile-dir paths so nothing points at live. Recorded the real zero-input cold
boot with `bootrec-tap` → ffmpeg (video-only; the LiveCD boot is silent even though
`-device AC97` is present), let Tier-1 settle, froze, `savevm golden` on the **clone
copy**, verified the seam, then killed by pidfile and removed the clone dir.

Measurements (clone):

| measurement | value | gate | result |
|---|---|---|---|
| SSIM(poster, screendump(loadvm golden))    | **1.000000** (md5-identical) | ~1.0    | PASS — seam machinery byte-perfect |
| SSIM(boot.mp4 last frame, poster)          | **0.999860**                 | ≥0.999  | PASS |
| SSIM(zero-input settle, curated live golden) | **0.696970**               | —       | far off — settle ≠ desktop |

The freeze→poster→`savevm`→`loadvm` **invariant machinery works perfectly on reactos**
(1.0 / identical md5). What fails is the **content** of the settle frame: it is a
transient PnP dialog, and with zero input the best reachable frame is the Language
dialog — **never the interactive desktop**. → **promoteReady = NO.**

## Golden-change risk (for the human go/no-go)

- **Current live golden ("from"):** curated fixture — active empty *"\*Untitled -
  Notepad"* window (focused caret = keyboard-reactive surface), pointer parked on the
  clear blue desktop, **taskbar clock hidden**, screensaver/DPMS off. This is the exact
  frame every visitor sees the instant the tile goes live.
- **A boot-video-derived golden ("to"):** the video must end on the frame that is
  re-baked as golden. With zero input that frame is a **Language dialog** (or the PnP
  progress dialog Tier-1 grabbed) — **regressing** the tile from a polished desktop to
  a setup dialog. Even after manually clicking through, a clean-boot golden would be a
  **bare desktop with a visible ticking clock and no Notepad** — a different curated
  surface than today's, and the ticking clock re-introduces above-floor ambient motion
  the current fixture deliberately removed.

## What promotion would require (options for a human)

1. **Keep the curated golden, script the boot video separately.** Record a boot clip
   that is driven (2 clicks) through the Language + Run dialogs to the desktop, then
   `savevm` a golden that matches the *curated* end-state (Notepad open, clock hidden).
   The recorded pointer clicks are cosmetic; the handoff only needs last-frame == golden
   first-frame. Needs the record tool taught to drive input + the external-golden fix.
2. **Re-architect to an installed disk.** Install ReactOS to the qcow2 and boot the
   disk (not the LiveCD) so `AutoAdminLogon`-style zero-input prep has a surface. Large
   change; new golden; out of scope for a record pass.
3. **Unattended LiveCD.** Rebuild the ISO with a preseeded language/run answer so the
   LiveCD auto-advances to the desktop. Changes the boot medium; new golden.

All three are **golden re-bakes**, not a record-only step, so they are deferred to a
supervised bake window. This pass leaves the clone artifacts **staged only**
(`/data/vms/streamhost/boot-rec/reactos/`) and promotes nothing.
