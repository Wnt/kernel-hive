# Graphical bridge template, absolute-pointer contract, and latency budget

This is the shared foundation for the heavier graphical emulator exhibits:
Mac OS 9 in SheepShaver, NeXTSTEP in Previous, and IRIX in MAME. It extends the
8-bit bridge pattern in [BRIDGE.md](BRIDGE.md), but it does **not** add a
production tile or modify the frozen shared base.

The acceptance reference is a 1024×768 full-screen X11 client in an isolated
4 GiB/4-vCPU bridge clone. Its visible crosshair proves the complete outer
pointer path:

```
browser guest-pixel coordinate
  -> WebTransport type-1 input
  -> streamhost Mouse.SetAbsPosition
  -> QEMU usb-tablet
  -> Debian kiosk Xorg
  -> full-screen client
  -> QEMU framebuffer
  -> streamhost/H.264/WebTransport
  -> browser-decoded pixel
```

The inner emulator adds one more mapping. That mapping must independently pass
the same framebuffer gate before an OS worker promotes a tile.

## 1. Scratch-first graphical bridge template

The reusable builder is:

```
scripts/build-guests/lib/graphical-bridge.sh
```

It is fail-closed to `/data/vms/soltest/<name>/`, sources
`/usr/local/bin/clone-guard`, requires a clone-range VMID, and kills only its
namespaced pidfile through `clone_guard_kill_pidfile`. It creates a thin overlay
whose backing is the read-only
`/data/vms/bridge/bridge-base.qcow2`. It never rebuilds or writes that base.

Required extension points:

- `--install-script`: a script piped over bridge SSH and run as root **inside
  the overlay**. Install SheepShaver, Previous, or MAME here. This is the
  intended extension point; none of those emulators belongs in the frozen base.
- `--launch-script`: becomes the overlay's `/etc/bridge/launch.sh`.
- `--payload-dir`: optional files staged as
  `/tmp/graphical-bridge-payload/` before the installer runs.
- `--mem`, `--smp`, and `--scope-memory-max`: default to 4096 MiB, 4 vCPUs, and
  a 6 GiB qcap scope. These are deliberately above the 8-bit bridge's
  1536 MiB/2-vCPU/3 GiB values.

The reference build, run on the lab box from a synced repository, is:

```bash
scripts/build-guests/lib/graphical-bridge.sh \
  --tile gbridge-issue16 --vmid 99916 \
  --udp 54996 --ssh-port 5896 --web-port 8296 \
  --out-dir /data/vms/soltest/gbridge-issue16 \
  --install-script scripts/tools/graphical-bridge-probe-install.sh \
  --launch-script scripts/tools/graphical-bridge-probe-launch.sh \
  --payload-dir scripts/tools \
  --mem 4096 --smp 4 --scope-memory-max 6G --fps 60
```

It emits:

- `overlay.qcow2`: thin per-tile writable overlay;
- `qemu-streamhost.sh`: IDE overlay, pinned `pc-i440fx-11.0`, e1000 SLIRP
  hostfwd, AC97, `-usb -device usb-tablet`, and conditional
  `-loadvm golden`;
- `launch-scoped.sh`: permanent `systemd-run --scope` launcher with the chosen
  `MemoryMax`;
- `station.env`: scratch streamhost configuration with absolute input, identity
  cursor calibration, 60 fps, audio, loadvm reset, idle-pause disabled, and a
  4096 MiB QEMU RSS guard;
- `BUILD-INFO.txt`: the assigned namespace and device-set ledger.

The golden-bake and every later boot must use the byte-identical device set.
Changing RAM, SMP, machine type, disk bus, NIC, audio card, or tablet after
`savevm golden` invalidates the snapshot.

For production, copy the proven launcher and environment into the new tracked
`streamhost/stations/<id>/` source, then update the lifecycle launch paths to use a
6 GiB bridge scope. Today those paths are
`streamhost/scripts/ensure-station-qemu.sh` and the source template
`registry/templates/bring-up-all.sh.in`; do not hand-edit the generated
`streamhost/bring-up-all.sh`.

### Registry JSON blueprint

Do not add this example to the registry. Copy the complete shape of
`registry/stations/amiga.json`, then replace its exhibit-specific values with the
fields below. Leave `enabled` false until the separate OS issue is authorized
to change the production lineup, and regenerate rather than editing derived
files.

