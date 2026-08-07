#!/bin/bash
# bootrec-lib.sh — shared helpers for the boot-video capture tooling
# (record-boot.sh / detect-interactive.sh / postprocess-boot.sh / gen-boot-manifest.sh).
#
# NOT executable on its own — `source` it. Implements: logging, a tiny QMP client
# (qmp_capabilities handshake + one command, over the tile's unix qmp.sock via
# python3), HMP passthrough (screendump / savevm / loadvm / delvm), an ffmpeg-SSIM
# change-fraction probe (the Tier-1/Tier-2 detector signal), and kill-by-pidfile
# cleanup. Model: scripts/coldboot/amiga-coldboot-watch.sh (box-side prototype, not in repo; single-shell sidecar,
# no streamhost daemon change). See README.md "Boot-video capture" for the flow.
#
# Conventions (AGENTS.md hard rules honoured by every caller):
#   * clones live under /data/vms/soltest/ (NEVER touch a live tile);
#   * VMs are killed ONLY by pidfile, never pkill-by-name;
#   * device set of a vmstate clone MUST match the live launcher exactly
#     (loadvm golden requires an exact device match) — the clone is a byte copy
#     of the live qemu-streamhost.sh with only paths/ports/loadvm rewritten.
set -uo pipefail

# ---- paths / constants ---------------------------------------------------------
BOOTREC_TILES_ROOT="${BOOTREC_TILES_ROOT:-/data/vms/streamhost/tiles}"
BOOTREC_CLONE_ROOT="${BOOTREC_CLONE_ROOT:-/data/vms/soltest}"
BOOTREC_STAGING_ROOT="${BOOTREC_STAGING_ROOT:-/data/vms/streamhost/boot-rec}"

# ---- logging -------------------------------------------------------------------
br_log() { printf '[bootrec] %s\n' "$*" >&2; }
br_warn() { printf '[bootrec] WARN: %s\n' "$*" >&2; }
br_die() {
  printf '[bootrec] ERR: %s\n' "$*" >&2
  exit 1
}

# ---- central clone-guard (fail-closed; NEVER touch a live tile) ----------------
# Route every kill / destructive-QMP through scripts/lib/clone-guard.sh so a
# mis-set clone path can never reach a production tile (see clone-guard.sh header
# for the incident this prevents). The clone root here IS the guard's clone root.
export CLONE_GUARD_CLONE_ROOT="${CLONE_GUARD_CLONE_ROOT:-$BOOTREC_CLONE_ROOT}"
export CLONE_GUARD_PROD_TILES_ROOT="${CLONE_GUARD_PROD_TILES_ROOT:-$BOOTREC_TILES_ROOT}"
_br_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _cg in "${CLONE_GUARD:-}" /usr/local/bin/clone-guard \
  "$_br_here/clone-guard.sh" "$_br_here/../lib/clone-guard.sh"; do
  if [ -n "$_cg" ] && [ -f "$_cg" ]; then
    # shellcheck source=/dev/null
    source "$_cg" && break
  fi
done
unset _cg _br_here

# ---- QMP client ----------------------------------------------------------------
# br_qmp <qmp.sock> <json-command>  -> prints the JSON response line to stdout.
# Does the greeting + qmp_capabilities handshake on every call (cheap; the socket
# is server=on,wait=off so re-connecting is fine). Returns non-zero on error.
br_qmp() {
  local sock="$1" cmd="$2"
  python3 - "$sock" "$cmd" <<'PY'
import json, socket, sys
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
f.readline()                                   # greeting
f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
f.write(cmd.encode() + b"\n")
# Skip async QMP EVENT lines (e.g. STOP/RESUME/POWERDOWN): QEMU can emit the event
# for a state-changing command (stop/cont/loadvm) BEFORE the command's own
# {"return":{}} response. Read until we see the actual return/error, not an event.
while True:
    line = f.readline()
    if not line:
        sys.exit(1)                            # connection closed without a reply
    resp = line.decode(errors="replace")
    try:
        j = json.loads(resp)
    except Exception:
        continue
    if isinstance(j, dict) and "event" in j and "return" not in j and "error" not in j:
        continue                               # async event — keep reading
    sys.stdout.write(resp)
    sys.exit(0 if "return" in j else 1)
PY
}

# br_hmp <qmp.sock> <hmp-command-line> -> runs a human-monitor command via QMP.
# DESTRUCTIVE verbs (savevm/loadvm/delvm/stop/cont/quit/system_reset/powerdown)
# are gated by the clone-guard: the socket MUST be inside the clone root, so a
# mis-set CLONE_QMP can never savevm-clobber a live golden or stop a live tile.
br_hmp() {
  local sock="$1" line="$2" json verb
  verb="${line%% *}"
  case "$verb" in
    savevm | loadvm | delvm | stop | cont | quit | system_reset | system_powerdown | q)
      if declare -F clone_guard_assert_clone_qmp >/dev/null 2>&1; then
        clone_guard_assert_clone_qmp "$sock" ||
          br_die "clone-guard refused destructive HMP '$verb' on '$sock' (not a clone socket)."
      else
        case "$(realpath -m -- "$sock" 2>/dev/null || echo "$sock")/" in
          "$BOOTREC_CLONE_ROOT"/?*/) : ;;
          *) br_die "REFUSED destructive HMP '$verb': socket '$sock' is not inside the clone root $BOOTREC_CLONE_ROOT/." ;;
        esac
      fi
      ;;
  esac
  json=$(
    python3 - "$line" <<'PY'
import json, sys
print(json.dumps({"execute": "human-monitor-command",
                  "arguments": {"command-line": sys.argv[1]}}))
PY
  )
  br_qmp "$sock" "$json"
}

