#!/bin/bash
# chroot-guard.sh — HARD safety guard for chroot / rootfs API mounts
# (/proc, /sys, /dev, /dev/pts) and for tearing them down again.
#
# WHY THIS EXISTS (the incident it prevents — 2026-08-10)
#   The operator suddenly could not open a new interactive session:
#       ssh root@lab  ->  "PTY allocation failed"
#   Non-interactive `ssh lab '<cmd>'` still worked (no PTY needed) and every
#   session that already HELD a pty kept working, so nothing looked broken until
#   somebody logged in. Cause: devpts was no longer mounted on the HOST's
#   /dev/pts.
#
#   Nobody unmounted /dev/pts. A chroot rig did:
#       mount --rbind /dev  "$CHROOT/dev"     # ... work ...
#       umount "$CHROOT/dev/pts"
#   The host's /dev is `shared:2` propagation (see /proc/self/mountinfo). An
#   --rbind of a shared mount joins its peer group, so the copy's /dev/pts is a
#   PEER of the real /dev/pts — and unmount propagates to the peers of the
#   unmounted mount's PARENT. The chroot teardown therefore unmounted the host's
#   real /dev/pts. Recovery was one line:
#       mount -t devpts devpts /dev/pts -o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000
#
# WHAT THIS GUARANTEES (fail-CLOSED — non-zero exit + loud message on any doubt)
#   * a mount target must be strictly INSIDE the chroot root, and the root
#     itself must live under a sanctioned sandbox prefix — never /, /dev, /proc,
#     /sys or any other host directory;
#   * every API mount is made RECURSIVELY PRIVATE the instant it is created, so
#     a later umount inside the chroot tree cannot propagate back to the host;
#   * teardown is derived from /proc/self/mountinfo, is idempotent, unmounts
#     deepest-first, re-asserts privacy before each umount, and can only ever
#     name paths under the chroot root — a bare `umount /dev/pts` is
#     unreachable by construction.
#
# DUAL USE
#   * source it:  . "$(dirname "$0")/../../lib/chroot-guard.sh"
#                 -> chroot_guard_* functions (RETURN non-zero on refusal)
#   * run it CLI: chroot-guard <subcommand> …    -> exits non-zero on refusal
#       chroot-guard assert-root  <root>              # sandbox-confined root
#       chroot-guard assert-under <root> <path>       # path strictly inside it
#       chroot-guard mount-api    <root>              # proc+sys+dev, rprivate
#       chroot-guard umount-all   <root>              # guarded teardown
#       chroot-guard run-private  <cmd> [args…]       # private mount namespace
#
#   The strongest form is `run-private` (or chroot_guard_reexec_private in a
#   script): inside a private mount namespace an escaping umount is structurally
#   impossible, and the kernel tears every mount down when the last process
#   exits. Use it for ad-hoc chroot work on the box:
#       chroot-guard run-private bash        # then mount/chroot freely
#
# SOURCE OF TRUTH: scripts/lib/chroot-guard.sh in the kernel-hive repo. Repo
# scripts source it by relative path, so a box copy is OPTIONAL — but the
# ad-hoc/CLI use above wants one; if installed, /usr/local/bin/chroot-guard is
# kept byte-identical (scripts/README.md box-sync pairs), exactly like
# clone-guard.

# ---- configuration --------------------------------------------------------
# Space-separated prefixes a chroot root may live under. Override ONLY to point
# at a different sandbox; the point is that a "root" can never be a host dir.
CHROOT_GUARD_ALLOWED_ROOTS="${CHROOT_GUARD_ALLOWED_ROOTS:-/data/vms/soltest /data/vms/chroots /var/tmp /tmp}"

# ---- logging --------------------------------------------------------------
_chg_err() { printf 'chroot-guard: REFUSED: %s\n' "$*" >&2; }
_chg_warn() { printf 'chroot-guard: WARN: %s\n' "$*" >&2; }
_chg_info() { printf 'chroot-guard: %s\n' "$*" >&2; }

# _chg_norm <path> — canonicalise without requiring existence.
_chg_norm() {
  realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"
}

