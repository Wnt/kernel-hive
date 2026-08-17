"""labctl.d/health.py — read-only fleet health: journal/RSS-guard reading,
per-tile QMP query-status, and `labctl health`'s table/JSON rendering.
Moved verbatim out of scripts/labctl (size-exclusions.json split, step 3b).
Imports from labctl.d/common only — never from labctl.
"""

import json, os, re, subprocess, sys, time

from common import (
    QmpConn,
    TILES_DIR,
    die,
    is_x11_tile,
    load_matrix,
    pause_pidfile,
    proc_stopped,
    read_env,
    svc_state,
    tile_conf,
)


def qmp_command(path, command, arguments=None, timeout=3):
    """Execute one QMP command on a fresh connection. Health uses only the
    read-only query-status command; the generic helper keeps parsing structured
    QMP instead of scraping HMP prose."""
    conn = QmpConn(path, timeout=timeout)
    try:
        return conn.execute(command, arguments)
    finally:
        conn.close()


def journal_health(name):
    """Read the daemon's existing systemd journal surface for its current
    invocation. SESSION_ACCEPTED/SESSION_ENDED are paired by the daemon. The
    most recent capture/encoder activity record is the available last-damage
    evidence (the daemon intentionally does not log every damage rectangle)."""
    state = {
        "encoder_up": False,
        "sessions": 0,
        "last_damage_us": None,
        "guard_base_mb": None,
        "guard_mb": None,
        "journal_error": None,
    }
    try:
        r = subprocess.run(
            ["journalctl", "-u", "streamhost@%s.service" % name, "-b", "--no-pager", "-o", "json"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        state["journal_error"] = str(exc)
        return state
    if r.returncode != 0:
        state["journal_error"] = r.stderr.strip() or "journalctl failed"
        return state
    for raw in r.stdout.splitlines():
        try:
            row = json.loads(raw)
            message = str(row.get("MESSAGE", ""))
            stamp = int(row.get("__REALTIME_TIMESTAMP", 0)) or None
        except (ValueError, TypeError):
            continue
        if message.startswith("[streamhost] tile="):
            state.update(encoder_up=False, sessions=0, last_damage_us=None, guard_base_mb=None, guard_mb=None)
        if message == "[streamhost] encoder up":
            state["encoder_up"] = True
            if stamp:
                state["last_damage_us"] = stamp
        if "SESSION_ACCEPTED" in message or "WebRTC session lease started" in message:
            state["sessions"] += 1
        elif "SESSION_ENDED" in message or "WebRTC session lease ended" in message:
            state["sessions"] = max(0, state["sessions"] - 1)
        if (
            message.startswith("[encode] enc latency")
            or message.startswith("[capture] Scanout")
            or message.startswith("[capture] v1 Scanout")
        ) and stamp:
            state["last_damage_us"] = stamp
        match = re.search(r"rss-guard ON: qemu pid=\d+ anon=(\d+) MB, trip at \+(\d+) MB", message)
        if match:
            state["guard_base_mb"] = int(match.group(1))
            state["guard_mb"] = int(match.group(2))
        match = re.search(r"low-water re-?baselined at (\d+) MB", message)
        if match:
            state["guard_base_mb"] = int(match.group(1))
    return state


def proc_rss_mb(tile_dir):
    try:
        with open(os.path.join(tile_dir, "qemu.pid")) as f:
            pid = int(f.read().strip())
        values = {}
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith(("RssAnon:", "VmRSS:")):
                    key, raw = line.split(":", 1)
                    values[key] = int(raw.strip().split()[0]) / 1024.0
        return pid, values.get("RssAnon"), values.get("VmRSS")
    except (OSError, ValueError, IndexError):
        return None, None, None


def age_text(seconds):
    if seconds is None:
        return "?"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % divmod(seconds, 60)
    hours, rest = divmod(seconds, 3600)
    return "%dh%02dm" % (hours, rest // 60)


def tile_health(name, c):
    service = svc_state(name)
    log = journal_health(name)
    qemu = "unknown"
    qmp_error = None
    x11 = is_x11_tile(c)
    if x11:
        # No QEMU/QMP: query-status is not applicable. Health is service+encoder.
        # Idle auto-pause still applies though — it SIGSTOPs the emulator here —
        # and a frozen exhibit reads as a dead one to anyone who cannot see the
        # difference, so report it. Read-only: this must never thaw anything.
        qemu = "x11"
        pidfile = pause_pidfile(c, name)
        if pidfile and proc_stopped(pidfile)[1]:
            qemu = "x11 (paused)"
    else:
        try:
            answer = qmp_command(c["qmp"], "query-status")
            qemu = answer.get("status", "unknown") if isinstance(answer, dict) else "unknown"
        except Exception as exc:
            qmp_error = str(exc)
    env = read_env(os.path.join(c.get("dir", os.path.join(TILES_DIR, name)), "station.env"))
    guard_mb = log["guard_mb"]
    if guard_mb is None:
        try:
            guard_mb = int(env.get("SH_QEMU_RSS_GUARD_MB", "2048"))
        except ValueError:
            guard_mb = 2048
    pid, anon_mb, rss_mb = proc_rss_mb(c.get("dir", os.path.join(TILES_DIR, name)))
    base_mb = log["guard_base_mb"]
    trip_mb = (base_mb + guard_mb) if base_mb is not None and guard_mb else None
    headroom_mb = (trip_mb - anon_mb) if trip_mb is not None and anon_mb is not None else None
    stamp = log["last_damage_us"]
    damage_age = (time.time() - stamp / 1_000_000.0) if stamp else None
    encoder = bool(service == "active" and log["encoder_up"])
    healthy = bool(service == "active" and encoder and qemu != "unknown")
    if headroom_mb is not None and headroom_mb < 0:
        healthy = False
    return {
        "tile": name,
        "service": service,
        "sessions": log["sessions"],
        "encoder_up": encoder,
        "last_damage_age_s": (round(damage_age, 1) if damage_age is not None else None),
        "qemu_status": qemu,
        "paused": qemu in ("paused", "x11 (paused)"),
        "idle": log["sessions"] == 0,
        "qemu_pid": pid,
        "qemu_rss_anon_mb": (round(anon_mb, 1) if anon_mb is not None else None),
        "qemu_rss_mb": (round(rss_mb, 1) if rss_mb is not None else None),
        "rss_guard_base_mb": base_mb,
        "rss_guard_growth_mb": guard_mb,
        "rss_guard_trip_mb": trip_mb,
        "rss_guard_headroom_mb": (round(headroom_mb, 1) if headroom_mb is not None else None),
        "healthy": healthy,
        "qmp_error": qmp_error,
        "journal_error": log["journal_error"],
    }


def rss_summary(h):
    current = h["qemu_rss_anon_mb"]
    growth = h["rss_guard_growth_mb"]
    trip = h["rss_guard_trip_mb"]
    if current is None:
        return "?"
    if not growth:
        return "%.0f/off" % current
    if trip is None:
        return "%.0f/+%s" % (current, growth)
    return "%.0f/%.0f" % (current, trip)


def cmd_health(argv):
    """Read-only fleet health. It never calls ensure_running and all QMP
    interaction is query-status."""
    json_mode = False
    names = []
    for arg in argv:
        if arg == "--json":
            json_mode = True
        elif arg.startswith("-"):
            die("usage: labctl health [<tile>] [--json]")
        else:
            names.append(arg)
    if len(names) > 1:
        die("usage: labctl health [<tile>] [--json]")
    matrix = load_matrix().get("tiles", {})
    if names:
        name = names[0]
        if name not in matrix:
            tile_conf(name)  # emits the canonical unknown-tile error
        rows = [tile_health(name, matrix[name])]
    else:
        rows = [tile_health(name, matrix[name]) for name in sorted(matrix)]
    if json_mode:
        print(json.dumps(rows[0] if names else {"tiles": rows}, sort_keys=True))
    elif names:
        h = rows[0]
        print("Tile:              %s" % h["tile"])
        print("Service:           %s" % h["service"])
        print("Client sessions:   %s" % h["sessions"])
        print("Idle:              %s" % ("yes (zero sessions)" if h["idle"] else "no"))
        print("Encoder:           %s" % ("up" if h["encoder_up"] else "DOWN/unknown"))
        print("Last damage*:      %s ago" % age_text(h["last_damage_age_s"]))
        print("QEMU state:        %s%s" % (h["qemu_status"], " (idle-paused)" if h["paused"] and h["idle"] else ""))
        print("QEMU RSS anon:     %s MiB" % (h["qemu_rss_anon_mb"] if h["qemu_rss_anon_mb"] is not None else "?"))
        if h["rss_guard_growth_mb"] == 0:
            print("RSS guard:         disabled (SH_QEMU_RSS_GUARD_MB=0)")
        else:
            base = h["rss_guard_base_mb"]
            trip = h["rss_guard_trip_mb"]
            headroom = h["rss_guard_headroom_mb"]
            if base is None:
                print("RSS guard:         +%s MiB growth (baseline unavailable)" % h["rss_guard_growth_mb"])
            else:
                print(
                    "RSS guard:         base %s + %s = %s MiB trip; %s MiB headroom"
                    % (base, h["rss_guard_growth_mb"], trip, headroom)
                )
        print("Overall:           %s" % ("HEALTHY" if h["healthy"] else "UNHEALTHY"))
        print("* age of the daemon's latest capture/encoder activity record; individual")
        print("  damage rectangles are intentionally not journaled")
        if h["qmp_error"]:
            print("QMP error:          %s" % h["qmp_error"])
        if h["journal_error"]:
            print("Journal error:      %s" % h["journal_error"])
    else:
        hdr = "%-13s %-9s %4s %-7s %-9s %-14s %-10s %s" % (
            "TILE",
            "SERVICE",
            "SESS",
            "ENCODER",
            "DAMAGE*",
            "QEMU",
            "RSS/TRIP",
            "HEALTH",
        )
        print(hdr)
        print("-" * len(hdr))
        for h in rows:
            qemu = h["qemu_status"]
            if h["idle"]:
                qemu = "idle/%s" % qemu
            else:
                qemu = "active/%s" % qemu
            print(
                "%-13s %-9s %4s %-7s %-9s %-14s %-10s %s"
                % (
                    h["tile"],
                    h["service"],
                    h["sessions"],
                    "up" if h["encoder_up"] else "DOWN",
                    age_text(h["last_damage_age_s"]),
                    qemu,
                    rss_summary(h),
                    "ok" if h["healthy"] else "FAIL",
                )
            )
        print("* latest daemon capture/encoder activity; RSS/TRIP is QEMU RssAnon MiB")
    if any(not row["healthy"] for row in rows):
        sys.exit(1)
