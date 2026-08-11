# De-bridging spike — the two arms, and how to bring them back up

The rig behind [`docs/lab/DEBRIDGE-SPIKE-MEASUREMENT.md`](../../docs/lab/DEBRIDGE-SPIKE-MEASUREMENT.md).
**Arm A** is MAME's Atari ST inside the Debian bridge kiosk (tier 2, the status
quo); **arm B** is the *same binary* on the bare host publishing frames through
`drawshm` (tier 3, the candidate). The live `atarist` tile — hatari in the
kiosk — is arm C and nothing here touches it.

These are **not tiles**. They have no registry entry, no poster and no SPA
scene, they live entirely under `/data/vms/soltest/debridge-7f3a/`, and they are
run by hand rather than by `streamhost@`. That last part is deliberate: the
systemd template pulls in `session-key.conf`, which makes every WebTransport
session require a ticket the public-gallery gateway mints for a tile it knows
about — and the gateway has never heard of these.

## The one binary

Both arms execute the same file, and the rig asserts it:

```sh
/data/vms/streamhost/assets/atarist-mame/mame/atarist         # host, arm B
/opt/bridge/atarist-mame/atarist                              # in the guest, arm A
```

Built by [`../build-guests/emulators/build-mame-atarist.sh`](../build-guests/emulators/build-mame-atarist.sh)
— MAME `mame0289` plus skip-warnings, ctlsock, ctlsock-ptr-tags and drawshm.
Every arm-specific capability is compiled in and gated by an environment
variable at runtime, so a measured difference can never be a build difference.

## Bring-up

```sh
# 0. the binary (host-native; ccache makes a rebuild ~2 min)
/data/kernel-hive/scripts/build-guests/emulators/build-mame-atarist.sh

# 1. arm A — the bridge kiosk
/data/vms/soltest/debridge-7f3a/armA/launch-qemu.sh      # == armA-qemu.sh here
#    first time only: the trixie bridge base has hatari's SDL2 but not
#    libsdl2-ttf, which MAME needs, and the kiosk launcher + binary + rompath
#    have to be inside the guest:
#      apt-get install -y libsdl2-ttf-2.0-0
#      /opt/bridge/atarist-mame/{atarist,roms/st/{tos100.bin,keyboard.u1},ui.ini}
#      /etc/bridge/launch.sh   <- armA-kiosk-launch.sh
#      systemctl restart getty@tty1
#    then, once MAME has written its own cfg/st.cfg, the pointer fix (see "The
#    pointer" below) -- without it arm A's pointer runs backwards:
#      python3 armA-ptr-cfg.py /opt/bridge/atarist-mame/cfg/st.cfg
#      systemctl restart getty@tty1
# 2. arm B — host-native
/data/vms/soltest/debridge-7f3a/armB/launch-mame.sh      # == armB-mame.sh here
# 3. one streamhost per arm
/data/vms/soltest/debridge-7f3a/run-streamhost.sh armA start
/data/vms/soltest/debridge-7f3a/run-streamhost.sh armB start
```

Namespace: ssh 5793, UDP 54793/54794, plain-HTTP signaling 14793/14794, input
bench 57931/57932. Kill only through `clone-guard kill-pidfile`.

## What is pinned, and why

