# Solaris `galleryhid` VUID pointer driver

This is the Solaris 10 amd64 leaf driver for the v1 `gallery-hid-pci`
transport. It maps control BAR0 as Solaris rnumber 1 and the device-owned BAR2
ring as rnumber 2; it does not allocate DMA memory.

The driver retains the Stage-B diagnostic ring drain and adds a `DDI_NT_MOUSE`
STREAMS minor. Pointer records become adjacent X/Y absolute `Firm_event`s,
button transitions, and vertical wheel events for Xorg's `mouse` driver in
VUID mode. The diagnostic and mouse device nodes are independent minors of the
same hardware instance.

## Solaris 10 u11 prerequisites

From the matching `Solaris_10/Product` package directory, install `SUNWhea`,
`SUNWgcc`, `SUNWsprot`, and `SUNWbtool`. The optional `xquery-pointer` proof
also needs `SUNWarc` for the 32-bit startup object. GCC is
`/usr/sfw/bin/gcc` 3.4.3 and the linker is `/usr/ccs/bin/ld`.

From the box checkout, stage the directory through SLIRP, then build and
install in the guest:

    ./stage-to-guest.sh 58790
    # in the guest:
    cd /var/tmp/galleryhid
    ./build.sh
    ./install.sh
    ./install-xorg.sh

`install.sh` uses Solaris 10 `install -f <directory>` syntax, installs the
module and `galleryhid.conf`, binds `pci1b36,15`, and creates the deterministic
devlink rule:

    type=ddi_mouse;name=pci1af4,1100;minor=mouse	gallerymouse

The `name` field is the devinfo node name, not `galleryhid`. The expected link
is:

    /dev/gallerymouse -> ../devices/pci@0,0/pci1af4,1100@1e:mouse

The installer never hardcodes the routed legacy IRQ.

If Xorg currently has the mouse minor open, schedule `reload-driver.sh` from a
durable console or `at` job. It stops CDE login, rebuilds and installs the
module, and re-enables CDE even on error:

    cd /var/tmp/galleryhid
    at now <<'EOF'
    /var/tmp/galleryhid/reload-driver.sh
    EOF
    tail -f /var/tmp/galleryhid-reload.log

Stopping CDE also stops a relay launched from that desktop session, which is
why an in-session synchronous reload is not reliable.

## VUID contract

The mouse open is exclusive. `VUIDSFORMAT` accepts only `VUID_FIRM_EVENT`;
`VUIDGFORMAT`, `VUIDSADDR`, `VUIDGADDR`, `MSIOBUTTONS`,
`VUIDGWHEELCOUNT`, `VUIDGWHEELINFO`, `VUIDGWHEELSTATE`,
`VUIDSWHEELSTATE`, and `MSIOSRESOLUTION` are implemented. Transparent wheel
and resolution ioctls use STREAMS `M_COPYIN`/`M_COPYOUT` handling.

Each T1 `POINTER_ABS_STATE` is decoded explicitly. The raw 16-byte transport
record is never treated as a `Firm_event`. X/Y are emitted together as
`LOC_X_ABSOLUTE` and `LOC_Y_ABSOLUTE`; changed transport bits map to
`MS_LEFT`, `MS_MIDDLE`, and `MS_RIGHT` with `VKEY_DOWN=1` and `VKEY_UP=0`;
the signed vertical delta maps to VUID wheel 0. `release-all` emits releases
for held pointer buttons.

This clone's installed Xorg mouse module does not send `MSIOSRESOLUTION`.
`galleryhid.conf` therefore seeds the verified fixture size as 1920x1200 so
the driver can emit pixel-valued absolute events. A later
`MSIOSRESOLUTION` overrides those properties and triggers one
`MOUSE_TYPE_ABSOLUTE` notification.

## Xorg configuration

`xorg.conf.gallerymouse` makes only `GalleryMouse` the `CorePointer`, using
`Driver "mouse"`, `Protocol "VUID"`, `/dev/gallerymouse`, and three physical
buttons. It does not list the stock mouse as `CorePointer` or
`SendCoreEvents`. `install-xorg.sh` preserves an existing config at
`/etc/X11/xorg.conf.pre-gallerymouse`; if there was no config it creates the
`.pre-gallerymouse.absent` marker.

Restart CDE login after installation and verify `/var/log/Xorg.0.log` contains
`GalleryMouse: Protocol: VUID`, `GalleryMouse: Core Pointer`, and the XINPUT
registration.

Per-record and control-IRQ logging is compiled out by default with
`GHID_DEBUG_LOG=0`. Warnings for malformed rings or sequence faults remain.
Snapshot restore does not invoke `DDI_RESUME`: the first backend LINK interrupt
validates the restored header/epoch, releases locally held buttons, discards
entries by advancing consumer to producer, writes `last_epoch` and
`DRIVER_READY`, acknowledges stale causes, and unmasks interrupts. QEMU gates
post-hello event frames until that re-arm write completes.

## Stage-C result (2026-07-15)

The disposable clone attached the final module with fallback resolution
1920x1200. X's root pointer reported exactly (0,0), (1919,0), (0,1199),
(1919,1199), and (960,600) for normalized corners and centre. Five QMP
framebuffer dumps were inspected; the 1024x768 cap did not reproduce.

A left press/move/release selected a visible dtterm region, with X reporting
Button1 mask `0x100` while held and zero after release. One vertical wheel
notch visibly moved dtterm scrollback and its scrollbar. Exact commands and
artifact paths are in
`docs/lab/research/low-latency-input/spike-solaris-runbook.md`.

The golden-resume proof on 2026-07-16 restored this installed module without a
reload or reinstall across seven process-start `-loadvm golden` cycles and one
live QMP `loadvm golden` cycle. Exact corner, click, and CDE border-resize tests
passed after reconnect in the restored desktop.
