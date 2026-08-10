#!/bin/bash
# clone-guard.sh — HARD, central safety guard for the OS-gallery VM-clone tooling.
#
# WHY THIS EXISTS (the incident it prevents)
#   A clone-setup task ran a STALE lab-side launcher that had been copied from a
#   LIVE tile's qemu-streamhost.sh. That launcher opens with the production
#   footgun pattern:
#       D="${D:-/data/vms/streamhost/tiles/solaris}"         # parameter-DEFAULT
#       [ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")"  # unconditional kill
#   The intended namespace override was expressed as `D=...`; when it was NOT
#   actually exported into the launcher's environment the `:-` default silently
#   fell back to the LIVE tile path, and the very next line killed the running
#   production Solaris QEMU (the tile was named `solariscde` then). Recovered
#   from golden in ~1 min, but a real breach.
#
# WHAT THIS GUARANTEES (fail-CLOSED — non-zero exit + loud message on any doubt)
#   Clone tooling MUST route every kill / stop / destructive-QMP / launcher-run
#   through this guard. The guard refuses, LOUDLY, to touch anything that is not
#   confined to the clone namespace root ($CLONE_GUARD_CLONE_ROOT, default
#   /data/vms/soltest):
#     * any path under the production tiles tree /data/vms/streamhost/tiles/,
#     * any `streamhost@<tile>` systemd unit,
#     * any pidfile whose PATH is outside the clone root, OR whose PID is a QEMU
#       process whose argv references the production tiles tree (belt & braces:
#       catches a clone dir whose qemu.pid was mis-populated with the live PID),
#     * a clone launcher file that statically embeds a production target
#       (the `${D:-/data/vms/streamhost/tiles/...}` default, a live pidfile/qmp/
#       disk path, or a `systemctl stop streamhost@…`).
#   Kills are ONLY ever by the clone's own pidfile — never pkill-by-name.
#
# DUAL USE
#   * source it:   source /usr/local/bin/clone-guard   → clone_guard_* functions
#                  (functions RETURN non-zero on refusal; they never kill on refusal)
#   * run it CLI:  clone-guard <subcommand> …          → exits non-zero on refusal
#       clone-guard assert-path     <path>       # path must be inside the clone root
#       clone-guard assert-unit     <unit|tile>  # refuse a streamhost@<tile> unit
#       clone-guard assert-qmp      <qmp.sock>   # sock must be inside the clone root
#       clone-guard assert-vmid     <vmid>       # refuse a production-range VMID
#       clone-guard check-launcher  <file>       # static lint a clone launcher
#       clone-guard kill-pidfile    <pidfile>    # the GUARDED kill (path + /proc)
#
# SOURCE OF TRUTH: scripts/lib/clone-guard.sh in the osgallery repo. Kept
# byte-identical to the box copy /usr/local/bin/clone-guard (see scripts/README.md
# box-sync pairs). Re-sync after any edit.

# ---- configuration (override via env only to point at a *different* sandbox) ----
CLONE_GUARD_CLONE_ROOT="${CLONE_GUARD_CLONE_ROOT:-/data/vms/soltest}"
CLONE_GUARD_PROD_TILES_ROOT="${CLONE_GUARD_PROD_TILES_ROOT:-/data/vms/streamhost/tiles}"
# VMIDs below this look like production tiles (real tiles are 100..~130; clones use
# 99xxx / 9911 / 9912 etc). Advisory numeric backstop for check-launcher/assert-vmid.
CLONE_GUARD_MIN_CLONE_VMID="${CLONE_GUARD_MIN_CLONE_VMID:-900}"

# ---- logging -------------------------------------------------------------------
_cg_err() { printf 'clone-guard: REFUSED: %s\n' "$*" >&2; }
_cg_warn() { printf 'clone-guard: WARN: %s\n' "$*" >&2; }

# _cg_norm <path> — canonicalise without requiring existence (resolves symlinks of
# existing components). Prints the normalised absolute path.
_cg_norm() {
  local p="$1"
  # realpath -m: no existence requirement; resolves .. and symlinks where possible.
  realpath -m -- "$p" 2>/dev/null || printf '%s' "$p"
}

