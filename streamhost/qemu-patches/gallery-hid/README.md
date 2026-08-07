# gallery-hid-pci device

This directory is the canonical source for the gallery-hid low-latency-input
device (PCI `1b36:0015`, class `ff00`, BAR0 control regs + BAR2 GLIN ring),
LIVE in production on the `solariscde` tile.

**Production packaging is a pve-qemu quilt patch, not a standalone binary.**
The device is carried by `../0003-gallery-hid-device.patch`, which
`scripts/provision/build-pve-qemu-fastpoll.sh` inserts into the pve-qemu series as
`pve/0049-streamhost-gallery-hid-device.patch` (after fast-poll `pve/0047` and
serial-Sphinx `pve/0048`). That patch is generated from the sources in THIS
directory (device `.c`/`.h` + Kconfig/meson/qtest wiring) against the assembled
pve-qemu tree, so a rebuilt fleet `qemu-system-x86_64` carries fast-poll AND
gallery-hid and survives QEMU version bumps. The old standalone
`/data/vms/streamhost/qemu-gallery-hid/qemu-system-x86_64` (built by
`build-standalone.sh`) is superseded by that packaged binary and kept only for
fast source-iteration and as the current live/rollback binary until the fleet
QEMU swap. Regenerate the quilt patch after any device/source change (see
"Regenerating the quilt patch" below).

## Contents

- gallery-hid-proto.h: endian-explicit v1 constants shared by the device/tests
  (installed into the tree as `include/hw/misc/gallery-hid.h`).
- gallery-hid-pci.c: conventional PCI device model and chardev frontend.
- qemu-wiring.patch: the original zero-context Kconfig/Meson/qtest wiring hunks;
  the canonical, refreshed-with-context form now lives in the packaged
  `../0003-gallery-hid-device.patch`.
- tests/gallery-hid-test.c: upstream-style qtests.
- tools/ghid-inject: standalone Rust Unix-socket exerciser.
- build-standalone.sh: applies the sources to a configured pinned tree, builds
  only qemu-system-x86_64 and the test, and copies runtime BIOS data (fast
  iteration only; production uses the quilt patch).
- launch-solaris-stage-a.sh: isolated cold-boot or `LOADVM=golden` launcher.
- golden-bake-solaris-clone.py: clone-only empty-ring validator and snapshot
  helper; it refuses paths outside `/data/vms/soltest/`.

## Regenerating the quilt patch

`../0003-gallery-hid-device.patch` is a `quilt refresh` of these sources against
a clean assembled pve-qemu tree (fast-poll + Sphinx applied). To regenerate it
after editing the device: assemble the pve-qemu source tree, `quilt push -a`
through the last streamhost patch, `quilt new pve/0049-streamhost-gallery-hid-device.patch`,
`quilt add` the six targets (`hw/misc/Kconfig`, `hw/misc/meson.build`,
`tests/qtest/meson.build`, `include/hw/misc/gallery-hid.h`,
`hw/misc/gallery-hid-pci.c`, `tests/qtest/gallery-hid-test.c`), drop in the new
files, append the Kconfig block + `hw/misc/meson.build` line + the
`qtests_pci` `CONFIG_GALLERY_HID` entry, then `quilt refresh --no-timestamps -p ab`.

## Pinned build

The validated build used:

    pve-qemu packaging commit:
      f17b668feb67097891a5f7012a99bcc1687c2584
    QEMU submodule:
      e545d8bb9d63e9dd61542b88463183314cff9482
    version:
      pve-qemu-kvm_11.0.2-1 / QEMU 11.0.2
    assembled source:
      /data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
    output:
      /data/vms/soltest/lli/spike-solaris-a/qemu-build

