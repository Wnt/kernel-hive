#!/usr/bin/env bash
# =============================================================================
# fleet-rollout-probe.sh — the READ-ONLY box side of scripts/dev/fleet_rollout.py.
#
# Shipped and run by `scripts/dev/labrun`, so it lives on labhost only for the
# length of one call. It never starts, stops, thaws or writes anything: every
# QMP call is `query-status`, every capture passes resume=False, and the journal
# is read with a bounded tail.
#
#   fleet-rollout-probe.sh state              one JSON doc for the WHOLE fleet:
#                                             unit states, guest run/pause state,
#                                             session activity, kh-claim registry
#   fleet-rollout-probe.sh state <tile>...    the same for named tiles only, plus
#                                             the daemon-readiness fact (its own
#                                             `LISTENING udp/ ... tile=<t>` line
#                                             from the CURRENT MainPID)
#   fleet-rollout-probe.sh frames <tile>...   one JSON doc: a real framebuffer
#                                             grab per tile with its non-black
#                                             coverage
#
# WHY A PROBE FILE AND NOT `labctl health`. `labctl health --json` is the
# obvious answer and it is unusable here: it reads each tile's WHOLE boot
# journal (`journalctl -b -o json`, ~21k lines, ~4 s per station), so a
# fleet-wide preflight takes over ten minutes. Measured 2026-08-31. The same
# facts come out of `query-status` (0.16 s for all 49 QMP tiles) plus a bounded
# 400-line journal tail (0.065 s per station), which is what this does.
#
# WHY resume=False. `labctl shot` calls the capture dispatcher with resume=True,
# which issues `cont` on a paused guest. A rollout must not thaw a guest that
# somebody parked, and a frozen guest's last frame IS its current screen, so the
# gate reads the framebuffer without touching the run state.
# =============================================================================
set -euo pipefail

MODE="${1:-}"
shift || true

case "$MODE" in
  state) ;;
  frames)
    [ "$#" -gt 0 ] || {
      echo "fleet-rollout-probe: frames needs at least one tile" >&2
      exit 2
    }
    ;;
  *)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac

exec python3 - "$MODE" "$@" <<'PY'
import json, os, subprocess, sys

sys.path.insert(0, "/usr/local/lib/labctl")
from common import is_x11_tile, load_matrix, pause_pidfile, proc_stopped  # noqa: E402
from capture import capture_png_any  # noqa: E402

# Luminance at or below this counts as black. Same convention as
# scripts/dev/verify-tile.sh's ppm_stats, which uses an R+G+B sum of 30.
BLACK_LEVEL = 10


def unit_states():
    """Every streamhost@ unit systemd knows about, loaded or not."""
    out = {}
    argv = ["systemctl", "list-units", "--all", "--plain", "--no-legend", "streamhost@*.service"]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[0].startswith("streamhost@"):
            continue
        name = parts[0][len("streamhost@") : -len(".service")]
        if "@" in name:  # walk-in clone identities are not registry stations
            continue
        out[name] = {"load": parts[1], "active": parts[2], "sub": parts[3]}
    return out


def guest_state(name, conf):
    """run/pause state without a journal read and without resuming anything."""
    if is_x11_tile(conf):
        pidfile = pause_pidfile(conf, name)
        if pidfile and proc_stopped(pidfile)[1]:
            return "x11 (paused)", True
        return "x11", False
    try:
        from health import qmp_command

        answer = qmp_command(conf["qmp"], "query-status", timeout=3)
        status = answer.get("status", "unknown") if isinstance(answer, dict) else "unknown"
    except Exception:
        return "unreachable", False
    return status, status == "paused"


