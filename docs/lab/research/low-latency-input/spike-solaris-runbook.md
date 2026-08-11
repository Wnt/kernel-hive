# Solaris gallery-hid spike runbook

Status: Stages A-C PASS, Stage D PARTIAL, and VMState/checkpoint-resume PASS;
captured 2026-07-15--16 on labhost.

This is the reproducible handoff for the standalone QEMU transport and Solaris
driver work. Early stages do not install QEMU, change a live station, or load a
saved VM state; the final section records the isolated clone-only VMState and
checkpoint-resume proof.

## Fixed paths and identities

    repo=/data/vms/streamhost/build
    scratch=/data/vms/soltest/lli/spike-solaris-a
    source=/data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
    qemu=/data/vms/soltest/lli/spike-solaris-a/qemu-build/qemu-system-x86_64
    disk=/data/vms/soltest/lli/spike-solaris-a/solariscde-stage-a.qcow2
    launcher=/data/vms/soltest/lli/spike-solaris-a/launch-stage-a.sh
    qmp=/data/vms/soltest/lli/spike-solaris-a/qmp.sock
    ghid_socket=/data/vms/soltest/lli/spike-solaris-a/gallery-hid.sock
    pidfile=/data/vms/soltest/lli/spike-solaris-a/qemu.pid
    VMID label=9910
    VNC=127.0.0.1:5991
    hostfwd=127.0.0.1:58790 to guest 10.0.2.15:7777

The standalone binary reports QEMU 11.0.2
(pve-qemu-kvm_11.0.2-1).  Pins:

    pve-qemu f17b668feb67097891a5f7012a99bcc1687c2584
    qemu     e545d8bb9d63e9dd61542b88463183314cff9482

It was built from the already assembled complete PVE quilt tree, including
fast-poll patch pve/0047 and Sphinx patch pve/0048.  The final binary SHA-256
is bba447fd6217201d5098d5552de45ce8580d3f737c4d1e0524349365920f4206
and is recorded in scratch/qemu-build/SHA256SUMS.  SH_DBUS_UPDATE_MS is
present.

## Build QEMU and the exerciser

    cd /data/vms/streamhost/build
    S=/data/vms/qemu-fastpoll-build.1784076046-22671/pve-qemu/pve-qemu-kvm-11.0.2
    O=/data/vms/soltest/lli/spike-solaris-a/qemu-build
    streamhost/qemu-patches/gallery-hid/build-standalone.sh "$S" "$O"

This copies the device/header/test into the configured pinned source, applies
qemu-wiring.patch once, runs only the system-binary and qtest targets under
ionice/nice, and copies the pc-bios runtime data.  It never packages or
installs anything.

    cd streamhost/qemu-patches/gallery-hid/tools/ghid-inject
    cargo build --release
    install -m 0755 target/release/ghid-inject \
      /data/vms/soltest/lli/spike-solaris-a/bin/ghid-inject

The nested tool manifest contains an empty local workspace.  Without it Cargo
mistakes the utility for an omitted member of the parent streamhost workspace.

## Tests

Run qtests against the exact copied scratch binary and runtime data:

    cd "$O"
    QTEST_QEMU_BINARY=./qemu-system-x86_64 \
      QTEST_QEMU_DATA_DIR="$O/pc-bios" ./gallery-hid-test --tap

Initial Stage-A result: four of four passed:

    ok 1 /gallery-hid/ids-bars-header
    ok 2 /gallery-hid/hello-split-malformed
    ok 3 /gallery-hid/level-irq-ack-race
    ok 4 /gallery-hid/wrap-full-backpressure

The initial TAP is scratch/qtests-scratch-final.tap. The VMState work below
adds and passes a fifth save/load test; parser fuzzing remains follow-up work.

## Clone and launch

The Stage-A disk was made with a plain independent copy of the station-local
checkpoint.  Never point the scratch QEMU at the source image:

    D=/data/vms/soltest/lli/spike-solaris-a
    L=/data/vms/streamhost/stations/solaris
    ionice -c2 -n7 nice -n15 cp --sparse=always \
      "$L/solariscde-golden.qcow2" "$D/solariscde-stage-a.qcow2"
    qemu-img check "$D/solariscde-stage-a.qcow2"

The copy inherited one leaked cluster (zero corruptions).  It was repaired on
the clone only:

    ionice -c2 -n7 nice -n15 qemu-img check -r leaks \
      "$D/solariscde-stage-a.qcow2"
    qemu-img check "$D/solariscde-stage-a.qcow2"

QMP query-pci with the original device set showed only slots 0 through 4, so
pci.0 slot 0x1e was free.  Evidence is
scratch/query-pci-before-gallery.json.

Install and run the checked-in launcher:

    install -m 0755 \
      /data/vms/streamhost/build/streamhost/qemu-patches/gallery-hid/launch-solaris-stage-a.sh \
      "$D/launch-stage-a.sh"
    "$D/launch-stage-a.sh"

It uses the scratch binary by absolute path, pc-i440fx-11.0, Nehalem, 3 GiB,
two vCPUs, std VGA, AC97, USB tablet, IDE clone disk, e1000/user networking,
and adds:

    -chardev socket,id=ghid0,path=$D/gallery-hid.sock,server=on,wait=off
    -device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e

There is deliberately no loadvm.  The launcher kills only the PID read from
its own pidfile.

Cold boot first reached the Oracle Solaris dtlogin screen.  QMP absolute
coordinates are normalized 0..32767, not framebuffer pixels.  For this
1920x1200 guest, pixel (1104,747) is approximately (18845,20408) and
(960,651) is approximately (16392,17783).  Use the existing lab credential
source programmatically and do not print it.  The final framebuffer proof is:

    /data/vms/soltest/lli/spike-solaris-a/cde-proven.png

