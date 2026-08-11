#!/usr/bin/env bash
# migrate-to-versioned.sh — one-time supervised streamhost ExecStart migration.
#
# This script is intentionally inert unless --apply or --stage-only is given.
# The normal --apply flow snapshots the already-built release binary as
# streamhost-<gitsha>, creates per-station current/previous links, installs the
# versioned systemd template, and restarts helenos first.  It then PAUSES for a
# human framebuffer/stream check before continuing in bounded waves.
#
# Usage:
#   migrate-to-versioned.sh                         plan only (no changes)
#   migrate-to-versioned.sh --stage-only /tmp/NAME rehearse the filesystem layout
#   migrate-to-versioned.sh --apply                 supervised live migration
#
# Options:
#   --git-sha SHA          version to install (default: this worktree's HEAD)
#   --wave-size N          post-canary restart wave size (default: 4)
#   --expected-count N     required live fleet size (default: 28)
#   --yes-after-canary     skip the interactive framebuffer confirmation
#   -h, --help             show this help
set -euo pipefail

LAB="${LAB:-lab}"
SAFE_TILE="${SAFE_TILE:-helenos}"
BOX_BUILD="/data/vms/streamhost/build"
BOX_BINARY="${BOX_BINARY:-${BOX_BUILD}/target/release/streamhost}"
INSTALL_ROOT="/usr/local/lib/streamhost"
LOCK_PATH="/data/vms/streamhost/.build-deploy.lock"
LEGACY_EXEC="${BOX_BINARY}"
VERSIONED_UNIT="/etc/systemd/system/streamhost@.service"
UNIT_BACKUP="/etc/systemd/system/streamhost@.service.pre-versioned"
WAVE_SIZE=4
EXPECTED_COUNT=28
APPLY=0
STAGE_ROOT=""
YES_AFTER_CANARY=0
SOURCE_SHA=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TOP="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
UNIT_SOURCE="${REPO_TOP}/streamhost/deploy/streamhost@.service"

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    [OK] %s\n' "$*"; }
warn() { printf '    [WARN] %s\n' "$*"; }
die() {
  printf '    [FAIL] %s\n' "$*" >&2
  exit 1
}
usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_tile() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --stage-only)
      [ "$#" -ge 2 ] || die "--stage-only requires a /tmp path"
      STAGE_ROOT="$2"
      shift
      ;;
    --git-sha)
      [ "$#" -ge 2 ] || die "--git-sha requires a full SHA"
      SOURCE_SHA="$2"
      shift
      ;;
    --wave-size)
      [ "$#" -ge 2 ] || die "--wave-size requires a value"
      WAVE_SIZE="$2"
      shift
      ;;
    --expected-count)
      [ "$#" -ge 2 ] || die "--expected-count requires a value"
      EXPECTED_COUNT="$2"
      shift
      ;;
    --yes-after-canary) YES_AFTER_CANARY=1 ;;
    -h | --help) usage ;;
    --*) die "unknown flag: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

[ "$APPLY" -eq 0 ] || [ -z "$STAGE_ROOT" ] || die "--apply and --stage-only are mutually exclusive"
positive_integer "$WAVE_SIZE" || die "--wave-size must be positive"
positive_integer "$EXPECTED_COUNT" || die "--expected-count must be positive"
valid_tile "$SAFE_TILE" || die "invalid SAFE_TILE"
if [ -z "$SOURCE_SHA" ]; then SOURCE_SHA="$(git -C "$REPO_TOP" rev-parse HEAD)"; fi
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "--git-sha must be a full 40-character lowercase SHA"
ARTIFACT="streamhost-${SOURCE_SHA}"
[ -f "$UNIT_SOURCE" ] || die "missing versioned unit source: $UNIT_SOURCE"
grep -Fq "ExecStart=${INSTALL_ROOT}/tiles/%i/current" "$UNIT_SOURCE" ||
  die "unit source does not use the versioned per-tile path"

