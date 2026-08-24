"""labctl.d/common.py — shared paths, tile-config helpers and QMP/HMP plumbing
used by more than one labctl.d module (and by labctl's own dispatch code).

This module must NEVER import from labctl (labctl imports from labctl.d, not
the other way around) — see scripts/labctl's sys.path shim and the size
ledger entry this split satisfies (size-exclusions.json, scripts/labctl).
"""

import json, os, re, signal, socket, subprocess, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))

from guest_wake import GuestPaused, WakeLease, hold_lease  # noqa: E402,F401

TILES_DIR = os.environ.get("LABCTL_TILES_DIR", "/data/vms/streamhost/stations")
TILES_JSON = os.environ.get("LABCTL_TILES_JSON", "/data/vms/streamhost/stations.json")
CDRV = os.environ.get("LABCTL_CDRV", "/root/cdrv.py")
QMP_HMP = os.environ.get("LABCTL_QMP_HMP", "/root/qmp_hmp.py")
SHMSHOT = os.environ.get("LABCTL_SHMSHOT", "/root/shmshot.py")


def die(msg, code=2):
    sys.stderr.write("labctl: " + msg + "\n")
    sys.exit(code)


def load_matrix():
    try:
        with open(TILES_JSON) as f:
            return json.load(f)
    except OSError:
        die("cannot read %s — run 'labctl gen' first" % TILES_JSON)


def tile_conf(name):
    m = load_matrix()
    tiles = m.get("tiles", {})
    if name not in tiles:
        die("unknown tile '%s'. known: %s" % (name, ", ".join(sorted(tiles))))
    return tiles[name]


