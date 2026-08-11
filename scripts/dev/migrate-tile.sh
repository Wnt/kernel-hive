#!/usr/bin/env bash
# =============================================================================
# migrate-tile.sh — move ONE kiosk from the bookworm guest base to trixie
#
# THE PROCEDURE IS docs/lab/BRIDGE-TRIXIE-MIGRATION.md §2 — read it there, not
# here; two copies of it would drift. Wave 1 ran it three times with one agent
# per station and each re-derived it from that doc; one lost an hour to a trap
# another had already hit. 25 stations remain, so it is a script now: one
# invocation per station, plus a human looking at two screenshots.
#
# Everything runs on labhost over `ssh lab` (the only door). The nine steps
# announce themselves as "N/9", and the two wave-1 traps are explained at the
# step that handles them — 4/9 the stale SSH host key, 7/9 the builders that
# print the capture commands instead of capturing. Three things to know first:
#
#   * It does NOT claim visual acceptance, and cannot. It prints the BEFORE and
#     AFTER PNGs and says a human must compare them: the failure this migration
#     produces (amiga losing Mesa and rendering black) looks healthy in every
#     log and every exit code below.
#   * The overlay is MOVED to overlay.qcow2.bookworm-bak, never deleted. That is
#     the whole rollback, and it is exact because the bookworm base is frozen.
#     Any failed mechanical check restores it automatically and leaves the
#     trixie attempt beside it as overlay.qcow2.trixie-failed for the postmortem.
#   * The station's REAL daemon identity is read from its signaling.json, because
#     an UI id is not always an SH_TILE and the systemd unit follows the
#     daemon's (AGENTS.md).
#
# The registry prose is deliberately not automated — the twinned .museum.notes /
# .render.museumBlock, the builder header, the launcher comment and the
# per-guest doc are judgement, and `make station-registry-generate` runs after a
# human has written them. --flip edits the ledger only; the rest is printed.
#
# usage: migrate-tile.sh <tile> [--flip] [--dry-run] [--no-restart]
#   --flip        after every mechanical check passes, set this station to "trixie"
#                 in registry/bridge-suites.json (default: OFF — you flip it in
#                 the same commit as the prose)
#   --dry-run     print every step and every command, touch nothing. Preflight
#                 still runs for real (read-only), so the plan is the real plan
#   --no-restart  leave the unit stopped after the build (skips the AFTER shot)
#
# env: LAB=lab  MIGRATE_BUILD_TIMEOUT=5400  MIGRATE_BAKE_SETTLE=180
#      MIGRATE_EVIDENCE=<local dir for the PNGs>
#
# exit: 0 migrated (mechanically) — a human still owes the screenshot compare
#       1 a check failed; rolled back to bookworm
#       2 usage, refusal, or local error — nothing was touched
#       3 box unreachable — nothing was touched
# =============================================================================
set -uo pipefail

# The ledger's own value is what we are acting on, so an experiment override
# leaking in from the environment would make the preflight agree with itself.
unset BRIDGE_SUITE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/scripts/build-guests/lib/bridge-suite.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/box-detached-build.sh"

LAB="${LAB:-lab}"
SSH_OPTS=(-o ConnectTimeout=15)
BOX_BUILD_SSH=(ssh "${SSH_OPTS[@]}" "$LAB")
TILES_ROOT="${BRIDGE_TILES_ROOT:-/data/vms/streamhost/tiles}"
BRIDGE_KEY=/data/vms/bridge/bridge_key
TARGET_SUITE=trixie
LEDGER="$REPO/registry/bridge-suites.json"

# The frozen bookworm base, as stat'ed after wave 0 (BRIDGE-TRIXIE-MIGRATION.md
# §wave 0). Every overlay that has not migrated resolves through this file by
# path, block for block. We assert it is byte-for-byte untouched before and
# after, because the failure mode of touching it is 25 stations booting corrupt.
BOOKWORM_SIZE=3162308608
BOOKWORM_MTIME="2026-07-15 10:52:41"

BUILD_TIMEOUT="${MIGRATE_BUILD_TIMEOUT:-5400}" # seconds; builds run 5-40 min
BAKE_SETTLE="${MIGRATE_BAKE_SETTLE:-180}"      # seconds to let the kiosk settle