mapfile -t LIVE < <(ssh -o ConnectTimeout=15 "$LAB" \
  "systemctl list-units --plain --no-legend 'streamhost@*.service' 2>/dev/null | awk '{print \$1}' | sed -E 's/^streamhost@(.*)\\.service$/\\1/'" | sort)
[ "${#LIVE[@]}" -eq "$EXPECTED_COUNT" ] ||
  die "expected ${EXPECTED_COUNT} live tiles, found ${#LIVE[@]} (${LIVE[*]})"
printf '%s\n' "${LIVE[@]}" | grep -qx "$SAFE_TILE" || die "safe canary ${SAFE_TILE} is not live"

declare -a ORDER=("$SAFE_TILE")
for t in "${LIVE[@]}"; do [ "$t" = "$SAFE_TILE" ] || ORDER+=("$t"); done

stage_layout() {
  local root="$1" t
  [[ "$root" =~ ^/tmp/streamhost-versioned-[a-zA-Z0-9._-]+$ ]] ||
    die "stage root must match /tmp/streamhost-versioned-NAME"
  step "rehearse versioned layout at ${LAB}:${root}"
  ssh -o ConnectTimeout=15 "$LAB" "set -eu; rm -rf '${root}'; install -d -m 0755 '${root}/tiles'; install -m 0755 '${BOX_BINARY}' '${root}/${ARTIFACT}'"
  for t in "${LIVE[@]}"; do
    ssh -o ConnectTimeout=15 "$LAB" "set -eu; d='${root}/tiles/${t}'; install -d -m 0755 \"\$d\"; ln -s '../../${ARTIFACT}' \"\$d/current\"; ln -s '../../${ARTIFACT}' \"\$d/previous\""
  done
  ssh -o ConnectTimeout=15 "$LAB" \
    "printf 'artifact: '; ls -l '${root}/${ARTIFACT}'; printf 'canary links: '; ls -l '${root}/tiles/${SAFE_TILE}/current' '${root}/tiles/${SAFE_TILE}/previous'; printf 'resolved current: '; readlink -f '${root}/tiles/${SAFE_TILE}/current'"
  ok "isolated layout staged; rollback is: current <- previous, previous <- old current"
}

if [ -n "$STAGE_ROOT" ]; then
  stage_layout "$STAGE_ROOT"
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  step "DRY-RUN: supervised versioned ExecStart migration"
  printf '    source binary: %s\n' "$BOX_BINARY"
  printf '    artifact:      %s/%s\n' "$INSTALL_ROOT" "$ARTIFACT"
  printf '    unit:          ExecStart=%s/tiles/%%i/current\n' "$INSTALL_ROOT"
  printf '    first restart: streamhost@%s.service, then PAUSE for framebuffer/stream verification\n' "$SAFE_TILE"
  printf '    later waves:   %s tiles at a time (%s total tiles)\n' "$WAVE_SIZE" "${#LIVE[@]}"
  printf '    rollback:      atomically swap tiles/<tile>/current and previous; restart that tile\n'
  printf '    no live files, symlinks, units, or processes were changed\n'
  exit 0
fi

git -C "$REPO_TOP" diff --quiet HEAD -- streamhost/deploy/streamhost@.service ||
  die "commit the versioned unit before live migration"
[ -z "$(git -C "$REPO_TOP" ls-files --others --exclude-standard -- streamhost/deploy)" ] ||
  die "untracked deployment files present"

LOCK_IN_FD=""
LOCK_PID=""
LOCK_ACTIVE=0
release_lock() {
  if [ "$LOCK_ACTIVE" -eq 1 ]; then
    exec {LOCK_IN_FD}>&-
    wait "$LOCK_PID" || true
    LOCK_ACTIVE=0
  fi
}
trap release_lock EXIT
trap 'release_lock; exit 130' INT TERM

