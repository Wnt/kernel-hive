#!/usr/bin/env bash
# build-deploy.sh — build streamhost on the lab box and deploy it safely.
#
# Ordinary (legacy-unit) operation:
#   build-deploy.sh                 release build + restart helenos only
#   build-deploy.sh <tile> [...]    release build + restart named tile(s)
#   build-deploy.sh --all           release build + restart every live tile
#   build-deploy.sh --fast          dev-fast iteration build; never installs/restarts
#   build-deploy.sh --check         release cargo check; never installs/restarts
#   build-deploy.sh --no-restart    release build only
#
# Versioned operation (after migrate-to-versioned.sh has been supervised):
#   build-deploy.sh --canary <tile> build/install streamhost-<gitsha>, switch one tile
#   build-deploy.sh --promote       promote the verified canary in bounded waves
#   build-deploy.sh --rollback <tile>
#                                    atomically swap that tile to its previous binary
#
# Flags:
#   --wave-size N       promotion wave size (default: 4)
#   -n, --dry-run       print the complete plan; make no changes
#   -h, --help          show this help
#
# --changed-only was removed: a streamhost source change has no meaningful
# per-tile mapping. Use an explicit tile, --canary, or --all.
#
# Guardrails:
#   * a bare deploy targets SAFE_TILE (helenos), never the fleet;
#   * --fast is build-only so a development binary never occupies the legacy
#     shared release path;
#   * one remote flock covers mirror/build/install/restart operations;
#   * destructive source mirroring requires streamhost/.last-harvest and an
#     exact match to its harvested source-tree digest;
#   * only streamhost@ units are restarted; QEMU/VM units are never targeted.
set -euo pipefail

LAB="${LAB:-lab}"
SAFE_TILE="${SAFE_TILE:-helenos}"
LOCK_WAIT_SECS="${LOCK_WAIT_SECS:-30}"
WAVE_SIZE=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="${REPO_SRC:-${SCRIPT_DIR}/../../streamhost/streamhost/src/}"
BOX_BUILD="/data/vms/streamhost/build"
BOX_MEMBER="${BOX_BUILD}/streamhost"
BOX_SRC="${BOX_MEMBER}/src"
BOX_MARKER="${BOX_MEMBER}/.last-harvest"
BOX_LOCK="/data/vms/streamhost/.build-deploy.lock"
BOX_TARGET="${BOX_BUILD}/target"
INSTALL_ROOT="/usr/local/lib/streamhost"
CANARY_GATE="${INSTALL_ROOT}/.canary-ready"

RESTART_ALL=0
NO_RESTART=0
CHECK_ONLY=0
FAST=0
DRY_RUN=0
CANARY_TILE=""
PROMOTE=0
ROLLBACK_TILE=""
declare -a TILES=()
declare -a LIVE=()
declare -a TARGET=()

c_red() { printf '\033[31m%s\033[0m' "$*"; }
c_grn() { printf '\033[32m%s\033[0m' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    [%s] %s\n' "$(c_grn OK)" "$*"; }
warn() { printf '    [%s] %s\n' "$(c_ylw WARN)" "$*"; }
die() {
  printf '    [%s] %s\n' "$(c_red FAIL)" "$*" >&2
  exit 1
}

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

valid_tile() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
valid_artifact() { [[ "$1" =~ ^streamhost-[0-9a-f]{40}$ ]]; }
positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) RESTART_ALL=1 ;;
    --changed-only) die "--changed-only was removed: choose a tile, --canary, or --all explicitly" ;;
    --no-restart) NO_RESTART=1 ;;
    --check) CHECK_ONLY=1 ;;
    --fast) FAST=1 ;;
    --canary)
      [ "$#" -ge 2 ] || die "--canary requires a tile"
      CANARY_TILE="$2"
      shift
      ;;
    --promote) PROMOTE=1 ;;
    --rollback)
      [ "$#" -ge 2 ] || die "--rollback requires a tile"
      ROLLBACK_TILE="$2"
      shift
      ;;
    --wave-size)
      [ "$#" -ge 2 ] || die "--wave-size requires a positive integer"
      WAVE_SIZE="$2"
      shift
      ;;
    -n | --dry-run) DRY_RUN=1 ;;
    -h | --help) usage ;;
    --*) die "unknown flag: $1 (see --help)" ;;
    *) TILES+=("$1") ;;
  esac
  shift
