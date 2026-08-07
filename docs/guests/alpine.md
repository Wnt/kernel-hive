# Alpine gallery tile — golden fixture + ssh exec channel

**Status: LIVE.** Tile `alpine` (VMID 81, udp/54081) — Alpine Linux standard
LiveCD, text-console golden test fixture, `resetMode=loadvm`, ssh exec channel
on host port **5881** (user `root`, gallery key). Reproducible builder:
**`scripts/build-guests/alpine.sh`** (fully automated, proven end-to-end
2026-07-14 on Alpine 3.24.1).

## What this tile is

- **OS**: Alpine Linux, latest stable x86_64 **standard** LiveCD (resolved at
  build time from `dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml`,
  sha256-verified). The **standard** flavor matters: it carries the apk
  repository ON the ISO (`/media/cdrom/apks`), so `apk add openssh` works with
  no network repository — the whole bake is possible on an offline mirror of
  the single ISO file.
- **Model**: the LiveCD runs entirely in guest RAM — there is **no installed
  disk**. A scratch qcow2 (`state.qcow2`, 2G, **IDE**) is attached solely to
  hold the live `savevm golden` VM-state snapshot; the guest never boots or
  mounts it (`-boot d` keeps booting the CD).
- **Surface**: root text console on tty1 — ASCII fixture banner + a fresh
  `localhost:~#` prompt with a **steady (non-blinking) caret**. Keyboard-
  reactive; no pointer surface (text console, no gpm — usb-tablet is present
  but unconsumed).

## Device-set contract

The golden snapshot records the QEMU device set; **every** launcher that wants
`-loadvm golden` to work must match it exactly:

```
-enable-kvm -m 1024 -smp 2 -cpu host -rtc base=localtime
-cdrom <ISO> -boot d -drive file=state.qcow2,if=ide,format=qcow2
-vga std -audiodev …,id=snd0 -device AC97,audiodev=snd0 -usb -device usb-tablet
```

- **No `-machine`** (QEMU default pc) and **no explicit `-netdev`** — the guest
  uses QEMU's DEFAULT SLIRP user NIC. Display/audio *backends* (dbus vs
  none/vnc) are not part of vmstate and may differ between the bake and
  production launchers; devices may not.
- The host→guest ssh forward is **host-side SLIRP state**, re-added after every
  cold QEMU start via QMP (`hostfwd_add tcp:127.0.0.1:5881-10.0.2.15:22`) —
  never as a `-device`, so the device set never drifts.

## What lives inside the golden snapshot

Baked by the builder, captured in RAM/device state (the LiveCD persists
nothing on disk):

- `eth0` static `10.0.2.15/24`, gw `10.0.2.2` (no DHCP client in the fixture).
- `openssh` installed from the ISO's own apks, host keys generated
  (`ssh-keygen -A`), `sshd` running, gallery pubkey
  (`/root/.ssh/gallery_guest_key.pub` on the box) as
  `/root/.ssh/authorized_keys`.
- Fixture tweaks (`/root/fixture-tweaks.sh` in-guest): fbcon
  `cursor_blink=0` (the blinking caret was the only idle animation),
  `printf '\033[9;0]\033[14;0]' > /dev/tty1` (console blank + VESA powerdown
  off).
- `/root/banner` + the painted clean screen (`clear; cat /root/banner`).

## Builder (`scripts/build-guests/alpine.sh`)

Fully automated, zero human interaction:

1. Resolves + downloads the latest stable `alpine-standard-*-x86_64.iso`
   → `/data/isos/` (pin with `ALPINE_BRANCH=vX.Y`, or `ISO_URL=…`).
2. Creates `state.qcow2` → `/data/gallery-guests/Alpine/`.
3. Boots the production device set headless (`-display none -vnc unix:…`,
   `-audiodev none`), drives login (`root`, no password) + static network over
   QMP `input-send-event`, then has the guest fetch a payload script from a
   one-shot loopback `http.server` via SLIRP (`10.0.2.2`) that does the
   openssh/key/tweaks work in one shot.
4. Adds a **bake-time** ssh forward (default `127.0.0.1:58811`, deliberately
   NOT the production 5881 so a live tile never collides) and probes it.
5. Paints the banner screen, then PROVES: two idle screendumps 5 s apart
   byte-identical → `savevm golden` → dirty the screen → `loadvm golden` →
   frame byte-identical to the fixture → ssh still answers.
6. Artifacts: `state.qcow2` (golden inside), `fixture-golden.png`,
   `BUILD-INFO.txt`. Idempotent: existing golden → no-op (`REBAKE=1` rebakes);
   ISO re-download skipped on sha256 match.

Trial runs are fully namespaceable: `OUT_DIR= WORK_DIR= ISO_DIR=
BAKE_SSH_PORT= HTTP_PORT=` (see the header). The builder keeps the versioned
ISO and converges `Alpine.iso` inside the selected `ISO_DIR`. It never touches
`/data/vms/streamhost/tiles/*`.

## Tile wiring (production)

- Manifest stanza: `emit alpine` in `streamhost/tiles-manifest.sh`
  (`--pointer abs --audio-dev ac97 --input-dev usb --mem 1024 --smp 2
  --cpu host --vga std --cdrom <ISO> --boot d`, no `--machine`).
- The live launcher `tiles/alpine/qemu-streamhost.sh` is the hand-baked golden
  launcher: create-if-missing `state.qcow2`, conditional `-loadvm golden`,
  post-boot QMP `hostfwd_add` for :5881. `labctl reset alpine` = live
  `loadvm golden`; `labctl exec alpine "<cmd>"` = the ssh channel.

## Gotchas

- **Never delete `state.qcow2`** — it IS the golden snapshot.
- `sshd` runs from the snapshot's RAM state; `rc-update add sshd` is baked too
  but only matters if the guest ever cold-reboots (it shouldn't — reset is
  `loadvm golden`).
- The ssh forward must be re-added after every **cold QEMU start** (it is not
  in the snapshot). `loadvm golden` on a running QEMU does NOT drop it.
- Booting the ISO cold (fresh NVMe rebuild, no snapshot yet) lands at a login
  prompt, not the fixture — run the builder (or its bake steps) to re-bake.
- The bake types only four short console lines; everything else ships in the
  payload — if you extend the payload, keep it idempotent (the console line is
  retry-wrapped).
- **Resolution 1920×1200** (bumped 2026-07-26 from the QEMU std-VGA EDID default
  1280×800). `bochs-drm` only advertises the EDID mode, so the bump is a
  kernel-cmdline change: append `video=1920x1200` to the ISO's isolinux `boot:`
  line (label `lts`) before the LiveCD boots. The golden RAM snapshot captures
  the 1920×1200 fbcon, so `loadvm golden` restores it live and the ssh channel
  is unaffected. A from-scratch `build-guests/alpine.sh` rebuild boots the ISO
  default (1280×800) — re-add the `video=` param at the `boot:` prompt to
  reproduce 1920×1200 (device set / golden container are otherwise unchanged).
