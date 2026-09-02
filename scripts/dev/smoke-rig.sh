#!/usr/bin/env bash
# smoke-rig.sh — publish a booted smoke guest at /os/<id> in ONE command.
#
# WHY. pcgeos speedrun (2026-09-02): a smoke guest was booted at 21:34:41 but
# `/os/pcgeos` only resolved at ~21:36:30 because publishing it took five
# hand steps and four retries — kh-claim syntax, a hand-written stream.env,
# a hand-run daemon, and an entry.json derived by guessing which manifest
# file to copy from (it is serve/webroot/gallery-manifest.json, via a
# sibling station's own row). This script is that whole sequence, once.
#
# usage: scripts/dev/smoke-rig.sh <id> --like STATION [--qmp PATH]
#                                  [--slot N|auto] [--display-name NAME]
#        scripts/dev/smoke-rig.sh <id> --down [--release-claims]
#
# Preconditions: the caller has ALREADY launched QEMU for <id> with
# `-display dbus,p2p=on` and a QMP socket (default: <rig>/qmp.sock, where
# rig = /data/vms/sandbox/$KH_SESSION/smoke or /data/vms/sandbox/<id>/smoke
# if KH_SESSION is unset). If that socket is missing this fails loudly with
# the expected launch shape rather than guessing.
#
# --like STATION supplies everything this script cannot invent on its own:
# the sibling's stream.env (SH_* lines, rewritten for the rig; golden/reset/
# fixture/key lines dropped, SH_IDLE_PAUSE_SECS=0 + SH_RESET_MODE=restart
# appended) and the sibling's released binary
# (/usr/local/lib/streamhost/stations/<like>/current).
#
# --slot auto follows the same next-free rule the registry scaffold uses:
# max(stream.slot) over registry/stations/*.json, + 1 — unless this session
# already holds a claim, in which case that claim is reused. UDP port is
# 54000+slot; slot/port/vmid are claimed with kh-claim under KH_SESSION and
# NOT released on --down (they pass to the eventual real station) unless
# --release-claims is also given.
#
# Run FROM CT950 (like station-up.sh): it opens its own `ssh lab` sessions
# via labrun heredocs — never nest this inside another `ssh lab`.
#
# Idempotent bring-up: re-running with the same <id>/--like is safe — the
# daemon is killed and restarted, stream.env is rewritten, and publish
# overlays the same manifest entry again. --down keeps every file in the
# rig; only --release-claims lets go of slot/port/vmid.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABRUN="$SCRIPT_DIR/labrun"
LAB="${LAB:-lab}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/kh-session.sh" 2>/dev/null || true

id=""
like=""
qmp=""
slot_arg=""
display_name=""
down=0
release_claims=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --like)
      like="$2"
      shift
      ;;
    --qmp)
      qmp="$2"
      shift
      ;;
    --slot)
      slot_arg="$2"
      shift
      ;;
    --display-name)
      display_name="$2"
      shift
      ;;
    --down) down=1 ;;
    --release-claims) release_claims=1 ;;
    -h | --help)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    -*)
      echo "smoke-rig: unknown flag $1" >&2
      exit 2
      ;;
    *) id="$1" ;;
  esac
  shift
done
[ -n "$id" ] || {
  echo "usage: smoke-rig.sh <id> --like STATION [--qmp PATH] [--slot N|auto] [--display-name NAME]" >&2
  echo "       smoke-rig.sh <id> --down [--release-claims]" >&2
  exit 2
}
case "$id" in
  *[!a-z0-9_-]*)
    echo "smoke-rig: bad station id '$id'" >&2
    exit 2
    ;;
esac
[ -n "${KH_SESSION:-}" ] || {
  echo "smoke-rig: KH_SESSION is not set — source scripts/lib/kh-session.sh or run under a wt.sh worktree" >&2
  exit 2
}

session="$KH_SESSION"
rig="/data/vms/sandbox/$session/smoke"
[ -n "$qmp" ] || qmp="$rig/qmp.sock"

step() { printf '\n== %s\n' "$*"; }
fail() {
  echo "smoke-rig: FAIL: $*" >&2
  exit 1
}

# ---- --down -----------------------------------------------------------------
if [ "$down" = 1 ]; then
  step "withdraw + kill (id=$id, rig=$rig, release-claims=$release_claims)"
  "$LABRUN" "$id" "$rig" <<'EOF_REMOTE'