| Setting | Both arms | Because |
|---|---|---|
| published surface | **1024x768** (`MAME_SHM_SIZE` == the kiosk's bare-X root) | unequal arms measure resolution, not the bridge |
| frameskip | `-frameskip 0 -noautoframeskip` | anything adaptive is load-dependent, and arm B is by construction less loaded |
| throttle | `-throttle` | otherwise part of any "win" is just the emulator running faster |
| renderer | software (`-video soft` / `drawshm`) | `accel`/`opengl` would put llvmpipe in one arm only |
| sound | `-sound none`, `SH_AUDIO=off` | one variable fewer; the spike measures video |
| idle auto-pause | `SH_IDLE_PAUSE_SECS=0` | a paused guest cannot be timed. Gallery behaviour is untouched |
| X root cursor | blanked in arm A | it moves with the tablet *without the emulator*, and would satisfy a damage detector before the GEM cursor moved — biasing the bridge arm faster |

## The pointer, which is the surprising part

MAME emulates the ST mouse as a **quadrature encoder**
(`src/mame/atari/stkbd.cpp`): a 500 Hz tick latches the 8-bit `:ikbd:MOUSEX` /
`MOUSEY` ioport every fourth tick, keeps only the *direction* of the change and
emits one quadrature cycle per latch. So

* a burst is **discarded**, not carried — the magnitude never reaches the guest;
* the ceiling is ~125 counts per emulated second per axis;
* one delivered count moves the GEM cursor **4 ST pixels**, which on the
  published 1024x768 surface is ~9.7 px across and ~12.3 px down (measured);
* so the pointer's real resolution is a **count grid of 81 x 52 reachable
  positions**, not 1024 x 768, and the top speed is ~500 ST px/s. Crossing the
  desktop takes about 1.3 s and there is nothing to be done about it: the
  ceiling is the emulated hardware.

Both arms inherit all of it, and both needed a fix for it — this is the part
that was wrong on the live rig until 2026-08-10, in a *different* way on each
arm, and the two fixes live in different places because the two input planes do.

**Arm B — the pointer ran away.** With no hardware cursor to read, the ctlsock
module's MOVEA engine degrades to open loop and issues one count per PIXEL of
target delta: a tenfold overshoot with no feedback to shrink the residual, so
the pointer bled paced counts until it slammed into an edge. streamhost now
states its targets on the count grid — `SH_MAMESOCK_PTR_GRID` in `stream.env`,
`MAME_CTL_SCREEN` naming the same grid in `armB-mame.sh`, and `ptr_grid.rs` for
the arithmetic. Landing error is under 0.6 counts on an ordinary move; a
full-screen traverse loses 2-3 counts to the module's 8 ms pacing beating
against the device's own 8 ms latch, and that drift is bounded rather than
cumulative: entering any edge carries a full-axis slam that re-pins guest and
model, and 30 s of pointer silence re-homes outright.

**Arm A — the pointer was inverted, on both axes.** Not a warp artefact and not
a guess: driving the usb-tablet and reading the emulated ioport latch back out
of MAME showed a clean sign negation, linear in the commanded distance, with no
drift while stationary. MAME's analog path also delivered 6.4 (X) / 8.6 (Y)
counts per surface pixel into an 8-bit field, so anything faster than ~20 px per
emulated frame WRAPPED and the latch read the direction backwards as well.
`armA-ptr-cfg.py` fixes both in MAME's own input configuration
(`reverse="yes" sensitivity="1"`), which is why arm A carries a `cfg/st.cfg`
that must be re-applied whenever the kiosk's MAME home is rebuilt.

Three knobs exist because of the encoder and are set in `armB-mame.sh`:
`MAME_CTL_PTR_MOD=256` (the ST's axis ioport is 8-bit where the SGI's is 16-bit;
without it the accumulator saturates at 255 and the cursor freezes while every
command is still acked), `MAME_CTL_MOVE_STEP=1` / `MAME_CTL_MOVE_WINDOW=8` (the
device's own delivery rate — 9 ms was tried and is worse, trading a y drift for
a larger x one), and `MAME_CTL_SCREEN` (the count grid, not a pixel surface).

**The pointer is measurable without a browser, and should be measured that way.**
`armB-ptr-grid.py verify` reports where the cursor actually lands, in counts.
Arm A's kiosk MAME runs with `MAME_CTL_SOCK` set and deliberately WITHOUT
`MAME_CTL_PTR_TAGS`, so the module resolves no axes and cannot inject, but
`ITEM m_mouse_x` still reads the emulated ioport latch straight out of a running
kiosk — the only machine-checkable evidence there is about that arm's input.

## Driving the arms by hand, in a browser

Both arms are reachable from the ordinary gallery HTTPS origin, side by side:

```
https://192.0.2.10:8443/debridge-compare.html   # both panes, one page
https://192.0.2.10:8443/os/dbr-arma             # arm A alone
https://192.0.2.10:8443/os/dbr-armb             # arm B alone
```

(`192.0.2.10` is the repo's scrubbed placeholder for the box — see AGENTS.md
"Placeholder values". Use the operator's real LAN address.)

Each pane is an `<iframe>` onto the SPA's own `/os/<id>` route, so the pointer,
keyboard and WebTransport paths a visitor uses are exactly the paths being
compared; nothing about input is re-implemented. The arms run **without**
`SH_SESSION_KEY`, so the ticket the gateway mints for them is accepted but not
required.

Publish / revert, on the box:

```sh
/data/vms/soltest/debridge-7f3a/gallery-arms.py publish     # or: status
ssh lab '/data/vms/soltest/debridge-7f3a/gallery-arms.py withdraw'   # THE REVERT
```

`withdraw` removes the two signalling rows, the two manifest entries and the
compare page, and touches nothing else. **The arms keep running either way** —
publishing and withdrawing are gallery-side only.

While published, the overlay is **declared** in
`serve/darklaunch.d/debridge-arms.json` (written by `publish`, removed by
`withdraw`). `scripts/dev/verify-box-sync.sh` verifies the two touched
documents minus the declared `dbr-arm*` ids still match the repo and reports
them **DARKLAUNCH** — visible, proven additive-only, and **not** blocking
`git push`. Any divergence beyond the declared rows still fails the gate, and a
declaration left behind after the rows are gone fails it as
`DARKLAUNCH_STALE`. See "Darklaunch overlays" in
[`../README.md`](../README.md).

### Why the arms are NOT registry entries with a `listing` soft hide

The soft hide (`registry/README.md`) hides a row that **belongs** in the lineup.
It is not a way to admit a `soltest` rig into it, and three things block that
route concretely rather than tediously:

- `scripts/gen_tiles_json.py` — what `labctl gen` runs — hard-exits with
  `declared/live tile set mismatch` for any streamhost registry row with no
  `/data/vms/streamhost/tiles/<tileDir>/` directory, and
  `tiles-registry.py --check` on the box compares the same two sets. Both arms
  live under `/data/vms/soltest/debridge-7f3a/`, so a registry row **breaks
  `labctl gen` for every other session** until the arms are moved into the
  production tile directory and given a `tile.env` + `qemu-streamhost.sh`. Arm B
  has no QEMU launcher at all — it is host-native MAME.
- the generated `scripts/serve/tiles.json` hardcodes each row's `hashFile` to
  `/data/vms/streamhost/tiles/<tileDir>/cert_hash_b64.txt`, so the registry
  cannot express where these arms actually are.
- `spa/src/data/tileWiring.test.ts` requires every streamhost manifest row to
  carry an exhibit poster, a scene identity, a machine assembly and a keyboard
  profile, and `machines.test.ts` requires a hardware signature **distinct from
  `atarist`'s** — i.e. invented exhibit identity for two instances of a machine
  that is already an exhibit.

So the arms stay out of the registry and `gallery-arms.py` carries the same
*shape* of divergence the soft hide produces (row present so `/os/<id>`
resolves, `"listed": false` so the grid and the 3D hall never show it) as an
explicit, committed, one-command-revertible overlay owned by the rig.

## Tools

| Script | What it does |
|---|---|
| `armA-qemu.sh` | boots arm A's QEMU with the live `atarist` tile's device set, namespaced |
| `armA-kiosk-launch.sh` | the guest's `/etc/bridge/launch.sh` — MAME full-screen at 1024x768 |
| `armA-ptr-cfg.py` | run IN the guest: fixes arm A's pointer polarity + gain in MAME's own `cfg/st.cfg`. Re-apply whenever that cfg is regenerated |
| `armB-mame.sh` | host-native MAME, `-video shm` + ctlsock |
| `armB-ptr-grid.py` | `measure` the count grid `SH_MAMESOCK_PTR_GRID` names, `verify` where the pointer actually lands (in counts) |
| `run-streamhost.sh` | one daemon per arm from a plain env file |
| `armcpu.py` | interleaved A/B/A/B per-arm CPU, resolved through `/proc/<pid>/exe` |
| `fixtures.py` | closed-loop pointer parking + the three fixtures, with evidence PNGs |
| `gallery-arms.py` | publish/withdraw both arms in the DEPLOYED gallery (above) |
| `compare.html` | the side-by-side page it installs into the webroot |
