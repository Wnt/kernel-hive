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
(`src/mame/atari/stkbd.cpp`): a 500 Hz tick latches the axis ioport every fourth
tick, keeps only the *direction* of the change and emits one step per latch. So

* a burst is **discarded**, not carried — the magnitude never reaches the guest;
* the ceiling is ~125 counts per emulated second per axis;
* and TOS then applies its own acceleration on top (~4 surface px across, ~12.8
  down, per delivered count, at this walking rate).

Both arms inherit all of it — arm A feeds the same 8-bit axis through SDL — so
it is not a confound between them, but it does mean **open-loop dead reckoning
cannot place this pointer**. `fixtures.py` therefore walks the pointer in small
steps and closes the loop against the published framebuffer, identically for
both arms.

Two knobs exist because of this and are set in `armB-mame.sh`:
`MAME_CTL_PTR_MOD=256` (the ST's axis ioport is 8-bit where the SGI's is 16-bit;
without it the accumulator saturates at 255 and the cursor freezes while every
command is still acked) and `MAME_CTL_MOVE_STEP=1` / `MAME_CTL_MOVE_WINDOW=8`
(the device's own delivery rate).

## Tools

| Script | What it does |
|---|---|
| `armA-qemu.sh` | boots arm A's QEMU with the live `atarist` tile's device set, namespaced |
| `armA-kiosk-launch.sh` | the guest's `/etc/bridge/launch.sh` — MAME full-screen at 1024x768 |
| `armB-mame.sh` | host-native MAME, `-video shm` + ctlsock |
| `run-streamhost.sh` | one daemon per arm from a plain env file |
| `armcpu.py` | interleaved A/B/A/B per-arm CPU, resolved through `/proc/<pid>/exe` |
| `fixtures.py` | closed-loop pointer parking + the three fixtures, with evidence PNGs |