id="$1"
rig="$2"
python3 /data/kernel-hive/scripts/dev/darklaunch-station.py withdraw "$id" || true
for pf in daemon.pid qemu.pid; do
  p="$rig/$pf"
  [ -f "$p" ] || continue
  pid="$(cat "$p" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "-- killed $pf pid=$pid"
  else
    echo "-- $pf: no live pid"
  fi
  rm -f "$p"
done
echo "-- rig kept: $rig"
EOF_REMOTE
  if [ "$release_claims" = 1 ]; then
    step "release claims"
    "$LABRUN" "$session" <<'EOF_REMOTE'
session="$1"
export KH_SESSION="$session"
while IFS=' ' read -r cls name; do
  [ -n "$cls" ] || continue
  kh-claim release "$cls" "$name" && echo "-- released $cls $name"
done <<CLAIMLIST
$(kh-claim ls --mine --json 2>/dev/null | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class") in ("port","slot","vmid"):
        print(c["class"]+" "+c["name"])
')
CLAIMLIST
EOF_REMOTE
  else
    echo "-- claims kept (slot/port/vmid pass to the real station); use --release-claims to drop them"
  fi
  exit 0
fi

# ---- publish path -------------------------------------------------------------
[ -n "$like" ] || fail "--like STATION is required (whose stream.env / binary to borrow)"

step "0 rig + QMP socket"
"$LABRUN" "$rig" <<'EOF_REMOTE'
rig="$1"
mkdir -p "$rig"
EOF_REMOTE
sock_present="$(
  "$LABRUN" "$qmp" <<'EOF_REMOTE'
[ -S "$1" ] && echo yes || echo no
EOF_REMOTE
)"
[ "$sock_present" = yes ] || fail "QMP socket $qmp not found — launch QEMU first with:
  -display dbus,p2p=on  -qmp unix:$qmp,server=on,wait=off  -pidfile $rig/qemu.pid"
echo "-- qmp socket present: $qmp"

step "1 slot / port / vmid claims"
slot="$(
  "$LABRUN" "$session" "$slot_arg" "$id" <<'EOF_REMOTE'
session="$1"
slot_arg="$2"
id="$3"
export KH_SESSION="$session"
mine_slot="$(kh-claim ls --mine --json 2>/dev/null | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    if c.get("class") == "slot":
        print(c["name"]); break
' 2>/dev/null || true)"
if [ "$slot_arg" != "auto" ] && [ -n "$slot_arg" ]; then
  slot="$slot_arg"
elif [ -n "$mine_slot" ]; then
  slot="$mine_slot" # re-run: reuse the slot this session already holds
else
  # next free slot: above every registry slot AND every slot claim anyone holds
  slot="$(python3 - <<'PY_SLOT'
import glob, json, subprocess
taken = set()
for f in glob.glob("/data/kernel-hive/registry/stations/*.json"):
    try:
        taken.add(int(json.load(open(f)).get("stream", {}).get("slot", 0)))
    except Exception:
        pass
try:
    for c in json.loads(subprocess.run(["kh-claim", "ls", "--all", "--json"], capture_output=True, text=True).stdout):
        if c.get("class") == "slot" and str(c.get("name", "")).isdigit():
            taken.add(int(c["name"]))
except Exception:
    pass
print(max(taken) + 1)
PY_SLOT
  )"
fi
port=$((54000 + slot))
# fleet convention (see bootos/pcgeos): claims are named by the NUMBER, so they
# pass to the real station and `kh-claim who slot <n>` answers.
kh-claim take slot "$slot" --purpose "$id station slot (smoke rig)" >&2 || kh-claim who slot "$slot" >&2
kh-claim take port "$port" --purpose "$id station streamhost UDP (slot $slot, smoke rig)" >&2 || fail_port=1
kh-claim take vmid "$slot" --purpose "$id station VMID label (slot $slot, smoke rig)" >&2 || fail_vmid=1
if [ "${fail_port:-0}" = 1 ] || [ "${fail_vmid:-0}" = 1 ]; then
  echo "port $port / vmid $slot already claimed by another session (kh-claim who port $port)" >&2
  exit 1
fi
echo "$slot"
EOF_REMOTE
)"
port=$((54000 + slot))
echo "-- slot=$slot udp-port=$port (claimed under session $session)"

