"""What each `stream.pointer.method` implies, as data.

Split out of validate_rules.py when that module reached its size cap: these four
tables are a ledger of the fleet's emulated input hardware, they are read by the
pointer rule and by nothing else, and they change whenever a station gains a new
KIND of pointer -- which is a different rhythm from the rules that consume them.
"""

from __future__ import annotations

# stream.pointer.method -> (the SH_INPUT_BACKEND values that can deliver it,
# device-ledger tokens the station MUST carry, tokens it must NOT carry). The
# backend column mirrors InputBackend in streamhost/streamhost/src/config/
# backends.rs; the ledger columns are what the launcher/emitArgs must show.
POINTER_METHODS: dict[str, tuple[set[str], tuple[str, ...], tuple[str, ...]]] = {
    # "none" admits mamesock and vicesock as well as disabled: a de-bridged
    # keyboard-only station has NO pointer, but its KEYS ride that backend --
    # the MAME module acks pointer verbs as silent no-ops (btns=0 axes=0), and
    # the vicesock sink rejects them outright (there is no pointer verb).
    "none": (
        {"disabled", "mamesock", "vicesock"},
        (),
        ("usb-tablet", "vmmouse", "gallery-hid-pci"),
    ),
    "qemu-usb-tablet": ({"dbus-abs"}, ("usb-tablet",), ()),
    "qemu-vmmouse": ({"dbus-abs"}, ("vmmouse", "vmport=on"), ("usb-tablet",)),
    "qemu-ps2-relative": ({"dbus-rel"}, (), ("usb-tablet",)),
    # The m68k q800's mouse is ADB. Same daemon backend as the PS/2 relative
    # stations and the same abs->rel bridge, but it is NOT a PS/2 mouse and the
    # ledger must not claim it is: the machine has no PS/2 controller, no USB
    # bus to hang a tablet off, and no absolute pointer path of any kind.
    "qemu-adb-relative": ({"dbus-rel"}, (), ("usb-tablet",)),
    # mac99 via=pmu has BUILT-IN USB kbd+mouse and Mac OS 9 has no usb-tablet
    # driver; the launcher must add neither a tablet nor a second usb-mouse.
    "qemu-usb-hid-relative": ({"dbus-rel"}, (), ("usb-tablet", "-device usb-mouse")),
    "gallery-hid": ({"gallery-hid"}, ("gallery-hid-pci",), ()),
    "warpd-agent": ({"warpd"}, (), ("usb-tablet",)),
    "mame-ioport": ({"mamecmd", "mamesock"}, (), ()),
    "x11-xtest": ({"x11test"}, (), ()),
    "simh-light-pen": ({"dbus-abs"}, ("usb-tablet",), ()),
    # nextstep: Previous emulates a SummaGraphics MM 1201 digitiser on the NeXT's
    # own SCC serial port B, and NeXTSTEP 3.3's own tablet driver is attached
    # inside the golden, so an absolute target is one tablet_pen_move() and lands
    # on the commanded pixel. There is no QEMU here at all -- no usb-tablet, no
    # PS/2, no ADB -- so the device ledger must name none of them.
    "previous-tablet": ({"mamesock"}, (), ("usb-tablet",)),
    # aix432: the fleet's second CLOSED-LOOP pointer and the first inside QEMU.
    # The 40p has a PS/2 mouse and no absolute device at all, so on the WIRE
    # this is still relative -- but AIX's X server drives the emulated Matrox
    # HARDWARE cursor, so the device model reads the guest's own pointer
    # position back out of the DAC's CURPOSX/Y registers and converges on it.
    # `absolute: true` is therefore earned by measurement, not by a device. The
    # ledger must show the control chardev the engine serves: without
    # `mga.ptrctl` the loop is not armed and the daemon has nothing to talk to.
    "qemu-mga-closedloop": ({"mgactl"}, ("mga.ptrctl",), ("usb-tablet",)),
    # hpuxvue: the aix432 loop ported to the hppa B160L. The machine has ONE
    # graphics path -- the built-in Artist framebuffer -- and a LASI PS/2 mouse
    # with no absolute device at all, so on the WIRE this is still relative.
    # But HP-UX 10.20's X server drives the Artist HARDWARE cursor, so the
    # device model reads the guest's own pointer position back out of the
    # CURSOR_POS/CURSOR_CTRL registers and converges on it: the Artist cursor
    # registers are the loop's sensor, and `absolute: true` is earned by
    # measurement (framebuffer-verified at 7 targets, --tol 1), not by a
    # device. The ledger must show the control chardev the engine serves:
    # without `artist.ptrctl` the loop is not armed and the daemon has nothing
    # to talk to.
    "qemu-artist-closedloop": ({"artistctl"}, ("artist.ptrctl",), ("usb-tablet",)),
    # rhapsody: an absolute pointer with NO absolute device and NO control loop.
    # Rhapsody DR2 keeps its own pointer coordinate in a known guest-RAM
    # structure, so the commanded coordinate is simply WRITTEN there and one
    # small relative event is injected to make the window server republish it.
    # The hotspot never enters the path, and the display adapter is not involved
    # at all -- which is why this station's device set and golden are unchanged.
    # `absolute: true` is earned by reading the guest's own coordinate back after
    # every write; the control object refuses to write at all until it has
    # verified its address, so the ledger must show the `kh-ramabs` control
    # object. Without it the daemon has nothing to talk to.
    "qemu-guestram-abswrite": ({"ramabs"}, ("kh-ramabs",), ("usb-tablet",)),
}
# `pointer_mode` in the labctl matrix is the daemon's own backend -> abs/rel/
# warpd/none projection (InputBackend::pointer_mode()); labctl's `abs x y` and
# the UI's transport choice both key on it, so it must agree with `absolute`.
POINTER_MODE_BY_BACKEND = {
    "disabled": "none",
    "dbus-rel": "rel",
    "warpd": "warpd",
    "dbus-abs": "abs",
    "gallery-hid": "abs",
    "x11test": "abs",
    "mamecmd": "abs",
    "mamesock": "abs",
    "mgactl": "abs",
    "artistctl": "abs",
    "ramabs": "abs",
    # Keyboard-only by construction: InputBackend::pointer_mode() reports
    # "none" for ViceSock, and the sink has no pointer verb at all.
    "vicesock": "none",
}
LEGACY_POINTER_BACKEND = {"abs": "dbus-abs", "rel": "dbus-rel", "warpd": "warpd", "none": "disabled"}
# serenityos gets QEMU's absolute VMware aux mouse from the q35 default
# `vmport=auto`, so its device ledger names neither `vmmouse` nor `vmport=on`
# (verified live: dbus SetAbsPosition lands 1:1, a relative delta is ignored).
POINTER_LEDGER_EXCEPTION = "pointer-vmmouse-implicit"

# Backends that construct NO InputRouter, mirroring the single seam that decides
# it: `InputRouter::from_config` in streamhost/streamhost/src/realtime_input.rs,
# whose first match arm is
#     InputBackend::Disabled | InputBackend::DbusAbs | InputBackend::DbusRel => return None
# Everything else builds a sink and therefore routes.
#
# DELIBERATELY A NEGATIVE SET, so it fails CLOSED: a backend added tomorrow is
# treated as routed on the day it is added rather than the day someone remembers
# to extend a positive list. Only add a name here after checking that arm.
NON_ROUTED_BACKENDS = {"disabled", "dbus-abs", "dbus-rel"}


def constructs_router(backend: str | None) -> bool:
    """Does this backend build an InputRouter? Absent backend -> no."""
    return bool(backend) and backend not in NON_ROUTED_BACKENDS
