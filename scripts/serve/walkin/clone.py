"""One walk-in clone, from empty directory to reaped.

The whole lifecycle lives here so that the pool (`broker.py`) never has to know
how a machine is made — it asks for one, hands it out, and asks for it to be
destroyed. Every step that could touch something that is not a clone goes
through `clone-guard`, with its clone root pointed at `/data/vms/walkin`
(`docs/lab/clone-guard.md` documents that override as the supported way to name
a different sandbox). The kill is by PIDFILE, never by name: `pkill -f` from a
box session matches the session's own ssh (rule 5).

Order matters, and it is the order the brief gives:

    prepare  claim slot -> mkdir root -> overlay backed by the READ-ONLY seed
             -> tap up through the station's own wi-tapnet.sh
    spawn    QEMU under walkin.slice, -loadvm golden -S: instant-ready, PAUSED
    resume   the claim is what un-pauses it; a pool member costs ~nothing until
             somebody is actually there
    kill     clone-guard kill-pidfile, then the unit, then the tap down
    discard  rm -rf the root — the overlay dies with it, which is what makes the
             next visitor's machine pristine

A clone is never handed to a second visitor, so `discard` has no "clean it up
and re-list it" path. Reuse is respawn.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import claims, derive, naming
from .qmp import QMP
from .spec import StationSpec

CLONE_GUARD = os.environ.get("CLONE_GUARD_BIN", "/usr/local/bin/clone-guard")
STREAMHOST_BIN = "/usr/local/lib/streamhost/stations/{station}/current"
STATIONS_ROOT = Path(os.environ.get("WALKIN_STATIONS_ROOT", "/data/vms/streamhost/stations"))

# brief §4: the museum's stations must not feel the walk-in plane. These are the
# defaults the slice imposes per clone; the slice itself carries the global cap.
# The plane's ARP-priming helper (ledger §6), as a command template. `{ip}`,
# `{tap}` and `{identity}` are filled in. Lane 6 owns the helper itself — it
# lives with the plane's tooling rather than being copied into three station
# scripts — so the broker only knows how to CALL it, and is told which by this.
ARP_PRIME_CMD = os.environ.get("WALKIN_ARP_PRIME", "")
CPU_QUOTA = os.environ.get("WALKIN_CPU_QUOTA", "100%")
MEMORY_MAX = os.environ.get("WALKIN_MEMORY_MAX", "1G")
TASKS_MAX = os.environ.get("WALKIN_TASKS_MAX", "96")


class CloneError(RuntimeError):
    """A clone that could not be built, or one we refuse to touch."""


def _guard_env() -> dict:
    return {**os.environ, "CLONE_GUARD_CLONE_ROOT": str(naming.WALKIN_ROOT)}


def _run(argv: list, env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(argv, capture_output=True, text=True, env=env or os.environ.copy(), check=False)
    if check and proc.returncode != 0:
        raise CloneError(f"{argv[0]} failed ({proc.returncode}): {(proc.stderr or proc.stdout).strip()[:400]}")
    return proc


def guard(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    if not Path(CLONE_GUARD).exists():
        raise CloneError(f"clone-guard is not installed at {CLONE_GUARD}; refusing to run unguarded")
    return _run([CLONE_GUARD, *args], env=_guard_env(), check=check)


@dataclass
class Clone:
    """A single pool member. Created by `build`, destroyed by `destroy`."""

    plan: derive.ClonePlan
    spec: StationSpec
    argv: list
    slot_claim: claims.SlotClaim
    unit: str = ""
    daemon_unit: str = ""
    primed: bool = False
    extras: dict = field(default_factory=dict)

    @property
    def identity(self) -> str:
        return self.plan.identity

    # -- construction ----------------------------------------------------

    def prepare(self) -> None:
        root = self.plan.root
        guard("assert-path", str(root))
        root.mkdir(parents=True, exist_ok=True)
        root.chmod(0o750)
        self._make_overlay()
        self._tapnet("up")

    def _make_overlay(self) -> None:
        """The clone's writable disks: COPIES of the seeds, not backing overlays.

        This is the one place the obvious design does not work, and it is worth
        the paragraph. A pool member boots `-loadvm golden`, and a qcow2's
        snapshots live in the image's OWN snapshot table — a `qemu-img create -b
        seed` overlay inherits the seed's data and none of its snapshots, so QEMU
        answers `Snapshot 'golden' does not exist in one or more devices` and the
        clone never starts. Measured on the box against the os2warp seed, and
        independently by lanes 7, 8 and 10.

        So each disk is copied with `cp --reflink=ALWAYS`: on a reflink-capable
        filesystem this IS copy-on-write — hundreds of megabytes in tens of
        milliseconds for a kilobyte of new space, snapshot table included.
        `always`, not `auto`, on purpose: `auto` degrades silently to a full
        copy, and a pool that refills on a timer would spend minutes and
        gigabytes doing it without a word. A reflink across datasets fails
        `EXDEV`, so the seeds must be staged inside the same dataset as the clone
        root (ledger §5.2).

        EVERY seed is copied, because `loadvm` needs the snapshot present in
        every attached image: win311 restores `win311-golden` and `games-golden`
        together, and half a restore is not a restore.

        The seeds themselves are never opened for writing by anything here.
        """
        for seed_path, target in zip(self.spec.seed_disks, self.plan.disks):
            seed = Path(seed_path)
            if not seed.exists():
                raise CloneError(f"seed disk {seed} is missing — a pool member has nothing to be a copy of")
            if target.exists():
                target.unlink()
            proc = _run(["cp", "--reflink=always", str(seed), str(target)], check=False)
            if proc.returncode != 0:
                raise CloneError(
                    f"reflink copy of {seed} -> {target} failed: "
                    f"{(proc.stderr or proc.stdout).strip()[:200]} — stage the seed in the same dataset as "
                    f"{naming.WALKIN_ROOT} (a cross-dataset reflink is EXDEV, and a full copy per clone is not a pool)"
                )
            target.chmod(0o600)

    def _tapnet(self, verb: str) -> None:
        if self.spec.netdev.type != "tap" or not self.spec.tapnet:
            return
        script = STATIONS_ROOT / self.spec.station / Path(self.spec.tapnet).name
        if not script.exists():
            raise CloneError(f"{script} is not on the box — the walk-in tap script has not been deployed")
        _run(
            ["bash", str(script), verb],
            env={**os.environ, "WI_TAP": self.plan.tap, "WI_IDENTITY": self.identity, "WI_MAC": self.plan.mac},
            check=(verb == "up"),
        )

    # -- running ---------------------------------------------------------

    def spawn(self) -> None:
        """Start QEMU under `walkin.slice`, restored to the golden and PAUSED."""
        self.unit = naming.unit_name(self.identity)
        cmd = [
            "systemd-run", f"--unit={self.unit}", f"--slice={naming.SLICE}", "--collect",
            f"--property=CPUQuota={CPU_QUOTA}", f"--property=MemoryMax={MEMORY_MAX}",
            f"--property=TasksMax={TASKS_MAX}", "--property=Delegate=no",
            f"--property=WorkingDirectory={self.plan.root}",
            f"--property=StandardOutput=append:{self.plan.logfile}",
            f"--property=StandardError=append:{self.plan.logfile}",
            "--", *self.argv,
        ]  # fmt: skip
        _run(cmd)

    def qmp(self) -> QMP:
        return QMP(self.plan.qmp_socket)

    def wait_ready(self, timeout: float = 30.0) -> str:
        import time

        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            if self.plan.qmp_socket.exists():
                try:
                    with self.qmp() as conn:
                        return conn.status()
                except Exception as exc:  # the socket exists before QEMU answers on it
                    last = str(exc)
            time.sleep(0.5)
        raise CloneError(f"{self.identity}: QMP never answered ({last or 'no socket'}) — see {self.plan.logfile}")

    def resume(self) -> None:
        with self.qmp() as conn:
            conn.resume()

    def pause(self) -> None:
        with self.qmp() as conn:
            conn.pause()

    def screenshot(self, out: Path | None = None) -> Path:
        target = Path(out) if out else self.plan.root / "frame.ppm"
        with self.qmp() as conn:
            return conn.screendump(target)

    def pid(self) -> int:
        try:
            return int(self.plan.pidfile.read_text().strip())
        except (OSError, ValueError):
            return 0

    def alive(self) -> bool:
        pid = self.pid()
        if not pid:
            return False
        try:
            exe = Path(f"/proc/{pid}/exe").resolve()
        except OSError:
            return False
        # Resolve through /proc/<pid>/exe, never a cmdline grep (rule 5).
        return "qemu-system" in exe.name or exe.name == Path(self.argv[0]).name

    # -- the network plane -----------------------------------------------

    def guest_ip(self) -> str:
        """The address this golden was captured with, read from the station's
        own `wi-tapnet.sh` rather than restated here.

        The tap script is where the address is ASSERTED — it scopes the guard
        chain to it — so a second copy in the broker is a second thing to get
        wrong. `WALKIN_GUEST_IP_<STATION>` overrides for a bring-up.
        """
        override = os.environ.get(f"WALKIN_GUEST_IP_{self.spec.station.upper()}", "")
        if override:
            return override
        if not self.spec.tapnet:
            return ""
        script = STATIONS_ROOT / self.spec.station / Path(self.spec.tapnet).name
        try:
            text = script.read_text()
        except OSError:
            return ""
        found = re.search(r"WI_TAP_GUEST_IP:-([0-9][0-9.]+)", text)
        return found.group(1) if found else ""

    def prime_network(self) -> bool:
        """Repair the clone's ARP cache before any visitor touches it.

        Not renumbering the walk-in plane has exactly one cost, measured by lane
        8 on the real bridge: a golden carries a WARM ARP CACHE from its
        retronet capture, so it believes `10.99.0.2` lives at CT 951's MAC —
        which does not exist on `vmbr-wi`. The clone's FIRST outbound flow is
        100% lost until it hears the real gateway's ARP, after which it works
        permanently. Left alone, every walk-in visitor's first page load dies.

        The repair is one ping FROM the gateway TO the clone. It happens here,
        while the member is still paused and unclaimed, so it costs the visitor
        nothing — the warm pool pays for it in advance.

        Returns whether the clone is primed. A pool member that could not be
        primed is still returned rather than discarded: a first dead page load
        is a worse experience than a working one, but it is a far better one
        than no machine at all, and the caller logs the difference.
        """
        if self.spec.netdev.type != "tap":
            return True  # nothing to prime: no bridge, no stale neighbour
        ip = self.guest_ip()
        if not ARP_PRIME_CMD or not ip:
            self.primed = False
            return False
        command = ARP_PRIME_CMD.format(ip=ip, tap=self.plan.tap, identity=self.identity)
        proc = _run(["bash", "-lc", command], check=False)
        self.primed = proc.returncode == 0
        return self.primed

    # -- teardown --------------------------------------------------------

    def kill(self) -> None:
        if self.plan.pidfile.exists():
            guard("kill-pidfile", str(self.plan.pidfile), check=False)
        if self.unit:
            _run(["systemctl", "stop", self.unit], check=False)
        if self.daemon_unit:
            _run(["systemctl", "stop", self.daemon_unit], check=False)
        self._tapnet("down")

    def discard(self) -> None:
        """Destroy the overlay by destroying the whole clone root.

        Guarded twice on purpose: `clone-guard assert-path`, and then a literal
        check that the path really is under the walk-in root. An `rm -rf` built
        from a variable is the shape of the incident clone-guard exists for, and
        this one runs unattended, on a timer, forever.
        """
        root = self.plan.root
        guard("assert-path", str(root))
        if naming.WALKIN_ROOT not in root.parents:
            raise CloneError(f"refusing to remove {root}: not under {naming.WALKIN_ROOT}")
        shutil.rmtree(root, ignore_errors=True)

    def destroy(self) -> None:
        try:
            self.kill()
            if self.spec.overlay_discard_on_kill:
                self.discard()
        finally:
            self.slot_claim.release()


def build(spec: StationSpec, index: int, repo_root: Path, preferred_slot: int | None = None) -> Clone:
    """Everything up to (not including) `spawn`, in the order that fails safest.

    The slot is claimed FIRST: a clone that cannot have a number should never
    have had a directory. The command line is derived (and its device set
    checked) BEFORE anything is created, so a bad override costs nothing.
    """
    ident = naming.identity(spec.station, index)
    slot_claim = claims.claim_slot(ident, preferred_slot)
    try:
        plan = derive.plan_for(spec, index, slot_claim.slot)
        base = derive.read_launcher(spec, repo_root)
        argv = derive.derive_argv(base, plan, spec)
        clone = Clone(plan=plan, spec=spec, argv=argv, slot_claim=slot_claim)
        clone.prepare()
        write_manifest(clone)
        return clone
    except Exception:
        slot_claim.release()
        raise


def station_env(clone: Clone) -> str:
    """The clone's `station.env`, derived from the station's own.

    Same derivation rule as the command line: read what the station actually
    runs with and re-point it, rather than writing a second copy that drifts.
    """
    source = STATIONS_ROOT / clone.spec.station / "station.env"
    if not source.exists():
        raise CloneError(f"{source} is missing — cannot derive a daemon config for {clone.identity}")
    station_dir = str(STATIONS_ROOT / clone.spec.station)
    out = []
    for line in source.read_text().splitlines():
        if not line.startswith("SH_"):
            continue
        key, _, value = line.partition("=")
        value = value.replace(station_dir, str(clone.plan.root))
        if key == "SH_STATION":
            value = clone.identity
        elif key == "SH_PORT":
            value = str(clone.plan.udp_port)
        out.append(f"{key}={value}")
    return "\n".join(out) + "\n"


def spawn_daemon(clone: Clone) -> None:
    """Start this clone's streamhost, on the SAME versioned binary the station
    runs — the golden, the binary and the device set are one combination."""
    binary = STREAMHOST_BIN.format(station=clone.spec.station)
    if not Path(binary).exists():
        raise CloneError(f"{binary} is missing — the station has no deployed daemon to clone")
    env_file = clone.plan.root / "station.env"
    env_file.write_text(station_env(clone))
    clone.daemon_unit = f"walkin-daemon@{clone.identity}.service"
    _run(
        [
            "systemd-run",
            f"--unit={clone.daemon_unit}",
            f"--slice={naming.SLICE}",
            "--collect",
            f"--property=EnvironmentFile={env_file}",
            f"--property=CPUQuota={CPU_QUOTA}",
            f"--property=MemoryMax={MEMORY_MAX}",
            f"--property=TasksMax={TASKS_MAX}",
            f"--property=StandardOutput=append:{clone.plan.root}/streamhost.log",
            f"--property=StandardError=append:{clone.plan.root}/streamhost.log",
            "--",
            binary,
        ]  # fmt: skip
    )


MANIFEST = "clone.json"


def write_manifest(clone: Clone) -> None:
    """A crumb in the clone root naming its slot, unit and pidfile.

    Without it an ORPHAN — a clone whose broker died — is un-reapable: the
    directory says which station it came from but not which slot claim to
    release, and a leaked slot is 1/49th of the pool gone until someone
    notices. Written at prepare time, before anything is running.
    """
    import json

    (clone.plan.root / MANIFEST).write_text(
        json.dumps(
            {
                "identity": clone.identity,
                "station": clone.spec.station,
                "index": clone.plan.index,
                "slot": clone.plan.slot,
                "udpPort": clone.plan.udp_port,
                "tap": clone.plan.tap,
                "unit": naming.unit_name(clone.identity),
                "createdAt": __import__("time").time(),
            },
            indent=1,
        )
        + "\n"
    )


def read_manifest(root: Path) -> dict:
    import json

    try:
        return json.loads((Path(root) / MANIFEST).read_text())
    except (OSError, ValueError):
        return {}


def reap_orphan(root: Path) -> dict:
    """Destroy a clone this process does not own. Returns what it removed.

    Every step is the guarded one, and every step tolerates the previous step
    having already happened: an orphan is by definition in an unknown state.
    """
    root = Path(root)
    info = read_manifest(root)
    guard("assert-path", str(root))
    pidfile = root / "qemu.pid"
    if pidfile.exists():
        guard("kill-pidfile", str(pidfile), check=False)
    for unit in (info.get("unit"), f"walkin-daemon@{info.get('identity', '')}.service"):
        if unit and "@." not in unit:
            _run(["systemctl", "stop", unit], check=False)
    if naming.WALKIN_ROOT in root.parents:
        shutil.rmtree(root, ignore_errors=True)
    slot = info.get("slot")
    if isinstance(slot, int):
        _run([claims.kh_claim_bin(), "release", claims.SLOT_CLASS, str(slot), "--force"], check=False)
        _run([claims.kh_claim_bin(), "release", claims.PORT_CLASS, str(naming.udp_port(slot)), "--force"], check=False)
    return info