It visibly shows the 1920x1200 CDE desktop and scene dtterm.  The earlier
boot and dtlogin evidence is in framebuffer.png and framebuffer-2.png.

ImageMagick is not installed on labhost.  Convert a QMP PPM screendump with
the available ffmpeg instead:

    ffmpeg -loglevel error -y -i "$D/framebuffer.ppm" "$D/framebuffer.png"

To stop, and only to stop this clone:

    D=/data/vms/soltest/lli/spike-solaris-a
    kill "$(cat "$D/qemu.pid")"

## Enumeration gate

Stage A passed.  The exact prtconf node is:

    Node 0x00000f
        assigned-addresses:  8200f010.00000000.febf1000.00000000.00001000.c200f018.00000000.fe000000.00000000.00002000
        reg:  0000f000.00000000.00000000.00000000.00000000.0200f010.00000000.00000000.00000000.00001000.4200f018.00000000.00000000.00000000.00002000
        compatible: 'pci1b36,15.1af4.1100.1' + 'pci1b36,15.1af4.1100' + 'pci1af4,1100' + 'pci1b36,15.1' + 'pci1b36,15' + 'pciclass,ff0000' + 'pciclass,ff00'
        model:  'Unknown class of pci/pnpbios device'
        power-consumption:  00000001.00000001
        devsel-speed:  00000000
        interrupts:  00000001
        max-latency:  00000000
        min-grant:  00000000
        subsystem-vendor-id:  00001af4
        subsystem-id:  00001100
        unit-address:  '1e'
        class-code:  00ff0000
        revision-id:  00000001
        vendor-id:  00001b36
        device-id:  00000015
        name:  'pci1af4,1100'

The subsystem-derived node name is not the binding key.  Stage B must bind the
exact compatible string pci1b36,15:

    add_drv -m '* 0600 root sys' -i '"pci1b36,15"' galleryhid

In-guest /usr/X11/bin/scanpci -v confirms:

    pci bus 0x0000 cardnum 0x1e function 0x00: vendor 0x1b36 device 0x0015
     Red Hat, Inc. Device unknown
     CardVendor 0x1af4 card 0x1100 (Red Hat, Inc, Card unknown)
      STATUS    0x0000  COMMAND 0x0103
      CLASS     0xff 0x00 0x00  REVISION 0x01
      BIST      0x00  HEADER 0x00  LATENCY 0x00  CACHE 0x00
      BASE0     0xfebf1000 SIZE 4096  MEM
      BASE2     0xfe000000 SIZE 8192  MEM PREFETCHABLE
      BASEROM   0x00000000  addr 0x00000000
      MAX_LAT   0x00  MIN_GNT 0x00  INT_PIN 0x01  INT_LINE 0x0a

Thus this boot assigned fixed legacy INTA to IRQ 10.  The driver must obtain
the routed fixed interrupt through DDI and must not hardcode 10.

Solaris rnumbers index reg-property entries, not PCI BAR numbers.  This node
has configuration, BAR0, and BAR2 entries.  Therefore:

    rnumber 0 = PCI configuration space
    rnumber 1 = QEMU BAR0, 4096-byte control MMIO
    rnumber 2 = QEMU BAR2, 8192-byte prefetchable RAM ring

The older Solaris plan text describing a guest-allocated DMA ring is obsolete;
the authoritative T1 v1 ABI uses device-owned BAR2 RAM.

Raw evidence:

    scratch/prtconf-gallery-node.txt
    scratch/scanpci-gallery.txt
    scratch/query-pci-with-gallery-early.json

The guest-exec relay returns at most 8192 output bytes, so a full `prtconf -pv`
is truncated before this high-numbered node.  Run the node-selection filter
inside Solaris and return only the matching node; do not fetch all output and
filter it on the host.

## Stage-B preflight, verbatim

uname -a:

    SunOS solaris 5.10 Generic_147148-26 i86pc i386 i86pc

isainfo -kv:

    64-bit amd64 kernel modules

cc -V:

    /usr/ucb/cc:  language optional software package not installed

/usr/sfw/bin/gcc --version:

    /bin/sh: /usr/sfw/bin/gcc: not found

pkginfo -l SUNWhea SUNWsprot SUNWgcc:

    ERROR: information for "SUNWhea" was not found
    ERROR: information for "SUNWsprot" was not found
    ERROR: information for "SUNWgcc" was not found

Every requested DDI header is absent:

    /usr/include/sys/ddi.h: No such file or directory
    /usr/include/sys/sunddi.h: No such file or directory
    /usr/include/sys/pci.h: No such file or directory
    /usr/include/sys/stream.h: No such file or directory
    /usr/include/sys/vuid_event.h: No such file or directory
    /usr/include/sys/vuid_wheel.h: No such file or directory
    /usr/include/sys/msio.h: No such file or directory

/usr/ccs/bin/ld and /usr/ccs/bin/nm are installed.  The running kernel exports
the modern fixed-interrupt APIs ddi_intr_get_supported_types, ddi_intr_alloc,
ddi_intr_add_handler, and ddi_intr_enable, as well as legacy ddi_add_intr and
ddi_get_iblock_cookie.

Xorg:

    X Window System Version 1.3.0
    Release Date: 19 April 2007
    X Protocol Version 11, Revision 0, Release 1.3
    Build Operating System: SunOS 5.10 Generic i86pc
    Current Operating System: SunOS solaris 5.10 Generic_147148-26 i86pc
    Build Date: 11 September 2012
    Solaris ABI: 32-bit
    SUNWxorg-server package version: 6.8.0.5.10.7400,REV=0.2004.12.15

