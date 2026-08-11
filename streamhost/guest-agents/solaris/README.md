# Solaris CDE full-screen cursor — warpd in-guest X pointer agent

## The problem
Solaris 10 x86 (CDE, screen 1920×1200) caps the QEMU **usb-tablet** absolute range at a
fixed **1024×768** box — the guest kernel `usbms`/VUID input path maps the tablet's full
`0..0x7FFF` range onto 1024×768 regardless of screen size, so the cursor could never reach
the right/bottom of the desktop. Relative motion is ignored by the guest entirely. This is
**guest-side** and cannot be fixed by any QEMU device option, tablet descriptor patch, or
Xorg/Xsun config (verified by a 7-angle investigation; the golden actually runs Xorg, and
the cap is in the shared kernel input path, not the X server).

## The fix: warpd
`warpd.py` is a tiny agent that runs **inside** the guest and positions the X pointer
directly via **XTEST** (`XTestFakeMotionEvent`/`XTestFakeButtonEvent`, with `XWarpPointer`
fallback) — true full-screen absolute positioning, immune to the tablet cap. No compiler or
download is needed: Solaris 10 ships **Python 2.6 + ctypes** and `libX11`/`libXtst`.

- warpd listens on TCP `:7777` in the guest and speaks newline ASCII:
  `M x y` move · `P n x y`/`R n x y` press/release button n · `B n x y` wheel · `C x y`
  click · `D`/`U` drag · `W x y` pure XWarpPointer.
- **`E <cmd...>` — real exec channel.** Runs `<cmd>` in the guest shell (stderr merged),
  and — unlike every other (fire-and-forget) verb — writes a **framed reply back on the
  same connection**:
  ```
  O <base64 of stdout+stderr, first 8KB>
  X <exit code>
  .
  ```
  base64 keeps the payload on one line (no newline ambiguity); output is capped at 8KB and
  the child is fully drained so it can never block. The per-connection thread isolates it,
  so the streamhost daemon's M/P/R/B connections (which never read) are unaffected. Host
  client: `python3 gexec.py <port> <cmd...>` (deployed on the box as `/root/gexec.py`) —
  prints guest stdout/stderr and exits with the guest's exit code, e.g.
  `python3 /root/gexec.py 57790 uname -a`.
- The streamhost daemon reaches it over a **QEMU hostfwd** `127.0.0.1:57790 -> 10.0.2.15:7777`.
  With `SH_POINTER=warpd` (see config.rs / input.rs / warpd.rs), the daemon replaces the
  dbus `Mouse.SetAbsPosition` path with TCP writes to warpd; video/audio/keyboard stay on dbus.
- Coordinates are guest pixels `0..1920/0..1200` — the same space the daemon already computes,
  with **no** tablet scaling.

Verified end-to-end through the real browser→daemon→warpd path: corner test reaches
0.989×0.996 (was 0.529×0.642 confined); clicks land accurately deep in the former dead zone.

## How it's wired (build scripts)
- `stations-manifest.sh` — solaris emits `--pointer warpd --warpd-addr 127.0.0.1:57790` and
  the netdev carries `hostfwd=tcp:127.0.0.1:57790-10.0.2.15:7777`.
- `scripts/streamhost-tile.sh` — `--warpd-addr` → `SH_WARPD_ADDR`; keeps `-device usb-tablet`
  for warpd tiles so `loadvm golden` matches the snapshot's device set.
- Daemon: `InputBackend::Warpd` (config.rs), `warpd.rs` (reconnecting TCP client), `input.rs`
  (M/P/R/B routing), `transport.rs` (per-session client).

## Re-baking the golden (NVMe rebuild / from scratch)
warpd + guest networking are baked **into the golden snapshot**. To reproduce on a fresh
Solaris golden:
1. Boot the tile to the clean CDE golden (`loadvm golden`).
2. Copy `warpd.py` + `cdrv.py` to the host and run `golden-warpd-bake.sh` (drives the guest
   over QMP `send-key`; serves warpd.py over the SLIRP host alias 10.0.2.2:8099). It:
   - brings `e1000g1` up at 10.0.2.15/24,
   - installs `/opt/warpd/warpd.py`,
   - writes `/etc/hostname.e1000g1` (net at boot) and
     `/etc/dt/config/Xsession.d/0100.warpd.sh` (autostart warpd in the CDE session),
   - starts warpd (`DISPLAY=:0`), clears the terminal.
3. `savevm golden` (QMP `human-monitor-command`) — the snapshot then carries warpd running
   + network up, so `loadvm golden` at runtime is immediately drivable via the hostfwd.

The persistent config (`/etc/hostname.e1000g1` + `Xsession.d`) means a cold boot also brings
warpd up, but the primary path is the RAM snapshot.
