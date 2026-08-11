#!/usr/bin/env bash
# =============================================================================
# bridge-suite-status.sh — does the bookworm -> trixie ledger match labhost?
#
# registry/bridge-suites.json declares INTENT: which Debian suite each bridge
# station's overlay is built on. labhost holds REALITY: the backing file actually
# recorded in that station's live disk. A gradual migration fails silently exactly
# when those two drift apart — a station flipped to "trixie" in the ledger whose
# overlay still backs onto the frozen bookworm base, or an overlay rebased on
# labhost that nobody declared. This script makes that impossible to miss.
#
# For every station in the ledger it reports:
#   OK        declared suite == the suite implied by the real backing file
#   DRIFT     they disagree (both values printed) — exit 1
#   DETACHED  the disk has NO backing file (flattened standalone image). Not
#             drift, but visible: migrating it means a full REBUILD, not a
#             rebase. Fails only under --strict.
#   MISSING   no launcher, or no disk resolvable from it — exit 1
#
# labhost's side is ONE ssh round trip: a python program is piped to `python3 -`
# on labhost, which parses each station launcher for its boot disk (they are not
# all tiles/<tile>/overlay.qcow2 — openvms names its own) and runs `qemu-img
# info --output=json` on it. Strictly read-only: nothing is started, stopped
# or written.
#
# With no `ssh lab` (public clone, offline laptop, CI) it exits 3 with a clear
# message rather than inventing drift — the probe-gate idiom of
# scripts/dev/verify-tile.sh and .claude/hooks/pre-push-gate.sh.
#
# usage: bridge-suite-status.sh [--tile <id>] [--json] [--strict]
# exit:  0 all OK (DETACHED tolerated unless --strict)
#        1 DRIFT / MISSING (or DETACHED under --strict)
#        2 usage or local error
#        3 box unreachable — actual state could not be verified
# =============================================================================
set -uo pipefail

# The ledger's own value is what we are auditing, so an experiment override
# leaking in from the environment would make every station agree with itself.
unset BRIDGE_SUITE

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build-guests/lib/bridge-suite.sh"

LAB="${LAB:-lab}"
TILES_ROOT="${BRIDGE_TILES_ROOT:-/data/vms/streamhost/tiles}"
ONE_TILE=""
AS_JSON=0
STRICT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tile)
      [ "$#" -ge 2 ] || {
        echo "bridge-suite-status: --tile needs a tile id" >&2
        exit 2
      }
      ONE_TILE="$2"
      shift
      ;;
    --json) AS_JSON=1 ;;
    --strict) STRICT=1 ;;
    -h | --help)
      sed -n '4,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "bridge-suite-status: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

mapfile -t TILES < <(bridge_suite_tiles) || exit 2
[ "${#TILES[@]}" -gt 0 ] || {
  echo "bridge-suite-status: ledger declares no tiles" >&2
  exit 2
}
ALL_TILES=("${TILES[@]}")
if [ -n "$ONE_TILE" ]; then
  bridge_suite_for "$ONE_TILE" >/dev/null || exit 2
  TILES=("$ONE_TILE")
fi

# suite=base pairs for labhost's side, so it can map a backing file to a suite
# without a second round trip.
BASE_ARGS=()
while read -r suite; do
  base="$(bridge_base_for "$suite")" || exit 2
  BASE_ARGS+=("$suite=$base")
done < <(bridge_suite_list)

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"boxReachable":false,"error":"ssh %s unreachable","tiles":[]}\n' "$LAB"
  else
    echo "bridge-suite-status: ssh $LAB unreachable — cannot verify actual state"
    echo "  (public clone, offline, or CI). The ledger was NOT checked against the box."
  fi
  exit 3
fi

# ---------------------------------------------------------------------------
# Box side. argv: <tiles-root> <suite=base>… -- <tile>…
# Emits one TSV line per station: station  state  suite  disk  backing
# state: ok | detached | nolauncher | nodisk | unreadable
# ---------------------------------------------------------------------------
read -r -d '' REMOTE_PY <<'PY'
import json, os, re, subprocess, sys