/etc/X11/xorg.conf does not exist:

    /etc/X11/xorg.conf: No such file or directory
    cat: cannot open /etc/X11/xorg.conf

Current mouse links:

    lrwxrwxrwx 1 root root 32 Jul 15 08:58 /dev/mouse -> ../devices/pseudo/consms@0:mouse
    lrwxrwxrwx 1 root root 35 Jul 15 08:58 /dev/kdmouse -> ../devices/isa/i8042@1,60/mouse@1:l

Full captures are under scratch/preflight.

Stage B cannot compile in this image as-is.  Before loading a driver, provision
matching Generic_147148-26 Solaris 10 headers plus either the matching Sun
Studio compiler or a working Solaris GCC in this disposable clone/build VM.
Do not substitute illumos headers.  The installed X server is 32-bit even
though kernel modules are 64-bit; a direct VUID STREAMS device must match the
kernel data model while exposing the userspace STREAMS ABI expected by Xorg.

## Host exerciser and transport proof

The exact source path is:

    /data/vms/streamhost/build/streamhost/qemu-patches/gallery-hid/tools/ghid-inject

Smoke commands against the clone:

    GH=/data/vms/soltest/lli/spike-solaris-a/bin/ghid-inject
    S=/data/vms/soltest/lli/spike-solaris-a/gallery-hid.sock
    "$GH" "$S" pointer 16384 12000 1 -1 0
    "$GH" "$S" key 0x001e down 0
    "$GH" "$S" key 0x001e up 0
    "$GH" "$S" release-all 1

All returned GHOK epoch 1, status 0x00000005.  Status means backend connected
and reset/driver-required; no Solaris driver exists yet, as expected.

The qtest arms DRIVER_READY with the current epoch, performs the same GHIN/GHOK
protocol and 16-byte record publication, observes producer and sequence in
BAR2, observes an enabled ring cause, and proves ACK reasserts when enqueue
races consumer/ACK.  Its full-ring test proves 256 records plus one staged
record recover through GUEST_KICK and wrap into slot zero.  This is the
Stage-A host-to-ring-to-INTA proof; in-guest draining belongs to Stage B.

## Measurement hook feasibility

QMP screendump contains the Solaris software cursor.  One non-benchmark
calibration move to guest pixel (1500,900) changed 482 PPM bytes and the cursor
is visibly present at the destination in:

    scratch/feas-after.png
    scratch/measurement-feasibility.txt

This proves the cursor endpoint is observable.  It is not a latency sample:
the calibration used a direct sidecar write and VNC display.  Stage C must
relaunch the same candidate device set with the deployed D-Bus display,
attach the callback-entry timestamp observer, and use the real persistent
WarpdClient for B0/B1.  Capture B1 on this candidate clone with gallery-hid
quiescent, then C after the driver drains the ring; do not use direct netcat
timings as the baseline.  The binary carries the 4 ms fast-poll hook.

## Stage-A handoff to Stage B (completed)

1. Preserve pci1b36,15, slot 1e, fixed-INTx discovery, rnumber 1 for BAR0, and
   rnumber 2 for BAR2.
2. Provision the exact Solaris header/compiler prerequisites before any module
   load attempt.
3. Build a diagnostic 64-bit galleryhid DDI driver that validates both magics,
   maps the full BAR sizes, registers DDI_INTR_TYPE_FIXED, returns UNCLAIMED
   when no enabled cause is present, and drains/logs records with the T1
   acquire/release and ACK/recheck loop.
4. Only after transport diagnostics pass, add the direct VUID STREAMS mouse
   minor and a new explicit Xorg configuration; keep /dev/mouse and warpd
   unchanged for rollback.
5. Do not loadvm until production VMState/save-load tests and coordinated
   backend reconnect behavior are complete.

## Stage B: Solaris toolchain and diagnostic driver

Status: **P2 PASS**, captured 2026-07-15. P3 VUID injection is not started.
The clone is still running with `galleryhid` loaded and the diagnostic BAR2
drain active.

### Matching Solaris 10 u11 toolchain

The launcher's implicit empty secondary IDE CD is QMP device `ide1-cd0`.
Insert the exact ISO without restarting or changing the saved device set:

    ISO=/data/assets-staging/SolarisCDE/sol10.iso
    python3 - <<'PY'
    import json, socket
    qmp = "/data/vms/soltest/lli/spike-solaris-a/qmp.sock"
    s = socket.socket(socket.AF_UNIX)
    s.connect(qmp)
    f = s.makefile("rwb", buffering=0)
    f.readline()
    f.write(b'{"execute":"qmp_capabilities"}\n')
    f.readline()
    command = {"execute": "human-monitor-command", "arguments": {
        "command-line": "change ide1-cd0 " +
        "/data/assets-staging/SolarisCDE/sol10.iso raw"}}
    f.write((json.dumps(command) + "\n").encode())
    PY

In Solaris, `volcheck` mounted it read-only at
`/cdrom/sol_10_113_x86`. `pkgadd -n` alone suspends because these packages
contain privileged scripts. Use an explicit noninteractive admin policy:

    sed 's/=ask$/=nocheck/' /var/sadm/install/admin/default \
      > /var/tmp/spike-b-admin
    pkgadd -n -a /var/tmp/spike-b-admin \
      -d /cdrom/sol_10_113_x86/Solaris_10/Product \
      SUNWhea SUNWgcc SUNWsprot

`SUNWbtool` was already installed in this clone. The exact final set is:

    system SUNWhea   SunOS Header Files
    system SUNWgcc   gcc - The GNU C compiler
    system SUNWsprot Solaris Bundled tools
    system SUNWbtool CCS tools bundled with SunOS