step "2 stream.env from sibling $like"
"$LABRUN" "$like" "$id" "$rig" "$qmp" "$port" <<'EOF_REMOTE'
like="$1"
id="$2"
rig="$3"
qmp="$4"
port="$5"
src="/data/vms/streamhost/stations/$like/station.env"
[ -f "$src" ] || {
  echo "sibling station.env not found: $src" >&2
  exit 1
}
out="$rig/stream.env"
: >"$out"
while IFS= read -r line; do
  case "$line" in
    \#*) continue ;;
    SH_GOLDEN_*|SH_RESET_MODE=*|SH_FIXTURE_DESC*|SH_KEY_*) continue ;;
    # a sibling's pointer backend names ITS device (ramabs socket, x11warp
    # display, mga ptrctl): on a rig that device does not exist and the daemon
    # retries it forever (netbsd14, 2026-09-03). Rigs are relative-pointer.
    SH_INPUT_BACKEND=*|SH_RAMABS_*|SH_X11WARP_*|SH_X11TEST_*|KH_RAMABS_*|SH_MGACTL_*) continue ;;
    SH_STATION=*) echo "SH_STATION=$id" >>"$out" ;;
    SH_QMP=*) echo "SH_QMP=$qmp" >>"$out" ;;
    SH_PORT=*) echo "SH_PORT=$port" >>"$out" ;;
    SH_HASH_FILE=*) echo "SH_HASH_FILE=$rig/cert_hash_b64.txt" >>"$out" ;;
    SH_SIGNALING_JSON=*) echo "SH_SIGNALING_JSON=$rig/signaling.json" >>"$out" ;;
    SH_*=*) echo "$line" >>"$out" ;;
    *) continue ;;
  esac
done <"$src"
echo "SH_INPUT_BACKEND=dbus-rel" >>"$out"
echo "SH_IDLE_PAUSE_SECS=0" >>"$out"
echo "SH_RESET_MODE=restart" >>"$out"
# Runtime residue stays in the rig: unset, the daemon writes probes.json, traces/ and
# logs/ under /data/vms/streamhost/stations/<id>/, which creates an undeclared
# station dir in the fleet tree and refuses `labctl gen` fleet-wide (2026-09-03).
echo "SH_PROBES_JSON=$rig/probes.json" >>"$out"
echo "SH_TRACE_DIR=$rig/traces" >>"$out"
echo "SH_LOG_DIR=$rig/logs" >>"$out"
echo "-- wrote $out ($(wc -l <"$out") lines)"
EOF_REMOTE

step "3 run-daemon.sh + start"
"$LABRUN" "$like" "$rig" <<'EOF_REMOTE'
like="$1"
rig="$2"
bin="$(readlink -f "/usr/local/lib/streamhost/stations/$like/current")"
[ -x "$bin" ] || {
  echo "sibling binary not found/executable: $bin" >&2
  exit 1
}
cat >"$rig/run-daemon.sh" <<SCRIPT
#!/bin/bash
set -e
rig="$rig"
[ -f "\$rig/daemon.pid" ] && kill "\$(cat "\$rig/daemon.pid")" 2>/dev/null || true
sleep 0.3
set -a
. "\$rig/stream.env"
. /etc/osgallery/stream-ticket.env
set +a
nohup "$bin" >"\$rig/daemon.log" 2>&1 &
echo \$! >"\$rig/daemon.pid"
echo "daemon pid=\$(cat "\$rig/daemon.pid")"
SCRIPT
chmod +x "$rig/run-daemon.sh"
"$rig/run-daemon.sh"
for i in $(seq 1 30); do
  [ -f "$rig/signaling.json" ] && [ -f "$rig/cert_hash_b64.txt" ] && break
  sleep 0.5
done
[ -f "$rig/signaling.json" ] && [ -f "$rig/cert_hash_b64.txt" ] || {
  echo "signaling.json / cert_hash_b64.txt did not appear within 15s — see $rig/daemon.log" >&2
  tail -n 20 "$rig/daemon.log" >&2 || true
  exit 1
}
echo "-- daemon up: signaling.json + cert_hash_b64.txt present"
EOF_REMOTE

step "4 publish /os/$id"
publish_args=(publish "$id" --rig "$rig" --like "$like")
[ -n "$display_name" ] && publish_args+=(--display-name "$display_name")
"$LABRUN" "${publish_args[@]}" <<'EOF_REMOTE'
python3 /data/kernel-hive/scripts/dev/darklaunch-station.py "$@"
EOF_REMOTE

step "SUMMARY $id"
echo "   rig      : $rig"
echo "   like     : $like"
echo "   slot/port: $slot / $port"
echo "   url      : /os/$id"
echo "   REMINDER : restart the daemon after every guest relaunch: $rig/run-daemon.sh"
