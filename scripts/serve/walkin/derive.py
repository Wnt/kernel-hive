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

The MAC is deliberately NOT rewritten. `loadvm` restores the NIC's MAC from
saved device state, so a per-clone `mac=` on the command line is a lie the guest
never hears: every clone of one station comes up as the address its golden was
captured with. Setting it anyway would leave the command line disagreeing with
the vmstate — the exact mismatch that reads as "the network is broken" three
hours later. Concurrency is solved one layer down instead: each clone's tap
joins its OWN bridge (`wi-clonecell`, ledger §6), so identical MACs never share
an FDB, and the cell's NAT gives the gateway a unique peer per clone. The
command line stays in perfect agreement with the vmstate.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import deviceset, launcher, naming
from .spec import StationSpec

SANDBOX_ARG = "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"


class InvariantError(ValueError):
    """A derived command line that lost something the station said must survive."""


@dataclass(frozen=True)
class ClonePlan:
    """Everything one pool member needs, resolved before anything is created."""

    identity: str
    station: str
    index: int
    slot: int
    root: Path
    # One per `-drive` the launcher carries, in argv order. A golden can span
    # several images and `loadvm` needs its snapshot in every one of them.
    disks: tuple
    tap: str
    mac: str
    udp_port: int
    vmid: int
    tapnet: str

    @property
    def overlay(self) -> Path:
        return self.disks[0]

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
        disks=clone_disks(spec, root),
        tap=naming.tap_name(spec.station, index, spec.netdev.ifname_pattern),
        mac=naming.clone_mac(slot),
        udp_port=naming.udp_port(slot),
        vmid=naming.vmid(slot),
        tapnet=spec.tapnet,
    )


def clone_disks(spec: StationSpec, root: Path) -> tuple:
    """Where each seed lands inside the clone, keeping the seed's own basename.

    The name is kept so a clone directory says what it holds — `win311-golden`
    and `games-golden`, not `overlay` and `overlay-2`. A collision between two
    seeds that share a basename is disambiguated by position rather than
    silently overwritten, because the second copy would otherwise clobber the
    first and the guest would restore against one disk twice.
    """
    out, seen = [], set()
    for position, seed in enumerate(spec.seed_disks):
        name = Path(seed).name
        if name in seen:
            name = f"{position}-{name}"
        seen.add(name)
        out.append(root / name)
    return tuple(out)


def read_launcher(spec: StationSpec, repo_root: Path) -> launcher.Launcher:
    """The station's launcher as the broker sees it: golden, paused, no cold boot.

    `LOADVM` is preset rather than parsed because the launcher decides it with a
    `qemu-img snapshot -l | grep` we will not execute. A pool member has no
    business cold-booting anyway: if the golden is missing, the right outcome is
    a loud failure, which is what `spawn` gets when QEMU refuses the `-loadvm`.
    """
    path = Path(repo_root) / spec.launcher
    station_dir = path.parent
    return launcher.parse(path, presets={"B": str(station_dir), "LOADVM": f"-loadvm {spec.seed_snapshot} -S"})


def _netdev_value(base: str, plan: ClonePlan, spec: StationSpec) -> str:
    _, opts = deviceset.parse_opts(base)
    ident = opts.get("id", "n0")
    if spec.netdev.id and spec.netdev.id != ident:
        raise deviceset.DeviceSetError(
            f"{spec.station}: overrides.netdev.id is {spec.netdev.id!r} but the launcher's netdev is {ident!r}. "
            "The id binds the NIC to its backend in the vmstate; it is an assertion here, never a rename."
        )
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
    if spec.binary and "/" not in spec.binary and spec.binary != argv[0]:
        # A bare name is not a pin — it is a PATH lookup — so the only honest
        # meaning it can carry is "the launcher already runs this". win311
        # declares `qemu-system-i386` and that is what its launcher runs. A bare
        # name that DISAGREES would silently substitute an emulator the golden
        # was never captured against, which is the failure rule 6 exists for.
        raise InvariantError(
            f"{spec.station}: binary is declared as {spec.binary!r} but the launcher runs {argv[0]!r}. "
            "Use an absolute path to pin a different emulator; a bare name can only assert the one in use."
        )
    if spec.binary and "/" in spec.binary and not Path(spec.binary).exists():
        raise launcher.LauncherError(
            f"{spec.station}: overrides.binary {spec.binary} is not on this box. Refusing to fall back to stock "
            "QEMU — the golden was captured against that binary and rule 6 binds the two together."
        )
    drives = [tok for j, tok in enumerate(argv) if j and argv[j - 1] == "-drive"]
    if len(drives) != len(plan.disks):
        raise InvariantError(
            f"{spec.station}: the launcher carries {len(drives)} -drive flag(s) but the station file declares "
            f"{len(plan.disks)} seed disk(s). `loadvm` needs the snapshot in every image, so these must match "
            "one for one, in order."
        )
    out = [binary]
    drive_index = 0
    i = 1
    while i < len(argv):
        flag = argv[i]
        has_value = i + 1 < len(argv) and not argv[i + 1].startswith("-")
        value = argv[i + 1] if has_value else None
        if value is not None:
            value = value.replace(station_prefix, str(plan.root).rstrip("/"))
        if flag == "-name":
            value = f"streamhost-{plan.identity}"
        elif flag == "-drive" and value is not None:
            _, opts = deviceset.parse_opts(value)
            opts["file"] = str(plan.disks[drive_index])
            drive_index += 1
            value = ",".join(f"{k}={v}" for k, v in opts.items())
        elif flag == "-netdev" and value is not None:
            value = _netdev_value(argv[i + 1], plan, spec)
        elif flag == "-chardev" and value is not None and spec.chardev:
            value = _chardev_value(value, plan, spec)
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
    assert_invariants(spec, out)
    return out


def _chardev_value(value: str, plan: ClonePlan, spec: StationSpec) -> str:
    """Re-root one chardev's BACKEND path. The device does not move.

    `-chardev socket,id=ser0,path=…` is the host end of the COM1 pipe the
    in-guest warpd agents speak over; the serial device itself comes from the
    machine type. So this changes a path and nothing else, and
    `assert_same_device_set` sees no change at all — `path` is one of the
    options a chardev is allowed to move (paths, ports, tap names), which is
    exactly the legitimate case the ledger names.
    """
    head, opts = deviceset.parse_opts(value)
    template = spec.chardev.get(opts.get("id", ""))
    if not template:
        return value
    opts["path"] = template.replace("<clone>", str(plan.root)).replace("{stateDir}", str(plan.root))
    return ",".join([head] + [f"{k}={v}" for k, v in opts.items()])


def assert_invariants(spec: StationSpec, argv: list) -> None:
    """Every fragment the station said must survive, still in the command line.

    A station declaring its own invariants is better than a reviewer noticing:
    win311's patched `-bios …/bios-256k-int16if.bin` carries the SeaBIOS INT16h
    fix, and a clone that quietly loses it wedges after ~61 key edges instead of
    surviving hundreds — a failure that looks like a streaming bug, three
    minutes into somebody's session.
    """
    joined = " ".join(argv)
    missing = [fragment for fragment in spec.invariants if fragment not in joined]
    if missing:
        raise InvariantError(
            f"{spec.station}: the derived command line lost {missing!r}. "
            "The station declared it as an invariant, so this is a derivation bug, not a stale declaration."
        )
