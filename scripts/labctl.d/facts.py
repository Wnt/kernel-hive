"""labctl.d/facts.py — the `labctl facts` field gatherers: repo state,
registry lookups, disk/backing/suite inspection and the builder probe.
Moved verbatim out of scripts/labctl (size-exclusions.json split, step 3).
Imports from labctl.d/common only — never from labctl.
"""

import json, os, re, subprocess

from common import TILES_DIR, is_x11_tile, read_env, svc_state

# ---- facts -----------------------------------------------------------------
#
# WHY THIS EXISTS. Every one of the fields below already existed somewhere — the
# capability matrix, station.env, signaling.json, the generated registry, the
# bridge-suite ledger, qemu-img, systemd — and so every agent session re-derived
# them by hand out of ~10 files (unit name, SPA-id vs SH_STATION, disk + backing,
# declared vs actual suite, builder + whether it bakes, exec channel). `facts`
# only JOINS what is already generated; it derives nothing that a generator
# already wrote down.
#
# DEGRADATION IS PER FIELD. The repo-declared half (registry id, builder, the
# suite ledger) is read from a repo checkout on the box. A missing input yields
# null for THAT field plus a line in `warnings` naming the path — never a failed
# call, because the live half (matrix, station.env, systemd, qemu-img) is the half
# that is always available.
#
# WHICH CHECKOUT, AND WHY IT REPORTS ITS OWN COMMIT. /data/kernel-hive is the
# canonical box checkout (scripts/dev/box-repo.sh — a real git clone that
# advances only on an explicit `box-repo.sh sync`, never on a timer, so it
# cannot swap build-guests/ out from under a 40-minute golden bake). Explicit
# sync means it can legitimately LAG main, so every answer carries the commit it
# was read at and a DIRTY flag: a stale answer that says it is stale is fine, one
# that looks authoritative is not. NOT /data/vms/streamhost/build — that is
# build-deploy.sh's rsync mirror of the Rust workspace, not a git tree, and it
# never received registry/bridge-suites.json at all.
REPO = os.environ.get("LABCTL_REPO", "/data/kernel-hive")
BRIDGE_DIR = os.environ.get("LABCTL_BRIDGE_DIR", "/data/vms/bridge")
DISK_SUFFIX = (".qcow2", ".chd", ".img", ".raw", ".vmdk")


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def repo_facts(warn):
    """Which commit the repo-declared fields were read at, and whether that tree
    is dirty. Same two questions `box-repo.sh status` asks — asked here directly
    with git rather than through that script, because box-repo.sh is a
    WORKSTATION tool that ssh's INTO the box and labctl is already on it."""
    facts = {"root": REPO, "commit": None, "branch": None, "dirty": None}
    if not os.path.isdir(REPO):
        warn("no repo checkout at %s — run scripts/dev/box-repo.sh init" % REPO)
        return facts

    def git(*args):
        try:
            r = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return r.stdout if r.returncode == 0 else None

    facts["commit"] = (git("rev-parse", "--short", "HEAD") or "").strip() or None
    facts["branch"] = (git("rev-parse", "--abbrev-ref", "HEAD") or "").strip() or None
    status = git("status", "--porcelain")
    if facts["commit"] is None or status is None:
        warn("%s is not a readable git checkout — repo-declared fields have no version" % REPO)
        return facts
    facts["dirty"] = len([line for line in status.splitlines() if line.strip()])
    if facts["dirty"]:
        warn(
            "%s is DIRTY (%d path(s)) — repo-declared fields below are NOT %s; "
            "check with scripts/dev/box-repo.sh status --strict" % (REPO, facts["dirty"], facts["commit"])
        )
    return facts


def registry_entry(sh_tile, warn):
    """The canonical registry entry for a tile, keyed by its stationDir (== SH_STATION).
    registry/stations/ is the generated source everything else in the repo is
    rendered from, so the SPA id and the builder come from there rather than
    from a second guess about naming."""
    root = os.path.join(REPO, "registry", "tiles")
    try:
        names = sorted(n for n in os.listdir(root) if n.endswith(".json"))
    except OSError:
        warn("no registry checkout at %s (set LABCTL_REPO) — id/builder unknown" % root)
        return {}
    for name in names:
        entry = load_json(os.path.join(root, name)) or {}
        if entry.get("stationDir") == sh_tile or entry.get("id") == sh_tile:
            return entry
    warn("no registry entry with stationDir=%s under %s" % (sh_tile, root))
    return {}


def shell_expand(value, env):
    """$VAR / ${VAR} / ${VAR:-default} against assignments already seen."""
    for _ in range(6):
        new = re.sub(
            r"\$\{([A-Za-z_]\w*)(?::-([^}]*))?\}|\$([A-Za-z_]\w*)",
            lambda m: env.get(m.group(1) or m.group(3), m.group(2) or ""),
            value,
        )
        if new == value:
            return value
        value = new
    return value


