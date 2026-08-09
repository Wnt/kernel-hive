# TinyCore gallery tile — golden fixture + ssh exec channel

**Status: LIVE.** Tile `tinycore` (VMID 82, udp/54082) — Tiny Core Linux x86
GUI LiveCD (FLWM + wbar desktop), golden test fixture with an open aterm
terminal, `resetMode=loadvm`, ssh exec channel on host port **5882** (user
`tc`, gallery key). Reproducible builder:
**`scripts/build-guests/tiles/tinycore.sh`** (fully automated, proven end-to-end
2026-07-14 on Tiny Core 17.0).

## What this tile is

- **OS**: Tiny Core Linux, latest stable **x86 (32-bit)** "TinyCore" GUI
  LiveCD (~26 MB; version resolved at build time from
  `tinycorelinux.net/downloads.html`, md5-verified against the upstream
  `.md5.txt` sidecar). Release discovery uses Tiny Core's HTTP-only download
  page; ISO and checksum downloads prefer its HTTPS ibiblio mirror. This is
  the middle of the three Core spins — Core
  (CLI-only) < **TinyCore** (FLWM/wbar GUI) < CorePlus.
- **Model**: the LiveCD runs entirely in guest RAM — **no installed disk, no
  TinyCore backup (`mydata.tgz`) and no tce dir**. A scratch qcow2
  (`state.qcow2`, 3G, **virtio**) is attached solely to hold the live
  `savevm golden` VM-state snapshot; the guest never boots or uses it. The
  whole fixture — loaded `openssh.tcz`, sshd, DHCP lease, open terminal, xset
  tweaks — lives in the snapshot's RAM/device state.
- **Surface**: FLWM desktop at **1600x1200x32** (4:3, under the 1920x1200 cap;
  set by `Xvesa -screen 1600x1200x32` in `~/.xsession`) with the wbar dock,
  static "core" wallpaper, and one open **aterm** terminal at a clean
  `tc@box:~$` prompt
  (steady non-blinking caret). Keyboard-reactive (the terminal) and
  mouse-reactive (wbar, titlebar, desktop).

## Device-set contract

The golden snapshot records the QEMU device set; **every** launcher that wants
`-loadvm golden` to work must match it exactly:

```
-enable-kvm -m 768 -smp 2 -machine pc -cpu host -rtc base=localtime
-drive file=state.qcow2,if=virtio,format=qcow2 -cdrom <ISO> -boot d
-vga std -audiodev …,id=snd0 -device AC97,audiodev=snd0 -usb -device usb-tablet
```

- **No explicit `-netdev`** — QEMU's DEFAULT SLIRP user NIC; the host→guest
  ssh forward is re-added after every cold QEMU start via QMP
  (`hostfwd_add tcp:127.0.0.1:5882-10.0.2.15:22`), never as a `-device`.