step "acquire exclusive deployment flock"
coproc LAB_MIGRATION_LOCK {
  ssh -o ConnectTimeout=15 "$LAB" \
    "exec flock -w 30 '${LOCK_PATH}' sh -c 'printf \"LOCKED\\n\"; cat >/dev/null'"
}
LOCK_PID="$LAB_MIGRATION_LOCK_PID"
LOCK_IN_FD="${LAB_MIGRATION_LOCK[1]}"
status=""
if ! IFS= read -r status <&"${LAB_MIGRATION_LOCK[0]}" || [ "$status" != LOCKED ]; then
  wait "$LOCK_PID" || true
  die "could not acquire deployment lock"
fi
LOCK_ACTIVE=1
ok "exclusive flock held"

step "preflight legacy unit and release artifact"
ssh -o ConnectTimeout=15 "$LAB" "test -x '${BOX_BINARY}'" || die "legacy release binary is missing"
for t in "${LIVE[@]}"; do
  exec_line="$(ssh -o ConnectTimeout=15 "$LAB" "systemctl show -p ExecStart --value 'streamhost@${t}.service'")"
  printf '%s' "$exec_line" | grep -Fq "path=${LEGACY_EXEC}" ||
    die "streamhost@${t} is not on the expected legacy ExecStart"
done
ok "all ${#LIVE[@]} units still use the legacy path"

step "install immutable artifact and per-tile symlink layout"
ssh -o ConnectTimeout=15 "$LAB" "set -eu; dst='${INSTALL_ROOT}/${ARTIFACT}'; install -d -m 0755 '${INSTALL_ROOT}/tiles'; if [ -e \"\$dst\" ]; then cmp -s '${BOX_BINARY}' \"\$dst\"; else tmp=\"\$dst.tmp.\$\$\"; install -m 0755 '${BOX_BINARY}' \"\$tmp\"; mv -Tf \"\$tmp\" \"\$dst\"; fi"
for t in "${LIVE[@]}"; do
  ssh -o ConnectTimeout=15 "$LAB" "set -eu; d='${INSTALL_ROOT}/tiles/${t}'; install -d -m 0755 \"\$d\"; for link in current previous; do tmp=\"\$d/.\$link.\$\$\"; ln -s '../../${ARTIFACT}' \"\$tmp\"; mv -Tf \"\$tmp\" \"\$d/\$link\"; done"
done
ok "versioned filesystem layout ready (current=previous=${ARTIFACT})"

