> **Historical snapshot.** This document describes a one-time promotion session on 2026-07-13. It is kept for historical context and is not a description of the current system.

# os2warp boot-video — LIVE promotion notes (2026-07-13)

Re-bake + supervised live golden swap for the **os2warp** tile (IBM OS/2 Warp 4
GA / "Merlin"), modelled on the win95-clean promotion. The earlier discovery run
(commit `de82576`) proved feasibility and committed the prep/detect, but cleaned
up its clone, so the validated golden was gone — this run **re-baked a fresh
matched clip+golden on a clone and promoted it live**.

## Flow (what was done)

Tooling: `scripts/coldboot/{record-boot,postprocess-boot,gen-boot-manifest}.sh` +
`bootrec-tiles.conf` (os2warp arm) run on the box. `SH_DBUS_TAP` = the crate
`[[bin]]` `bootrec-tap` — the box's built binary source was **sha256-identical**
to this branch's `streamhost/streamhost/src/bin/bootrec-tap.rs`, so the surviving
`/data/vms/bootrec-build-a97055/target/release/bootrec-tap` was reused (no rebuild
needed).

**Staging** (os2warp's launcher references its disk by the ABSOLUTE path
`/data/gallery-guests/OS2Warp/os2.qcow2`, outside `$TILE_DIR`, so record-boot's
`$TILE_DIR`→clone sed can't redirect it): a sandbox staging tiles root
`/data/vms/sandbox/os2warp-stage-tiles/os2warp/` held a copy of `os2.qcow2`, a
byte-copy launcher with only `D=`/`DISK=$D/os2.qcow2` made tile-dir-relative, and
`boot-ref-desktop.png` (the Tier-2 reference = a **read-only** `labctl shot` of the
live golden's settled desktop — the left-icon-column crop carries no clock/pointer).
Run with `BOOTREC_TILES_ROOT=<staging>`. Dry-run confirmed the rewritten clone
device set was byte-identical to live (machine pc,acpi=off,usb=off / cpu pentium /
-vga cirrus / sb16 dbus audio / ide golden / pcnet user-net no-hostfwd / serial
chardev) with only paths/`-name`/`LOADVM` rewritten (cold boot).

## PHASE A — re-bake + validate on the clone (live untouched)

- Zero-input prep: **NONE** (os2warp cold-boots unattended to the clean gallery WPS
  desktop; STARTUP.CMD launches WARPD.EXE + builds the desktop, then auto-closes its
  VIO window). Verified by the clone's own cold boot reaching the interactive desktop.
- Detect: **Tier-2 reference-region** (crop `110:250:10:105`, left icon column).
  Discrimination was clean — "please wait" plateau region-SSIM ~0.0001, settled
  desktop 1.000000 ×3 — **INTERACTIVE reached at +115587 ms** (`tier2 region match x3`).
  (Tier-1 framebuffer-stability is a trap here: the "Setting up the gallery desktop,
  please wait…" VIO sits byte-static ~45 s, and the WarpCenter clock ticks forever.)
- **M1 GATE (the ONLY gate for os2warp): poster == screendump(loadvm golden) —
  `md5` IDENTICAL** `0a7ff7d641ca539a59d73cd57c133d8e` (poster.png == verify.png),
  **SSIM 1.000000**. This is the load-bearing seam invariant.
- **M2 IGNORED (as mandated):** boot.mp4-last vs lossless poster ≈ 0.885 is a proven
  H.264 4:2:0-vs-lossless chroma artifact on the dithered blue-noise wallpaper — NOT
  a wrong frame / seam. Live and boot are BOTH 4:2:0 so they match. Wallpaper NOT
  flattened.
- Clip: 640×480, `durationMs 115920` (~116 s, long boot), `hasAudio true` (the sb16
  track is digital silence — OS/2's startup chime didn't fire in-window; harmless).

## PHASE B — live promotion (gated, reversible)

Launch model (per `streamhost@.service`: "The tile's QEMU must already be up"):
the **daemon only connects** to an already-running qemu's `qmp.sock`; qemu is
launched separately by `qemu-streamhost.sh` (which does `-loadvm golden`). Swap
procedure therefore: stop daemon → kill qemu **by pidfile** → `cp` clone golden →
live path → **relaunch qemu via the launcher** → daemon auto-reconnects.

- **Golden backup:** `/data/gallery-guests/OS2Warp/os2.qcow2.promote-bak-20260713-230412`
  — `md5 e20ddf1510f9f986aeeaef0f3faf9c7c` (== pre-swap live).
  **Rollback:**
  ```
  systemctl stop streamhost@os2warp
  kill "$(cat /data/vms/streamhost/tiles/os2warp/qemu.pid)"   # by pidfile only
  cp -f /data/gallery-guests/OS2Warp/os2.qcow2.promote-bak-20260713-230412 \
        /data/gallery-guests/OS2Warp/os2.qcow2
  /data/vms/streamhost/tiles/os2warp/qemu-streamhost.sh       # relaunch qemu (loadvm golden)
  systemctl start streamhost@os2warp
  ```
- **New live golden:** `md5 9b64e22fa98747f00b5429bc6f634b90`, internal `golden`
  snapshot `2026-07-13 23:02:59` (122 MiB), `goldenSha 07d1b31dae76849aedd58af8a737625b25e5bfcdafc6f183e7dd2932d5ae01ce`.
  `qemu-img check` = no errors.
- **Framebuffer money shot** (`labctl shot os2warp` after restart): CLEAN interactive
  WPS desktop — full icon column (OS/2 System, Klondike, OS/2 Chess, Mahjongg, DOOM,
  System Editor, OS/2 Window; Assistance Center, Connections, Programs, WebExplorer,
  Get Netscape Navigator; Shredder), OS/2 WARP logo, pointer parked at the WARPD
  default. NO error / login / wizard / ScanDisk / greeter. Matches the clip end (only
  the WarpCenter clock time + pointer park differ — cosmetic). **GATE PASSED.**
- **Published** (`gen-boot-manifest.sh`): `/boot/os2warp/{boot.mp4,poster.jpg,
  sprite.jpg,thumbs.vtt}` + merged into `/boot/index.json` (amiga + win95 + haiku
  preserved, os2warp added). curl over the live HTTPS server:
  `/boot/os2warp/boot.mp4` → `206 Partial Content`, `Content-Type: video/mp4`,
  `Content-Range bytes 0-1023/21940615`; `/boot/index.json` keys
  `[amiga, win95, haiku, os2warp]`.

Clone + staging (`/data/vms/sandbox/{bootrec-os2warp-*,os2warp-stage-tiles}`) removed
by pidfile-safe teardown. Live `streamhost@os2warp` healthy on the new golden.
SPA bundle intentionally **not** touched (flagged for a later step).