The ISO package metadata is the matching u11 media: `SUNWhea` includes patch
`147148-26`, exactly the running kernel. The requested headers are now present
at `/usr/include/sys/{ddi.h,sunddi.h,pci.h,stream.h,vuid_event.h}`. GCC reports
`3.4.3 (csl-sol210-3_4-branch+sol_rpath)` and the linker reports Solaris Link
Editors `5.10-1.1514`.

The kernel-object smoke test succeeded and produced a 1136-byte ELF64 AMD64
relocatable object:

    printf '#include <sys/ddi.h>\n#include <sys/sunddi.h>\nint kernel_smoke(void) { return DDI_SUCCESS; }\n' | \
      /usr/sfw/bin/gcc -D_KERNEL -m64 -mcmodel=kernel -mno-red-zone \
      -ffreestanding -nodefaultlibs -x c -c \
      -o /var/tmp/galleryhid-kernel-smoke.o -

### Driver source, build, and install

The reproducible source is:

    /data/vms/streamhost/build/streamhost/guest-agents/solaris-galleryhid/

It contains `galleryhid.c`, `galleryhid.conf`, `build.sh`, `install.sh`,
`stage-to-guest.sh`, and a README. The Stage-B form is a `D_MP` hardware leaf
with `dev_ops`, STREAMS `cb_ops`/`streamtab`, a `diag` minor, and the modern
fixed-interrupt DDI. It maps Solaris rnumber 1 and 2 with
`DDI_STRUCTURE_LE_ACC`; there is no DMA allocation.

Stage that directory with the checked-in helper. It makes a tarball, starts a
temporary host HTTP server, waits for a successful readiness probe, fetches
through SLIRP, and extracts in the guest:

    cd /data/vms/streamhost/build/streamhost/guest-agents/solaris-galleryhid
    ./stage-to-guest.sh 58790

Then in the guest:

    cd /var/tmp/galleryhid
    ./build.sh
    ./install.sh

Both `galleryhid.o` and `galleryhid` are ELF64 AMD64 relocatables. The
installer uses Solaris 10 syntax `install -f <directory> -m <mode> <file>`;
GNU source/destination syntax does not work. It installs:

    /usr/kernel/drv/amd64/galleryhid
    /usr/kernel/drv/galleryhid.conf

and runs:

    add_drv -m '* 0600 root sys' -i '"pci1b36,15"' galleryhid
    devfsadm -i galleryhid

The successful attach evidence is:

    galleryhid0 is /pci@0,0/pci1af4,1100@1e
    NOTICE: galleryhid0: attached BAR0=rnumber1/4096 BAR2=rnumber2/8192 \
      epoch=1 producer=0 fixed-pri=1 caps=0x31

`modinfo` showed module 249, `prtconf -D` showed the node with driver name
`galleryhid`, and the diagnostic minor is
`/devices/pci@0,0/pci1af4,1100@1e:diag` (major 266, minor 0). The PCI nexus
routed fixed INTA to IOAPIC input `0xa` for this boot; the driver never reads
or hardcodes that value.

### P2 interrupt-driven BAR2 drain proof

Run separate commands so one-event interrupt accounting is visible:

    GH=/data/vms/soltest/lli/spike-solaris-a/bin/ghid-inject
    S=/data/vms/soltest/lli/spike-solaris-a/gallery-hid.sock
    "$GH" "$S" pointer 16384 12000 1 -1 0
    "$GH" "$S" key 0x001e down 0
    "$GH" "$S" key 0x001e up 0
    "$GH" "$S" release-all 1

All four returned `GHOK epoch=1 status=0x00000003`. The exact ordered guest
records were:

    event=1 irq=1 seq=0 type=pointer x=16384 y=12000 buttons=0x1 wheel=-1 hwheel=0 producer=1 consumer=0
    event=2 irq=2 seq=1 type=key flags=0x1 key=0x1e modifiers=0x0 producer=2 consumer=1
    event=3 irq=3 seq=2 type=key flags=0x0 key=0x1e modifiers=0x0 producer=3 consumer=2
    event=4 irq=4 seq=3 type=release-all flags=0x1 producer=4 consumer=3

Each invocation connects, publishes, and disconnects. The link cause therefore
coalesced with the ring cause as `status=0x5`; total claimed ISR count and
ring-IRQ count were both exactly four. There was no extra interrupt, storm,
or polling. The ISR reads `IRQ_STATUS` first, publishes consumer, executes the
producer barrier, writes `GUEST_KICK`, W1C-acks the handled causes, and rereads
producer as required by T1.

The final source added the bounded producer-recheck loop, was rebuilt, and was
reloaded once. The old module detached cleanly with `isr=4 ring_irq=4 events=4
invalid=0 sequence_faults=0`; the final module reattached at producer 4. The
same four commands then produced sequences 4 through 7 with exactly four new
ISRs/ring IRQs and the same payloads. This final module is the one left loaded.

## Stage C: VUID pointer through Xorg to the framebuffer (PASS)

Stage C was completed on 2026-07-15 against the same disposable standalone
clone. The final QEMU PID is recorded in
`/data/vms/soltest/lli/spike-solaris-a/qemu.pid`; it was `990736` at handoff.
The clone remains running, `galleryhid` is loaded, CDE is logged in, and Xorg
has `/dev/gallerymouse` open.

### Verified geometry

Do not infer the geometry from the requested Xorg mode. The QMP framebuffer
and `/usr/openwin/bin/xdpyinfo` both reported **1920x1200**. (`xdpyinfo` is not
under `/usr/X11/bin` in this image.) All Stage-C coordinate checks therefore
used:

    pixel_x = round(norm_x * 1919 / 32767)
    pixel_y = round(norm_y * 1199 / 32767)

### Driver and installation result