argv = sys.argv[1:]
root, rest = argv[0], argv[1:]
cut = rest.index("--")
bases = dict(spec.split("=", 1) for spec in rest[:cut])
tiles = rest[cut + 1:]

# Map every base to its suite under both its literal and its resolved path.
by_path = {}
for suite, path in bases.items():
    by_path[path] = suite
    by_path[os.path.realpath(path)] = suite

ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def literal(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    return raw.split()[0] if raw.split() else ""


def expand(value, env):
    def sub(m):
        name = m.group(1) or m.group(3)
        default = m.group(2)
        if name in env:
            return env[name]
        return expand(default, env) if default is not None else "\0"
    for _ in range(8):
        new = VAR.sub(sub, value)
        if new == value:
            break
        value = new
    return value


def launcher_disk(text):
    """First bootable qcow2 the launcher attaches, with variables expanded."""
    env = {}
    for line in text.splitlines():
        m = ASSIGN.match(line)
        if m and " " not in m.group(1):
            env[m.group(1)] = expand(literal(m.group(2)), env)
    cands = []
    for m in re.finditer(r"-drive\s+([^\s\\]+)", text):
        opts = {}
        for part in m.group(1).split(","):
            if "=" in part:
                k, v = part.split("=", 1)
                opts[k.strip()] = v.strip()
        if opts.get("if") == "pflash" or opts.get("readonly") == "on":
            continue
        cands.append(opts.get("file", ""))
    for m in re.finditer(r"-hda\s+([^\s\\]+)", text):
        cands.append(m.group(1))
    for raw in cands:
        path = expand(literal(raw), env)
        if "\0" in path or not path.endswith(".qcow2"):
            continue
        return path
    return ""


def emit(tile, state, suite="-", disk="-", backing="-"):
    print("\t".join((tile, state, suite, disk, backing)))


for tile in tiles:
    launcher = os.path.join(root, tile, "qemu-streamhost.sh")
    try:
        with open(launcher, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        emit(tile, "nolauncher", disk=launcher)
        continue
    disk = launcher_disk(text)
    if not disk:
        emit(tile, "nodisk", disk=launcher)
        continue
    if not os.path.exists(disk):
        emit(tile, "nodisk", disk=disk)
        continue
    try:
        out = subprocess.run(["qemu-img", "info", "--output=json", "-U", disk],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             timeout=60, check=True).stdout
        info = json.loads(out)
    except Exception as exc:  # noqa: BLE001 - any failure is "cannot verify"
        emit(tile, "unreadable", disk=disk, backing=str(exc).splitlines()[0][:120])
        continue
    backing = info.get("full-backing-filename") or info.get("backing-filename") or ""
    if not backing:
        emit(tile, "detached", disk=disk)
        continue
    suite = by_path.get(backing) or by_path.get(os.path.realpath(backing)) or "?"
    emit(tile, "ok", suite=suite, disk=disk, backing=backing)
PY

REMOTE_ARGS="$(printf ' %q' "$TILES_ROOT" "${BASE_ARGS[@]}" -- "${TILES[@]}")"
BOX_ERR="$(mktemp "${TMPDIR:-/tmp}/bridge-suite-status.XXXXXX")" || exit 2
trap 'rm -f "$BOX_ERR"' EXIT
BOX_OUT="$(printf '%s' "$REMOTE_PY" |
  ssh -o ConnectTimeout=15 "$LAB" "python3 -${REMOTE_ARGS}" 2>"$BOX_ERR")"
BOX_RC=$?
if [ "$BOX_RC" -ne 0 ]; then
  echo "bridge-suite-status: box probe failed (rc=$BOX_RC):" >&2
  cat "$BOX_ERR" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Compare, report.
# ---------------------------------------------------------------------------
DECLARED_JOINED=""
for tile in "${TILES[@]}"; do
  DECLARED_JOINED+="$tile=$(bridge_suite_for "$tile" || echo '?')"$'\n'
done
# Progress is always over the WHOLE ledger, even under --tile: "1 of 1 migrated"
# for a single selected station would be a lie about the migration.
ALL_JOINED=""
for tile in "${ALL_TILES[@]}"; do
  ALL_JOINED+="$tile=$(bridge_suite_for "$tile" || echo '?')"$'\n'
done

SUITES_JOINED="$(bridge_suite_list | tr '\n' ' ')"
python3 - "$AS_JSON" "$STRICT" "$DECLARED_JOINED" "$BOX_OUT" "$SUITES_JOINED" "$ALL_JOINED" <<'PY'
import json, sys

as_json, strict = sys.argv[1] == "1", sys.argv[2] == "1"
declared = dict(
    line.split("=", 1) for line in sys.argv[3].splitlines() if "=" in line
)
box = {}
for line in sys.argv[4].splitlines():
    parts = line.split("\t")
    if len(parts) == 5:
        box[parts[0]] = parts[1:]

NOTES = {
    "detached": "no backing file — standalone image; migrating it means a full "
                "REBUILD, not a rebase",
    "nolauncher": "no qemu-streamhost.sh under the tile root",
    "nodisk": "launcher parsed, but no existing qcow2 boot disk resolved",
    "unreadable": "qemu-img could not read the disk",
}

rows = []
# Seed every known suite so the progress line shows "trixie 0" before the
# first station moves, not a gap. Progress counts the whole ledger; rows are the
# selection.
counts = {suite: 0 for suite in sys.argv[5].split()}
for line in sys.argv[6].splitlines():
    if "=" in line:
        suite = line.split("=", 1)[1]
        counts[suite] = counts.get(suite, 0) + 1
for tile in sorted(declared):
    want = declared[tile]
    entry = box.get(tile)
    if entry is None:
        rows.append(dict(tile=tile, declared=want, actual=None, status="MISSING",
                         disk=None, backing=None, note="box reported nothing"))
        continue
    state, actual, disk, backing = entry
    if state == "ok":
        if actual == want:
            status, note = "OK", ""
        elif actual == "?":
            status = "DRIFT"
            note = "backs onto a file no suite in the ledger claims"
        else:
            status, note = "DRIFT", ""
        rows.append(dict(tile=tile, declared=want, actual=actual, status=status,
                         disk=disk, backing=backing, note=note))
    elif state == "detached":
        rows.append(dict(tile=tile, declared=want, actual=None, status="DETACHED",
                         disk=disk, backing=None, note=NOTES[state]))
    else:
        rows.append(dict(tile=tile, declared=want, actual=None, status="MISSING",
                         disk=None if disk == "-" else disk, backing=None,
                         note=NOTES.get(state, state)))

tally = {}
for row in rows:
    tally[row["status"]] = tally.get(row["status"], 0) + 1
total = sum(counts.values()) or 1
migrated = counts.get("trixie", 0)
progress = " · ".join("%s %d" % (s, counts[s]) for s in sorted(counts))
progress += " · %d%% migrated" % round(100.0 * migrated / total)

bad = tally.get("DRIFT", 0) + tally.get("MISSING", 0)
if strict:
    bad += tally.get("DETACHED", 0)

if as_json:
    print(json.dumps(dict(boxReachable=True, strict=strict, tiles=rows,
                          declaredCounts=counts, statusCounts=tally,
                          progress=progress, failures=bad), indent=2,
                     sort_keys=True))
else:
    print("%-14s %-9s %-9s %s" % ("TILE", "DECLARED", "ACTUAL", "STATUS"))
    for row in rows:
        line = "%-14s %-9s %-9s %s" % (row["tile"], row["declared"],
                                       row["actual"] or "-", row["status"])
        if row["note"]:
            line += "  (%s)" % row["note"]
        print(line)
    print()
    print("migration: " + progress)
    print("status:    " + " · ".join("%s %d" % (s, tally[s]) for s in sorted(tally)))
    if tally.get("DETACHED") and not strict:
        print("note:      DETACHED is not drift; --strict fails on it too.")
    if bad:
        print("FAIL:      %d tile(s) need attention." % bad)

sys.exit(1 if bad else 0)
PY