TILE=""
FLIP=0
DRY=0
RESTART=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flip) FLIP=1 ;;
    --dry-run | -n) DRY=1 ;;
    --no-restart) RESTART=0 ;;
    -h | --help)
      sed -n '3,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "migrate-tile: unknown option: $1" >&2
      exit 2
      ;;
    *)
      [ -z "$TILE" ] || {
        echo "migrate-tile: one tile at a time (got '$TILE' and '$1')" >&2
        exit 2
      }
      TILE="$1"
      ;;
  esac
  shift
done
[ -n "$TILE" ] || {
  echo "usage: migrate-tile.sh <tile> [--flip] [--dry-run] [--no-restart]" >&2
  exit 2
}

# --- helpers ---------------------------------------------------------------
log() { printf '[migrate %s %s] %s\n' "$TILE" "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() {
  printf '[migrate %s] ERROR: %s\n' "$TILE" "$1" >&2
  exit "${2:-2}"
}

# box_ro <cmd…> — read-only probe. ALWAYS runs, including under --dry-run: the
# plan is only worth reviewing if its facts came off real labhost.
# shellcheck disable=SC2029 # every caller quotes its own %q substitutions
box_ro() { ssh "${SSH_OPTS[@]}" "$LAB" "$@"; }

# box_sh <label> <program> [arg…] — run a bash program on labhost. Mutating, so
# --dry-run prints the program verbatim instead of running it.
box_sh() {
  local label="$1" prog="$2"
  shift 2
  if [ "$DRY" -eq 1 ]; then
    printf '  [would] %s\n' "$label"
    printf '%s\n' "$prog" | sed 's/^/          | /'
    [ "$#" -gt 0 ] && printf '          | # args: %s\n' "$*"
    return 0
  fi
  log "$label"
  ssh "${SSH_OPTS[@]}" "$LAB" bash -s -- "$@" <<<"$prog"
}

# --- local preflight (no box needed; the refusals live here) ----------------
step "preflight: ledger and repo"

SUITE="$(bridge_suite_for "$TILE")" || exit 2
if [ "$SUITE" = "$TARGET_SUITE" ]; then
  echo "migrate-tile: '$TILE' is already declared $TARGET_SUITE in the ledger."
  echo "  Nothing to migrate. (scripts/dev/bridge-suite-status.sh --tile $TILE"
  echo "   is what proves the box agrees with that declaration.)"
  exit 2
fi
log "ledger declares suite=$SUITE -> target $TARGET_SUITE"

if [ "$TILE" = "c64" ]; then
  cat >&2 <<'EOM'
migrate-tile: refusing c64 — it is not a rebase, it is a rebuild.

  c64's overlay was FLATTENED on 2026-08-07 into a standalone 5.21 GiB qcow2
  with NO backing file (bridge-suite-status.sh reports it as DETACHED, not as
  drift). This script rebases an overlay onto a new base, so everything it
  would do here is wrong: the backup is 5 GiB rather than a delta, and the
  acceptance check "backs onto the trixie base" can never pass. c64 needs a
  full by-hand rebuild from scripts/build-guests/tiles/c64.sh with its own
  acceptance — docs/lab/BRIDGE-TRIXIE-MIGRATION.md §1 and §4 (wave 4, c64 last).
EOM
  exit 2
fi

BUILDER_REL="scripts/build-guests/tiles/$TILE.sh"
BUILDER="$REPO/$BUILDER_REL"
[ -f "$BUILDER" ] || die "no builder at $BUILDER_REL — this tile cannot be rebuilt by this script"

# The provisioning port is DERIVED, never hardcoded: it is the builder's own
# SSH_PORT, and the stale-host-key trap is keyed on exactly that port.
SSH_PORT="$(sed -n 's/^SSH_PORT=\([0-9][0-9]*\).*$/\1/p' "$BUILDER" | head -1)"
[ -n "$SSH_PORT" ] ||
  die "cannot derive SSH_PORT from $BUILDER_REL (expected a literal 'SSH_PORT=<n>' line)"
log "builder $BUILDER_REL, provisioning port $SSH_PORT"

TRIXIE_BASE="$(bridge_base_for "$TARGET_SUITE")" || exit 2
BOOKWORM_BASE="$(bridge_base_for bookworm)" || exit 2