- Display/audio *backends* differ freely between bake (`-vnc`/`none`) and
  production (dbus) — backends are not part of vmstate (verified for this
  tile 2026-07-06 and again by the builder's own round-trip).

## Pointer: two quirks worth knowing

- **tinyX (Xvesa) is relative-only** — it ignores the usb-tablet. Automation
  must drive the pointer via the legacy QMP relative path (`mouse_move`),
  which needs an active graphic console (a `-vnc` server suffices; dbus-p2p
  with no peer does not). The builder does exactly this.
- **The streamhost transport runs `SH_POINTER=abs`**, but because Xvesa reads a
  RELATIVE PS/2 mouse (the kernel feeds tablet-abs → `/dev/input/mice` as
  relative deltas), the daemon's `SetAbsPosition` path is effectively
  **relative tracking with edge re-homing**: the cursor clamps at the screen
  edges (which re-anchors the origin) and tracks 1:1 in the interior. So the
  single `cursor_scale` sets the **1:1 GAIN** — the offset is a neutral origin,
  not an absolute anchor. The abs→rel transfer is linear with slope `A≈1.28`
  per axis (equal at 4:3), so at **1600x1200** the calibration is
  `scale 0.783, off (0,0)` (`1/A`). Live-client + framebuffer verified 2026-07:
  after any edge touch, commanded corners/center/edges land within **~1px**
  (e.g. center 800,600 → 799,599; left-mid 80,600 → 79,599). The FIRST cursor
  move of a session lands at an arbitrary offset until the pointer first touches
  an edge (inherent to the relative device). Calibration MUST be measured on the
  LIVE tile via a registered browser client — no QMP/HMP offline injection moves
  the cursor under the production dbus launcher. Derivation: drive the client
  across a mid-screen grid with `SH_DEBUG_INPUT=1`, read `recv`/`inject` from the
  daemon log, locate the guest cursor via `labctl shot`, fit `landing = A·inject
  + B`, set `scale = 1/A`. **Re-verify after any TinyCore major bump or
  resolution change.**

## What lives inside the golden snapshot

- `openssh.tcz` (+deps) tce-loaded from the version-matched upstream repo,
  `sshd_config` copied from `.orig`, host keys generated, sshd running,
  gallery pubkey (`/root/.ssh/gallery_guest_key.pub` on the box) as
  `/home/tc/.ssh/authorized_keys`. Login user is **`tc`** (passwordless sudo).
- `eth0` DHCP lease `10.0.2.15` (SLIRP).
- `~/.X.d/gallery-fixture`: `xset s off; xset s noblank; xset -dpms` + `aterm &`
  — TinyCore sources `~/.X.d/*` at X startup, so the desktop comes up already
  curated. The open aterm is the same plain `aterm` the wbar Terminal icon
  execs.

## Builder (`scripts/build-guests/tiles/tinycore.sh`)

Fully automated, zero human interaction:

1. Resolves the current stable x86 version, downloads
   `TinyCore-<ver>.iso` → `/data/isos/` (md5-verified; HTTPS ibiblio official
   mirror, with the upstream site as fallback; pin with `TC_VERSION=N.N` or
   `ISO_URL=…`).
2. Creates `state.qcow2` → `/data/gallery-guests/TinyCore/`.
3. Boots the production device set headless and, at the ISOLINUX **menu.c32**
   boot menu (default label `tc`, `APPEND loglevel=3 cde`), presses **TAB and
   appends the official `text` bootcode**: the onboard GUI extensions still
   load (`cde`) but X does not autostart — we land at a fully keyboard-
   driveable `tc@box:~$` text shell (verified reactive before proceeding).
4. The guest fetches a payload from a one-shot loopback `http.server` via
   SLIRP (`10.0.2.2`): openssh + gallery key + the `~/.X.d` fixture drop.
5. Bake-time ssh forward (default `127.0.0.1:58821`, deliberately NOT the
   production 5882) + probe; then `startx` → curated desktop; pointer parked
   inside the aterm + click (FLWM is focus-follows-mouse); typed focus probe
   must visibly change the framebuffer; `clear`.
6. PROVES: idle determinism (two shots 5 s apart byte-identical) →
   `savevm golden` → dirty → `loadvm golden` → byte-identical frame → ssh
   still answers.
7. Artifacts: `state.qcow2` (golden inside), `fixture-golden.png`,
   `BUILD-INFO.txt`. Idempotent: existing golden → no-op (`REBAKE=1`
   rebakes); ISO re-download skipped on md5 match.

Trial runs are fully namespaceable: `OUT_DIR= WORK_DIR= ISO_DIR=
BAKE_SSH_PORT= HTTP_PORT=`. The builder keeps the versioned ISO and converges
`TinyCore.iso` inside the selected `ISO_DIR`. It never touches
`/data/vms/streamhost/tiles/*`.

## Tile wiring (production)

- Manifest stanza: `emit tinycore` in `streamhost/tiles-manifest.sh`
  (`--pointer abs --cursor-scale 0.783 --cursor-off-x 0 --cursor-off-y 0
  --audio-dev ac97 --input-dev usb --mem 768 --smp 2 --machine pc --cpu host
  --vga std --cdrom <ISO> --boot d`).
- The live launcher `tiles/tinycore/qemu-streamhost.sh` is the hand-baked
  golden launcher: create-if-missing `state.qcow2`, conditional
  `-loadvm golden`, post-boot QMP `hostfwd_add` for :5882. `labctl reset
  tinycore` = live `loadvm golden`; `labctl exec tinycore "<cmd>"` = the ssh
  channel.

## Gotchas

- **Never delete `state.qcow2`** — it IS the golden snapshot.
- **Do not use resetMode=restart**: a reboot re-runs the LiveCD boot and lands
  on a bare desktop with no terminal, no ssh and no tweaks — the fixture only
  exists inside the snapshot.
- The bake **must** go through text mode: the GUI has no terminal open and no
  ssh yet, so there is nothing to type into (chicken-and-egg); `text` +
  payload + `startx` breaks it cleanly. TinyCore has used the same menu.c32
  config since at least 15.x (re-verified on 17.0).
- `tce-load -wi openssh` needs internet at bake time (the tcz repo is not on
  the ISO) — the only network-dependent in-guest step.
- aterm launch is deliberately via `~/.X.d`, not a wbar click: wbar icon
  coordinates drift between releases, `~/.X.d` does not.
- The ssh forward must be re-added after every **cold QEMU start**;
  `loadvm golden` on a running QEMU does NOT drop it.