# br_screendump <qmp.sock> <out.png> — framebuffer -> PNG.
# NOTE: this box's pve-qemu 11.0.0 is built WITHOUT libpng, so HMP `screendump -f png`
# errors ("Enable PNG support with libpng"). Dump the always-available PPM instead and
# convert to the requested (PNG) file with ffmpeg (present on the box).
br_screendump() {
  local sock="$1" out="$2" ppm i
  rm -f "$out"
  ppm="${out%.png}.ppm"
  [ "$ppm" = "$out" ] && ppm="${out}.ppm"
  rm -f "$ppm"
  br_hmp "$sock" "screendump $ppm -f ppm" >/dev/null || return 1
  # HMP screendump returns immediately; give QEMU a beat to flush the file.
  for i in $(seq 1 20); do
    [ -s "$ppm" ] && break
    sleep 0.2
  done
  [ -s "$ppm" ] || return 1
  if [ "$out" != "$ppm" ]; then
    ffmpeg -hide_banner -y -i "$ppm" "$out" >/dev/null 2>&1 || return 1
    rm -f "$ppm"
  fi
  [ -s "$out" ]
}

# ---- ffmpeg image similarity (the detector signal) -----------------------------
# br_ssim <a.png> <b.png> [cropspec] -> prints SSIM "All" in [0,1] (1 == identical).
# cropspec (optional) is an ffmpeg crop= filter applied to BOTH inputs, e.g.
# "crop=200:40:20:8" for a Tier-2 reference region. Uses ffmpeg's ssim filter and
# parses "All:<x>" from stderr. ffmpeg 7.1.5 is present on the box.
br_ssim() {
  local a="$1" b="$2" crop="${3:-}" pre=""
  [ -n "$crop" ] && pre="${crop},"
  ffmpeg -hide_banner -nostats -i "$a" -i "$b" \
    -lavfi "[0:v]${pre}format=gray[x];[1:v]${pre}format=gray[y];[x][y]ssim" \
    -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1
}

# br_change_fraction <a.png> <b.png> [cropspec] -> 1 - SSIM  (the "cf" signal,
# comparable to the per-tile cf in scripts/serve/golden-manifest.json).
br_change_fraction() {
  local ssim
  ssim="$(br_ssim "$1" "$2" "${3:-}")"
  [ -z "$ssim" ] && {
    echo "1.0"
    return
  }
  python3 -c "print(max(0.0, 1.0 - float('${ssim}')))"
}

# ---- kill-by-pidfile cleanup ---------------------------------------------------
# br_kill_pidfile <pidfile> — terminate a QEMU clone by its pidfile ONLY, THROUGH
# the central clone-guard (refuses any pidfile outside the clone root, or whose PID
# is a production QEMU). If the guard is sourced, delegate to it. If it is somehow
# absent, fall back to an INLINE fail-closed check — never LESS safe than the guard.
br_kill_pidfile() {
  local pf="$1" pid i
  if declare -F clone_guard_kill_pidfile >/dev/null 2>&1; then
    clone_guard_kill_pidfile "$pf" ||
      br_die "clone-guard refused to kill '$pf' (see message above) — refusing to fall through to an unguarded kill."
    return 0
  fi
  # ---- inline fail-closed fallback (guard file not found) ----
  # 1) pidfile PATH must be strictly inside the clone root.
  case "$(realpath -m -- "$pf" 2>/dev/null || echo "$pf")/" in
    "$BOOTREC_CLONE_ROOT"/?*/) : ;;
    *) br_die "REFUSED: pidfile '$pf' is not inside the clone root $BOOTREC_CLONE_ROOT/ — refusing to kill (possible production target)." ;;
  esac
  case "$(realpath -m -- "$pf" 2>/dev/null || echo "$pf")" in
    */streamhost/tiles/*) br_die "REFUSED: pidfile '$pf' traverses the production tiles tree — refusing to kill." ;;
  esac
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null || true)"
  [ -n "$pid" ] || {
    rm -f "$pf"
    return 0
  }
  case "$pid" in *[!0-9]*) br_die "REFUSED: pidfile '$pf' has a non-numeric pid '$pid'." ;; esac
  # 2) the running PID must not be a production QEMU (argv under the tiles tree).
  if [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q '/streamhost/tiles/'; then
    br_die "REFUSED: pid $pid is a PRODUCTION QEMU (argv references $BOOTREC_TILES_ROOT/) — refusing to kill."
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$pf"
}

# br_wait_qmp <qmp.sock> [tries] — block until the clone's QMP socket accepts.
br_wait_qmp() {
  local sock="$1" tries="${2:-60}" i
  for i in $(seq 1 "$tries"); do
    if [ -S "$sock" ] && br_qmp "$sock" '{"execute":"query-status"}' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}