The Stage-B diagnostic ring drain remains intact. `galleryhid.c` now also:

- creates a `mouse` STREAMS minor with `DDI_NT_MOUSE` and keeps the read queue
  from the exclusive mouse open;
- converts each T1 pointer record to adjacent, separately constructed
  `LOC_X_ABSOLUTE` and `LOC_Y_ABSOLUTE` `Firm_event` records, followed by
  changed `MS_LEFT`/`MS_MIDDLE`/`MS_RIGHT` events and a vertical wheel event;
- uses Solaris `timeval32` through the installed `Firm_event` layout; no raw
  16-byte T1 record is copied as a VUID event;
- implements `VUIDSFORMAT`, `VUIDGFORMAT`, `VUIDSADDR`, `VUIDGADDR`,
  `MSIOBUTTONS`, `MSIOSRESOLUTION`, `VUIDGWHEELCOUNT`, `VUIDGWHEELINFO`,
  `VUIDGWHEELSTATE`, and `VUIDSWHEELSTATE`, including transparent ioctls; and
- emits `MOUSE_TYPE_ABSOLUTE` after the first `MSIOSRESOLUTION`.

Solaris 10's installed `mouse_drv.so` does not contain the absolute-scaling
path from the later `sun_mouse.c` build and never sends `MSIOSRESOLUTION`.
With an initially unknown resolution the cursor consequently remained at its
old 960,600 position even though the ring drained. The deterministic fixture
fallback is now in `galleryhid.conf`:

    screen-width=1920;
    screen-height=1200;

An actual `MSIOSRESOLUTION`, when available, still overrides these properties
at runtime. The final attach and open messages confirm
`resolution=1920x1200`. The 64-bit build succeeded with only the pre-existing
legacy `modlinkage.ml_linkage` missing-braces warning.

The final devlink rule must match the devinfo node name, not the driver name:

    type=ddi_mouse;name=pci1af4,1100;minor=mouse	gallerymouse

`install.sh` removes stale/wrong gallery rules before installing that exact
line. The result is:

    /dev/gallerymouse -> ../devices/pci@0,0/pci1af4,1100@1e:mouse

Use the staged helper for a repeatable live reload. It disables CDE login so
Xorg releases the STREAMS minor, rebuilds before install, and always re-enables
the service through its trap:

    cd /var/tmp/galleryhid
    at now <<'EOF'
    /var/tmp/galleryhid/reload-driver.sh
    EOF
    tail -f /var/tmp/galleryhid-reload.log

The scheduled job is important because stopping CDE also terminates the
CDE-hosted guest relay used by the current shell. A cold boot immediately
after the first `add_drv` reported `WARNING: Reboot required` and left
`svc:/system/filesystem/usr` in maintenance with status 95. Entering the
maintenance password once and issuing `reboot` rebuilt the boot state; the
next boot was normal. This was not a driver panic.

The optional 32-bit Xlib coordinate probe is `xquery-pointer.c`. Linking it
requires `SUNWarc` (`11.10.0,REV=2005.01.21.16.34`) for `crt1.o`; the end-user
media has libraries but not Xlib development headers, so the source carries
only the small Xlib ABI declarations it uses. If the restarted QEMU has an
empty virtual CD, insert `/data/assets-staging/SolarisCDE/sol10.iso` into
`ide1-cd0`, run `volcheck`, and wait for the `Solaris_10/Product` directory
before `pkgadd`.

### Xorg CorePointer configuration

`install-xorg.sh` records whether `/etc/X11/xorg.conf` was absent. For this
clone the rollback marker is
`/etc/X11/xorg.conf.pre-gallerymouse.absent`. The installed config is:

    Section "ServerLayout"
        Identifier  "GalleryLayout"
        Screen      0 "GalleryScreen" 0 0
        InputDevice "GalleryKeyboard" "CoreKeyboard"
        InputDevice "GalleryMouse" "CorePointer"
    EndSection

    Section "InputDevice"
        Identifier "GalleryKeyboard"
        Driver     "kbd"
    EndSection

    Section "InputDevice"
        Identifier "GalleryMouse"
        Driver     "mouse"
        Option     "Protocol" "VUID"
        Option     "Device" "/dev/gallerymouse"
        Option     "Buttons" "3"
    EndSection

    Section "Monitor"
        Identifier "QEMUMonitor"
    EndSection

    Section "Device"
        Identifier "QEMUVESA"
        Driver     "vesa"
    EndSection

    Section "Screen"
        Identifier   "GalleryScreen"
        Device       "QEMUVESA"
        Monitor      "QEMUMonitor"
        DefaultDepth 24
        SubSection "Display"
            Depth 24
            Modes "1920x1200"
        EndSubSection
    EndSection

There is no stock pointer in `ServerLayout`, as either `CorePointer` or
`SendCoreEvents`. `/var/log/Xorg.0.log` confirms `Protocol: VUID`, `Core
Pointer`, `ZAxisMapping: buttons 4 and 5`, and XINPUT registration of
`GalleryMouse`.

### Full-screen framebuffer proof

The final proof injected normalized points with labhost-side `ghid-inject`, waited
for Xorg to consume each event, queried X's root pointer with
`xquery-pointer`, then took a QMP `screendump` and converted the PPM with
`pnmtopng`. The exact results are saved in:

    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-coordinates.txt

They are:

    tl norm=0,0 root_x=0 root_y=0 mask=0x0
    tr norm=32767,0 root_x=1919 root_y=0 mask=0x0
    bl norm=0,32767 root_x=0 root_y=1199 mask=0x0
    br norm=32767,32767 root_x=1919 root_y=1199 mask=0x0
    center norm=16384,16384 root_x=960 root_y=600 mask=0x0