D="$TILES_ROOT/$TILE"
OVERLAY="$D/overlay.qcow2"
BAK="$OVERLAY.bookworm-bak"
FAILED="$OVERLAY.trixie-failed"
STAGE="/data/vms/soltest/migrate-$TILE-trixie"
BUILD_LOG="$STAGE/build.log"
EVIDENCE="${MIGRATE_EVIDENCE:-${TMPDIR:-/tmp}/migrate-tile/$TILE}"

# --- box preflight ---------------------------------------------------------
step "preflight: the box"

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  echo "migrate-tile: ssh $LAB unreachable — nothing was touched. There is no"
  echo "  offline mode; see docs/lab/CLOUD-AGENTS.md if you are in a cloud VM."
  exit 3
fi

read -r -d '' PROBE <<'PY'
import json, os, subprocess, sys
d, trixie, bookworm = sys.argv[1], sys.argv[2], sys.argv[3]
overlay = os.path.join(d, "overlay.qcow2")
yn = lambda ok: "yes" if ok else "no"  # noqa: E731 - one-off, this is a probe
out = lambda k, v: print("%s=%s" % (k, v))  # noqa: E731

out("tiledir", yn(os.path.isdir(d)))
out("launcher", yn(os.path.isfile(os.path.join(d, "qemu-streamhost.sh"))))
out("trixiebase", yn(os.path.isfile(trixie)))
out("overlay", yn(os.path.isfile(overlay)))
out("bak", yn(os.path.exists(overlay + ".bookworm-bak")))
out("key", yn(os.path.isfile("/data/vms/bridge/bridge_key")))
try:
    with open(os.path.join(d, "signaling.json"), encoding="utf-8") as fh:
        out("shtile", json.load(fh)["tile"])
except Exception as exc:  # noqa: BLE001 - any failure means "identity unknown"
    out("shtile", "")
    out("shtileerr", str(exc)[:120])
if os.path.isfile(overlay):
    try:
        info = json.loads(subprocess.run(
            ["qemu-img", "info", "-U", "--output=json", overlay],
            stdout=subprocess.PIPE, check=True).stdout)
        out("backing", info.get("full-backing-filename") or info.get("backing-filename") or "")
        out("golden", "yes" if any(s.get("name") == "golden"
                                   for s in info.get("snapshots", [])) else "no")
    except Exception as exc:  # noqa: BLE001
        out("backing", "ERR:%s" % str(exc)[:80])
        out("golden", "?")
PY

PROBE_OUT="$(printf '%s' "$PROBE" | box_ro "python3 - $(printf '%q ' "$D" "$TRIXIE_BASE" "$BOOKWORM_BASE")")" ||
  die "box preflight probe failed" 3
declare -A P=()
while IFS='=' read -r k v; do [ -n "$k" ] && P["$k"]="$v"; done <<<"$PROBE_OUT"

[ "${P[tiledir]:-no}" = yes ] || die "no live tile dir on the box: $D"
[ "${P[launcher]:-no}" = yes ] || die "no $D/qemu-streamhost.sh — the golden bake has no device set to use"
[ "${P[trixiebase]:-no}" = yes ] ||
  die "the trixie base is missing: $TRIXIE_BASE (build it: build-guests/lib/bridge-base.sh --suite trixie)"
[ "${P[overlay]:-no}" = yes ] || die "no overlay to rebase: $OVERLAY"
[ "${P[key]:-no}" = yes ] || die "no bridge SSH key on the box: $BRIDGE_KEY"
[ -n "${P[shtile]:-}" ] ||
  die "cannot read the daemon identity from $D/signaling.json (${P[shtileerr]:-unknown}) — the unit name would be a guess"

SH_TILE="${P[shtile]}"
UNIT="streamhost@$SH_TILE"
[ "$SH_TILE" = "$TILE" ] ||
  log "NOTE: SPA id '$TILE' != daemon id '$SH_TILE'; the unit follows the daemon"
log "daemon identity $SH_TILE (unit $UNIT), overlay backs onto ${P[backing]:-<none>}"
log "golden snapshot present before the rebuild: ${P[golden]:-?}"

