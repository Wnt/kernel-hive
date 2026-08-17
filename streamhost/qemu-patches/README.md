## Patch vs. fork — which one to edit

The `.patch` files in this directory are **the maintained source**. The
published fork (`github.com/Wnt/qemu`, consumed as the
`third_party/qemu-kernel-hive` git submodule, branch `kernel-hive`) is **the
published, consumable form** — one commit per shipped patch (`0001`-`0003`
plus the two Cirrus fixes below). They are not two independent copies to
keep in sync by hand:

1. Edit the patch here (or its source under `gallery-hid/` for `0003`; see
   that directory's "Regenerating the quilt patch").
2. Apply the regenerated patch to a checkout of the fork and update the
   corresponding commit on its `kernel-hive` branch, then push.
3. Run `git submodule update --remote third_party/qemu-kernel-hive` in this
   repo and commit the bumped gitlink.

Never edit the fork's checked-out tree directly and call that the source of
truth — the patch files are. `scripts/provision/build-pve-qemu-fastpoll.sh`
builds the patch trio (fast-poll, sphinx, gallery-hid) from the submodule
when it's initialized (the patches already land as commits there, via
`git format-patch`) and falls back to the loose `.patch` files in this
directory otherwise — both paths produce the same text. `0004` and `0005`
(the two Cirrus fixes) are applied directly to the per-tile custom build,
not through that script, but are published on the same fork branch.

**Not published**: `cirrus-blt-trace.patch` (debug-only tracing aid) and the
in-repo tooling (`g2g_*.py`, `harness/`, `tools/`, `build-standalone.sh`,
`golden-bake-*.py`, `launch-*.sh`) stay development-only and are not part of
the fork.

## `seabios/` — firmware patches (not QEMU, not on the fork)

`seabios/0001-kbd-check-keystroke-returns-with-interrupts-enabled.patch` is a
one-hunk patch against SeaBIOS `rel-1.17.0` (the release pve-qemu-kvm ships
prebuilt as `/usr/share/kvm/bios-256k.bin`): INT 16h "check keystroke"
(AH=01h/11h) returns with IF=1, the IBM AT BIOS contract (`STI` … `RET 2`).
Stock SeaBIOS returns the *pushed* IF, and DOS POWER.EXE's INT 16h chain turns
that into a WfW 3.11 guest running with interrupts disabled — the win311
freeze, [`docs/lab/win311-interrupts-disabled-freeze.md`](../../docs/lab/win311-interrupts-disabled-freeze.md).
Built and installed on labhost by `scripts/provision/build-seabios-int16if.sh`
→ `/data/vms/streamhost/firmware/bios-256k-int16if.bin`; consumed by the win311
launcher's `-bios`. It is **not** part of the pve-qemu quilt series or the QEMU
fork — a different tree, its own build. Any station that switches ROM must
re-bake its golden from a cold boot (the ROM bytes are in the vmstate).

# QEMU display-capture fast-poll patch

Cuts the **capture-wait** — the time a finished guest frame sits idle before
QEMU's dbus display listener notices it — which is the dominant slice of the
~25–33 ms glass-to-glass floor for the streamhost tiles.

## Root cause (measured)

Tiles capture via `-display dbus,p2p=on`. QEMU pulls the guest framebuffer on a
**poll timer**, not on damage. `ui/console.c` sets the display's scan interval to
the *minimum* `update_interval` over all registered display listeners, or
`GUI_REFRESH_INTERVAL_DEFAULT` (**30 ms**, `include/ui/console.h:47`) when a
listener sets none. The dbus listener (`ui/dbus-listener.c`, `dbus_dcl_ops`) sets
**no** custom `update_interval`, so it scans at 30 ms (≈33 Hz). A finished frame
therefore waits on average **~15 ms** (uniform 0–30 ms) for the next poll before
`dbus_refresh → graphic_hw_update → vga_update_display → dbus_gfx_update` even
emits the Update to streamhost.