done

positive_integer "$WAVE_SIZE" || die "--wave-size must be a positive integer"
positive_integer "$LOCK_WAIT_SECS" || die "LOCK_WAIT_SECS must be a positive integer"
valid_tile "$SAFE_TILE" || die "invalid SAFE_TILE: $SAFE_TILE"
for t in "${TILES[@]}"; do valid_tile "$t" || die "invalid tile name: $t"; done
[ -z "$CANARY_TILE" ] || valid_tile "$CANARY_TILE" || die "invalid canary tile: $CANARY_TILE"
[ -z "$ROLLBACK_TILE" ] || valid_tile "$ROLLBACK_TILE" || die "invalid rollback tile: $ROLLBACK_TILE"

SPECIAL=0
[ -z "$CANARY_TILE" ] || SPECIAL=$((SPECIAL + 1))
[ "$PROMOTE" -eq 0 ] || SPECIAL=$((SPECIAL + 1))
[ -z "$ROLLBACK_TILE" ] || SPECIAL=$((SPECIAL + 1))
[ "$SPECIAL" -le 1 ] || die "--canary, --promote, and --rollback are mutually exclusive"
if [ "$SPECIAL" -eq 1 ]; then
  if [ "${#TILES[@]}" -ne 0 ] || [ "$RESTART_ALL" -ne 0 ]; then
    die "versioned actions cannot be combined with positional tiles or --all"
  fi
  if [ "$NO_RESTART" -ne 0 ] || [ "$CHECK_ONLY" -ne 0 ] || [ "$FAST" -ne 0 ]; then
    die "versioned actions cannot be combined with --no-restart, --check, or --fast"
  fi
fi
[ "$RESTART_ALL" -eq 0 ] || [ "${#TILES[@]}" -eq 0 ] ||
  die "positional tiles and --all are mutually exclusive"
if [ "$FAST" -eq 1 ]; then
  [ "$CHECK_ONLY" -eq 0 ] || die "choose either --fast or --check"
  if [ "$RESTART_ALL" -ne 0 ] || [ "${#TILES[@]}" -ne 0 ]; then
    die "--fast is build-only and does not accept deployment targets"
  fi
  NO_RESTART=1
fi
if [ "$CHECK_ONLY" -eq 1 ]; then NO_RESTART=1; fi

# ssh with retry for transient 255 (shared, loaded box).
ssh_lab() {
  local attempt rc
  for attempt in 1 2 3 4; do
    ssh -o ConnectTimeout=15 "$LAB" "$@" && return 0
    rc=$?
    if [ "$rc" -eq 255 ] && [ "$attempt" -lt 4 ]; then
      warn "ssh transient (255), retry ${attempt}/3 in $((attempt * 3))s ..." >&2
      sleep $((attempt * 3))
      continue
    fi
    return "$rc"
  done
}

LOCK_ACTIVE=0
LOCK_IN_FD=""
LOCK_PID=""

release_lock() {
  if [ "$LOCK_ACTIVE" -eq 1 ]; then
    exec {LOCK_IN_FD}>&-
    wait "$LOCK_PID" || true
    LOCK_ACTIVE=0
  fi
}
trap release_lock EXIT
trap 'release_lock; exit 130' INT TERM

acquire_lock() {
  [ "$DRY_RUN" -eq 0 ] || {
    ok "DRY-RUN would acquire flock ${BOX_LOCK}"
    return
  }
  step "acquire exclusive box build/deploy lock"
  coproc LAB_BUILD_LOCK {
    ssh -o ConnectTimeout=15 "$LAB" \
      "exec flock -w '${LOCK_WAIT_SECS}' '${BOX_LOCK}' sh -c 'printf \"LOCKED\\n\"; cat >/dev/null'"
  }
  LOCK_PID="$LAB_BUILD_LOCK_PID"
  LOCK_IN_FD="${LAB_BUILD_LOCK[1]}"
  local status=""
  if ! IFS= read -r status <&"${LAB_BUILD_LOCK[0]}" || [ "$status" != "LOCKED" ]; then
    wait "$LOCK_PID" || true
    die "could not acquire ${LAB}:${BOX_LOCK} within ${LOCK_WAIT_SECS}s"
  fi
  LOCK_ACTIVE=1
  ok "exclusive flock held"
}