def live_argv(tile_dir):
    """The emulator's own command line, from whichever pidfile the tile keeps.
    Authoritative where it exists: it survives launcher edits and relaunches."""
    for pidfile in ("qemu.pid", "mame.pid"):
        try:
            with open(os.path.join(tile_dir, pidfile)) as f:
                pid = int(f.read().strip())
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                return f.read().decode("utf-8", "replace").split("\0")
        except (OSError, ValueError):
            continue
    return []


def launcher_boot_disk(text):
    """First writable disk image a stopped tile's launcher attaches.

    scripts/dev/bridge-suite-status.sh carries an equivalent parser, but its
    copy lives inside a heredoc that a WORKSTATION pipes to `python3 -` on the
    box, so there is nothing importable to share. This one stays deliberately
    small because it is only the fallback: a running tile answers from its own
    argv above."""
    env = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_]\w*)=(.*)$", line)
        if m:
            env[m.group(1)] = shell_expand(m.group(2).split("#")[0].strip().strip("\"'"), env)
    for m in re.finditer(r"-drive\s+([^\s\\]+)", text):
        opts = dict(p.split("=", 1) for p in m.group(1).split(",") if "=" in p)
        if opts.get("if") == "pflash" or opts.get("readonly") == "on":
            continue
        path = shell_expand(opts.get("file", "").strip("\"'"), env)
        if path.endswith(DISK_SUFFIX):
            return path
    return None


def launcher_text(tile_dir):
    for base in ("qemu-streamhost.sh", "x11-runtime.sh"):
        try:
            with open(os.path.join(tile_dir, base), errors="replace") as f:
                return f.read()
        except OSError:
            continue
    return ""


def boot_disk(tile_dir, text):
    for arg in live_argv(tile_dir):
        candidate = arg[5:].split(",")[0] if arg.startswith("file=") else arg
        if candidate.startswith("/") and candidate.endswith(DISK_SUFFIX):
            return candidate
    return launcher_boot_disk(text)


def disk_facts(path, warn):
    """path/format/size/backing/snapshots. `-U` skips the image lock, so this is
    safe to run against the disk of a RUNNING guest."""
    facts = {"path": path, "format": None, "virtual_size": None, "actual_size": None, "backing": None}
    snapshots = None
    if not path:
        warn("could not resolve a boot disk (no live argv, no launcher -drive)")
        return facts, snapshots
    if not os.path.exists(path):
        warn("boot disk %s does not exist" % path)
        return facts, snapshots
    facts["actual_size"] = os.path.getsize(path)
    if path.endswith(".chd"):
        facts["format"] = "chd"  # MAME's own container; qemu-img cannot read it
        warn("%s is a MAME .chd — qemu-img cannot read it, so size/backing/snapshots stay unknown" % path)
        return facts, snapshots
    try:
        r = subprocess.run(
            ["qemu-img", "info", "--output=json", "-U", path], capture_output=True, text=True, timeout=60
        )
        info = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        info, r = None, None
        warn("qemu-img info failed on %s: %s" % (path, exc))
    if info is None:
        if r is not None:
            warn("qemu-img info failed on %s: %s" % (path, (r.stderr or "").strip().splitlines()[:1]))
        return facts, snapshots
    facts["format"] = info.get("format")
    facts["virtual_size"] = info.get("virtual-size")
    facts["actual_size"] = info.get("actual-size", facts["actual_size"])
    facts["backing"] = info.get("full-backing-filename") or info.get("backing-filename")
    snapshots = [s.get("name") for s in info.get("snapshots") or []]
    return facts, snapshots


def suite_facts(sh_tile, backing, launcher, warn):
    """Declared suite (registry/bridge-suites.json) vs the suite the overlay's
    ACTUAL backing file implies — the same comparison
    scripts/dev/bridge-suite-status.sh makes, so drift is visible here too.
    Returns (suite-or-None, is_bridge): a tile is a bridge tile if the ledger
    claims it OR its disk/launcher reaches for the shared bridge base, so a
    FLATTENED overlay (c64, no backing file) is still recognised as one."""
    on_base = (backing or "").startswith(BRIDGE_DIR + "/") or (BRIDGE_DIR + "/bridge-base") in launcher
    ledger = load_json(os.path.join(REPO, "registry", "bridge-suites.json"))
    if ledger is None:
        if on_base:
            warn("no bridge ledger at %s/registry/bridge-suites.json — declared suite unknown" % REPO)
            return {"declared": None, "actual": None, "status": "UNKNOWN"}, True
        return None, False
    declared = (ledger.get("tiles") or {}).get(sh_tile)
    bases = {}
    for suite, spec in (ledger.get("suites") or {}).items():
        base = (spec or {}).get("base")
        if base:
            bases[base] = suite
            bases[os.path.realpath(base)] = suite
    if declared is None and not on_base:
        return None, False
    if not backing:
        actual, status = None, "DETACHED"
    else:
        actual = bases.get(backing) or bases.get(os.path.realpath(backing)) or "?"
        status = "OK" if actual == declared else "DRIFT"
    return {"declared": declared, "actual": actual, "status": status}, True