```json
{
  "schemaVersion": 1,
  "id": "<tile-id>",
  "enabled": false,
  "stationDir": "<tile-id>",
  "lifecycle": "production",
  "operator": {
    "labctl": {
      "dir": "/data/vms/streamhost/stations/<tile-id>",
      "qmp": "/data/vms/streamhost/stations/<tile-id>/qmp.sock",
      "pointer_mode": "abs",
      "ssh_port": "<unique-ssh-port>",
      "exec_port": "<unique-ssh-port>",
      "exec_kind": "ssh",
      "exec_user": "root",
      "exec_key": "/data/vms/bridge/bridge_key",
      "console": "fb",
      "udp_port": "<unique-udp-port>"
    }
  },
  "stream": {
    "transport": "streamhost",
    "udpPort": "<unique-udp-port>",
    "fps": 60,
    "audio": true,
    "touch": false,
    "pointer": {
      "transport": "abs",
      "device": "usb-tablet",
      "scale": 1.0,
      "offset": [0, 0]
    },
    "slot": "<unique-slot>"
  },
  "runtime": {
    "vmidLabel": "<unique-vmid>",
    "qemu": {
      "mode": "verbatim",
      "launcher": "streamhost/stations/<tile-id>/qemu-streamhost.sh",
      "envFixture": "streamhost/stations/<tile-id>/station.env.fixture",
      "binary": "qemu-system-x86_64",
      "accel": "kvm",
      "cpu": "host",
      "memoryMB": 4096,
      "smp": 4,
      "vga": "std"
    }
  },
  "reset": {
    "stationDir": "<tile-id>",
    "pointer": "abs",
    "touch": false,
    "resetMode": "loadvm",
    "snapshot": "golden",
    "mouse": "PASS"
  }
}
```

Before committing a real registry source:

```bash
python3 scripts/stations-registry.py count
make station-registry-generate
make station-registry-check
```

## 2. Guaranteed absolute-pointer contract

The outer contract is non-negotiable:

1. QEMU exposes `-usb -device usb-tablet`.
2. streamhost uses `SH_POINTER=abs`/the `dbus-abs` backend.
3. The kiosk X server receives the tablet across its entire surface.
4. The full-screen X client or emulator maps the outer X position to its
   visible guest cursor.
5. Corners, center, and all four mid-edges land within two framebuffer pixels.

Keep `SH_CURSOR_SCALE=1.0` and offsets zero unless a measured relative-only
inner mapping proves otherwise. Do not compensate by eye.

### Class A: host-cursor-follow / absolute-capable emulator

This is preferred. With mouse grabbing disabled, moving the X pointer causes
the emulator's guest cursor to follow the host window position. The mapping is
native 1:1:

```
browser pixel == outer X pixel == inner guest cursor pixel
```

Identification gate:

- disable emulator input grab and hide no guest cursor;
- command the nine probe fractions;
- locate the guest cursor in each screendump;
- verify identity slope and no history-dependent offset;
- repeat after touching every edge and after `loadvm golden`.

SheepShaver is expected to use this class. FS-UAE is a proven real-emulator
example: the isolated Amiga clone's cursor change was detected at exactly the
commanded outer pixels `(256,384)` and `(768,384)`.

### Class B: relative-only inner emulator

MAME's workstation mouse is relative. Previous must be treated as relative
until its first framebuffer run proves host-cursor-follow behavior. The outer
tablet remains absolute; only the emulator-window-to-emulated-mouse transfer is
relative.

Use the already proven abs-to-rel calibration recipe:

1. Fix the kiosk and emulator resolution/aspect ratio first.
2. Re-home at an edge. Command the outer X pointer to the top-left (or sweep
   beyond each edge) so the relative guest cursor clamps to a known origin.
   Re-home at session start and after reset.
3. With the real browser/streamhost path and `SH_DEBUG_INPUT=1`, command a
   mid-screen grid. For every point, use a QMP screendump and a cursor locator;
   logs alone are not evidence.
4. Fit each axis independently:

   ```
   landing = A * injected + B
   cursor_scale = 1 / A
   ```

5. The current transport has one scalar gain. If `A_x` and `A_y` differ
   materially, do not average them: fix the aspect ratio, emulator scaling, or
   acceleration until the slopes agree.
6. Keep offsets `(0,0)` for edge-rehomed relative tracking. Re-run all nine
   fractions and require at most two pixels per axis.

Worked example: TinyCore at 1600×1200/4:3 measured
`A_x ≈ A_y ≈ 1.28`, so `cursor_scale=0.783`; after an edge touch its center and
edges land within about one pixel. That number is an example, not a default for
MAME or Previous.