declare -a RESTARTED=()
restore_legacy_unit() {
  local i end units t
  warn "restoring legacy unit after migration failure"
  if ! ssh -o ConnectTimeout=15 "$LAB" \
    "test -f '${UNIT_BACKUP}' && install -m 0644 '${UNIT_BACKUP}' '${VERSIONED_UNIT}' && systemctl daemon-reload"; then
    warn "legacy unit backup was unavailable or could not be restored; manual intervention required"
    return 1
  fi
  # Return touched services to the legacy template in the same bounded waves;
  # a late failure must not turn recovery into an all-fleet restart.
  for ((i = 0; i < ${#RESTARTED[@]}; i += WAVE_SIZE)); do
    end=$((i + WAVE_SIZE))
    [ "$end" -le "${#RESTARTED[@]}" ] || end="${#RESTARTED[@]}"
    units=""
    for t in "${RESTARTED[@]:i:end-i}"; do units+=" streamhost@${t}.service"; done
    [ -z "$units" ] || ssh -o ConnectTimeout=15 "$LAB" "systemctl restart${units}" || true
  done
}

step "install versioned systemd template (running processes are not changed yet)"
REMOTE_UNIT_TMP="/tmp/streamhost@.service.migrate.$$"
rsync -a --checksum -e "ssh -o ConnectTimeout=15" "$UNIT_SOURCE" "${LAB}:${REMOTE_UNIT_TMP}"
if ! ssh -o ConnectTimeout=15 "$LAB" "set -eu; [ ! -e '${UNIT_BACKUP}' ] && cp -a '${VERSIONED_UNIT}' '${UNIT_BACKUP}' || true; install -m 0644 '${REMOTE_UNIT_TMP}' '${VERSIONED_UNIT}'; rm -f '${REMOTE_UNIT_TMP}'; systemctl daemon-reload"; then
  restore_legacy_unit || true
  die "could not install/reload the versioned unit; attempted legacy restore"
fi
ok "template installed; backup at ${UNIT_BACKUP}"

readiness() {
  local tile="$1" out
  out=$(ssh -o ConnectTimeout=15 "$LAB" "set -u; t='${tile}'; for i in \$(seq 1 30); do active=\$(systemctl is-active \"streamhost@\$t.service\" 2>/dev/null || true); pid=\$(systemctl show -p MainPID --value \"streamhost@\$t.service\"); if [ \"\$active\" = active ] && [ \"\${pid:-0}\" -gt 0 ] 2>/dev/null; then line=\$(journalctl _PID=\"\$pid\" -n 120 --no-pager | grep -F 'LISTENING udp/' | grep -F \" tile=\$t \" | tail -1); [ -z \"\$line\" ] || { printf '%s\\n' \"\$line\"; exit 0; }; fi; sleep 1; done; exit 3") || return 1
  ok "${tile}: $(printf '%s' "$out" | tail -1)"
}

step "restart the migration canary only"
if ssh -o ConnectTimeout=15 "$LAB" "systemctl restart 'streamhost@${SAFE_TILE}.service'" &&
  readiness "$SAFE_TILE"; then
  RESTARTED+=("$SAFE_TILE")
else
  restore_legacy_unit
  die "migration canary failed; legacy unit restored"
fi

if [ "$YES_AFTER_CANARY" -eq 0 ]; then
  printf '\nFramebuffer-verify %s now (QMP screenshot + real stream).\n' "$SAFE_TILE"
  printf 'Type PROMOTE to migrate the remaining %d tiles: ' "$((${#ORDER[@]} - 1))"
  if ! read -r confirmation </dev/tty; then
    restore_legacy_unit || true
    die "no interactive confirmation available; legacy unit restored"
  fi
  [ "$confirmation" = PROMOTE ] || {
    restore_legacy_unit
    die "operator declined promotion; legacy unit restored"
  }
else
  warn "--yes-after-canary supplied; continuing without the interactive framebuffer pause"
fi

step "restart remaining tiles in waves of ${WAVE_SIZE}"
for ((i = 1; i < ${#ORDER[@]}; i += WAVE_SIZE)); do
  end=$((i + WAVE_SIZE))
  [ "$end" -le "${#ORDER[@]}" ] || end="${#ORDER[@]}"
  wave=("${ORDER[@]:i:end-i}")
  units=""
  for t in "${wave[@]}"; do units+=" streamhost@${t}.service"; done
  printf '    wave %d: %s\n' "$(((i - 1) / WAVE_SIZE + 1))" "${wave[*]}"
  if ! ssh -o ConnectTimeout=15 "$LAB" "systemctl restart${units}"; then
    restore_legacy_unit
    die "wave restart failed; legacy unit restored"
  fi
  # Every unit in the wave has now consumed the new template. Track all of
  # them before readiness polling so the failure path returns the whole wave
  # to the backed-up legacy template, including a station that fails its gate.
  RESTARTED+=("${wave[@]}")
  for t in "${wave[@]}"; do
    if readiness "$t"; then
      :
    else
      restore_legacy_unit
      die "${t} failed readiness; legacy unit restored"
    fi
  done
done

step "migration complete"
ok "all ${#LIVE[@]} tiles now execute per-tile current symlinks"
ok "instant rollback: scripts/dev/build-deploy.sh --rollback <tile>"
