"""Station launcher + override -> one clone's QEMU command line.

Three rewrites and nothing else:

1. **Re-root every path.** Wherever the station's own directory appears —
   pidfile, QMP socket, serial chardev, log — the clone root replaces it,
   basename intact. One substitution covers the whole family, so a launcher that
   grows a fourth socket tomorrow is re-rooted without a code change here.
2. **Swap the disk for the overlay.** The seed stays read-only; the clone writes
   to a throwaway qcow2 backed by it. This is the whole reason a visitor can
   wreck a machine.
3. **Rebuild the netdev backend** from the override, and give the clone its own
   MAC.

Then `-loadvm golden -S` (instant-ready, paused) and, where the binary is QEMU,
the sandbox flags from brief §6.2. Then `deviceset.assert_same_device_set`, which
is allowed to veto everything above.

The MAC is deliberately NOT rewritten, and that is the whole reason the pool is
one clone per station. `loadvm` restores the NIC's MAC from saved device state,
so a per-clone `mac=` on the command line is a lie the guest never hears: every
clone of one station comes up as the address its golden was captured with.
Setting it anyway would leave the command line disagreeing with the vmstate — the
exact mismatch that reads as "the network is broken" three hours later. Ledger
§5.3 has the consequence: `poolSize` is 1, and growing it needs a walk-in golden
captured on this plane, not a command-line flag.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import deviceset, launcher, naming
from .spec import StationSpec

SANDBOX_ARG = "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"


@dataclass(frozen=True)
class ClonePlan:
    """Everything one pool member needs, resolved before anything is created."""

    identity: str
    station: str
    index: int
    slot: int
    root: Path
    overlay: Path
    tap: str
    mac: str
    udp_port: int
    vmid: int
    tapnet: str

    @property
    def qmp_socket(self) -> Path:
        return self.root / "qmp.sock"

    @property
    def pidfile(self) -> Path:
        return self.root / "qemu.pid"

    @property
    def logfile(self) -> Path:
        return self.root / "qemu.log"


def plan_for(spec: StationSpec, index: int, slot: int) -> ClonePlan:
    ident = naming.identity(spec.station, index)
    root = naming.clone_root(ident)
    return ClonePlan(
        identity=ident,
        station=spec.station,
        index=index,
        slot=naming.check_slot(slot),
        root=root,
        overlay=root / f"overlay.{spec.overlay_format}",
        tap=naming.tap_name(spec.station, index, spec.netdev.ifname_pattern),
        mac=naming.clone_mac(slot),
        udp_port=naming.udp_port(slot),
        vmid=naming.vmid(slot),
        tapnet=spec.tapnet,
    )


def read_launcher(spec: StationSpec, repo_root: Path) -> launcher.Launcher:
    """The station's launcher as the broker sees it: golden, paused, no cold boot.

    `LOADVM` is preset rather than parsed because the launcher decides it with a
    `qemu-img snapshot -l | grep` we will not execute. A pool member has no
    business cold-booting anyway: if the golden is missing, the right outcome is
    a loud failure, which is what `spawn` gets when QEMU refuses the `-loadvm`.
    """
    path = Path(repo_root) / spec.launcher
    station_dir = path.parent
    return launcher.parse(path, presets={"B": str(station_dir), "LOADVM": "-loadvm golden -S"})


def _netdev_value(base: str, plan: ClonePlan, spec: StationSpec) -> str:
    _, opts = deviceset.parse_opts(base)
    ident = opts.get("id", "n0")
    kind = spec.netdev.type
    if kind == "none":
        # A backend that goes nowhere: the guest keeps its NIC, the host offers
        # it no wire. This is what a clone gets before the walk-in bridge exists.
        return f"user,id={ident},restrict=on"
    if kind == "user":
        return f"user,id={ident},restrict=on"
    return f"tap,id={ident},ifname={plan.tap},script=no,downscript=no"


def station_runtime_dir(base: launcher.Launcher) -> str:
    """The directory the launcher actually writes into, read off its own argv.

    Taken from `-pidfile` rather than from a caller-supplied path: the pidfile IS
    the station's runtime dir by construction, and a caller who passed the REPO
    path instead would re-root only the tail of every absolute path and silently
    produce `/data/vms//data/vms/walkin/...`. Asked for once, from the one place
    that cannot be wrong.
    """
    argv = base.argv
    for i, tok in enumerate(argv):
        if tok == "-pidfile" and i + 1 < len(argv):
            return str(Path(argv[i + 1]).parent)
    fallback = base.variables.get("D", "")
    if not fallback:
        raise launcher.LauncherError(f"{base.path}: no -pidfile and no D= — cannot tell where this station lives")
    return str(fallback).rstrip("/")


def derive_argv(base: launcher.Launcher, plan: ClonePlan, spec: StationSpec) -> list:
    argv = list(base.argv)
    station_prefix = station_runtime_dir(base)
    binary = spec.binary or argv[0]
    if spec.binary and not Path(spec.binary).exists():
        raise launcher.LauncherError(
            f"{spec.station}: overrides.binary {spec.binary} is not on this box. Refusing to fall back to stock "
            "QEMU — the golden was captured against that binary and rule 6 binds the two together."
        )
    seed = spec.seed_disk
    out = [binary]
    i = 1
    while i < len(argv):
        flag = argv[i]
        has_value = i + 1 < len(argv) and not argv[i + 1].startswith("-")
        value = argv[i + 1] if has_value else None
        if value is not None:
            value = value.replace(station_prefix, str(plan.root).rstrip("/"))
        if flag == "-name":
            value = f"streamhost-{plan.identity}"
        elif flag == "-drive" and value is not None and seed in argv[i + 1]:
            value = value.replace(seed, str(plan.overlay))
        elif flag == "-netdev" and value is not None:
            value = _netdev_value(argv[i + 1], plan, spec)
        out.append(flag)
        if value is not None:
            out.append(value)
        i += 2 if has_value else 1

    if "-loadvm" not in out:
        out += ["-loadvm", "golden", "-S"]
    elif "-S" not in out:
        out.append("-S")
    if spec.sandbox and "qemu-system-" in out[0] and "-sandbox" not in out:
        out += ["-sandbox", SANDBOX_ARG]

    deviceset.assert_same_device_set(base.argv, out, expect_binary=binary)
    return out