### Framebuffer pointer-probe harness

The guest client source is
`scripts/tools/graphical-bridge-pointer-probe.c`. It hides the ordinary X
cursor and paints a green 3×3 hotspot plus a magenta crosshair at the real X
pointer. The overlay installer compiles it with Xlib.

The host acceptance runner is
`scripts/tools/graphical_bridge_pointer_probe.py`:

```bash
python3 scripts/tools/graphical_bridge_pointer_probe.py \
  --qmp /data/vms/soltest/<tile>/qmp.sock \
  --out-dir /data/vms/soltest/<tile>/pointer-proof \
  --tolerance 2 --settle-ms 150
```

It primes the cold tablet, commands four corners, center, and four mid-edges,
captures a PPM after each command, finds the marker in raw framebuffer pixels,
and writes `results.json`. QMP `input-send-event` uses tablet units 0…32767,
so the runner converts fractions to that range; expected and landing values in
the report remain framebuffer pixels.

For an emulator-specific cursor, pass `--locator /path/to/locator`. The
executable receives one PPM path and prints `x y`; this keeps the driver,
fractions, tolerance, JSON, and linear-fit/calibration logic unchanged. A
locator must identify the guest cursor hotspot, not merely its bounding box.

Reference result, 2026-07-29, scoped cold boot at 1024×768:

| Point | Command | Framebuffer landing | Error |
|---|---:|---:|---:|
| top-left | 0,0 | 0,0 | 0,0 |
| top-mid | 512,0 | 511,0 | -1,0 |
| top-right | 1023,0 | 1022,0 | -1,0 |
| left-mid | 0,384 | 0,383 | 0,-1 |
| center | 512,384 | 511,383 | -1,-1 |
| right-mid | 1023,384 | 1022,383 | -1,-1 |
| bottom-left | 0,767 | 0,766 | 0,-1 |
| bottom-mid | 512,767 | 511,766 | -1,-1 |
| bottom-right | 1023,767 | 1022,766 | -1,-1 |

All 9/9 pass the two-pixel gate. Evidence is under
`/data/vms/soltest/gbridge-issue16/pointer-proof-scoped/`. The center PNG was
also visually inspected; the green/magenta marker is visibly centered on the
real black framebuffer.

The internal golden round-trip is pixel-identical:

```
before   e7faa5d36d51094566f5b73372538ed0
dirty    1ae1cb8b819bec21288a948cbf7c7a69
restored e7faa5d36d51094566f5b73372538ed0
cold -loadvm golden e7faa5d36d51094566f5b73372538ed0
```

## 3. Measured browser-to-guest-to-browser latency

`scripts/tools/graphical-bridge-latency-probe.mjs` runs a real headless Chrome
WebTransport client. It sends type-1 absolute datagrams, waits for the guest
cursor/marker to change, receives one H.264 AU per QUIC stream, decodes with
WebCodecs, and detects the returned pixel. Its clock spans:

```
Chrome send -> streamhost input -> guest -> X/emulator composition ->
QEMU fast-poll -> streamhost encode -> QUIC -> Chrome decode/pixel
```

It excludes only the final physical monitor scan-out. For the reference marker
it also proves the browser-path landing `(256,384)->(255,383)` and
`(768,384)->(767,383)`.

Controlled conditions: CT950, local LAN Chrome 150, one comparison clone active
at a time, 1024×768, 60 fps, `SH_DBUS_UPDATE_MS=4`,
`SH_ABS_PACE_MS=0`, ultrafast/zerolatency CQP 10, 32bpp copy capture, 30
alternating trials after one seed.

| Path | p50 | p95 | min | max | Interpretation |
|---|---:|---:|---:|---:|---|
| native KolibriOS + usb-tablet | 25.6 ms | 36.7 ms | 16.1 ms | 70.2 ms | native streamhost baseline |
| 4 GiB/4-vCPU graphical template + X probe | 34.9 ms | 55.4 ms | 24.6 ms | 104.5 ms | **+9.3 ms p50** bridge composition |
| existing 8-bit bridge clone, FS-UAE/Amiga | 39.8 ms | 58.9 ms | 28.4 ms | 61.8 ms | +4.9 ms p50 inner-emulator cost over the template |

The measured +9.3 ms median is consistent with
[CAPTURE-FASTPOLL.md](CAPTURE-FASTPOLL.md)'s approximately 8 ms Linux
composition term. The template is low-latency; each real emulator still owns
its additional frame cost.

