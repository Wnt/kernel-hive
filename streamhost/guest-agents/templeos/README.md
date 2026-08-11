# TempleOS warpd agent (tile `templeos`)

`warpd.HC` — in-guest HolyC absolute-pointer agent. TempleOS has no USB stack
(usb-tablet impossible) and a relative PS/2 mouse, so the daemon's abs->rel homing
bridge cannot track 1:1. The agent gives true absolute positioning by polling COM1
directly (ring-0 `InU8`/`OutU8`, no driver) and applying the warpd M/P/R/B protocol
to the TempleOS globals `ms.pos.x/y` (motion) and `ms.lb/ms.rb` (clicks — the window
manager samples these to generate real click messages).

## Wiring (already live)

- Launcher (`/data/vms/streamhost/stations/templeos/qemu-streamhost.sh`):
  `-chardev socket,id=ser0,path=$BASE/serial.sock,server=on,wait=off -serial chardev:ser0`
- `station.env`: `SH_POINTER=warpd`, `SH_WARPD_ADDR=unix:/data/vms/streamhost/stations/templeos/serial.sock`
- Daemon side is OS-agnostic (`streamhost/streamhost/src/{warpd.rs,input.rs,config.rs}`);
  `connect_agent` already speaks the `unix:<path>` serial transport. No Rust changes.

## Re-bake procedure

TempleOS is ISO/RAM-only; `state.qcow2` holds the `savevm golden` snapshot. The
vendored bake is end-to-end and preserves the scratch disk while replacing its old
golden snapshot. It installs the pinned launcher, cold-boots, derives the REPL-safe
one-line agent from `warpd.HC`, starts it, saves the snapshot, and starts the tile:

```sh
cd /data/vms/streamhost/build
nice -n15 bash streamhost/stations/templeos/golden-bake.sh
```

The script requires the emitted `station.env` to already select `SH_POINTER=warpd` and
the TempleOS serial socket. The launcher pins `pc-i440fx-11.0`; changing its machine
or device set requires another full bake because `loadvm golden` must match exactly.

The running `WS` task is captured in the RAM snapshot, so every `loadvm golden` (the
tile's reset) comes up with the agent already polling COM1 and reconnect-ready.

## Verification (framebuffer, 2026-07-13)

Proven on an isolated clone (`/data/vms/soltest/templeos-c1`) and then on the live
golden: raw writes to `serial.sock` of `M 560 420` move the cursor 1:1, and
`P 1 18 7` / `R 1 18 7` open the File pull-down menu (a real click). The agent
survives `savevm golden` -> `loadvm golden` and still tracks over serial afterward.