The full 1920x1200 frames were individually inspected, including the clipped
edge cursor at each corner:

    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-tl.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-tr.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-bl.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-br.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-final-center.png

The 1024x768 cap did **not** reproduce: both bottom corners reached y=1199
and both right corners reached x=1919.

### Button drag and wheel proof

The final press/move/release proof selected text in the scene dtterm. It
moved from normalized 2732,6012 (pixel 160,220) to 7342,12298 (pixel
430,450). X reported mask `0x100` while held and `0x0` after release; the
selected region is visibly inverted in the held and after frames:

    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-drag-select-before.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-drag-select-held.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-drag-select-after.png

Allow about one second between state changes in this functional proof. A
zero-delay diagnostic query can race Xorg and observe the coordinate before
the corresponding button state is posted; that is a test-harness race, not
an input-path failure. Stage D should replace sleeps with correlated
timestamps/acknowledgements.

One vertical wheel notch was sent at the same pointer location with transport
`wheel_v=1, wheel_h=0`. The after frame visibly moves dtterm scrollback and
its scrollbar upward:

    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-wheel-notch-before.png
    /data/vms/soltest/lli/spike-solaris-a/stage-c-proof-wheel-notch-after.png

### Stage-D handoff

The complete functional chain is proven: `ghid-inject` -> T1 Unix socket ->
QEMU `gallery-hid-pci` -> fixed INTA -> Solaris BAR2 drain -> constructed
VUID events -> Xorg `GalleryMouse` CorePointer -> the real 1920x1200
framebuffer, including exact full-screen absolute motion, left-button drag,
and wheel. Stage D should measure/correlate latency without changing this
working functional configuration. The current diagnostic logging is verbose
and should be accounted for or disabled only as an explicit measurement
variant.

## `soltest-ghid` cold-boot repair and full-path certification

Status: **PASS**, captured 2026-07-15 on `labhost`.

The tile disk is
`/data/vms/streamhost/stations/soltest-ghid/soltest-ghid.qcow2`. It was copied
from the still-running Stage-C spike and initially entered
`svc:/system/filesystem/usr` maintenance with status 95 while completing the
`add_drv` device reconfiguration. Do not recopy it from that running source.
Boot the existing disk with the standalone gallery-hid QEMU, the same device
set, an isolated QMP/chardev/pidfile/VNC/hostfwd namespace, and `nice -n15`.

For a one-shot repair/certification launch, add `-no-reboot` and omit
`-no-shutdown`. Solaris `init 5` otherwise completes the clean shutdown but
the standalone QEMU resets into GRUB instead of exiting. With `-no-reboot`,
schedule the shutdown through the guest relay and wait for QEMU to remove its
pidfile:

    echo /sbin/init 5 | /usr/bin/at now

The gallery credential fields in `docs/gallery-credentials.md` are Markdown
code spans. A headless helper must strip the surrounding backticks before
typing them and must never print the password. Wait for the username and
password dialogs separately; sending both during a dtlogin repaint can lose
keystrokes. The verified login-field pixel is `(960,651)`, approximately
QMP absolute `(16392,17783)` at 1920x1200.

Two fresh QEMUs, with no `-loadvm`, reached 1920x1200 CDE with
`filesystem/usr` online, `galleryhid` in `modinfo` and `prtconf -D`, and Xorg
reporting `GalleryMouse: Protocol: VUID` and `GalleryMouse: Core Pointer`:

    /data/vms/streamhost/stations/soltest-ghid/cert-coldboot-1/cde-gallerymouse.png
    /data/vms/streamhost/stations/soltest-ghid/cert-coldboot-1/guest-verification.txt
    /data/vms/streamhost/stations/soltest-ghid/cert-coldboot-2-final/cde-gallerymouse.png
    /data/vms/streamhost/stations/soltest-ghid/cert-coldboot-2-final/guest-verification.txt

The deployed test station sets `SH_IDLE_PAUSE_SECS=0`; its 60-second default
pause otherwise pauses the 1--2 minute Solaris cold boot before dtlogin.
The systemd tile reached a 1920x1200 D-Bus scanout and listened on UDP 54912.

The final functional proof sent streamhost warpd verbs to
`127.0.0.1:57812`. X reported exact root coordinates for all five points:

    tl     (0,0)
    tr     (1919,0)
    bl     (0,1199)
    br     (1919,1199)
    center (960,600)

The labelled frames and coordinate log are
`/data/vms/streamhost/stations/soltest-ghid/fullpath-{tl,tr,bl,br,center}.png`
and `fullpath-coordinates.txt`. A persistent TCP session then sent
`D 160 220`, `M 430 450`, and `U 430 450`; X reported button mask `0x100`
while pressed/held and `0x0` after release, and the framebuffer visibly
selected dtterm text. `B 4 430 450` delivered one wheel notch and moved the
visible terminal range from lines 172--200 to 167--196. Evidence is:

    /data/vms/streamhost/stations/soltest-ghid/fullpath-drag-{before,pressed,held,after}.png
    /data/vms/streamhost/stations/soltest-ghid/fullpath-drag-coordinates.txt
    /data/vms/streamhost/stations/soltest-ghid/fullpath-wheel-{before,after}.png
    /data/vms/streamhost/stations/soltest-ghid/fullpath-wheel-coordinate.txt

## Stage D: bounded comparative measurement (PARTIAL)

The 2026-07-15 bounded measurement used the standalone coexisting QEMU D-Bus
listener in `streamhost/qemu-patches/gallery-hid/tools/stage-d-measure/`.
`CLOCK_MONOTONIC` timestamps were taken at display callback entry and two
32x32 ROIs around `(1200,250)` and `(1700,800)` were copied and tested in the
handler. QMP screendumps were audit evidence only. Each path had 320 idle
trials; the unexpected loaded tail was repeated in reversed order for 640
loaded trials per path. All 1,920 attempts completed with stable preconditions
and no timeout or wrong-target failure.