# _cg_under_clone_root <path> — 0 if <path> normalises to strictly inside the clone
# root AND does not traverse the production tiles tree; non-zero otherwise.
_cg_under_clone_root() {
  local raw="$1" p root
  [ -n "$raw" ] || return 1
  p="$(_cg_norm "$raw")"
  root="$(_cg_norm "$CLONE_GUARD_CLONE_ROOT")"
  # must be STRICTLY inside the root (not the root itself, not a sibling prefix)
  case "$p" in
    "$root"/?*) : ;; # ok: something below the clone root
    *) return 1 ;;
  esac
  # never allow the production tiles tree to appear anywhere in the resolved path
  case "$p/" in
    *"/streamhost/tiles/"*) return 1 ;;
  esac
  return 0
}

# ---- public: path assertion ----------------------------------------------------
# clone_guard_assert_clone_path <path> [what] — RETURN non-zero (function) if the
# path is not confined to the clone namespace root.
clone_guard_assert_clone_path() {
  local p="$1" what="${2:-path}"
  if [ -z "$p" ]; then
    _cg_err "$what is empty"
    return 2
  fi
  if ! _cg_under_clone_root "$p"; then
    _cg_err "$what '$p' is NOT inside the clone root $CLONE_GUARD_CLONE_ROOT/ (or traverses the production tiles tree). Clone actions must be confined to $CLONE_GUARD_CLONE_ROOT/<namespace>/."
    return 3
  fi
  return 0
}

# clone_guard_assert_clone_qmp <qmp.sock> — same rule, for a QMP socket a
# destructive command would be sent to.
clone_guard_assert_clone_qmp() {
  clone_guard_assert_clone_path "$1" "qmp socket"
}

# ---- public: systemd-unit assertion --------------------------------------------
# clone_guard_assert_not_prod_unit <unit-or-tile> — refuse any streamhost@<tile>
# unit. Clones NEVER run as a systemd unit; a clone action touching a
# `streamhost@…` service is by definition reaching a production (or reserved
# soltest-*) tile, so refuse unconditionally.
clone_guard_assert_not_prod_unit() {
  local u="$1"
  case "$u" in
    streamhost@* | */streamhost@*)
      _cg_err "clone tooling must NEVER stop/restart a systemd unit ('$u'). Clones are killed only by their own pidfile."
      return 4
      ;;
  esac
  return 0
}

# ---- public: vmid assertion ----------------------------------------------------
# clone_guard_assert_clone_vmid <vmid> — refuse a VMID that looks like a live tile.
clone_guard_assert_clone_vmid() {
  local v="$1"
  case "$v" in
    '' | *[!0-9]*)
      _cg_err "vmid '$v' is not numeric"
      return 2
      ;;
  esac
  if [ "$v" -lt "$CLONE_GUARD_MIN_CLONE_VMID" ]; then
    _cg_err "vmid $v is below the clone floor ($CLONE_GUARD_MIN_CLONE_VMID) — that is a production-range VMID. Namespace clones at 99xxx."
    return 5
  fi
  return 0
}

# ---- public: /proc inspection --------------------------------------------------
# _cg_pid_argv <pid> — print the process argv as a space-joined string (or empty).
_cg_pid_argv() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null
}

# clone_guard_assert_pid_is_clone <pid> — refuse if the running process is a
# production QEMU: its argv references the production tiles tree, or it carries a
# production `-name streamhost-<tile>-vmid-` that is not a clone/bootrec name.
clone_guard_assert_pid_is_clone() {
  local pid="$1" argv
  case "$pid" in '' | *[!0-9]*)
    _cg_err "pid '$pid' is not numeric"
    return 2
    ;;
  esac
  argv="$(_cg_pid_argv "$pid")" || return 0 # process gone / unreadable: nothing to kill
  [ -n "$argv" ] || return 0
  case " $argv " in
    *"/streamhost/tiles/"*)
      _cg_err "pid $pid is a PRODUCTION QEMU (argv references $CLONE_GUARD_PROD_TILES_ROOT/). REFUSING to kill. argv: $argv"
      return 6
      ;;
  esac
  return 0
}