The source already has the complete PVE quilt series, fast-poll patch 0047,
and serial Sphinx build patch 0048.  The produced standalone binary therefore
contains both PVE pbs-state support and SH_DBUS_UPDATE_MS fast-poll support.
This standalone path is for fast iteration; production now ships the device as
the pve-qemu quilt patch `../0003-gallery-hid-device.patch` (slot `pve/0049`)
built by `scripts/provision/build-pve-qemu-fastpoll.sh`.

Build:

    S=/data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
    O=/data/vms/soltest/lli/spike-solaris-a/qemu-build
    /data/vms/streamhost/build/streamhost/qemu-patches/gallery-hid/build-standalone.sh "$S" "$O"

Run tests from the configured tree so QEMU finds its generated runtime data:

    cd "$S/build"
    QTEST_QEMU_BINARY=./qemu-system-x86_64 \
      ./tests/qtest/gallery-hid-test --tap

Or test the exact copied scratch artifacts:

    cd "$O"
    QTEST_QEMU_BINARY=./qemu-system-x86_64 \
      QTEST_QEMU_DATA_DIR="$O/pc-bios" ./gallery-hid-test --tap

All build work is ionice class 2 priority 7 and nice level 15.

The lab image does not currently include shellcheck or the Cargo clippy
component.  Stage-A validation therefore used `bash -n`, `cargo fmt --check`,
`cargo build --release`, `cargo test`, the warning-clean QEMU C build, and the
five qtests below.

## Implemented v1 contract

The device is PCI 1b36:0015 revision 01, class ff00, header type 0, one
function, with INTA and no MSI/MSI-X.  BAR0 is 4 KiB non-prefetchable MMIO.
BAR1 is unused.  BAR2 is 8 KiB 32-bit prefetchable RAM with the GLIN header,
separate producer/consumer cache lines, and 256 16-byte records.

The Unix stream chardev parser handles split input, requires the 16-byte GHIN
1.0 hello, returns GHOK with epoch/status, validates every host record, and
assigns sequence numbers at publication.  It implements one staged record and
socket backpressure when the ring is full.  Producer publication uses release
ordering; consumer reads use acquire ordering.  INTA is level asserted exactly
for enabled causes.  IRQ_ACK is W1C and rechecks nonempty state; GUEST_KICK
retries a staged record and recomputes the level.

The qtests cover:

- IDs, revision/class/header, INTA pin, BAR flags/sizes, and ring header;
- masked/unmasked persistent level causes and a simulated shared-IRQ
  UNCLAIMED path with no side effects;
- host enqueue, ring publication, level assertion, and enqueue-before-ACK
  lost-wakeup closure;
- 256-entry full state, one-record staging/backpressure, kick recovery, and
  slot wrap;
- malformed hello disconnect and a hello split after byte 3.
- VMState save/load of PCI configuration, control/IRQ state, producer,
  consumer, epoch, sequence, driver-ready, and BAR2 RAM; stale INTA and the
  process-local backend are absent after load, and hello/re-arm resumes input.

The device has stable version-1 VMState name `gallery-hid-pci` and stable BAR2
RAM-region name `gallery-hid-ring`. `pre_save` captures the guest consumer and
INTx level. `post_load` first deasserts stale INTA, excludes all backend/parser
connection state, validates the VMState fields against BAR2's ABI, epoch,
producer, consumer, sequence, and last armed epoch, then gates frames until a
fresh hello causes the guest to re-arm. The exact copied scratch artifacts pass
all five qtests.

## ghid-inject

Build:

    cd /data/vms/streamhost/build/streamhost/qemu-patches/gallery-hid/tools/ghid-inject
    cargo build --release

Examples:

    ghid-inject SOCKET pointer 16384 12000 1 -1 0
    ghid-inject SOCKET key 0x001e down 0
    ghid-inject SOCKET key 0x001e up 0
    ghid-inject SOCKET release-all 1

The tool stamps CLOCK_MONOTONIC_RAW microseconds, sends host sequence zero,
validates GHOK, and supports normalized absolute pointer state, XT-set-1 key
up/down/repeat/modifier state, and release-all.