case "${P[backing]:-}" in
  "$BOOKWORM_BASE") : ;;
  "") die "overlay has NO backing file (detached/flattened) — that is a rebuild, not a rebase" ;;
  *) die "overlay backs onto '${P[backing]}', not the bookworm base '$BOOKWORM_BASE' — resolve the drift first (scripts/dev/bridge-suite-status.sh --tile $TILE)" ;;
esac

assert_base_frozen() {
  local out size mtime
  out="$(box_ro "stat -c '%s|%.19y' $(printf '%q' "$BOOKWORM_BASE")")" ||
    die "cannot stat the frozen bookworm base" 3
  size="${out%%|*}"
  mtime="${out#*|}"
  [ "$size" = "$BOOKWORM_SIZE" ] && [ "$mtime" = "$BOOKWORM_MTIME" ] ||
    die "THE FROZEN BOOKWORM BASE CHANGED ($size $mtime, expected $BOOKWORM_SIZE $BOOKWORM_MTIME). Every unmigrated overlay resolves through it. Stop and investigate. ($1)" 1
  log "frozen bookworm base unchanged ($1)"
}
assert_base_frozen "preflight"

# The backup is the rollback, so an existing one is a resumable earlier attempt,
# never something to overwrite: the bookworm overlay it holds cannot be rebuilt.
if [ "${P[bak]:-no}" = yes ]; then
  log "NOTE: $BAK already exists (an earlier attempt). It will NOT be overwritten;"
  log "      this run backs the current overlay up to $FAILED instead."
fi

# --- rollback --------------------------------------------------------------
# The detached builder is NOT a child of this script, so nothing reaps it when a
# check fails — and whoever abandons a build owes it a kill, or it keeps writing
# to the overlay the rollback is about to replace (box-detached-build.sh).
stop_builder() {
  [ "$DRY" -eq 1 ] && return 0
  log "stopping the detached builder before the overlay is touched"
  box_build_stop "$BUILD_LOG"
}

ROLLED_BACK=0
rollback() {
  [ "$ROLLED_BACK" -eq 0 ] || return 0
  ROLLED_BACK=1
  # Fail CLOSED: no rollback under a live builder. A rollback restores the
  # bookworm overlay and restarts the unit, and the builder reaches its guest as
  # 127.0.0.1:<hostfwd> — so a survivor finds the restarted PRODUCTION station on
  # that port and provisions it, up to and including savevm golden over the live
  # fixture. That happened twice on 2026-08-10 (decos, plus4) and both stations
  # survived only on luck. Half-migrated with a known-live builder is a state a
  # human must look at; it is strictly better than racing it.
  stop_builder ||
    die "ROLLBACK ABORTED: the builder is still alive and the overlay was NOT touched. Kill its process group on the box, confirm via /proc/<pid>/exe, then restore $BAK by hand." 1
  step "ROLLBACK: restoring the bookworm overlay"
  box_sh "stop, restore $BAK, restart $UNIT" "$(
    cat <<'EOS'
set -u
d=$1 unit=$2 bak=$3 failed=$4
systemctl stop "$unit" 2>/dev/null
# Kill this station's QEMU only by its pidfile, and only after /proc/<pid>/exe says
# it really is a QEMU (never pkill -f from ssh lab — it matches its own shell).
if [ -f "$d/qemu.pid" ]; then
  pid=$(cat "$d/qemu.pid" 2>/dev/null || true)
  case "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" in
    *qemu-system-*) kill "$pid" 2>/dev/null; for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break; sleep 1; done ;;
  esac
fi
[ -f "$d/overlay.qcow2" ] && mv -f "$d/overlay.qcow2" "$failed"
if [ -f "$bak" ]; then mv -f "$bak" "$d/overlay.qcow2"; else
  echo "ROLLBACK: no $bak to restore!" >&2; exit 1; fi
systemctl start "$unit"
sleep 8
systemctl is-active --quiet "$unit" && echo "rollback: $unit is active again" ||
  { echo "ROLLBACK: $unit did NOT come back — hands on" >&2; exit 1; }
EOS
  )" "$D" "$UNIT" "$BAK" "$FAILED"
  echo
  echo "Rolled back. The trixie attempt is kept at $FAILED (delete it yourself"
  echo "once the post-mortem is done); the build log is $BUILD_LOG."
}
fail() {
  printf '[migrate %s] FAILED: %s\n' "$TILE" "$1" >&2
  rollback
  exit 1
}