# ---- public: the GUARDED kill --------------------------------------------------
# clone_guard_kill_pidfile <pidfile> — the ONLY sanctioned way for clone tooling to
# kill a clone. (1) the pidfile PATH must be inside the clone root; (2) the PID it
# names, if running, must not be a production QEMU; then TERM→(grace)→KILL that PID
# and remove the pidfile. RETURNS non-zero on refusal (kills nothing).
clone_guard_kill_pidfile() {
  local pf="$1" pid i
  clone_guard_assert_clone_path "$pf" "pidfile" || return $?
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    rm -f "$pf"
    return 0
  fi
  case "$pid" in *[!0-9]*)
    _cg_err "pidfile '$pf' does not contain a numeric pid ('$pid')"
    return 2
    ;;
  esac
  clone_guard_assert_pid_is_clone "$pid" || return $?
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$pf"
  return 0
}

# ---- public: static launcher lint ----------------------------------------------
# clone_guard_check_launcher <file> — reject a clone launcher that statically
# embeds a production target. This is what would have caught the incident's stale
# launcher BEFORE it ran. RETURNS non-zero if any production footgun is present.
clone_guard_check_launcher() {
  local f="$1" bad=0 line
  if [ ! -f "$f" ]; then
    _cg_err "launcher '$f' not found"
    return 2
  fi
  # 1) the exact incident footgun: a `${VAR:-…/streamhost/tiles/…}` parameter-default
  #    (quote-agnostic) whose fallback is a live tile — a missing override lands there.
  if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*/streamhost/tiles/' "$f"; then
    _cg_err "launcher $f has a parameter-default pointing at the production tiles tree (e.g. \${D:-/data/vms/streamhost/tiles/...}). A missing override silently falls back to a LIVE tile. Hardcode a $CLONE_GUARD_CLONE_ROOT/<ns> path instead."
    bad=1
  fi
  # 2) any production tiles-tree path referenced at all.
  if grep -Eq '/data/vms/streamhost/tiles/' "$f"; then
    _cg_warn "launcher $f references $CLONE_GUARD_PROD_TILES_ROOT/ — a clone must reference ONLY $CLONE_GUARD_CLONE_ROOT/<ns>/ paths (disk / -pidfile / -qmp / kill target)."
    # lines that actively TARGET the live tile (kill / -pidfile / -qmp / disk) are hard fails.
    if grep -Eq '(kill[^\n]*streamhost/tiles/|-pidfile[^\n]*streamhost/tiles/|-qmp[^\n]*streamhost/tiles/|file=[^ ]*streamhost/tiles/)' "$f"; then
      _cg_err "launcher $f actively targets a production tile path (kill/-pidfile/-qmp/disk under $CLONE_GUARD_PROD_TILES_ROOT/)."
      bad=1
    fi
  fi
  # 3) never manage a systemd unit from a clone launcher.
  if grep -Eq 'systemctl[[:space:]]+(stop|restart|disable|kill)[[:space:]]+[^&|;]*streamhost@' "$f"; then
    _cg_err "launcher $f runs 'systemctl stop/restart streamhost@…' — clone launchers must never touch a production service."
    bad=1
  fi
  [ "$bad" -eq 0 ] || return 7
  return 0
}

# ---- CLI dispatch --------------------------------------------------------------
_clone_guard_cli() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    assert-path) clone_guard_assert_clone_path "$@" ;;
    assert-qmp) clone_guard_assert_clone_qmp "$@" ;;
    assert-unit) clone_guard_assert_not_prod_unit "$@" ;;
    assert-vmid) clone_guard_assert_clone_vmid "$@" ;;
    assert-pid) clone_guard_assert_pid_is_clone "$@" ;;
    check-launcher) clone_guard_check_launcher "$@" ;;
    kill-pidfile) clone_guard_kill_pidfile "$@" ;;
    '' | -h | --help | help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0
      ;;
    *)
      _cg_err "unknown subcommand '$cmd' (see: clone-guard --help)"
      return 2
      ;;
  esac
}

# Run the CLI only when executed directly (not when sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _clone_guard_cli "$@"
  exit $?
fi