Nearest-rank pooled results in milliseconds:

| path | condition | N | p50 | p95 | p99 | p99-p50 | max | miss |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| warpd | idle | 320 | 2.688 | 4.817 | 4.938 | 2.249 | 4.988 | 0% |
| gallery-hid | idle | 320 | 2.716 | 4.751 | 4.908 | 2.192 | 4.929 | 0% |
| warpd | loaded | 640 | 2.760 | 4.872 | 30.556 | 27.797 | 40.906 | 0% |
| gallery-hid | loaded | 640 | 2.736 | 4.848 | 36.967 | 34.231 | 41.083 | 0% |

Idle p95/p99 gallery-hid-to-warpd ratios were 0.986/0.994. Loaded ratios were
0.995/1.210: the deployed diagnostic driver did **not** show the expected
loaded-tail win and was 21% worse at pooled p99. The first loaded block was
17.728 ms warpd versus 38.684 ms gallery-hid at p99; reversed order was
34.208 versus 36.599 ms, so the tail is not stable enough for a gate claim.

This is PARTIAL because Solaris exposes only CPU 0 even though QEMU launches
two vCPU threads (`max_ncpus=2`, `ncpus=1`, and processor 1 is invalid to
`psradm`). The loaded variant therefore used one normal-priority worker bound
to CPU 0, not one worker per requested vCPU. Repeated `mpstat` samples showed
97--98% user and 0% idle, while a visible 1 Hz `xclock` heartbeat continued.
Also, the diagnostic `galleryhid` driver calls `cmn_err(CE_NOTE)` for every
record from the interrupt drain; this behavior was kept intact because it is
the deployed path and has no runtime off switch. It is a likely tail confound
that must be removed or explicitly A/B tested before T2.

The direct persistent TCP drivers bypass streamhost's WarpdClient coalescer
and pacing on both paths. QEMU's 4 ms D-Bus update batching dominates the
idle result. The host clock reports 1 ns resolution, ROI inspection averaged
about 6--8 microseconds (observed maximum 119 microseconds), and audited QMP
screendumps cost about 19--33 ms but were outside all timed windows. Full raw
JSONL, metadata, audit frames, load evidence, and summaries are under
`/data/vms/streamhost/stations/soltest-ghid/stage-d/REPORT.md` and its sibling
artifacts.

## Native Rust streamhost sink remeasurement (PARTIAL / latency FAIL)

Captured 2026-07-16 on `labhost`. `soltest-ghid` explicitly selected
`SH_INPUT_BACKEND=gallery-hid`; the `warpd-to-ghid` service was inactive and
its streamhost systemd requirement was disabled. Streamhost negotiated
`GHIN`/`GHOK` directly with QEMU's `gallery-hid.sock`. The optional loopback
Stage-D ingress fed the same process-wide input router and `GalleryHidSink` as
WebTransport, rather than writing either the Python bridge or device socket.

The native functional path reached `(0,0)`, `(1919,0)`, `(0,1199)`,
`(1919,1199)`, and `(960,600)` exactly according to `XQueryPointer`. A held
left button reported X mask `0x100` and release reported `0x0`; the CDE resize
gesture entered its visible live-outline state. Two attempted releases did
not commit new geometry, so committed resize remains unproven. The guest had
both processors online, `galleryhid` loaded as the Xorg core pointer, and no
per-record driver logging. Streamhost's final observed counters had no
drops, queue overflow, or backend-down rejection; one stale boot-era socket
was detected on the first functional write and immediately re-negotiated
before measurement.

Two 150-trial native blocks completed under one normal-priority `yes` worker
bound to each guest CPU. Guest `mpstat` showed 100% and 97--98% busy after its
cumulative row, and host sampling showed the QEMU consuming 205--210% CPU.
All 300 attempts succeeded. Nearest-rank results:

| path | N | p50 | p95 | p99 | p99-p50 | max | miss |
|---|---:|---:|---:|---:|---:|---:|---:|
| native gallery-hid | 300 | 2.697 ms | 56.978 ms | 86.638 ms | 83.941 ms | 118.903 ms | 0/300 |

The two native block tails both reproduced: block 1 p95/p99 was
56.978/66.941 ms and block 2 was 64.940/114.557 ms. Against the corrected
loaded baselines above (500 samples each), native gallery-hid is 9.86x warpd
at p95 and 10.77x at p99; it is also 4.96x the Python-bridge gallery-hid p95
and 1.89x its p99. Removing the bridge therefore did **not** improve the
loaded tail and did not beat warpd, despite a lower p50.

The planned same-run G-W-W-G comparison did not complete. A separate
port-7778 load relay successfully kept the normal warpd Python process
responsive to diagnostics and both QEMUs at roughly 200% host CPU, but the
streamhost-driven warpd calibration still produced zero A/B cursor signal.
After the bounded reconnect/retry attempts, no valid new warpd sample existed;
none is invented here. This makes the remeasurement PARTIAL, while the native
path's latency verdict itself is a clear FAIL. Raw native JSONL, metadata,
audits, counters, and the invalid warpd attempts are under
`/data/vms/streamhost/stations/soltest-ghid/native-sink/measure/`.
## VMState and clone checkpoint-resume proof

Status: **PASS**, captured 2026-07-16 on `labhost`. The live `solariscde`
station was not modified or restarted by this work; its warpd-backed QEMU stayed
running. All installation, capturing, and restore testing used the isolated clone:

    /data/vms/soltest/ghid-vmstate-codex