# ---- public: root assertion ------------------------------------------------
# chroot_guard_assert_root <root> — the root must be absolute, must normalise to
# something strictly inside one of CHROOT_GUARD_ALLOWED_ROOTS, and must not be
# one of those prefixes itself. Everything else in this file builds on it, so a
# host path can never become a mount target.
chroot_guard_assert_root() {
  local raw="$1" root ok=0 prefix
  if [ -z "$raw" ]; then
    _chg_err "chroot root is empty"
    return 2
  fi
  case "$raw" in
    /*) : ;;
    *)
      _chg_err "chroot root '$raw' is not absolute"
      return 2
      ;;
  esac
  root="$(_chg_norm "$raw")"
  if [ "$root" = "/" ]; then
    _chg_err "chroot root resolves to / — refusing"
    return 3
  fi
  for prefix in $CHROOT_GUARD_ALLOWED_ROOTS; do
    prefix="$(_chg_norm "$prefix")"
    case "$root" in
      "$prefix"/?*) ok=1 ;;
    esac
  done
  if [ "$ok" -ne 1 ]; then
    _chg_err "chroot root '$root' is not inside a sanctioned sandbox prefix ($CHROOT_GUARD_ALLOWED_ROOTS). A chroot/rootfs tree must live in the sandbox, never in a host directory."
    return 3
  fi
  return 0
}

# chroot_guard_assert_under <root> <path> [what] — <path> must be the root
# itself or strictly below it. This is the assertion that makes a stray
# `umount /dev/pts` unreachable.
chroot_guard_assert_under() {
  local rawroot="$1" rawpath="$2" what="${3:-path}" root p
  chroot_guard_assert_root "$rawroot" || return $?
  if [ -z "$rawpath" ]; then
    _chg_err "$what is empty"
    return 2
  fi
  root="$(_chg_norm "$rawroot")"
  p="$(_chg_norm "$rawpath")"
  case "$p" in
    "$root" | "$root"/?*) return 0 ;;
  esac
  _chg_err "$what '$p' is NOT inside the chroot root $root/ — refusing. (This is the guard that stops a chroot teardown from touching the host's /dev, /dev/pts, /proc or /sys.)"
  return 4
}

# ---- public: private mount namespace --------------------------------------
# chroot_guard_reexec_private "$@" — re-execute the CALLING SCRIPT inside a
# private mount namespace, once. Call it near the top of a script whose whole
# job is chroot work: after it returns, no mount the script makes is visible to
# the host and none of its unmounts can propagate out. The kernel also reaps
# every mount when the script exits, however it exits.
chroot_guard_reexec_private() {
  local self="${CHROOT_GUARD_SELF:-$0}"
  [ "${CHROOT_GUARD_PRIVATE_NS:-0}" = 1 ] && return 0
  if ! command -v unshare >/dev/null 2>&1; then
    _chg_err "unshare(1) not found — cannot enter a private mount namespace (install util-linux)"
    return 5
  fi
  if [ "$(id -u)" -ne 0 ]; then
    _chg_err "a private mount namespace needs root (unshare --mount)"
    return 5
  fi
  _chg_info "re-executing in a private mount namespace: $self"
  export CHROOT_GUARD_PRIVATE_NS=1
  # Run through $BASH rather than relying on the script's exec bit.
  exec unshare --mount --propagation private -- "${BASH:-/bin/bash}" "$self" "$@"
}

# chroot_guard_run_private <cmd> [args…] — run one command in a private mount
# namespace (the ad-hoc/CLI form of the above).
chroot_guard_run_private() {
  [ $# -ge 1 ] || {
    _chg_err "run-private needs a command"
    return 2
  }
  if ! command -v unshare >/dev/null 2>&1; then
    _chg_err "unshare(1) not found (install util-linux)"
    return 5
  fi
  CHROOT_GUARD_PRIVATE_NS=1 unshare --mount --propagation private -- "$@"
}

# ---- public: mount / umount ------------------------------------------------
# _chg_make_private <mountpoint> — recursively detach a subtree from its
# propagation peer group. THE load-bearing line of this whole file.
_chg_make_private() {
  mount --make-rprivate "$1" 2>/dev/null
}

# chroot_guard_mount_api <root> — mount /proc, /sys and /dev into the chroot and
# make each subtree recursively private IMMEDIATELY. A mount whose privacy
# cannot be established is a hard failure: it is left in place and named, rather
# than unmounted blindly (unmounting a still-shared copy is the incident).
chroot_guard_mount_api() {
  local root src tgt name
  chroot_guard_assert_root "$1" || return $?
  root="$(_chg_norm "$1")"
  [ -d "$root" ] || {
    _chg_err "chroot root '$root' is not a directory"
    return 2
  }
  for name in proc sys dev; do
    src="/$name"
    tgt="$root/$name"
    chroot_guard_assert_under "$root" "$tgt" "mount target" || return $?
    mkdir -p "$tgt"
    if mountpoint -q "$tgt" 2>/dev/null; then
      _chg_info "$tgt already mounted — re-asserting private propagation"
      _chg_make_private "$tgt" || {
        _chg_err "cannot make $tgt private; refusing to proceed"
        return 6
      }
      continue
    fi
    mount --rbind "$src" "$tgt" || {
      _chg_err "mount --rbind $src $tgt failed"
      return 6
    }
    if ! _chg_make_private "$tgt"; then
      _chg_err "mounted $tgt but could NOT make it private — it is still a propagation peer of the host's $src, so any umount under it would unmount the HOST's $src subtree (this is exactly the 2026-08-10 /dev/pts incident). Leaving it mounted; investigate before touching it."
      return 6
    fi
  done
  return 0
}

# _chg_mountpoints_under <root> — mountpoints from /proc/self/mountinfo that are
# <root> itself or below it, shallowest first. Handles the octal escaping the
# kernel applies to spaces/tabs/newlines/backslashes in mount paths.
_chg_mountpoints_under() {
  local root="$1"
  awk -v root="$root" '
    {
      mp = $5
      gsub(/\\040/, " ", mp); gsub(/\\011/, "\t", mp)
      gsub(/\\012/, "\n", mp); gsub(/\\134/, "\\", mp)
      if (mp == root || index(mp, root "/") == 1) print mp
    }
  ' /proc/self/mountinfo | awk '{ print gsub(/\//, "/"), $0 }' | sort -n -k1,1 | cut -d" " -f2-
}

# chroot_guard_umount_all <root> — the ONLY sanctioned teardown. Every path it
# can name comes from mountinfo AND is re-asserted to be under <root>; each is
# made recursively private BEFORE it is unmounted, and unmounts run
# deepest-first with `umount -R`. Idempotent: no mounts is success. Returns
# non-zero if anything under <root> survives.
chroot_guard_umount_all() {
  local root mps mp rc=0 left
  chroot_guard_assert_root "$1" || return $?
  root="$(_chg_norm "$1")"
  mps="$(_chg_mountpoints_under "$root")"
  [ -n "$mps" ] || return 0
  # pass 1, shallowest first: detach the whole subtree from every peer group, so
  # neither the unmounts below nor their parents can propagate to the host.
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    chroot_guard_assert_under "$root" "$mp" "mountpoint" || return $?
    _chg_make_private "$mp" || _chg_warn "could not make $mp private"
  done <<<"$mps"
  # pass 2, deepest first: unmount.
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    chroot_guard_assert_under "$root" "$mp" "mountpoint" || return $?
    mountpoint -q "$mp" 2>/dev/null || continue
    if ! umount -R "$mp" 2>/dev/null; then
      _chg_warn "umount -R $mp busy — retrying lazily"
      umount -R -l "$mp" 2>/dev/null || _chg_warn "could not unmount $mp"
    fi
  done < <(printf '%s\n' "$mps" | tac)
  left="$(_chg_mountpoints_under "$root")"
  if [ -n "$left" ]; then
    _chg_err "mounts still present under $root after teardown:"
    while IFS= read -r mp; do [ -z "$mp" ] || printf '  %s\n' "$mp" >&2; done <<<"$left"
    rc=7
  fi
  return "$rc"
}

# ---- CLI dispatch ----------------------------------------------------------
_chroot_guard_cli() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    assert-root) chroot_guard_assert_root "$@" ;;
    assert-under) chroot_guard_assert_under "$@" ;;
    mount-api) chroot_guard_mount_api "$@" ;;
    umount-all) chroot_guard_umount_all "$@" ;;
    run-private) chroot_guard_run_private "$@" ;;
    '' | -h | --help | help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0
      ;;
    *)
      _chg_err "unknown subcommand '$cmd' (see: chroot-guard --help)"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _chroot_guard_cli "$@"
  exit $?
fi