# --- 1. BEFORE evidence ----------------------------------------------------
step "1/9  BEFORE evidence — reset to golden, then shoot"
echo "  A visitor's drifted mid-session screen is not a fair baseline, so: reset first."
mkdir -p "$EVIDENCE" 2>/dev/null || true
BEFORE_BOX="$STAGE/before-bookworm.png"
AFTER_BOX="$STAGE/after-trixie.png"
BEFORE_LOCAL="$EVIDENCE/before-bookworm.png"
AFTER_LOCAL="$EVIDENCE/after-trixie.png"

box_sh "labctl reset + shot -> $BEFORE_BOX" "$(
  cat <<'EOS'
set -eu
tile=$1 out=$2
mkdir -p "$(dirname "$out")"
labctl reset "$tile" || echo "note: labctl reset failed (no golden?); shooting live state" >&2
sleep 12
labctl shot "$tile" "$out"
EOS
)" "$TILE" "$BEFORE_BOX" || die "BEFORE shot failed; nothing has been touched yet" 1

if [ "$DRY" -eq 0 ]; then
  scp -q "$LAB:$BEFORE_BOX" "$BEFORE_LOCAL" 2>/dev/null &&
    log "BEFORE png: $BEFORE_LOCAL" || log "BEFORE png stayed on the box: $BEFORE_BOX"
fi

# --- 2. stop, 3. back up, 4. clear the stale host key ----------------------
step "2/9  stop $UNIT"
box_sh "systemctl stop $UNIT + settle QEMU by pidfile" "$(
  cat <<'EOS'
set -u
d=$1 unit=$2
systemctl stop "$unit"
if [ -f "$d/qemu.pid" ]; then
  pid=$(cat "$d/qemu.pid" 2>/dev/null || true)
  case "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" in
    *qemu-system-*) kill "$pid" 2>/dev/null; for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break; sleep 1; done ;;
  esac
fi
systemctl is-active --quiet "$unit" && { echo "$unit still active" >&2; exit 1; }
exit 0
EOS
)" "$D" "$UNIT" || die "could not stop $UNIT" 1

step "3/9  back up the bookworm overlay (never deleted)"
DEST="$BAK"
[ "${P[bak]:-no}" = yes ] && DEST="$FAILED"
box_sh "mv $OVERLAY -> $DEST" "$(
  cat <<'EOS'
set -eu
src=$1 dest=$2
[ -e "$dest" ] && { echo "refusing to overwrite $dest" >&2; exit 1; }
mv "$src" "$dest"
ls -l "$dest"
EOS
)" "$OVERLAY" "$DEST" || die "backup failed — the overlay is untouched" 1

step "4/9  clear the stale SSH host key for port $SSH_PORT"
echo "  TRAP 1. The rebuilt overlay has NEW host keys, and StrictHostKeyChecking=no"
echo "  suppresses the UNKNOWN-key prompt, not the CHANGED-key refusal: every"
echo "  guest() call in the builder then fails, disguised as a boot timeout."
box_sh "ssh-keygen -R [127.0.0.1]:$SSH_PORT" \
  "ssh-keygen -f /root/.ssh/known_hosts -R \"[127.0.0.1]:$SSH_PORT\" || true"

# --- 5. build --------------------------------------------------------------
step "5/9  build: BRIDGE_SUITE=trixie $BUILDER_REL --force"
echo "  Staged under $STAGE so the builder's own lib/bridge-base-for"
echo "  and the ledger resolve relatively. Log: $BUILD_LOG"

# Some builders read HOST-SIDE SIDECARS kept next to the station's launcher rather
# than in build-guests/: zx81.sh takes its readiness predicate and paced QMP
# typist from ../../../streamhost/tiles/zx81, as do win95/win311/indyr4400. Stage
# those too, or the builder dies 20 s in on `cd: .../streamhost/tiles/<tile>: No
# such file or directory` (zx81, 2026-08-10), which reads like a bad station.
LAUNCHER_SRC="$REPO/streamhost/tiles/$TILE"
STAGE_LAUNCHER=0
[ -d "$LAUNCHER_SRC" ] && STAGE_LAUNCHER=1