Faster polling is nearly free *per tick*: `graphic_hw_update` on an unchanged
surface just checks the dirty bitmap and emits nothing; the pixel copy only
happens on real damage. **But the tick still fires.** `gui_update()` in
`ui/console.c` re-arms the refresh timer at `min(GUI_REFRESH_INTERVAL_IDLE=3 s,
listener intervals)` — and since it always takes the *min*, a listener asking
for 4 ms pins the timer at 4 ms **regardless of damage or vCPU run-state**.
There is **no** damage-based fall-back to the 3 s idle poll (an earlier
assumption that was measured false: a paused tile with a 4 ms listener kept
polling at ~250/s and burned ~1–2 % of a core each — ~4 % host across 26 tiles).
So the fast interval has to be gated on run-state, or the idle cost lands on
every tile whether or not anyone is watching.

## The patch — `0001-dbus-display-fast-poll.patch`

Two files, three changes:

1. **Fast poll (functional, `ui/dbus-listener.c`).** In
   `dbus_display_listener_constructed`, set `ddl->dcl.update_interval` from
   **`SH_DBUS_UPDATE_MS`** (clamped 1..29 ms). Unset / 0 / out-of-range keeps the
   stock 30 ms behavior, so the patch is **inert by default**.
2. **Idle gate (functional, `ui/console.c`).** In `gui_update`, after the
   min-interval loop, cap the interval back at `GUI_REFRESH_INTERVAL_DEFAULT`
   (30 ms) whenever `!runstate_is_running()`. A stopped guest's display cannot
   change, and streamhost pauses unwatched tiles, so this keeps
   **paused/unwatched tiles at ~0 idle cost** — the fast scan is spent **only
   while a tile is running (watched)**. It only ever *lengthens* the interval,
   never shortens it, so a running tile is unaffected and the failure mode is
   benign (a wrong interval, never a crash). On resume the next tick (≤30 ms)
   restores the fast rate, so join latency is unaffected.
3. **Poll-cadence probe (measurement-only, `ui/dbus-listener.c`).** In
   `dbus_refresh` (one call per poll tick), `SH_DBUS_TRACE=1` prints the tick
   rate to stderr every ~2 s. Inert unless the env is set.

There is **no CLI/QMP knob** for this in stock QEMU; the poll interval is an
internal timer, so a rebuilt `qemu-system-x86_64` is required.

## Build (measurement binary — what these numbers were taken on)