def session_activity(name):
    """Is a visitor connected RIGHT NOW, from a bounded journal tail.

    The daemon pairs SESSION_ACCEPTED with SESSION_ENDED, so the LAST of the two
    in the window answers the question without replaying the whole invocation.
    No session line in the window means nobody has connected recently; that is
    reported as idle, and 'unknown' is never guessed as busy.
    """
    argv = ["journalctl", "-u", "streamhost@%s.service" % name, "-n", "400", "--no-pager", "-o", "cat"]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    last = None
    for line in r.stdout.splitlines():
        if "SESSION_ACCEPTED" in line or "WebRTC session lease started" in line:
            last = True
        elif "SESSION_ENDED" in line or "WebRTC session lease ended" in line:
            last = False
        elif line.startswith("[streamhost] tile="):
            last = False  # a fresh invocation has no inherited sessions
    return bool(last)


def readiness(name):
    """The daemon's own LISTENING line, from THIS invocation's MainPID.

    `systemctl is-active` goes green the moment the process execs, long before
    it has re-opened its UDP socket, so a wave could "succeed" against a station
    that never came back. Scoping the journal read to the current MainPID is
    what makes a stale line from the previous run unable to satisfy the gate —
    the same invariant scripts/lib/streamhost-artifacts.sh states for
    build-deploy.sh, applied here without shelling out to it.
    """
    try:
        r = subprocess.run(
            ["systemctl", "show", "-p", "MainPID", "--value", "streamhost@%s.service" % name],
            capture_output=True,
            text=True,
            timeout=30,
        )
        pid = int((r.stdout or "0").strip() or 0)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None, False
    if pid <= 0:
        return None, False
    try:
        r = subprocess.run(
            ["journalctl", "_PID=%d" % pid, "-n", "500", "--no-pager", "-o", "cat"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return pid, False
    needle = " tile=%s " % name
    for line in r.stdout.splitlines():
        if "LISTENING udp/" in line and needle in line:
            return pid, True
    return pid, False


def claims():
    try:
        r = subprocess.run(["kh-claim", "ls", "--json"], capture_output=True, text=True, timeout=60)
        return json.loads(r.stdout or "[]")
    except Exception:
        return []


def cmd_state(only):
    matrix = load_matrix().get("tiles", {})
    units = unit_states()
    tiles = {}
    names = only or sorted(set(matrix) | set(units))
    for name in names:
        conf = matrix.get(name)
        unit = units.get(name, {})
        row = {
            "unit_load": unit.get("load"),
            "unit_active": unit.get("active"),
            "unit_sub": unit.get("sub"),
            "guest": None,
            "paused": None,
            "busy": None,
            "main_pid": None,
            "listening": None,
        }
        if conf is not None and unit.get("active") == "active":
            row["guest"], row["paused"] = guest_state(name, conf)
            row["busy"] = session_activity(name)
            if only:  # readiness costs a journal read per tile; only when asked
                row["main_pid"], row["listening"] = readiness(name)
        tiles[name] = row
    json.dump({"tiles": tiles, "claims": claims()}, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


def frame(name, conf):
    row = {"tile": name, "ok": False, "error": None, "width": None, "height": None, "nonblack_pct": None}
    png = "/tmp/.kh-fleet-roll-%s-%d.png" % (name, os.getpid())
    try:
        capture_png_any(name, conf, png, resume=False)
        from PIL import Image

        with Image.open(png) as image:
            row["width"], row["height"] = image.size
            hist = image.convert("L").histogram()
        total = sum(hist) or 1
        row["nonblack_pct"] = round(100.0 * (total - sum(hist[: BLACK_LEVEL + 1])) / total, 3)
        row["ok"] = True
    except Exception as exc:  # a wedged guest fails here, which is the point
        row["error"] = str(exc)[:300]
    finally:
        try:
            os.remove(png)
        except OSError:
            pass
    return row


def cmd_frames(names):
    matrix = load_matrix().get("tiles", {})
    rows = []
    for name in names:
        conf = matrix.get(name)
        if conf is None:
            rows.append({"tile": name, "ok": False, "error": "not in the labctl tile matrix"})
            continue
        rows.append(frame(name, conf))
    json.dump(rows, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


if sys.argv[1] == "state":
    cmd_state(sys.argv[2:])
else:
    cmd_frames(sys.argv[2:])
PY