Evidence JSON:

```
/data/vms/soltest/gbridge-issue16/latency/native-kolibrios-30.json
/data/vms/soltest/gbridge-issue16/latency/graphical-template-30.json
/data/vms/soltest/gbridge-issue16/latency/amiga-fsuae-30.json
```

Audio was proven through the same browser session, not inferred from an ALSA
log. A 440 Hz `speaker-test` in the overlay produced 109 Opus packets; Chrome
decoded 209,280 samples with RMS `0.557417` and peak `0.807820`
(`graphical-template-audio-proof.json`). This is decisively non-silent.

### Per-emulator tuning contract

- Keep the outer capture at 60 fps and configure the inner emulator for 60 Hz,
  no frame skipping, and software rendering. An emulator capped at 30 Hz adds
  another average half-frame.
- Keep `SH_DBUS_UPDATE_MS=4`; it is the deployed fast-poll knee.
- Keep `SH_ABS_PACE_MS=0` for normal absolute cursors. A nonzero value is a
  deliberate input delay used only when an old drawing application cannot
  consume a high-rate pen flood.
- `SH_WARPD_PACE_MS` applies only if a tile deliberately selects the warpd
  backend. It does not repair a relative inner emulator; use the measured
  `cursor_scale` recipe instead.
- Current bridge Xorg runs 32bpp, so QEMU uses the D-Bus copy path. A per-OS
  16bpp experiment may unlock shm/`UpdateMap`, but it must re-pass color,
  pointer, audio, and golden gates before adoption.
- The template sets `SH_QEMU_RSS_GUARD_MB=4096` and a 6 GiB cgroup cap. The
  live validation showed `memory.max=6442450944` with a 4096 MiB/4-vCPU QEMU.
  Keep the RSS guard below the outer scope ceiling.

## Handoff to the three OS workers

No SheepShaver, Previous, or IRIX media/ROM was found in the permitted staged
paths during this groundwork run, so installing those operating systems remains
in their separate issues. The outer contract, template, golden path, audio
path, and browser latency budget are complete.

### Mac OS 9 / SheepShaver

Expected pointer class: **Class A, host-cursor-follow (preferred)**.

1. Fork `graphical-bridge.sh` with a unique tile/VMID/UDP/SSH/web namespace.
2. Build/install SheepShaver entirely in the overlay installer; stage legally
   available ROM/disk media in the overlay, not the frozen base.
3. Launch windowed-borderless on bare X with mouse grabbing disabled and
   software rendering.
4. Run the outer green-marker gate, switch to SheepShaver, then run the same
   nine fractions with a Mac cursor hotspot locator.
5. Keep identity scale only if every fraction and post-`loadvm` run passes.

Caveat: host-cursor-follow is the expected behavior, but this issue did not have
a Mac ROM/OS disk with which to prove the inner Mac cursor. That final
emulator/OS gate belongs to the Mac OS 9 worker.

### NeXTSTEP / Previous

Expected pointer class: **unclassified; assume Class B until proven Class A**.

1. Fork the template and install/build Previous in the overlay.
2. Start with grab disabled, identity scale, and the nine-point cursor test.
3. If landings depend on motion history or show a linear gain, classify it as
   relative-only: edge re-home, fit both slopes, set one gain only if axes
   agree, and re-run the framebuffer gate.
4. Bake golden only after the Workspace Manager cursor passes after reset.

Caveat: do not encode a guessed 0.783 scale. That is TinyCore's measured
1600×1200 value, not a Previous constant.

### SGI IRIX / MAME

Expected pointer class: **Class B, relative-only workstation mouse**.

1. Fork the 4 GiB/4-vCPU template; install MAME and IRIX media in the overlay.
2. Keep the outer usb-tablet absolute and MAME's renderer/software frame rate
   stable; do not change the gallery transport to relative pointer lock.
3. Edge re-home the IRIX cursor, measure both transfer slopes at the final
   resolution, apply the reciprocal `cursor_scale`, and verify all nine points
   by framebuffer.
4. Record MAME's sustained CPU/frame rate and re-run the browser latency probe;
   IRIX/MIPS emulation is the most likely of the three to add a full frame or
   miss 60 Hz.

Caveat: MAME cursor acceleration or unequal axis slopes must be disabled/fixed
inside the emulator/guest before promotion; one scalar cannot correct unequal
axes.