Upstream QEMU 11.0.0 (matches the box's `pve-qemu-kvm 11.0.0-3`), one target,
dbus display + slirp:

```sh
apt-get install -y --no-install-recommends \
  meson libglib2.0-dev libpixman-1-dev libslirp-dev flex bison   # ninja/gcc already present
wget https://download.qemu.org/qemu-11.0.0.tar.xz && tar xf qemu-11.0.0.tar.xz
cd qemu-11.0.0
patch -p1 < 0001-dbus-display-fast-poll.patch
mkdir build && cd build
../configure --target-list=x86_64-softmmu --enable-kvm --enable-slirp \
  --enable-dbus-display --disable-docs --disable-gtk --disable-sdl \
  --disable-vnc --disable-spice --disable-opengl --disable-werror --disable-tools
ninja qemu-system-x86_64          # ~4 min on the box (16 threads)
```

Run a tile's QEMU under it with e.g. `SH_DBUS_UPDATE_MS=4` in the environment.

## Production rollout — as a pve-qemu quilt patch (validated 2026-07-15)

**Turnkey:** `scripts/provision/build-pve-qemu-fastpoll.sh` resolves the exact installed
`pve-qemu-kvm` version to its packaging commit, inserts the fast-poll patch in
the next numbered slot after the final PVE patch, downloads pinned Meson
subprojects, builds at `nice -n15`, and verifies both fast-poll code paths.
`rollout-fastpoll.sh` derives the expected SHA-256 from the installed binary
after first verifying its `SH_DBUS_UPDATE_MS` marker; it has no version-specific
binary hash.

Validated for 11.0.2-1: pve-qemu commit
`f17b668feb67097891a5f7012a99bcc1687c2584`, QEMU submodule
`e545d8bb9d63e9dd61542b88463183314cff9482`, fast-poll quilt slot
`pve/0047` (both hunks applied with no offset/fuzz). A build-only `pve/0048`
patch serializes Sphinx because Sphinx 8.1.3/Python 3.13 can lose parallel
workers with `EOFError`; Ninja compilation remains parallel.

The same build script also carries **`0003-gallery-hid-device.patch` in slot
`pve/0049`** — the `gallery-hid-pci` low-latency-input device (PCI `1b36:0015`,
class `ff00`; sources under `gallery-hid/`) that is LIVE on the `solaris`
tile. It adds only a new optional device (guarded by `CONFIG_GALLERY_HID`) plus
its qtest, so the rebuilt binary is a strict superset of the fleet binary: every
existing tile is byte-for-byte identical in behavior, and `solaris`
additionally gets `-device gallery-hid-pci`. Packaging it as a quilt patch
replaces the old standalone `qemu-gallery-hid` binary (a carried-patch/upgrade
risk) so it is built from source and survives QEMU version bumps. Because the
device model (and its VMState `gallery-hid-pci`, version 1) is identical to the
standalone build that baked `solaris`'s golden, `-loadvm golden` restores
cleanly on the packaged binary. Regenerate the patch from the device sources per
`gallery-hid/README.md` § "Regenerating the quilt patch".

The live tiles run the packaged `pve-qemu-kvm`, and an **upstream** binary can't
`loadvm golden` (the golden snapshots carry a pve-only `pbs-state` vmstate
section), so this **must** ship as a pve-qemu quilt patch — a rebuilt `.deb`
that keeps every pve patch (incl. `pbs-state`) plus this one. Exact steps used:

```sh
# The script defaults to the installed version and a PID-namespaced WORK dir.
WORK=/data/vms/qemu-fastpoll-build.$$ \
  scripts/provision/build-pve-qemu-fastpoll.sh
# Output: $WORK/pve-qemu/pve-qemu-kvm_<installed-version>_amd64.deb
# Metadata/logs: $WORK/fastpoll-build-metadata.txt, quilt-apply.log,
#                meson-subprojects.log, dpkg-build.log
```

Then, gated:

1. **Stage the rollback deb first** — download the stock `.deb` for the
   *installed* version with
   `apt-get download "pve-qemu-kvm=$(dpkg-query -W -f='${Version}' pve-qemu-kvm)"`
   and keep it durably. `dpkg -i` it to roll back (same version = clean file
   swap).
2. `dpkg -i` the rebuilt `.deb` (replaces the on-disk binary; **running QEMUs
   keep the old one until relaunched**, so this alone touches nothing live).
3. **Canary one tile.** Add `export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"`
   to its `qemu-streamhost.sh`, stop the daemon, relaunch qemu (kills old pid,
   launches new binary + knob, `-loadvm golden` restores state), restart the
   daemon. **Verify `loadvm golden` succeeds** (the whole point),
   `SH_DBUS_TRACE=1` poll rate ~230–250/s, and the tile streams
   (WebTransport probe / ff-check).
4. **Fleet.** Repeat step 3 per tile (bridge tiles c64/atarist/amiga must
   relaunch inside their `qcap-*` 3 G `systemd-run --scope`). The idle gate
   (§2 of the patch) means paused/unwatched tiles pay ~0, so the fast scan is
   spent only on tiles a viewer is connected to.

The tile launchers are emitted by `../scripts/streamhost-station.sh`, which now bakes
the `SH_DBUS_UPDATE_MS` export (default 4, per-tile overridable) so regenerated
launchers keep the knob.

## Harness (also here for reproduction)

- `g2g_key_inject.py <qmp.sock> <n> <gap_s>` — keystroke stimulus from a clean
  FreeCom prompt; stamps `t0` (CLOCK_REALTIME) per key.
- `g2g_key_detect.py <probe.csv> <inject.log> <workdir>` — pixel-verified
  inject→wire join (each key's glyph detected in its own cell; blink-immune).
  Pairs with the rig's `wt_probe.py` (WebTransport AU capture).

Full run scripts live on the box under `/data/vms/sandbox/freedos-fastpoll/`
(`launch-qemu.sh`, `launch-streamhost.sh`, `measure.sh` cadence, `g2g-run.sh`).