if [ "$DRY" -eq 1 ]; then
  printf '  [would] rsync -a --delete %s/scripts/build-guests/ %s:%s/scripts/build-guests/\n' \
    "$REPO" "$LAB" "$STAGE"
  printf '  [would] rsync -a %s %s:%s/registry/bridge-suites.json\n' "$LEDGER" "$LAB" "$STAGE"
  [ "$STAGE_LAUNCHER" -eq 1 ] &&
    printf '  [would] rsync -a %s/ %s:%s/streamhost/tiles/%s/   (host-side sidecars)\n' \
      "$LAUNCHER_SRC" "$LAB" "$STAGE" "$TILE"
  printf '  [would] ssh %s: cd %s && BRIDGE_SUITE=trixie setsid bash %s --force >%s 2>&1\n' \
    "$LAB" "$STAGE" "$BUILDER_REL" "$BUILD_LOG"
  printf '  [would] poll every 20s, printing new log lines, up to %ss\n' "$BUILD_TIMEOUT"
else
  # BOTH destination parents, because rsync creates only the LAST component of a
  # destination path: with only $STAGE/registry made here, the build-guests rsync
  # died on `mkdir "$STAGE/scripts/build-guests" failed: No such file or directory`
  # — after step 3 had already moved the live overlay aside, so every run ended in
  # a rollback that looked like a build failure.
  box_ro "mkdir -p $(printf '%q' "$STAGE")/registry $(printf '%q' "$STAGE")/scripts/build-guests $(printf '%q' "$STAGE")/streamhost/tiles" ||
    fail "cannot create the staging dir $STAGE"
  rsync -a --delete -e "ssh ${SSH_OPTS[*]}" \
    "$REPO/scripts/build-guests/" "$LAB:$STAGE/scripts/build-guests/" ||
    fail "staging rsync of build-guests failed"
  rsync -a -e "ssh ${SSH_OPTS[*]}" "$LEDGER" "$LAB:$STAGE/registry/bridge-suites.json" ||
    fail "staging rsync of the ledger failed"
  if [ "$STAGE_LAUNCHER" -eq 1 ]; then
    rsync -a -e "ssh ${SSH_OPTS[*]}" \
      "$LAUNCHER_SRC/" "$LAB:$STAGE/streamhost/tiles/$TILE/" ||
      fail "staging rsync of the host-side sidecars failed"
  fi

  log "launching the build (detached, logged)"
  box_build_start "$STAGE" "$BUILDER_REL" "$BUILD_LOG" "BRIDGE_SUITE=$TARGET_SUITE" ||
    fail "could not launch the build"

  log "polling (timeout ${BUILD_TIMEOUT}s) — builds run 5-40 min"
  box_build_wait "$BUILD_LOG" "$BUILD_TIMEOUT" ||
    fail "cannot read the build log on the box (log: $BUILD_LOG)"
  [ -n "$BOX_BUILD_RC" ] || fail "build did not finish within ${BUILD_TIMEOUT}s (log: $BUILD_LOG)"
  case "$BOX_BUILD_RC" in
    0) log "builder exited 0" ;;
    *[!0-9]*) fail "unparseable builder exit code '$BOX_BUILD_RC' (log: $BUILD_LOG)" ;;
    *) fail "builder exited $BOX_BUILD_RC (log: $BUILD_LOG)" ;;
  esac
fi

# --- 6. in-guest suite, while the builder's QEMU is still up ---------------
step "6/9  in-guest check: /etc/bridge/suite"
GUEST_SUITE=""
if [ "$DRY" -eq 1 ]; then
  printf '  [would] ssh -i %s -p %s root@127.0.0.1 cat /etc/bridge/suite  (expect: trixie)\n' \
    "$BRIDGE_KEY" "$SSH_PORT"
else
  GUEST_SUITE="$(box_ro "ssh -i $BRIDGE_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p $SSH_PORT root@127.0.0.1 'cat /etc/bridge/suite' 2>/dev/null" | tr -d '[:space:]')"
  [ "$GUEST_SUITE" = "$TARGET_SUITE" ] ||
    fail "the running guest reports /etc/bridge/suite='$GUEST_SUITE', expected '$TARGET_SUITE'"
  log "guest /etc/bridge/suite = $GUEST_SUITE"
fi