def builder_facts(entry, warn):
    """The golden builder for this tile, and whether IT bakes the golden or only
    prints the operator's bake step. The path comes from the registry's own
    build row — builder file names do not track tile ids (solaris-cde.sh,
    haiku-install.sh, android-x86.sh), so guessing tiles/<id>.sh is wrong."""
    facts = {"path": None, "resolved": None, "bakes": None, "bake_via": None, "ssh_port": None}
    rows = (entry.get("build") or {}).get("rows") or []
    script = ((rows[0].get("value") or {}) if rows else {}).get("script")
    if not script:
        if entry:
            warn("registry entry declares no build row — this tile has no golden builder script")
        return facts
    facts["path"] = os.path.join("scripts", "build-guests", script)
    text = None
    for candidate in (
        os.path.join(REPO, facts["path"]),
        os.path.join(REPO, "scripts", "build-guests", os.path.basename(script)),
    ):
        try:
            with open(candidate, errors="replace") as f:
                text, facts["resolved"] = f.read(), candidate
            break
        except OSError:
            continue
    if text is None:
        warn("builder %s not under %s — bakes/SSH_PORT unknown" % (facts["path"], REPO))
        return facts
    if facts["resolved"] != os.path.join(REPO, facts["path"]):
        warn("builder read from %s (older flat layout) — bakes/SSH_PORT may be stale" % facts["resolved"])
    # Comments and log/echo lines MENTION the bake without performing it
    # (indyr4400 prints the savevm the operator must run), so strip them first.
    code = "\n".join(line for line in text.splitlines() if not re.match(r"\s*(#|log\b|echo\b|printf\b|cat\b)", line))
    if "bridge-bake-golden" in code:
        facts["bakes"], facts["bake_via"] = False, "operator step: builder --bake -> lib/bridge-bake-golden"
    elif re.search(r"""savevm\s+["']?(golden|\$)""", code):
        facts["bakes"], facts["bake_via"] = True, "inline savevm golden"
    else:
        facts["bakes"], facts["bake_via"] = False, "no golden bake in the builder"
    m = re.search(r"^\s*(?:export\s+)?SSH_PORT=\"?(\d+)", code, re.M)
    facts["ssh_port"] = int(m.group(1)) if m else None
    return facts


def reset_facts(c, x11):
    """Mirrors cmd_reset's dispatch order, so this answers what reset would
    ACTUALLY do rather than what the golden_snapshot flag alone suggests."""
    mode = c.get("reset_mode")
    if mode == "relaunch" or (x11 and mode != "restart"):
        return True, "relaunch (x11 runtime; mamectl LOADST where a savestate exists)"
    if mode == "restart":
        return True, "cold service restart"
    if c.get("golden_snapshot") is False:
        return False, "no 'golden' snapshot — the tile boots cold"
    if c.get("golden_snapshot") is None:
        return None, "golden snapshot state unknown (matrix probe failed)"
    return True, "loadvm golden"