The standalone QEMU was rebuilt from the pinned assembled QEMU 11.0.2/PVE
tree. The stable tested binary and runtime data are:

    /data/vms/streamhost/qemu-gallery-hid/qemu-system-x86_64
    /data/vms/streamhost/qemu-gallery-hid/pc-bios
    SHA-256 ad6731cebf888cb007e7f9c0cffaf1a133f3babb81cd40208b9f53bf44c979d4

This is a standalone artifact, not a system pve-qemu install. The reproducible
production route remains a downstream pve-qemu quilt patch applied by
`scripts/provision/build-pve-qemu-fastpoll.sh`.

### VMState and driver restore behavior

`gallery-hid-pci` now has stable version-1 VMState name
`gallery-hid-pci`; BAR2 uses migratable RAM-region name
`gallery-hid-ring`. The stream contains PCI configuration, IRQ status/mask,
epoch, producer, saved consumer, next sequence, counters, driver-ready,
reset/stall state, and saved INTx level. BAR2 contains the complete ring header,
consumer cache line, and records. Backend socket ownership, hello/parser bytes,
and a staged host frame are deliberately excluded.

Before save, QEMU captures the guest consumer and computed INTx level. After
load it first deasserts INTA and clears stale causes, disconnects/resets all
backend parser state, then cross-validates VMState against BAR2 magic, ABI,
features, epoch, producer, consumer, occupancy, next sequence, IRQ bits, and
the driver's `last_epoch`. New backend frames remain gated until a fresh hello
raises LINK and the guest writes `DRIVER_READY` again.

Solaris does not receive `DDI_RESUME` for this restore. The LINK/RESET ISR now
masks interrupts, validates the ring and nonzero epoch, releases locally held
buttons, discards any pre-reconnect entries by setting consumer to producer,
sets `last_epoch`, writes `DRIVER_READY`, acknowledges stale causes, and
unmasks. This requires no module reload, reinstall, daemon, or userspace repair.
Per-record and control-IRQ diagnostics are compiled out by default with
`GHID_DEBUG_LOG=0`; fault warnings remain.

The exact copied QEMU artifacts passed all five qtests, including
`/gallery-hid/vmstate-save-load`. That test migrates armed device state with a
pending ring record and asserted INTA, verifies PCI/BAR2/control state at the
destination, proves backend-disconnected plus stale-INTA-deasserted state,
then reconnects, re-arms, and publishes the next sequence. TAP is:

    /data/vms/soltest/ghid-vmstate-codex/qtests-vmstate.tap

### Reproducible capture

Use the checked-in clone-only helper after the desktop is settled. First send
`RELEASE_ALL` plus a button-zero pointer snapshot, wait for X to report mask
zero, and close the gallery socket. The helper independently refuses live station
paths, verifies the pidfile uses a disk below the clone, rejects an established
gallery backend, reads BAR0/BAR2 through QMP, and requires an empty ring,
matching armed epoch, driver-ready, all IRQs enabled, and no pending cause:

    D=/data/vms/soltest/ghid-vmstate-codex
    streamhost/qemu-patches/gallery-hid/golden-bake-solaris-clone.py \
      --dry-run "$D"
    streamhost/qemu-patches/gallery-hid/golden-bake-solaris-clone.py \
      --replace "$D"

The installed clone reported `galleryhid` in `modinfo` and `prtconf -D`,
`/dev/gallerymouse` present, and Xorg logged VUID/CorePointer registration.
Immediately before the actual capture, BAR2 producer and consumer were both 20,
`last_epoch` equalled epoch 10, X button mask was zero, and the backend was
closed. `savevm golden` completed in 1.808 seconds.

### Restore proof

The checked-in launcher accepts `LOADVM=golden` while preserving the required
two-socket/two-vCPU topology and CPU identity:

    -smp 2,sockets=2,cores=1,threads=1
    -cpu Nehalem,hv-vendor-id=XenVMMXenVMM,hv-relaxed,-x2apic

Seven consecutive fresh QEMU processes loaded `golden`. QMP was running and
the settled 1920x1200 CDE framebuffer was available after 0.764--0.768 seconds
on every cycle. Each first hello reported epoch 10/status `0x7` (connected,
driver-ready, restore re-arm required); after the kernel ISR re-armed, the
tested corner or centre was exact and the X button mask was zero. The cycle
record is:

    /data/vms/soltest/ghid-vmstate-codex/process-loadvm-cycles.txt

On the first restored process, all four corners plus centre were exact, a left
click changed X mask `0x0 -> 0x100 -> 0x0`, and a right-border drag changed the
visible CDE terminal from 1098x538 to 1287x538. The held framebuffer contains
the CDE rubber-band outline and `138x30` resize overlay; the final framebuffer
shows the enlarged window.

A coordinated live QMP round-trip also closed the backend before load, observed
an empty ring, ran `loadvm golden` in 2.418 seconds, and restored a running CDE.
The new hello again reported `0x7`; the kernel re-armed and top-left landed at
`(0,0)`. A live-restored right-border drag then changed 1098x538 to 936x538,
with both held rubber-band and final framebuffers inspected. The TAP, cycle
logs, and selected instant/held/final framebuffer PNGs are retained at:

    /data/vms/streamhost/qemu-gallery-hid/proof-20260716

### Immediate promotion handoff

Do not cold-boot production. The next session promotes the proven launcher,
standalone QEMU, driver/Xorg state, and `golden` to the live `solariscde` station
through the normal clone-to-production procedure. Keep warpd installed and
available as fallback until the production framebuffer, reconnect, corners,
click, and resize-drag pass. Then remove the `soltest` clones and add the
registry-owned `HW input` grid badge; never hand-edit generated
`stations-manifest.sh`. Do not deploy the UI during that handoff.