# --- 7. golden bake, if the builder did not do it -------------------------
step "7/9  golden snapshot"
echo "  TRAP 2. pdp11.sh/gt40.sh bake inside the build; atarist.sh only prints the"
echo "  commands and exits 0. So ask the overlay, and bake under the tile's OWN"
echo "  qemu-streamhost.sh if not — a golden baked against a different device set"
echo "  does not loadvm, and that surfaces at some visitor's first reset."
box_sh "stop the builder's QEMU, bake the golden if absent, prove loadvm" "$(
  cat <<'EOS'
set -u
d=$1 settle=$2
ov="$d/overlay.qcow2"
stop_qemu() {
  [ -f "$d/qemu.pid" ] || return 0
  pid=$(cat "$d/qemu.pid" 2>/dev/null || true)
  case "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" in
    *qemu-system-*) kill "$pid" 2>/dev/null
      for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done ;;
  esac
}
stop_qemu
if qemu-img snapshot -l "$ov" 2>/dev/null | grep -qw golden; then
  echo "golden snapshot already present (the builder baked it)"
  exit 0
fi
echo "no golden snapshot — baking under $d/qemu-streamhost.sh"
bash "$d/qemu-streamhost.sh" || { echo "launcher failed" >&2; exit 1; }
for _ in $(seq 1 30); do [ -S "$d/qmp.sock" ] && break; sleep 2; done
[ -S "$d/qmp.sock" ] || { echo "no qmp.sock after the launcher" >&2; exit 1; }
echo "settling ${settle}s before the bake (this frame IS what visitors reset to)"
sleep "$settle"
python3 /root/cdrv.py "$d/qmp.sock" dump /tmp/prebake.ppm >/dev/null 2>&1 &&
  convert /tmp/prebake.ppm "$d/evidence-prebake.png" 2>/dev/null &&
  echo "pre-bake frame: $d/evidence-prebake.png"
python3 /root/qmp_hmp.py "$d/qmp.sock" 'savevm golden' || exit 1
qemu-img snapshot -l "$ov" 2>/dev/null | grep -qw golden ||
  { echo "savevm golden left no snapshot" >&2; exit 1; }
python3 /root/qmp_hmp.py "$d/qmp.sock" 'loadvm golden' || exit 1
echo "golden baked and loadvm-verified"
stop_qemu
EOS
)" "$D" "$BAKE_SETTLE" || fail "golden bake / verification failed"

# --- 8. restart ------------------------------------------------------------
step "8/9  restart"
if [ "$RESTART" -eq 0 ]; then
  log "--no-restart: leaving $UNIT stopped (and skipping the AFTER shot)"
else
  box_sh "systemctl start $UNIT and prove it is up" "$(
    cat <<'EOS'
set -eu
unit=$1
systemctl start "$unit"
for _ in $(seq 1 20); do systemctl is-active --quiet "$unit" && break; sleep 2; done
systemctl is-active --quiet "$unit" || { systemctl status --no-pager -n 20 "$unit"; exit 1; }
echo "$unit active"
EOS
  )" "$UNIT" || fail "$UNIT did not come up after the migration"
fi

# --- 9. acceptance ---------------------------------------------------------
step "9/9  acceptance"
if [ "$DRY" -eq 0 ]; then
  BACKING="$(box_ro "qemu-img info -U --output=json $(printf '%q' "$OVERLAY") | python3 -c 'import json,sys; i=json.load(sys.stdin); print(i.get(\"full-backing-filename\") or i.get(\"backing-filename\") or \"\")'")"
  [ "$BACKING" = "$TRIXIE_BASE" ] ||
    fail "overlay backs onto '$BACKING', expected the trixie base '$TRIXIE_BASE'"
  log "backing file = $TRIXIE_BASE"
else
  printf '  [would] qemu-img info -U %s  (expect backing = %s)\n' "$OVERLAY" "$TRIXIE_BASE"
fi

if [ "$RESTART" -eq 1 ]; then
  box_sh "labctl shot -> $AFTER_BOX" \
    "labctl shot $(printf '%q %q' "$TILE" "$AFTER_BOX")" ||
    fail "AFTER shot failed"
  if [ "$DRY" -eq 0 ]; then
    scp -q "$LAB:$AFTER_BOX" "$AFTER_LOCAL" 2>/dev/null &&
      log "AFTER png: $AFTER_LOCAL" || log "AFTER png stayed on the box: $AFTER_BOX"
  fi