def read_env(path):
    """Read simple KEY=VALUE settings without sourcing a station.env file."""
    values = {}
    try:
        with open(path, errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                    values[key] = value.strip().strip("\"'")
    except OSError:
        pass
    return values


def is_x11_tile(c):
    """x11-capture runtime tiles (SH_CAPTURE=x11, IRIX/issue #20) have no
    QEMU/QMP: screendump/type/key/reset go through the X display + Lua cmd file,
    not the QMP monitor. Keyed on the matrix console/qmp fields."""
    return c.get("console") == "x11" or not c.get("qmp")


def x11_display(c, name):
    """The X display an x11 tile serves + streamhost captures (SH_X11_DISPLAY)."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    env = read_env(os.path.join(tile_dir, "station.env"))
    return env.get("SH_X11_DISPLAY", ":40")


def is_shm_tile(c, name):
    """Tiles whose emulator publishes frames into a mapping (SH_CAPTURE=shm).

    These run `-video none`: no window, no X server, no QMP. They are a SUBSET
    of is_x11_tile() — input still goes through the Lua cmd file — so this must
    be tested FIRST wherever the two dispatch differently."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    return read_env(os.path.join(tile_dir, "station.env")).get("SH_CAPTURE") == "shm"


def shm_path(c, name):
    """The framebuffer file a shm tile's emulator publishes into."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    env = read_env(os.path.join(tile_dir, "station.env"))
    return env.get("SH_SHM_PATH", os.path.join(tile_dir, "fb.shm"))


def pause_pidfile(c, name):
    """The process streamhost's idle auto-pause freezes on a NON-QEMU tile
    (SH_IDLE_PAUSE_PIDFILE in station.env), or None. QEMU tiles have no such file:
    they freeze their vCPUs over the QMP monitor instead."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    return read_env(os.path.join(tile_dir, "station.env")).get("SH_IDLE_PAUSE_PIDFILE")


def proc_stopped(pidfile):
    """(pid, is_stopped) for a pidfile, or (None, False) when there is no
    usable pid. The state comes from /proc, so it is the kernel's answer and
    not a flag some other process claims to have set."""
    try:
        with open(pidfile) as fh:
            pid = int(fh.read().strip())
        with open("/proc/%d/stat" % pid) as fh:
            stat = fh.read()
    except (OSError, ValueError):
        return None, False
    # The state letter is the first field AFTER the ')' closing comm, which may
    # itself contain spaces and parens. T = stopped, t = trace-stopped.
    try:
        state = stat.rsplit(")", 1)[1].split()[0]
    except IndexError:
        return pid, False
    return pid, state in ("T", "t")


def cdrv(qmp, *args):
    return subprocess.run(["python3", CDRV, qmp, *args], capture_output=True, text=True, timeout=30)


def hmp(qmp, cmdline, timeout=200):
    return subprocess.run(["python3", QMP_HMP, qmp, cmdline], capture_output=True, text=True, timeout=timeout)


def ensure_running(c, name, verify=True):
    """Resume a guest streamhost idle-auto-paused, and PROVE it came back.

    A paused guest is not a slow guest: it accepts every key, every pointer
    event and every monitor command and reacts to none of them, while QMP
    answers OK. Driving one produces a screendump of a screen that never
    changed, which reads as a wedged guest and repeatedly sent 2026-08-23
    investigations after the emulator. So this no longer fires `cont` and hopes
    — it resumes and then CHECKS, and a guest that does not come back is a hard
    error naming the pause, not a silent fall-through.

    Two mechanisms, because the stations have two: a QEMU station is stopped
    over the QMP monitor (thaw with `cont`, verify with `query-status`); an
    x11/shm emulator station has no monitor at all and is SIGSTOPped by pidfile
    (thaw with SIGCONT, verify by re-reading /proc). Both arms MUST be covered:
    a frozen emulator never processes an injected verb and never answers its
    mamectl socket.

    It also TAKES THE WAKE LEASE (scripts/lib/guest_wake.py), which is what
    stops the daemon's 60 s pause re-assert landing in the middle of the caller's
    sequence. The lease expires on its own, so idle auto-pause is unchanged for
    everyone else. Long-running callers should hold a `guest_wake.WakeLease` for
    their whole run rather than relying on this single touch.

    `verify=False` is for read-only callers that merely prefer a running guest
    and have their own error path; it restores the old best-effort behaviour.
    """
    hold_lease(name)
    try:
        if c.get("qmp"):
            _wake_qemu(c, name, verify)
            return
        pidfile = pause_pidfile(c, name)
        if not pidfile:
            return
        _wake_emulator(pidfile, name, verify)
    except GuestPaused:
        raise
    except Exception as exc:
        if verify:
            die("cannot resume %s: %s" % (name, exc))


def _wake_qemu(c, name, verify, timeout=8.0):
    """`cont` a QEMU station, then poll query-status until it agrees."""
    hmp(c["qmp"], "cont", timeout=10)
    if not verify:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            conn = QmpConn(c["qmp"])
        except (OSError, RuntimeError):
            # Another transient QMP client holds the socket; that is exactly the
            # case the old code swallowed. Retry inside the deadline.
            time.sleep(0.2)
            continue
        try:
            status = conn.execute("query-status")
        except (OSError, RuntimeError):
            status = None
        finally:
            conn.close()
        if isinstance(status, dict) and status.get("running"):
            return
        time.sleep(0.2)
    raise GuestPaused(
        "%s is idle-auto-paused and did not resume within %.0fs of `cont` — "
        "NOTHING you send will reach it and nothing will say so. The guest is "
        "not wedged; its vCPUs are stopped. See docs/lab/INPUT-DEBUGGING.md." % (name, timeout)
    )


def _wake_emulator(pidfile, name, verify, timeout=5.0):
    """SIGCONT a non-QEMU station's emulator, then re-read /proc to confirm."""
    pid, stopped = proc_stopped(pidfile)
    if pid and stopped:
        os.kill(pid, signal.SIGCONT)
    if not verify:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pid, stopped = proc_stopped(pidfile)
        if pid is None or not stopped:
            return
        time.sleep(0.1)
    raise GuestPaused(
        "%s's emulator (pid from %s) is still SIGSTOPped after SIGCONT — every "
        "verb you send it is discarded and its control socket will not answer. "
        "See docs/lab/INPUT-DEBUGGING.md." % (name, pidfile)
    )


def svc_state(name):
    r = subprocess.run(["systemctl", "is-active", "streamhost@%s.service" % name], capture_output=True, text=True)
    return r.stdout.strip() or "unknown"


class QmpConn:
    """One negotiated QMP connection. Kept open so a paced key sequence pays
    the connect + capabilities handshake once instead of once per keystroke —
    the whole point of the pacing is that the delay between keys is the value
    we chose, not whatever the socket setup happened to cost."""

    def __init__(self, path, timeout=3):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.stream = self.sock.makefile("rwb", buffering=0)
        self._read(want_greeting=True)
        self.execute("qmp_capabilities")

    def _read(self, want_greeting=False):
        for _ in range(64):
            raw = self.stream.readline()
            if not raw:
                raise RuntimeError("QMP EOF")
            msg = json.loads(raw.decode("utf-8", "replace"))
            if want_greeting and "QMP" in msg:
                return msg
            if "event" in msg and "return" not in msg and "error" not in msg:
                continue
            if "error" in msg:
                raise RuntimeError("QMP error: %s" % msg["error"].get("desc", msg["error"]))
            if "return" in msg:
                return msg["return"]
        raise RuntimeError("QMP reply limit exceeded")

    def execute(self, command, arguments=None):
        request = {"execute": command}
        if arguments:
            request["arguments"] = arguments
        self.stream.write((json.dumps(request, separators=(",", ":")) + "\n").encode())
        return self._read()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