enumerate_live() {
  mapfile -t LIVE < <(ssh_lab \
    "systemctl list-units --plain --no-legend 'streamhost@*.service' 2>/dev/null | awk '{print \$1}' | sed -E 's/^streamhost@(.*)\\.service$/\\1/'" | sort)
  [ "${#LIVE[@]}" -gt 0 ] || die "could not enumerate live streamhost@ tiles"
  ok "live tiles: ${#LIVE[@]} (${LIVE[*]})"
}

is_live() {
  local needle="$1" item
  for item in "${LIVE[@]}"; do [ "$item" != "$needle" ] || return 0; done
  return 1
}

resolve_targets() {
  step "resolve target tiles"
  enumerate_live
  if [ -n "$CANARY_TILE" ]; then
    is_live "$CANARY_TILE" || die "canary '$CANARY_TILE' is not live"
    TARGET=("$CANARY_TILE")
  elif [ -n "$ROLLBACK_TILE" ]; then
    is_live "$ROLLBACK_TILE" || die "rollback tile '$ROLLBACK_TILE' is not live"
    TARGET=("$ROLLBACK_TILE")
  elif [ "$RESTART_ALL" -eq 1 ]; then
    TARGET=("${LIVE[@]}")
  elif [ "${#TILES[@]}" -gt 0 ]; then
    for t in "${TILES[@]}"; do
      is_live "$t" || die "tile '$t' is not live (live: ${LIVE[*]})"
      TARGET+=("$t")
    done
  else
    is_live "$SAFE_TILE" || die "safe default tile '$SAFE_TILE' is not live"
    TARGET=("$SAFE_TILE")
  fi
  ok "target: ${#TARGET[@]} tile(s): ${TARGET[*]}"
}

check_harvest_guard() {
  step "verify last-harvest guard before destructive mirror"
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would require ${BOX_MARKER} and match its src_tree_md5 digest"
    return
  fi
  local out
  if out=$(ssh_lab "set -eu; marker='${BOX_MARKER}'; src='${BOX_SRC}'; [ -f \"\$marker\" ] || { echo MISSING_MARKER; exit 41; }; version=\$(sed -n 's/^version=//p' \"\$marker\"); expected=\$(sed -n 's/^src_tree_md5=//p' \"\$marker\"); [ \"\$version\" = 1 ] && printf '%s' \"\$expected\" | grep -Eq '^[0-9a-f]{32}$' || { echo INVALID_MARKER; exit 42; }; actual=\$(find \"\$src\" -type f -name '*.rs' -print0 | sort -z | xargs -0 -r md5sum | md5sum | awk '{print \$1}'); [ \"\$actual\" = \"\$expected\" ] || { printf 'DIGEST_MISMATCH expected=%s actual=%s\\n' \"\$expected\" \"\$actual\"; exit 43; }; echo CLEAN"); then
    ok "box source digest matches .last-harvest"
  elif [ "$out" = "MISSING_MARKER" ]; then
    die "${LAB}:${BOX_MARKER} is missing; harvest the box before allowing rsync --delete-after"
  else
    die "box source changed since last harvest (${out:-invalid marker}); harvest it before mirroring"
  fi
}