fi
assert_base_frozen "post-migration"

# --- ledger flip (opt-in) --------------------------------------------------
if [ "$FLIP" -eq 1 ]; then
  step "ledger: flipping $TILE to $TARGET_SUITE in registry/bridge-suites.json"
  if [ "$DRY" -eq 1 ]; then
    printf '  [would] set tiles.%s = "%s" in %s (one-line edit, formatting preserved)\n' \
      "$TILE" "$TARGET_SUITE" "registry/bridge-suites.json"
  else
    # LOCKED, because this is a read-modify-write of a file OTHER TILES SHARE.
    # migrate-wave.sh runs stations concurrently; two flips completing together
    # both read the pre-edit text and the second write drops the first station's
    # entry — one station's whole migration silently reverted, with both
    # invocations reporting success. Found by inspection on 2026-08-10 before it
    # bit anyone, because wave 3 was deliberately run WITHOUT --flip for exactly
    # this reason.
    #
    # The lock is held on the ledger's own inode, not a sidecar: python rewrites
    # the same path with open(path,"w"), which truncates in place rather than
    # replacing the inode, so a waiter blocked on this fd is still blocked on
    # the file it is about to read.
    exec 9<"$LEDGER" || die "cannot open $LEDGER for locking" 1
    flock -w 60 9 || die "another migrate-tile is holding the ledger lock (>60s)" 1
    python3 - "$LEDGER" "$TILE" "$TARGET_SUITE" <<'PY'
import re, sys
path, tile, suite = sys.argv[1:4]
src = open(path, encoding="utf-8").read()
pat = re.compile(r'^(\s*"%s":\s*)"[a-z]+"(,?)$' % re.escape(tile), re.M)
new, n = pat.subn(lambda m: '%s"%s"%s' % (m.group(1), suite, m.group(2)), src)
if n != 1:
    sys.exit("bridge-suites.json: expected exactly one tiles entry for %r, found %d" % (tile, n))
open(path, "w", encoding="utf-8").write(new)
print("  flipped %s -> %s" % (tile, suite))
PY
    FLIP_RC=$?
    exec 9<&-
    [ "$FLIP_RC" -eq 0 ] || die "ledger flip failed" 1
  fi
fi

# --- what a human still owes ----------------------------------------------
cat <<EOM

================================ HUMAN REQUIRED ================================
The MECHANICAL checks passed. This script does NOT and cannot claim visual
acceptance — a tile that renders black (the amiga/Mesa failure mode) looks
healthy in every log and every exit code above.

  BEFORE (bookworm golden):  ${BEFORE_LOCAL}
  AFTER  (trixie golden):    ${AFTER_LOCAL}

Open both and compare them. It is the machine's own screen that must match, not
a boot console and not a black frame. If the tile has audio, re-prove it
non-silent the way its original build did (docs/lab/BRIDGE-TRIXIE-MIGRATION.md
§2 step 4).

Still to do BY HAND, in the same commit as the ledger flip — these are prose and
judgement, so they are deliberately not automated:

  1. registry/tiles/$TILE.json -> .museum.notes         ("a captured Debian 12
     kiosk" is now wrong)
  2. registry/tiles/$TILE.json -> .render.museumBlock   (the pre-rendered TWIN of
     that same prose — edit both or the twin check fails)
  3. scripts/build-guests/tiles/$TILE.sh header, and the $TILE launcher comment,
     wherever either names bookworm / Debian 12
  4. docs/guests/$TILE.md
  5. make station-registry-generate     (never hand-edit a generated file)
  6. make station-registry-check && scripts/dev/bridge-suite-status.sh
EOM
if [ "$FLIP" -eq 1 ]; then
  printf '\nThe ledger entry is already flipped (--flip); commit it WITH 1-6 above.\n'
else
  printf '\nAnd the ledger itself, in that same commit: registry/bridge-suites.json\n'
  printf '  "%s": "trixie"     (--flip does this edit for you once the checks pass)\n' "$TILE"
fi
printf '\nThe bookworm overlay is kept at\n  %s\nIt is the rollback: delete it only once the tile has stayed accepted.\n' "$BAK"
[ "$DRY" -eq 1 ] && printf '\n(--dry-run: nothing above was executed.)\n'
exit 0