def tile_facts(sh_tile, c, warn):
    tile_dir = c.get("dir", os.path.join(TILES_DIR, sh_tile))
    env = read_env(os.path.join(tile_dir, "station.env"))
    signaling = load_json(os.path.join(tile_dir, "signaling.json")) or {}
    daemon_id = env.get("SH_STATION") or signaling.get("tile") or sh_tile
    if daemon_id != sh_tile:
        warn("station.env SH_STATION=%s does not match the matrix key %s" % (daemon_id, sh_tile))
    repo = repo_facts(warn)
    entry = registry_entry(sh_tile, warn)
    # One tile, one name: the registry id IS the stationDir IS SH_STATION, and
    # stations-registry.py fails the build if an entry breaks that. This used to be
    # a passive `identity_diverges` field on every tile's facts, permanently true
    # for aros/amigaos and solaris/solariscde (both renamed 2026-08-10). A flag
    # that is normally set is a flag nobody reads, so it is a WARNING now — it
    # can only fire on a live tile whose station.env drifted from its registry entry.
    if entry.get("id") and entry["id"] != daemon_id:
        warn(
            "registry id %s but the daemon runs as %s — the two must match; "
            "reconcile station.env/the tile dir with registry/stations/%s.json" % (entry["id"], daemon_id, entry["id"])
        )
    launcher = launcher_text(tile_dir)
    disk, snapshots = disk_facts(boot_disk(tile_dir, launcher), warn)
    suite, is_bridge = suite_facts(sh_tile, disk["backing"], launcher, warn)
    x11 = is_x11_tile(c)
    if is_bridge:
        kind, evidence = "bridge", "emulator inside a captured Debian kiosk on the shared bridge base"
    elif x11:
        kind, evidence = (
            "x11",
            "SH_STATION_RUNTIME=x11 / SH_CAPTURE=%s — no QEMU, no QMP" % (env.get("SH_CAPTURE") or "x11"),
        )
    else:
        kind, evidence = "qemu", "direct QEMU with a QMP monitor"
    resettable, reset_how = reset_facts(c, x11)
    if snapshots is not None and c.get("golden_snapshot") is not None:
        if ("golden" in snapshots) != bool(c.get("golden_snapshot")):
            warn(
                "matrix golden_snapshot=%s but the disk's snapshots are %s — run 'labctl gen'"
                % (c.get("golden_snapshot"), snapshots or "none")
            )
    return {
        "id": entry.get("id") or sh_tile,
        "sh_tile": daemon_id,
        "dir": tile_dir,
        "unit": {"name": "streamhost@%s.service" % daemon_id, "state": svc_state(daemon_id)},
        "kind": kind,
        "kind_evidence": evidence,
        "suite": suite,
        "disk": disk,
        "snapshots": snapshots,
        "golden_resettable": resettable,
        "reset": {"mode": c.get("reset_mode"), "action": reset_how},
        "builder": builder_facts(entry, warn),
        "ssh_port": c.get("ssh_port"),
        "exec": {
            "kind": c.get("exec_kind"),
            "port": c.get("exec_port"),
            "user": c.get("exec_user"),
            "key": c.get("exec_key"),
        },
        "repo": repo,
    }


def human_size(n):
    if not n:
        return "-"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return "-"


TRISTATE = {True: "yes", False: "NO", None: "?"}
RESETTABLE = {True: "RESETTABLE", False: "NOT resettable", None: "unknown"}


def facts_rows(f):
    d, ex, s, b = f["disk"], f["exec"], f["suite"], f["builder"]
    ident = f["id"]
    if f["snapshots"] is None:
        snaps = "unknown"
    else:
        snaps = ", ".join(f["snapshots"]) or "none"
    if not ex["kind"]:
        execline = "none — 'labctl sh' is blind; see the tile's notes for alternatives"
    else:
        execline = "%s %s%s" % (
            ex["kind"],
            "port %s" % ex["port"] if ex["port"] else "(no port)",
            " user %s" % ex["user"] if ex["user"] else "",
        )
    rows = [
        ("tile", ident),
        ("unit", "%s  [%s]" % (f["unit"]["name"], f["unit"]["state"])),
        ("kind", "%s — %s" % (f["kind"], f["kind_evidence"])),
        ("dir", f["dir"]),
        (
            "disk",
            "%s  %s  %s virtual / %s on disk"
            % (d["path"] or "?", d["format"] or "?", human_size(d["virtual_size"]), human_size(d["actual_size"])),
        ),
        ("backing", d["backing"] or "none (standalone image)"),
        ("snapshots", snaps),
        ("reset", "%s — %s" % (RESETTABLE[f["golden_resettable"]], f["reset"]["action"])),
        ("exec", execline),
        ("ssh port", str(f["ssh_port"] or "-")),
        (
            "suite",
            "not a bridge tile"
            if s is None
            else "declared %s / actual %s  %s" % (s["declared"] or "unknown", s["actual"] or "-", s["status"]),
        ),
        (
            "builder",
            "%s  bakes=%s%s%s"
            % (
                b["path"] or "unknown",
                TRISTATE[b["bakes"]],
                " (%s)" % b["bake_via"] if b["bake_via"] else "",
                "  SSH_PORT=%s" % b["ssh_port"] if b["ssh_port"] else "",
            ),
        ),
    ]
    r = f["repo"]
    rows.append(
        (
            "repo",
            "%s @ %s%s"
            % (
                r["root"],
                r["commit"] or "unknown",
                "" if r["dirty"] == 0 else ("  DIRTY (%d)" % r["dirty"] if r["dirty"] else "  (no git version)"),
            ),
        )
    )
    return rows + [("warning", w) for w in f["warnings"]]


def print_facts(f):
    for label, value in facts_rows(f):
        print("%-11s %s" % (label + ":", value))