sync_workspace() {
  step "mirror streamhost workspace -> ${LAB}:${BOX_BUILD}"
  [ -d "$REPO_SRC" ] || die "repo src not found: $REPO_SRC"
  REPO_CRATE="$(cd "${REPO_SRC}/.." && pwd)"
  REPO_WORKSPACE="$(cd "${REPO_CRATE}/.." && pwd)"
  REPO_CONFIG="${REPO_WORKSPACE}/.cargo/config.toml"
  [ -f "$REPO_CONFIG" ] || die "Cargo config not found: $REPO_CONFIG"

  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would rsync src with --checksum --delete-after"
    ok "DRY-RUN would sync Cargo.toml, Cargo.lock, member manifest, and .cargo/config.toml"
    return
  fi

  ssh_lab "mkdir -p '${BOX_MEMBER}' '${BOX_BUILD}/.cargo'" || die "remote mkdir failed"
  rsync -a --checksum --delete-after --itemize-changes \
    -e "ssh -o ConnectTimeout=15" "$REPO_SRC" "${LAB}:${BOX_SRC}/" ||
    die "source rsync failed"
  rsync -a --checksum --itemize-changes -e "ssh -o ConnectTimeout=15" \
    "${REPO_WORKSPACE}/Cargo.toml" "${REPO_WORKSPACE}/Cargo.lock" "${LAB}:${BOX_BUILD}/" ||
    die "workspace manifest rsync failed"
  rsync -a --checksum --itemize-changes -e "ssh -o ConnectTimeout=15" \
    "${REPO_CRATE}/Cargo.toml" "${LAB}:${BOX_MEMBER}/Cargo.toml" ||
    die "member manifest rsync failed"
  rsync -a --checksum --itemize-changes -e "ssh -o ConnectTimeout=15" \
    "$REPO_CONFIG" "${LAB}:${BOX_BUILD}/.cargo/config.toml" ||
    die "Cargo config rsync failed"
  # The mirror just made the box source identical to the repo's, so the marker's
  # premise ("the box may hold changes the repo has not seen") is satisfied by
  # definition — re-stamp it. Without this the guard fires on the NEXT run of
  # this same script with DIGEST_MISMATCH though nothing was at risk: four manual
  # re-stamps in one session (2026-08-05), which teaches the next agent to
  # hand-edit a safety marker. Only reached AFTER the guard passed and the mirror
  # succeeded. SOURCE_SHA is set later by source_identity(), so read it here.
  local sha
  sha=$(git -C "$REPO_WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)
  ssh_lab "d=\$(find '${BOX_SRC}' -type f -name '*.rs' -print0 | sort -z | xargs -0 -r md5sum | md5sum | awk '{print \$1}');
    printf 'version=1\ngit_sha=%s\nharvested_at=%s\nsrc_tree_md5=%s\n' '${sha}' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$d\" > '${BOX_MARKER}'" ||
    die "could not re-stamp the harvest marker"
  ok "source, manifests, lockfile, and Cargo config synced (marker re-stamped)"
}

SOURCE_SHA=""
REPO_TOP=""
ARTIFACT_NAME=""
BUILD_ARTIFACT=""

source_identity() {
  [ -n "${REPO_WORKSPACE:-}" ] || {
    REPO_CRATE="$(cd "${REPO_SRC}/.." && pwd)"
    REPO_WORKSPACE="$(cd "${REPO_CRATE}/.." && pwd)"
  }
  REPO_TOP="$(git -C "$REPO_WORKSPACE" rev-parse --show-toplevel 2>/dev/null)" ||
    die "streamhost source is not in a git worktree"
  SOURCE_SHA="$(git -C "$REPO_TOP" rev-parse HEAD)"
  [[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve a full git SHA"
  ARTIFACT_NAME="streamhost-${SOURCE_SHA}"
}

require_clean_version_source() {
  [ "$DRY_RUN" -eq 1 ] && return
  git -C "$REPO_TOP" diff --quiet HEAD -- streamhost ||
    die "versioned deploy requires committed streamhost sources"
  [ -z "$(git -C "$REPO_TOP" ls-files --others --exclude-standard -- streamhost)" ] ||
    die "versioned deploy requires no untracked files under streamhost"
}

build_streamhost() {
  local cargo_desc cargo_cmd profile_dir
  if [ "$CHECK_ONLY" -eq 1 ]; then
    cargo_desc="cargo check --release"
    cargo_cmd="cargo check --release --bin streamhost"
    profile_dir="release"
  elif [ "$FAST" -eq 1 ]; then
    cargo_desc="cargo build --profile dev-fast"
    cargo_cmd="cargo build --profile dev-fast --bin streamhost"
    profile_dir="dev-fast"
  else
    cargo_desc="cargo build --release"
    cargo_cmd="cargo build --release --bin streamhost"
    profile_dir="release"
  fi
  BUILD_ARTIFACT="${BOX_TARGET}/${profile_dir}/streamhost"
  step "${cargo_desc} (nice -n 15; shared target + mold)"
  local build_sh="cd '${BOX_BUILD}' && CARGO_TARGET_DIR='${BOX_TARGET}' nice -n 15 ${cargo_cmd}"
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would run: ssh ${LAB} ${build_sh}"
  elif ssh_lab "$build_sh"; then
    ok "${cargo_desc} succeeded"
  else
    die "${cargo_desc} failed"
  fi
}

install_versioned_artifact() {
  step "install immutable ${ARTIFACT_NAME}"
  local dst="${INSTALL_ROOT}/${ARTIFACT_NAME}"
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would atomically install ${BUILD_ARTIFACT} -> ${dst}"
    return
  fi
  ssh_lab "set -eu; src='${BUILD_ARTIFACT}'; dst='${dst}'; [ -x \"\$src\" ]; install -d -m 0755 '${INSTALL_ROOT}'; if [ -e \"\$dst\" ]; then cmp -s \"\$src\" \"\$dst\" || { echo 'immutable SHA collision' >&2; exit 43; }; else tmp=\"\$dst.tmp.\$\$\"; install -m 0755 \"\$src\" \"\$tmp\"; mv -Tf \"\$tmp\" \"\$dst\"; fi" ||
    die "versioned artifact install failed"
  ok "installed ${dst}"
}

service_uses_versioned() {
  local tile="$1"
  ssh_lab "systemctl show -p ExecStart --value 'streamhost@${tile}.service'" |
    grep -Fq "path=${INSTALL_ROOT}/tiles/${tile}/current"
}

require_versioned_service() {
  local tile="$1"
  [ "$DRY_RUN" -eq 1 ] && return
  service_uses_versioned "$tile" ||
    die "streamhost@${tile} still uses the legacy ExecStart; run migrate-to-versioned.sh under supervision"
}

switch_tile() {
  local tile="$1" artifact="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN ${tile}: previous <- current; current -> ../../${artifact} (atomic rename)"
    printf '%s\n' "DRY_RUN_PREVIOUS"
    return
  fi
  ssh_lab "set -eu; d='${INSTALL_ROOT}/tiles/${tile}'; a='${INSTALL_ROOT}/${artifact}'; [ -x \"\$a\" ]; [ -L \"\$d/current\" ]; old=\$(readlink -f \"\$d/current\"); [ -x \"\$old\" ]; old_name=\$(basename \"\$old\"); ptmp=\"\$d/.previous.\$\$\"; ctmp=\"\$d/.current.\$\$\"; ln -s \"../../\$old_name\" \"\$ptmp\"; mv -Tf \"\$ptmp\" \"\$d/previous\"; ln -s '../../${artifact}' \"\$ctmp\"; mv -Tf \"\$ctmp\" \"\$d/current\"; printf '%s\\n' \"\$old_name\""
}

set_tile_links() {
  local tile="$1" current="$2" previous="$3"
  [ "$DRY_RUN" -eq 0 ] || return 0
  ssh_lab "set -eu; d='${INSTALL_ROOT}/tiles/${tile}'; [ -x '${INSTALL_ROOT}/${current}' ]; [ -x '${INSTALL_ROOT}/${previous}' ]; ctmp=\"\$d/.current.\$\$\"; ptmp=\"\$d/.previous.\$\$\"; ln -s '../../${current}' \"\$ctmp\"; mv -Tf \"\$ctmp\" \"\$d/current\"; ln -s '../../${previous}' \"\$ptmp\"; mv -Tf \"\$ptmp\" \"\$d/previous\""
}

readiness() {
  local tile="$1" out
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would require active streamhost@${tile} and its PID's 'LISTENING ... tile=${tile}' line"
    return
  fi
  if out=$(ssh_lab "set -u; t='${tile}'; for i in \$(seq 1 30); do active=\$(systemctl is-active \"streamhost@\$t.service\" 2>/dev/null || true); pid=\$(systemctl show -p MainPID --value \"streamhost@\$t.service\" 2>/dev/null || true); if [ \"\$active\" = active ] && [ \"\${pid:-0}\" -gt 0 ] 2>/dev/null; then line=\$(journalctl _PID=\"\$pid\" -n 120 --no-pager 2>/dev/null | grep -F 'LISTENING udp/' | grep -F \" tile=\$t \" | tail -1); if [ -n \"\$line\" ]; then printf '%s\\n' \"\$line\"; exit 0; fi; fi; sleep 1; done; exit 3"); then
    ok "streamhost@${tile} ready: $(printf '%s' "$out" | tail -1)"
  else
    return 1
  fi
}

restart_tiles() {
  local units="" t
  for t in "$@"; do units+=" streamhost@${t}.service"; done
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would run: systemctl restart${units}"
    for t in "$@"; do readiness "$t"; done
    return
  fi
  ssh_lab "systemctl restart${units}" || return 1
  for t in "$@"; do readiness "$t" || return 1; done
}

write_canary_gate() {
  local artifact="$1" tile="$2"
  [ "$DRY_RUN" -eq 0 ] || {
    ok "DRY-RUN would record verified canary: ${artifact} ${tile}"
    return
  }
  ssh_lab "set -eu; tmp='${CANARY_GATE}.tmp.\$\$'; umask 022; printf '%s %s\\n' '${artifact}' '${tile}' > \"\$tmp\"; mv -Tf \"\$tmp\" '${CANARY_GATE}'"
  ok "promotion gate recorded"
}

read_canary_gate() {
  local gate extra
  if gate=$(ssh_lab "[ -f '${CANARY_GATE}' ] && sed -n '1p' '${CANARY_GATE}'" 2>/dev/null); then
    read -r ARTIFACT_NAME CANARY_TILE extra <<<"$gate"
    if [ -n "${extra:-}" ] || ! valid_artifact "$ARTIFACT_NAME" || ! valid_tile "$CANARY_TILE"; then
      die "invalid canary gate on ${LAB}"
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    source_identity
    CANARY_TILE="$SAFE_TILE"
    warn "no live canary gate; modeling promotion of ${ARTIFACT_NAME} from ${CANARY_TILE}"
  else
    die "no verified canary gate at ${LAB}:${CANARY_GATE}"
  fi
}

legacy_deploy() {
  local t
  for t in "${TARGET[@]}"; do
    if [ "$DRY_RUN" -eq 0 ] && service_uses_versioned "$t"; then
      die "streamhost@${t} is versioned; use --canary then --promote"
    fi
  done
  step "restart legacy target(s) and check daemon startup readiness"
  restart_tiles "${TARGET[@]}" || die "restart/readiness gate failed"
}

canary_deploy() {
  local tile="${TARGET[0]}" old
  require_versioned_service "$tile"
  step "atomically select canary artifact for ${tile}"
  if [ "$DRY_RUN" -eq 1 ]; then
    switch_tile "$tile" "$ARTIFACT_NAME"
    old="DRY_RUN_PREVIOUS"
  elif ! old=$(switch_tile "$tile" "$ARTIFACT_NAME"); then
    die "could not switch ${tile} to ${ARTIFACT_NAME}"
  fi
  step "restart canary and check startup readiness"
  if restart_tiles "$tile"; then
    write_canary_gate "$ARTIFACT_NAME" "$tile"
    ok "canary passed; framebuffer-verify ${tile}, then run --promote"
  else
    warn "canary failed; restoring ${old}"
    if [ "$DRY_RUN" -eq 0 ]; then
      set_tile_links "$tile" "$old" "$ARTIFACT_NAME" || true
      ssh_lab "systemctl restart 'streamhost@${tile}.service'" || true
    fi
    die "canary readiness failed and prior binary was restored"
  fi
}

promote_canary() {
  local t i end old failed
  declare -a promote_targets=() wave=() switched=()
  declare -A old_by_tile=()

  step "load verified canary gate"
  read_canary_gate
  enumerate_live
  is_live "$CANARY_TILE" || die "gated canary tile '$CANARY_TILE' is no longer live"
  for t in "${LIVE[@]}"; do [ "$t" = "$CANARY_TILE" ] || promote_targets+=("$t"); done
  [ "${#promote_targets[@]}" -gt 0 ] || die "no non-canary tiles to promote"

  if [ "$DRY_RUN" -eq 0 ]; then
    ssh_lab "test -x '${INSTALL_ROOT}/${ARTIFACT_NAME}'" || die "gated artifact is missing"
    [ "$(ssh_lab "basename \"\$(readlink -f '${INSTALL_ROOT}/tiles/${CANARY_TILE}/current')\"")" = "$ARTIFACT_NAME" ] ||
      die "canary tile no longer points at gated artifact"
  fi
  for t in "${promote_targets[@]}"; do require_versioned_service "$t"; done

  step "promote ${ARTIFACT_NAME} in waves of ${WAVE_SIZE}"
  for ((i = 0; i < ${#promote_targets[@]}; i += WAVE_SIZE)); do
    end=$((i + WAVE_SIZE))
    [ "$end" -le "${#promote_targets[@]}" ] || end="${#promote_targets[@]}"
    wave=("${promote_targets[@]:i:end-i}")
    switched=()
    failed=0
    printf '    wave %d: %s\n' "$((i / WAVE_SIZE + 1))" "${wave[*]}"
    for t in "${wave[@]}"; do
      if [ "$DRY_RUN" -eq 1 ]; then
        switch_tile "$t" "$ARTIFACT_NAME"
        old="DRY_RUN_PREVIOUS"
        old_by_tile["$t"]="$old"
        switched+=("$t")
      elif old=$(switch_tile "$t" "$ARTIFACT_NAME"); then
        old_by_tile["$t"]="$old"
        switched+=("$t")
      else
        failed=1
        break
      fi
    done
    if [ "$failed" -eq 0 ] && restart_tiles "${wave[@]}"; then
      ok "wave $((i / WAVE_SIZE + 1)) ready"
      continue
    fi
    warn "wave failed; restoring every switched tile in this wave"
    if [ "$DRY_RUN" -eq 0 ]; then
      for t in "${switched[@]}"; do
        set_tile_links "$t" "${old_by_tile[$t]}" "$ARTIFACT_NAME" || true
      done
      [ "${#switched[@]}" -eq 0 ] || restart_tiles "${switched[@]}" || true
    fi
    die "promotion stopped; earlier successful waves remain on the canary artifact"
  done
  if [ "$DRY_RUN" -eq 0 ]; then
    ssh_lab "mv -Tf '${CANARY_GATE}' '${INSTALL_ROOT}/.last-promoted'"
  fi
  ok "promotion complete; each tile's previous symlink retains N-1"
}

rollback_tile() {
  local tile="${TARGET[0]}" cur prev
  require_versioned_service "$tile"
  if [ "$DRY_RUN" -eq 1 ]; then
    step "rollback ${tile}"
    ok "DRY-RUN would atomically swap current and previous, restart, and require LISTENING readiness"
    return
  fi
  read -r cur prev < <(ssh_lab "d='${INSTALL_ROOT}/tiles/${tile}'; printf '%s %s\\n' \"\$(basename \"\$(readlink -f \"\$d/current\")\")\" \"\$(basename \"\$(readlink -f \"\$d/previous\")\")\"")
  if ! valid_artifact "$cur" || ! valid_artifact "$prev"; then
    die "invalid current/previous links for ${tile}"
  fi
  [ "$cur" != "$prev" ] || die "${tile} current and previous are identical; nothing to roll back"
  step "rollback ${tile}: ${cur} -> ${prev}"
  set_tile_links "$tile" "$prev" "$cur" || die "could not swap rollback links"
  if restart_tiles "$tile"; then
    ok "rollback complete; roll-forward target retained as previous"
  else
    warn "rollback target failed readiness; restoring ${cur}"
    set_tile_links "$tile" "$cur" "$prev" || true
    ssh_lab "systemctl restart 'streamhost@${tile}.service'" || true
    die "rollback target failed; original current link restored"
  fi
}

# Read-only target resolution happens even for dry-runs, proving the bare safe
# default against the actual live unit set.
if [ "$PROMOTE" -eq 0 ]; then resolve_targets; fi

if [ "$PROMOTE" -eq 1 ]; then
  acquire_lock
  promote_canary
  step "versioned promotion complete"
  exit 0
fi

if [ -n "$ROLLBACK_TILE" ]; then
  acquire_lock
  rollback_tile
  step "rollback complete"
  exit 0
fi

acquire_lock
check_harvest_guard
sync_workspace
source_identity
[ -z "$CANARY_TILE" ] || require_clean_version_source
build_streamhost

if [ "$CHECK_ONLY" -eq 1 ]; then
  step "done (--check: no artifact installed, nothing restarted)"
  exit 0
fi
if [ "$FAST" -eq 1 ]; then
  step "done (--fast: dev-fast artifact built for iteration; nothing installed/restarted)"
  exit 0
fi
if [ "$NO_RESTART" -eq 1 ]; then
  step "done (--no-restart: release built, nothing restarted)"
  exit 0
fi

if [ -n "$CANARY_TILE" ]; then
  install_versioned_artifact
  canary_deploy
  step "canary deploy complete"
else
  legacy_deploy
  step "legacy one-tile deploy complete"
fi
